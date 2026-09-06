import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../identity/device_identity.dart';
import '../pairing/pairing_service.dart';
import '../store/trust_store.dart';
import 'frame.dart';
import 'protocol.dart';
import 'session.dart';

/// How long the machine half of the handshake gets.
///
/// This deliberately does not cover the pairing comparison: that waits on a
/// person reading two screens, and a timeout there would just make pairing fail
/// for slow users.
const Duration defaultHandshakeTimeout = Duration(seconds: 20);

/// A session that is authenticated but may still need the D-02 comparison.
class PendingSession {
  const PendingSession(this.session, {required this.needsPairing});

  final PeerSession session;
  final bool needsPairing;
}

/// The dialling half of the connection.
///
/// The dialler is the side that can pin at the TLS layer: it sees the
/// listener's certificate during the handshake and checks the fingerprint
/// itself (D-09). It then proves its own identity by signing the listener's
/// nonce.
class Dialler {
  /// Opens an authenticated session to [host]:[port].
  ///
  /// [expectFingerprint] is a fingerprint the caller already knows, from an
  /// mDNS TXT record or a QR code. When given it must match exactly, and a
  /// mismatch aborts before anything is sent.
  ///
  /// [confirmPairing] must be supplied when either side may still be unpaired.
  /// Without it an unknown peer is refused rather than silently trusted.
  static Future<PeerSession> connect({
    required String host,
    required int port,
    required DeviceIdentity identity,
    required TrustStore trustStore,
    String? expectFingerprint,
    SasConfirm? confirmPairing,
    Duration timeout = defaultHandshakeTimeout,
  }) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      context: SecurityContext(withTrustedRoots: false),
      // Every peer certificate here is self-signed and so always "bad" to the
      // TLS stack. Accepting hands us the certificate; the fingerprint check in
      // _authenticate is the actual trust decision, and it runs before a single
      // byte is written.
      onBadCertificate: (_) => true,
      supportedProtocols: const <String>[alpnProtocol],
      timeout: timeout,
    );

    PeerSession? session;
    try {
      final pending = await _authenticate(
        socket: socket,
        identity: identity,
        trustStore: trustStore,
        expectFingerprint: expectFingerprint,
        allowPairing: confirmPairing != null,
      ).timeout(timeout);
      session = pending.session;

      if (pending.needsPairing) {
        final confirm = confirmPairing;
        if (confirm == null) {
          await session.abort('this device is not paired with you');
          throw const HandshakeException(
            'the listener does not have us pinned; run pair first',
          );
        }
        await runPairing(
          session: session,
          identity: identity,
          trustStore: trustStore,
          confirmPairing: confirm,
        );
      }
      return session;
    } on Object {
      if (session != null) {
        await session.close();
      } else {
        socket.destroy();
      }
      rethrow;
    }
  }

  static Future<PendingSession> _authenticate({
    required SecureSocket socket,
    required DeviceIdentity identity,
    required TrustStore trustStore,
    required String? expectFingerprint,
    required bool allowPairing,
  }) async {
    final certificate = socket.peerCertificate;
    if (certificate == null) {
      throw const HandshakeException('listener presented no certificate');
    }
    final listenerFingerprint =
        DeviceIdentity.fingerprintOf(Uint8List.fromList(certificate.der));

    if (listenerFingerprint == identity.fingerprint) {
      throw const HandshakeException('refusing to connect to this device');
    }

    if (expectFingerprint != null &&
        !constantTimeEquals(expectFingerprint, listenerFingerprint)) {
      throw HandshakeException(
        'certificate does not match the expected fingerprint\n'
        '  expected: $expectFingerprint\n'
        '  got:      $listenerFingerprint',
      );
    }

    final listenerPinned = trustStore.isPinned(listenerFingerprint);
    if (!listenerPinned && !allowPairing) {
      throw HandshakeException(
        'listener $listenerFingerprint is not paired; run pair first',
      );
    }

    final reader = FrameReader(socket);
    final writer = FrameWriter(socket);

    final hello = await readExpected(reader, const <String>{msgHello});
    requireVersion(hello);

    final claimedFingerprint = hello.requireString('fp');
    if (!constantTimeEquals(claimedFingerprint, listenerFingerprint)) {
      // The certificate is authoritative. A disagreement means the peer is
      // confused or lying, and neither is worth continuing with.
      throw const HandshakeException(
        'listener fingerprint does not match its certificate',
      );
    }
    final listenerName = hello.requireString('name');
    final nonce = hello.requireBytes('nonce');
    if (nonce.length < 16) {
      throw const HandshakeException('listener nonce is too short');
    }

    final signature = identity.sign(
      authTranscript(
        nonce: nonce,
        listenerFingerprint: listenerFingerprint,
      ),
    );

    writer.writeHeader(<String, Object?>{
      't': msgAuth,
      'v': protocolVersion,
      'cert': base64.encode(identity.certificateDer),
      'name': identity.name,
      'sig': base64.encode(signature),
      // Whether we hold the listener's pin, so both ends reach the same
      // conclusion about whether pairing is needed.
      'pinned': listenerPinned,
    });
    await socket.flush();

    final authOk = await readExpected(reader, const <String>{msgAuthOk});
    requireVersion(authOk);
    final diallerPinned = authOk.header['pinned'] == true;

    return PendingSession(
      PeerSession(
        socket: socket,
        reader: reader,
        writer: writer,
        peerFingerprint: listenerFingerprint,
        peerName: listenerName,
        isDialler: true,
      ),
      needsPairing: !(listenerPinned && diallerPinned),
    );
  }
}
