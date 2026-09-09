import 'package:lsync_transport/lsync_transport.dart';
import 'package:test/test.dart';

ClipboardEntry _entry(String text) => ClipboardEntry(
      content: ClipboardContent.text(text),
      direction: ClipboardDirection.sent,
      origin: 'a' * 64,
    );

void main() {
  test('holds D-05s twenty and no more', () {
    final history = ClipboardHistory();
    for (var i = 0; i < 25; i++) {
      history.record(_entry('item $i'));
    }
    expect(history.length, ClipboardHistory.capacity);
    expect(ClipboardHistory.capacity, 20);
  });

  test('evicts the oldest, not the newest', () {
    final history = ClipboardHistory();
    for (var i = 0; i < 25; i++) {
      history.record(_entry('item $i'));
    }
    final texts = history.entries.map((e) => e.content.text).toList();
    expect(texts.first, 'item 24', reason: 'newest first');
    expect(texts.last, 'item 5', reason: 'items 0 to 4 must have been evicted');
    expect(texts, isNot(contains('item 4')));
  });

  test('clear empties it, which is what closing does (D-05)', () {
    final history = ClipboardHistory()..record(_entry('secret'));
    expect(history.isEmpty, isFalse);
    history.clear();
    expect(history.isEmpty, isTrue);
    expect(history.entries, isEmpty);
    expect(history.newest, isNull);
  });

  test('the returned list cannot be used to reach back into the history', () {
    // Handing out a mutable view would let a caller append past the cap, or
    // hold entries after clear().
    final history = ClipboardHistory()..record(_entry('one'));
    expect(() => history.entries.add(_entry('two')), throwsUnsupportedError);
  });

  test('records direction and origin, because both are needed to show it', () {
    final history = ClipboardHistory()
      ..record(ClipboardEntry(
        content: ClipboardContent.text('from the phone'),
        direction: ClipboardDirection.received,
        origin: 'b' * 64,
      ));
    expect(history.newest!.direction, ClipboardDirection.received);
    expect(history.newest!.origin, 'b' * 64);
  });
}
