import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../identity/device_identity.dart' show toHex;
import '../transport/frame.dart';
import '../transport/protocol.dart';
import '../transport/session.dart';
import 'bond.dart';
import 'clipboard_access.dart';
import 'history.dart';
import 'messages.dart';

/// Keeps one clipboard in step with the bonded partner's, over a session
/// somebody else owns.
///
/// **It is handed a live [PeerSession] and never reconnects one.** Reconnect
/// policy is entangled with vendor power management — MIUI kills background
/// services that stock Android would leave alone — and dragging that in here
/// would make the piece untestable off a handset. A dropped session ends this
/// object; the app builds another when it has a new one.
///
/// Frames are dispatched in rather than pulled: the caller owns the read loop,
/// because a session also carries file transfers, and two readers on one stream
/// would desynchronise it. [handleFrame] says whether it took the frame.
class ClipboardSync {
  ClipboardSync({
    required PeerSession session,
    required ClipboardAccess clipboard,
    required ClipboardBond bond,
    required String localFingerprint,
    ClipboardHistory? history,
    void Function(ClipboardRefusal refusal)? onRefused,
    void Function(Object error)? onError,
  })  : _session = session,
        _clipboard = clipboard,
        _bond = bond,
        _localFingerprint = localFingerprint,
        history = history ?? ClipboardHistory(),
        _onRefused = onRefused,
        _onError = onError;

  final PeerSession _session;
  final ClipboardAccess _clipboard;
  final ClipboardBond _bond;
  final String _localFingerprint;
  final void Function(ClipboardRefusal refusal)? _onRefused;
  final void Function(Object error)? _onError;

  /// The last twenty items, in memory (D-05). Cleared by [close].
  final ClipboardHistory history;

  StreamSubscription<ClipboardContent>? _subscription;
  bool _closed = false;

  /// The digest of the last content this engine applied locally or sent.
  ///
  /// This is D-11's loop prevention, amended. The original rule compared an
  /// incoming update against *the current clipboard*, which cannot be executed
  /// on the platform D-04 is about: reading the clipboard in the background is
  /// exactly what Android forbids. Comparing against what the engine last
  /// applied or sent needs no read at all, so it runs everywhere — and it also
  /// closes a race the original has, because after writing an incoming item the
  /// local watcher fires before any read would reflect it, and that echo would
  /// escape.
  String? _lastHash;

  /// Content copied but not yet sent. Depth one, deliberately.
  ///
  /// A clipboard has no backlog: it has a current value. So a newer copy
  /// replaces a waiting one rather than queueing behind it, and nothing
  /// accumulates while the partner is unreachable. Never persisted, and dropped
  /// by [close].
  ClipboardContent? _pending;
  bool _sending = false;

  ClipboardContent? get pending => _pending;

  /// Starts watching for local clipboard changes, where the platform allows it.
  ///
  /// A null [ClipboardAccess.changes] is the Android case (D-04) and not an
  /// error: sends come from [sendCurrent] on the notification tap instead.
  void start() {
    final changes = _clipboard.changes;
    if (changes == null) return;
    _subscription = changes.listen(
      _onLocalChange,
      onError: (Object error) => _onError?.call(error),
    );
  }

  /// Sends whatever is on the clipboard now. This is D-04's notification tap.
  ///
  /// Does nothing when the clipboard is empty, or holds what the partner
  /// already has, so a repeated tap is harmless.
  Future<void> sendCurrent() async {
    final content = await _clipboard.read();
    if (content == null) return;
    if (!_accept(content)) return;
    await _drain();
  }

  /// Handles one inbound frame, returning false when it is not a clipboard
  /// frame and the caller should deal with it.
  ///
  /// A refused update still has its body consumed. The reader will not skip
  /// past an unread body, so leaving one would desynchronise every frame after
  /// it — which would turn a refusal into a broken session.
  Future<bool> handleFrame(Frame frame) async {
    switch (frame.type) {
      case msgClipboardRefused:
        _onRefused?.call(ClipboardRefusal.fromFrame(frame));
        return true;
      case msgClipboardUpdate:
        await _handleUpdate(frame);
        return true;
      default:
        return false;
    }
  }

  Future<void> _handleUpdate(Frame frame) async {
    final ClipboardUpdate update;
    try {
      update = ClipboardUpdate.fromFrame(frame);
    } on ProtocolException {
      await _session.reader.discardBody();
      rethrow;
    }

    // Ordered cheapest first, and identity before content: there is no reason
    // to read a megabyte from a device that is not the partner.
    if (!_bond.isPartner(_session.peerFingerprint)) {
      return _refuse(
        ClipboardRefusal.notBonded,
        'this device is bonded elsewhere',
      );
    }
    // The header can claim any origin. The handshake proved exactly one (D-09,
    // D-14), and nothing here relays a clipboard on another device's behalf.
    if (!constantTimeEquals(update.origin, _session.peerFingerprint)) {
      return _refuse(
        ClipboardRefusal.originMismatch,
        'declared origin is not the authenticated peer',
      );
    }
    if (update.mime != clipboardTextMime) {
      return _refuse(
        ClipboardRefusal.unsupportedType,
        'this version carries $clipboardTextMime only',
      );
    }
    // The frame reader caps bodies at the same figure, so this is the second of
    // two independent checks rather than the only one. A peer's declared size
    // is not evidence.
    if (update.size > maxClipboardBytes) {
      return _refuse(
        ClipboardRefusal.tooLarge,
        '${update.size} bytes exceeds the $maxClipboardBytes byte limit',
      );
    }

    // Safe to buffer precisely because of the cap above.
    final builder = BytesBuilder(copy: false);
    await _session.reader.readBodyInto(builder.add);
    final body = builder.takeBytes();

    final actual = toHex(Uint8List.fromList(crypto.sha256.convert(body).bytes));
    if (!constantTimeEquals(actual, update.sha256)) {
      return _refuseWithoutBody(
        ClipboardRefusal.digestMismatch,
        'body does not hash to the declared digest',
      );
    }

    final String text;
    try {
      text = const Utf8Decoder().convert(body);
    } on FormatException {
      return _refuseWithoutBody(
        ClipboardRefusal.malformedContent,
        'body is not valid UTF-8',
      );
    }

    // D-11, amended. We already hold this: either we sent it, or we applied it
    // a moment ago and this is the echo coming back. Applying it again is what
    // makes A set B set A indefinitely.
    if (_lastHash == update.sha256) return;

    final content = ClipboardContent.text(text);
    _lastHash = content.sha256;
    await _clipboard.write(content);
    history.record(ClipboardEntry(
      content: content,
      direction: ClipboardDirection.received,
      origin: _session.peerFingerprint,
    ));
  }

  void _onLocalChange(ClipboardContent content) {
    if (!_accept(content)) return;
    unawaited(_drain());
  }

  /// Decides whether [content] enters the send path, and takes the slot if so.
  bool _accept(ClipboardContent content) {
    if (_closed) return false;
    // The echo of our own write. Without this the watcher turns every received
    // item straight back into a send.
    if (content.sha256 == _lastHash) return false;
    if (!content.isWithinLimit) {
      // Refused here rather than after a wasted round trip, and deliberately
      // not placed in the pending slot: oversized content is not something to
      // remember and retry, it is something that will never be sendable.
      _onError?.call(ClipboardException(
        'clipboard content of ${content.size} bytes exceeds the '
        '$maxClipboardBytes byte limit and was not sent',
      ));
      return false;
    }
    _lastHash = content.sha256;
    _pending = content;
    return true;
  }

  Future<void> _drain() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_pending != null && !_closed) {
        final content = _pending!;
        try {
          await _sendOne(content);
        } on Object catch (error) {
          // Keep it in the slot. Depth one means a newer copy supersedes it
          // rather than stacking behind it, so an unreachable partner costs at
          // most one remembered item.
          _onError?.call(error);
          return;
        }
        // Only clear it if nothing newer arrived while the send was in flight.
        if (identical(_pending, content)) _pending = null;
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> _sendOne(ClipboardContent content) async {
    _session.writer.writeWithBody(
      <String, Object?>{
        't': msgClipboardUpdate,
        'v': protocolVersion,
        'mime': content.mime,
        'sha256': content.sha256,
        'origin': _localFingerprint,
      },
      content.bytes,
    );
    await _session.socket.flush();
    history.record(ClipboardEntry(
      content: content,
      direction: ClipboardDirection.sent,
      origin: _localFingerprint,
    ));
  }

  /// Refuses an update whose body has not been read yet.
  Future<void> _refuse(String reason, String message) async {
    await _session.reader.discardBody();
    await _refuseWithoutBody(reason, message);
  }

  Future<void> _refuseWithoutBody(String reason, String message) async {
    try {
      await _session.send(<String, Object?>{
        't': msgClipboardRefused,
        'v': protocolVersion,
        'reason': reason,
        'message': message,
      });
    } on Object catch (error) {
      // Refusing is a courtesy to the other end; the local outcome — that
      // nothing was applied — has already happened.
      _onError?.call(error);
    }
  }

  /// Stops watching and clears the history (D-05).
  ///
  /// Does not close the session, which this object does not own.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    _pending = null;
    history.clear();
  }
}
