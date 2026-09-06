import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../transport/protocol.dart';

/// Number of digits shown to the user (D-02).
const int sasDigits = 6;

/// Derives the short authentication string both devices display during pairing
/// (D-02).
///
/// Both fingerprints go in, sorted so the two ends agree on order without
/// negotiating one, and the digits fall out of a hash of the pair. There is no
/// secret here and nothing is transmitted: each side computes the number from
/// what it already holds, and the user checks the two screens match.
///
/// An attacker terminating TLS in the middle holds a different certificate on
/// each side, so the two sides hash different pairs and display different
/// numbers. That is the whole mechanism.
String shortAuthenticationString(String fingerprintA, String fingerprintB) {
  if (fingerprintA == fingerprintB) {
    throw ArgumentError('a device cannot pair with itself');
  }
  final ordered = <String>[fingerprintA, fingerprintB]..sort();
  final digest = crypto.sha256
      .convert(utf8.encode('$sasLabel:${ordered[0]}:${ordered[1]}'));
  final value =
      ByteData.sublistView(Uint8List.fromList(digest.bytes)).getUint32(0);
  final modulus = 1000000; // 10^sasDigits
  return (value % modulus).toString().padLeft(sasDigits, '0');
}

/// Formats the digits for display, grouped in threes so they are easier to read
/// off a screen and compare.
String formatSas(String sas) =>
    '${sas.substring(0, 3)} ${sas.substring(3)}';
