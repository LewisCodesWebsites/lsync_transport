import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asymmetric/api.dart' show RSAPublicKey;

const int derInteger = 0x02;
const int derBitString = 0x03;
const int derSequence = 0x30;
const int derContextTag0 = 0xa0;

/// A tag-length-value read out of a DER buffer.
class DerValue {
  const DerValue(this.tag, this.buffer, this.start, this.end);

  final int tag;
  final Uint8List buffer;
  final int start;
  final int end;

  int get length => end - start;

  /// A reader positioned over this value's contents, for constructed types.
  DerReader get contents => DerReader(buffer, start, end);

  Uint8List get bytes => Uint8List.sublistView(buffer, start, end);

  /// DER INTEGERs here are always non-negative (moduli and exponents).
  BigInt get asInteger {
    if (tag != derInteger) throw const FormatException('DER: not an INTEGER');
    var value = BigInt.zero;
    for (var i = start; i < end; i++) {
      value = (value << 8) | BigInt.from(buffer[i]);
    }
    return value;
  }
}

/// A deliberately small DER reader.
///
/// This is the one place where bytes from an unauthenticated peer are parsed,
/// so it is hand-written and short enough to read in full rather than handed to
/// a general-purpose ASN.1 library. It handles only what an X.509 certificate
/// needs: definite lengths, low tag numbers, no indefinite encoding.
class DerReader {
  DerReader(this.buffer, [this.offset = 0, int? end])
      : end = end ?? buffer.length;

  final Uint8List buffer;
  final int end;
  int offset;

  bool get atEnd => offset >= end;

  DerValue read() {
    if (offset >= end) throw const FormatException('DER: truncated tag');
    final tag = buffer[offset++];
    if (tag & 0x1f == 0x1f) {
      throw const FormatException('DER: high tag numbers are not supported');
    }
    if (offset >= end) throw const FormatException('DER: truncated length');
    var length = buffer[offset++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4) {
        throw const FormatException('DER: unsupported length encoding');
      }
      if (offset + count > end) {
        throw const FormatException('DER: truncated long length');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | buffer[offset++];
      }
    }
    if (offset + length > end) {
      throw const FormatException('DER: value overruns its container');
    }
    final value = DerValue(tag, buffer, offset, offset + length);
    offset += length;
    return value;
  }
}

/// Pulls the RSA public key out of an X.509 certificate.
///
/// Needed because the listener verifies the dialler's signed nonce (D-09) and
/// therefore needs the dialler's public key, which arrives as a certificate.
///
///     Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
///     TBSCertificate ::= SEQUENCE { [0] version, serialNumber, signature,
///                                   issuer, validity, subject,
///                                   subjectPublicKeyInfo, ... }
RSAPublicKey rsaPublicKeyFromCertificate(Uint8List certificateDer) {
  final certificate = DerReader(certificateDer).read();
  if (certificate.tag != derSequence) {
    throw const FormatException('certificate: not a SEQUENCE');
  }
  final tbs = certificate.contents.read();
  if (tbs.tag != derSequence) {
    throw const FormatException('certificate: tbsCertificate is not a SEQUENCE');
  }

  final fields = tbs.contents;
  var field = fields.read();
  if (field.tag == derContextTag0) {
    field = fields.read(); // Skip the explicit version, if present.
  }
  if (field.tag != derInteger) {
    throw const FormatException('certificate: serialNumber missing');
  }
  // signature, issuer, validity, subject.
  for (var i = 0; i < 4; i++) {
    fields.read();
  }

  final spki = fields.read();
  if (spki.tag != derSequence) {
    throw const FormatException('certificate: subjectPublicKeyInfo missing');
  }
  final spkiFields = spki.contents;
  spkiFields.read(); // AlgorithmIdentifier.
  final keyBits = spkiFields.read();
  if (keyBits.tag != derBitString) {
    throw const FormatException('certificate: public key is not a BIT STRING');
  }
  if (keyBits.length < 2 || keyBits.buffer[keyBits.start] != 0) {
    throw const FormatException('certificate: public key has unused bits');
  }

  final keyDer =
      Uint8List.sublistView(keyBits.buffer, keyBits.start + 1, keyBits.end);
  final key = DerReader(keyDer).read();
  if (key.tag != derSequence) {
    throw const FormatException('certificate: RSAPublicKey is not a SEQUENCE');
  }
  final parts = key.contents;
  final modulus = parts.read().asInteger;
  final exponent = parts.read().asInteger;
  return RSAPublicKey(modulus, exponent);
}

/// Strips the armour from a PEM document.
Uint8List pemToDer(String pem) {
  final body = pem
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), '');
  if (body.isEmpty) throw const FormatException('PEM: no body');
  return base64.decode(body);
}
