import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../identity/device_identity.dart' show toHex;

/// The only content type carried in v1.
///
/// Images are deliberately absent rather than forgotten. They are cheap on the
/// wire — the body path that moves a 2 GB file would move a screenshot without
/// noticing — and expensive in the platform layer, which needs Android bitmap
/// to PNG, Windows `CF_DIB` against `CF_PNG`, and X11 target negotiation, none
/// of which belongs in a pure-Dart package. The type travels on every frame
/// from day one so adding `image/png` later is not a protocol break.
const String clipboardTextMime = 'text/plain';

/// Largest clipboard payload accepted, encoded.
///
/// Chosen to match D-10's frame body cap, because v1 sends clipboard content in
/// a single frame with no chunked path. Content above this is refused and
/// reported, never truncated: a clipboard that quietly delivers half a key or
/// half a command is worse than one that delivers nothing, because the user
/// cannot see it happened until they paste.
const int maxClipboardBytes = 1024 * 1024;

/// One clipboard item, in the form both ends agree on.
class ClipboardContent {
  ClipboardContent.text(this.text) : mime = clipboardTextMime;

  final String text;

  /// Reserved for a second content type. Always [clipboardTextMime] in v1.
  final String mime;

  /// The encoded content, which is what is hashed and what travels.
  late final Uint8List bytes = Uint8List.fromList(utf8.encode(text));

  /// Lowercase hex SHA-256 over [bytes], and the identity used for loop
  /// prevention (D-11).
  ///
  /// Over the content alone rather than the content plus its type, which is
  /// what D-11 says and what stays true if a second type is added: two
  /// different types cannot produce the same bytes anyway.
  late final String sha256 =
      toHex(Uint8List.fromList(crypto.sha256.convert(bytes).bytes));

  int get size => bytes.length;

  /// Whether this can be sent at all. Checked before it enters the send path,
  /// so oversized content never occupies the pending slot.
  bool get isWithinLimit => size <= maxClipboardBytes;
}

/// The OS clipboard, supplied by the app.
///
/// The pure-Dart package never touches a platform clipboard, the same way it
/// never resolves a config directory itself. Everything above this line is
/// testable with `dart test` and a fake.
///
/// The shape of this interface is where D-04's asymmetry lands. Writing is
/// always available. *Watching* is not: Android has blocked background
/// clipboard reads since Android 10, so an Android implementation returns null
/// from [changes] and the app drives sends from the notification tap instead,
/// through `ClipboardSync.sendCurrent`. Both routes produce identical frames —
/// the protocol is symmetric, only the trigger differs.
abstract interface class ClipboardAccess {
  /// The clipboard's current content, or null when it holds nothing this
  /// version can carry.
  Future<ClipboardContent?> read();

  /// Replaces the clipboard's content.
  Future<void> write(ClipboardContent content);

  /// Local clipboard changes, or null where the platform will not allow
  /// watching. A null stream is not an error; it selects the tap-driven path.
  Stream<ClipboardContent>? get changes;
}

class ClipboardException implements Exception {
  const ClipboardException(this.message);
  final String message;
  @override
  String toString() => 'ClipboardException: $message';
}
