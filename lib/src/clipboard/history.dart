import 'clipboard_access.dart';

/// Which way an entry travelled.
enum ClipboardDirection {
  /// Copied here and sent to the partner.
  sent,

  /// Arrived from the partner and written to this clipboard.
  received,
}

/// One item that actually moved.
///
/// Suppressed echoes are not entries: they are the same item arriving back, and
/// recording them would fill the history with duplicates of whatever was copied
/// last (D-11).
class ClipboardEntry {
  const ClipboardEntry({
    required this.content,
    required this.direction,
    required this.origin,
  });

  final ClipboardContent content;
  final ClipboardDirection direction;

  /// The device it came from (D-14). This device's own fingerprint for a
  /// [ClipboardDirection.sent] entry.
  final String origin;
}

/// The last twenty clipboard items, in memory only (D-05).
///
/// Never written to disk, and cleared when the session closes. People copy
/// passwords and one-time codes, so a persistent clipboard log would be a
/// high-value target for a low-value feature; keeping it in memory delivers the
/// useful part and keeps D-06's storage claim literally true.
class ClipboardHistory {
  /// D-05's twenty.
  static const int capacity = 20;

  /// Newest first, which is the order anything displaying it wants.
  final List<ClipboardEntry> _entries = <ClipboardEntry>[];

  List<ClipboardEntry> get entries => List<ClipboardEntry>.unmodifiable(_entries);

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  ClipboardEntry? get newest => _entries.isEmpty ? null : _entries.first;

  void record(ClipboardEntry entry) {
    _entries.insert(0, entry);
    if (_entries.length > capacity) {
      _entries.removeRange(capacity, _entries.length);
    }
  }

  /// Drops everything. Called when the sync closes, and safe to call directly
  /// if the app wants a clear-history control.
  void clear() => _entries.clear();
}
