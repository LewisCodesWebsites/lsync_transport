import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart' show CryptoUtils, X509Utils;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' as pc;

import 'der.dart';

/// PKCS#1 DigestInfo prefix for SHA-256, as pointycastle's RSASigner wants it.
const String _sha256DigestIdentifier = '0609608648016503040201';

/// How long a generated certificate is valid. It is pinned rather than chained
/// to a CA, so expiry buys nothing; ten years just avoids a surprise.
const int _certificateValidityDays = 3650;

/// This device's long-lived private key and self-signed certificate (D-09).
///
/// The fingerprint is also the device's identity (D-14): there is no separate
/// device ID anywhere in the protocol.
class DeviceIdentity {
  DeviceIdentity._({
    required this.name,
    required this.certificatePem,
    required this.privateKeyPem,
    required this.certificateDer,
    required pc.RSAPrivateKey privateKey,
  })  : _privateKey = privateKey,
        fingerprint = fingerprintOf(certificateDer);

  /// This device's display name, shown to the peer during pairing.
  final String name;

  final String certificatePem;
  final String privateKeyPem;
  final Uint8List certificateDer;

  /// Lowercase hex SHA-256 over the certificate DER. Identity, per D-14.
  final String fingerprint;

  final pc.RSAPrivateKey _privateKey;

  static String certificatePath(String configDir) =>
      p.join(configDir, 'device.crt.pem');

  static String privateKeyPath(String configDir) =>
      p.join(configDir, 'device.key.pem');

  /// Loads the key and certificate, generating them on first run.
  ///
  /// Key generation is CPU-bound and takes a moment. It happens once.
  static Future<DeviceIdentity> loadOrCreate({
    required String configDir,
    required String deviceName,
  }) async {
    final certificateFile = File(certificatePath(configDir));
    final keyFile = File(privateKeyPath(configDir));

    if (await certificateFile.exists() && await keyFile.exists()) {
      final certificatePem = await certificateFile.readAsString();
      final privateKeyPem = await keyFile.readAsString();
      return DeviceIdentity._(
        name: deviceName,
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
        certificateDer: pemToDer(certificatePem),
        privateKey: CryptoUtils.rsaPrivateKeyFromPem(privateKeyPem),
      );
    }

    await Directory(configDir).create(recursive: true);

    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = pair.privateKey as pc.RSAPrivateKey;
    final publicKey = pair.publicKey as pc.RSAPublicKey;

    // The subject is cosmetic. Nothing validates it: the dialler checks the
    // fingerprint (D-09) and the certificate is never chained to anything.
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'lsync', 'O': 'lsync'},
      privateKey,
      publicKey,
    );
    final certificatePem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      _certificateValidityDays,
    );
    final privateKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);

    await _writePrivate(keyFile, privateKeyPem);
    await certificateFile.writeAsString(certificatePem, flush: true);

    return DeviceIdentity._(
      name: deviceName,
      certificatePem: certificatePem,
      privateKeyPem: privateKeyPem,
      certificateDer: pemToDer(certificatePem),
      privateKey: privateKey,
    );
  }

  /// Signs [data] with the key behind this device's certificate. The listener
  /// uses this as proof of key possession (D-09).
  Uint8List sign(Uint8List data) {
    final signer = pc.RSASigner(pc.SHA256Digest(), _sha256DigestIdentifier)
      ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(_privateKey));
    return signer.generateSignature(data).bytes;
  }

  /// Lowercase hex SHA-256 over a certificate's DER encoding.
  static String fingerprintOf(Uint8List certificateDer) =>
      toHex(Uint8List.fromList(crypto.sha256.convert(certificateDer).bytes));

  /// Verifies a signature made by the key behind [certificateDer].
  static bool verify({
    required Uint8List certificateDer,
    required Uint8List data,
    required Uint8List signature,
  }) {
    final pc.RSAPublicKey publicKey;
    try {
      publicKey = rsaPublicKeyFromCertificate(certificateDer);
    } on FormatException {
      return false;
    }
    final signer = pc.RSASigner(pc.SHA256Digest(), _sha256DigestIdentifier)
      ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));
    try {
      return signer.verifySignature(data, pc.RSASignature(signature));
    } on ArgumentError {
      // pointycastle throws rather than returning false on a malformed
      // signature block. A malformed signature is a failed signature.
      return false;
    }
  }

  static Future<void> _writePrivate(File file, String contents) async {
    await file.writeAsString(contents, flush: true);
    if (!Platform.isWindows) {
      // Best effort: Dart has no portable chmod. On Windows the ACL inherited
      // from the user profile directory already restricts this.
      await Process.run('chmod', ['600', file.path]);
    }
  }
}

/// Cryptographically random bytes, for nonces and transfer IDs.
Uint8List randomBytes(int count) {
  final random = Random.secure();
  final bytes = Uint8List(count);
  for (var i = 0; i < count; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

String toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
