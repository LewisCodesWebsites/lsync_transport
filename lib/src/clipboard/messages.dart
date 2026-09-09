import '../transport/frame.dart';
import 'clipboard_access.dart';

final RegExp _lowercaseHex = RegExp(r'^[0-9a-f]+$');

/// What a clipboard frame declares before its body is read.
class ClipboardUpdate {
  const ClipboardUpdate({
    required this.mime,
    required this.sha256,
    required this.origin,
    required this.size,
  });

  /// Content type. Only [clipboardTextMime] is carried in v1; anything else is
  /// well-formed but unsupported, which is a refusal rather than a protocol
  /// error — a peer running a later version is not misbehaving.
  final String mime;

  /// Lowercase hex SHA-256 over the body, checked against the bytes that
  /// actually arrive.
  final String sha256;

  /// The device the content came from (D-14: the certificate fingerprint).
  ///
  /// Untrusted as declared. The receiver checks it against the fingerprint the
  /// handshake proved, because a header field can say anything and nothing in
  /// this design relays a clipboard on someone else's behalf.
  final String origin;

  /// Body length, in bytes.
  final int size;

  /// Structural validation only. Whether the content is *acceptable* — the
  /// right type, from the right peer, within the limit — is the engine's call,
  /// because each of those is a refusal with a reason rather than a broken
  /// frame.
  static ClipboardUpdate fromFrame(Frame frame) {
    final sha256 = frame.requireString('sha256');
    if (sha256.length != 64 || !_lowercaseHex.hasMatch(sha256)) {
      throw const ProtocolException('clipboard update has a malformed digest');
    }
    return ClipboardUpdate(
      mime: frame.requireString('mime'),
      sha256: sha256,
      origin: frame.requireString('origin'),
      // Taken from the frame rather than from a separate header field, so the
      // length the engine checks is the same one the reader will deliver.
      size: frame.bodyLength,
    );
  }
}

/// One update turned away, with a reason the other end can act on.
///
/// A refusal ends the update, not the session. The bond is decided locally
/// (D-03), so the common case — the peer no longer being the partner — is a
/// disagreement to report, not a fault.
class ClipboardRefusal {
  const ClipboardRefusal({required this.reason, required this.message});

  /// The peer is not this device's clipboard partner. Expected whenever a bond
  /// has been switched on one side, and the reason an explicit refusal exists
  /// at all.
  static const String notBonded = 'not-bonded';

  /// The declared origin is not the fingerprint the handshake proved.
  static const String originMismatch = 'origin-mismatch';

  /// A content type this version does not carry.
  static const String unsupportedType = 'unsupported-type';

  /// Above [maxClipboardBytes]. Refused whole; never truncated.
  static const String tooLarge = 'too-large';

  /// The body does not hash to what the header declared.
  static const String digestMismatch = 'digest-mismatch';

  /// The body is not the text its type claims.
  static const String malformedContent = 'malformed-content';

  final String reason;
  final String message;

  static ClipboardRefusal fromFrame(Frame frame) => ClipboardRefusal(
        reason: frame.requireString('reason'),
        message: switch (frame.header['message']) {
          final String message => message,
          _ => 'no detail given',
        },
      );

  @override
  String toString() => 'ClipboardRefusal($reason): $message';
}
