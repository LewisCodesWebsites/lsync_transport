import 'dart:async';

import 'package:lsync_transport/lsync_transport.dart';

/// An OS clipboard, minus the OS.
///
/// The important detail is that [write] fires [changes], because a real
/// clipboard does. Every platform notifies watchers when the clipboard is set,
/// including when this app is the one setting it — so applying a received item
/// produces a local change event that looks exactly like the user copying it.
/// That echo is the loop D-11 exists to stop, and a fake that stayed silent on
/// write would make the loop test pass without testing anything.
class FakeClipboard implements ClipboardAccess {
  FakeClipboard({this.watchable = true});

  /// False models Android, where there is no background read and therefore no
  /// change stream (D-04). Sends are driven by `sendCurrent` instead.
  final bool watchable;

  final StreamController<ClipboardContent> _changes =
      StreamController<ClipboardContent>.broadcast();

  /// Every write this clipboard received, oldest first.
  final List<ClipboardContent> writes = <ClipboardContent>[];

  ClipboardContent? current;

  @override
  Stream<ClipboardContent>? get changes => watchable ? _changes.stream : null;

  @override
  Future<ClipboardContent?> read() async => current;

  @override
  Future<void> write(ClipboardContent content) async {
    current = content;
    writes.add(content);
    if (watchable) _changes.add(content);
  }

  /// The user copying something on this device.
  ///
  /// Separate from [write] only in intent: both set the clipboard and notify.
  void copy(String text) {
    final content = ClipboardContent.text(text);
    current = content;
    if (watchable) _changes.add(content);
  }

  /// Sets the clipboard without notifying anyone, for the Android case where
  /// there is no watcher to notify.
  void setSilently(String text) => current = ClipboardContent.text(text);

  Future<void> dispose() => _changes.close();
}

/// Lets a test wait for something to happen on the far end without sleeping for
/// a fixed period, which would be slow when it works and flaky when it does not.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String describe = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $describe');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Waits for a stretch of quiet, to show that nothing *else* arrives.
///
/// A loop test needs both halves: that the item crossed once, and that it then
/// stopped. Only the first is provable by waiting for a condition.
Future<void> settle([
  Duration duration = const Duration(milliseconds: 300),
]) =>
    Future<void>.delayed(duration);
