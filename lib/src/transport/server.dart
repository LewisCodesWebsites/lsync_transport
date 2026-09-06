import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../identity/device_identity.dart';
import '../pairing/pairing_service.dart';
import '../store/trust_store.dart';
import 'client.dart' show PendingSession, defaultHandshakeTimeout;
import 'frame.dart';
import 'protocol.dart';
import 'session.dart';

/// Length of the challenge the listener asks the dialler to sign (D-09).
const int nonceBytes = 32;

/// The listening half of the connection.
///
/// The listener cannot pin at the TLS layer: without a CA there is no clean way
/// to have the TLS stack accept a self-signed client certificate and then hand
/// it back for a fingerprint check. So it authenticates the dialler one layer
/// up, by sending a nonce and checking the signature that comes back against
/// the certificate the dialler supplies (D-09). That is proof of key
/// possession rather than a claim, and it is safe here because the dialler has
/// already pinned this listener's certificate before sending anything.
class LsyncServer {
  LsyncServer._(
    this._server,
    this._identity,
    this._trustStore,
    this._confirmPairing,
    this._onSession,
    this._onError,
  );

  final SecureServerSocket _server;
  final DeviceIdentity _identity;
  final TrustStore _trustStore;
  final SasConfirm? _confirmPairing;
  final void Function(PeerSession session) _onSession;
  final void Function(Object error, StackTrace stack)? _onError;

  StreamSubscription<SecureSocket>? _subscription;

  int get port => _server.port;
  InternetAddress get address => _server.address;

  /// Binds and starts accepting.
  ///
  /// [confirmPairing] must be supplied for this listener to accept an unpaired
  /// dialler. Left null, an unknown dialler is refused: pairing is a mode the
  /// user opts into, not something a stranger on the LAN can start.
  ///
  /// Pass port 0 for an ephemeral port. Tests do; D-01's 4917 is the default.
  static Future<LsyncServer> bind({
    required DeviceIdentity identity,
    required TrustStore trustStore,
    required void Function(PeerSession session) onSession,
    InternetAddress? address,
    int port = defaultPort,
    SasConfirm? confirmPairing,
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));

    final server = await SecureServerSocket.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      context,
      supportedProtocols: const <String>[alpnProtocol],
    );

    final listener = LsyncServer._(
      server,
      identity,
      trustStore,
      confirmPairing,
      onSession,
      onError,
    );
    listener._subscription = server.listen(
      listener._accept,
      onError: (Object error, StackTrace stack) => onError?.call(error, stack),
    );
    return listener;
  }

  void _accept(SecureSocket socket) {
    unawaited(
      _handshake(socket).then(
        _onSession,
        onError: (Object error, StackTrace stack) {
          socket.destroy();
          _onError?.call(error, stack);
        },
      ),
    );
  }

  Future<PeerSession> _handshake(SecureSocket socket) async {
    PeerSession? session;
    try {
      final pending = await _authenticate(socket).timeout(
        defaultHandshakeTimeout,
      );
      session = pending.session;

      if (pending.needsPairing) {
        final confirmPairing = _confirmPairing;
        if (confirmPairing == null) {
          await session.abort('this device is not accepting new pairings');
          throw HandshakeException(
            'refused unpaired dialler ${session.peerFingerprint}',
          );
        }
        // Untimed: the comparison waits on a person, not on the network.
        await runPairing(
          session: session,
          identity: _identity,
          trustStore: _trustStore,
          confirmPairing: confirmPairing,
        );
      }
      return session;
    } on Object {
      if (session != null) await session.close();
      rethrow;
    }
  }

  Future<PendingSession> _authenticate(SecureSocket socket) async {
    final reader = FrameReader(socket);
    final writer = FrameWriter(socket);

    final nonce = randomBytes(nonceBytes);
    writer.writeHeader(<String, Object?>{
      't': msgHello,
      'v': protocolVersion,
      'fp': _identity.fingerprint,
      'name': _identity.name,
      'nonce': base64.encode(nonce),
    });
    await socket.flush();

    final auth = await readExpected(reader, const <String>{msgAuth});
    requireVersion(auth);

    final certificateDer = auth.requireBytes('cert');
    final diallerFingerprint = DeviceIdentity.fingerprintOf(certificateDer);
    if (diallerFingerprint == _identity.fingerprint) {
      throw const HandshakeException('dialler presented our own certificate');
    }

    final signatureValid = DeviceIdentity.verify(
      certificateDer: certificateDer,
      data: authTranscript(
        nonce: nonce,
        listenerFingerprint: _identity.fingerprint,
      ),
      signature: auth.requireBytes('sig'),
    );
    if (!signatureValid) {
      throw const HandshakeException(
        'dialler does not hold the key behind its certificate',
      );
    }

    final diallerName = auth.requireString('name');
    final diallerPinned = _trustStore.isPinned(diallerFingerprint);
    final listenerPinned = auth.header['pinned'] == true;

    writer.writeHeader(<String, Object?>{
      't': msgAuthOk,
      'v': protocolVersion,
      'pinned': diallerPinned,
    });
    await socket.flush();

    return PendingSession(
      PeerSession(
        socket: socket,
        reader: reader,
        writer: writer,
        peerFingerprint: diallerFingerprint,
        peerName: diallerName,
        isDialler: false,
      ),
      needsPairing: !(diallerPinned && listenerPinned),
    );
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _server.close();
  }
}
