import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../transport/frame.dart';
import '../transport/protocol.dart';

/// What the user is shown during pairing, and asked to compare against the
/// other device's screen (D-02).
class SasPrompt {
  const SasPrompt({
    required this.sas,
    required this.peerName,
    required this.peerFingerprint,
    required this.localFingerprint,
  });

  /// Six digits, identical on both devices unless someone is in the middle.
  final String sas;

  final String peerName;
  final String peerFingerprint;
  final String localFingerprint;
}

/// Asks the user whether the two displayed numbers match.
///
/// Returning false aborts the pairing and pins nothing on either side.
typedef SasConfirm = Future<bool> Function(SasPrompt prompt);

class HandshakeException implements Exception {
  const HandshakeException(this.message);
  final String message;
  @override
  String toString() => 'HandshakeException: $message';
}

/// An authenticated connection to a peer.
///
/// By the time this exists the dialler has pinned the listener's certificate at
/// the TLS layer and the listener has verified the dialler's signed nonce
/// (D-09), so [peerFingerprint] is proven on both sides.
class PeerSession {
  PeerSession({
    required this.socket,
    required this.reader,
    required this.writer,
    required this.peerFingerprint,
    required this.peerName,
    required this.isDialler,
  });

  final SecureSocket socket;
  final FrameReader reader;
  final FrameWriter writer;

  /// The peer's certificate fingerprint, which is also its device ID (D-14).
  final String peerFingerprint;

  final String peerName;

  /// True on the side that opened the connection.
  final bool isDialler;

  bool _closed = false;

  Future<void> send(Map<String, Object?> header) async {
    writer.writeHeader(header);
    await socket.flush();
  }

  /// Tells the peer why we are giving up, then closes. Best effort: if the
  /// connection is already gone there is nothing to report.
  Future<void> abort(String message) async {
    try {
      await send(<String, Object?>{'t': msgError, 'message': message});
    } on Object {
      // The peer is unreachable; closing is all that is left.
    }
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await reader.cancel();
    } on Object {
      // Already torn down.
    }
    socket.destroy();
  }
}

/// Reads the next frame, turning a peer-sent error frame into an exception so
/// callers do not each have to check for one.
Future<Frame> readExpected(FrameReader reader, Set<String> allowed) async {
  final frame = await reader.readFrame();
  if (frame == null) {
    throw const HandshakeException('peer closed the connection');
  }
  final type = frame.type;
  if (type == msgError) {
    final message = frame.header['message'];
    throw HandshakeException(
      'peer aborted: ${message is String ? message : 'no reason given'}',
    );
  }
  if (!allowed.contains(type)) {
    throw HandshakeException(
      'expected one of ${allowed.join(', ')} but got "$type"',
    );
  }
  return frame;
}

/// The bytes the dialler signs to prove possession of the key behind its
/// certificate (D-09).
///
/// The listener's fingerprint is included so the signature is only good for the
/// listener that issued the nonce.
Uint8List authTranscript({
  required Uint8List nonce,
  required String listenerFingerprint,
}) {
  final builder = BytesBuilder(copy: false)
    ..add(utf8.encode(authTranscriptLabel))
    ..add(nonce)
    ..add(utf8.encode(listenerFingerprint));
  return builder.toBytes();
}

/// Constant-time comparison, so a fingerprint check cannot be walked byte by
/// byte with timing. These are public values, but the habit is cheap.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

/// Rejects a peer speaking a different protocol version rather than trying to
/// interpret its frames.
void requireVersion(Frame frame) {
  final version = frame.header['v'];
  if (version != protocolVersion) {
    throw HandshakeException(
      'peer speaks protocol version $version, we speak $protocolVersion',
    );
  }
}
