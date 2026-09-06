import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

/// Pull-based reader over a byte stream.
///
/// Everything in the framing layer needs "give me exactly N bytes" over a
/// socket that delivers arbitrary chunks. Built on [StreamIterator] so reads
/// are demand-driven: the socket is only pumped when a frame is being decoded,
/// which is what applies backpressure to the sender.
///
/// [pipeExact] hands out views into the underlying chunk rather than copying,
/// so a file body never accumulates in memory (D-10).
class ByteReader {
  ByteReader(Stream<List<int>> stream)
      : _iterator = StreamIterator<List<int>>(stream);

  final StreamIterator<List<int>> _iterator;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;

  /// Ensures at least one byte is buffered. False means end of stream.
  Future<bool> _fill() async {
    while (_offset >= _chunk.length) {
      if (!await _iterator.moveNext()) return false;
      final current = _iterator.current;
      _chunk = current is Uint8List ? current : Uint8List.fromList(current);
      _offset = 0;
    }
    return true;
  }

  /// Reads exactly [count] bytes, or returns null at a clean end of stream.
  ///
  /// Throws if the stream ends part way through, which is a truncated frame
  /// rather than a closed connection.
  Future<Uint8List?> tryReadExact(int count) async {
    if (count == 0) return Uint8List(0);
    if (!await _fill()) return null;
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (!await _fill()) {
        throw const EndOfStreamException('stream ended mid-frame');
      }
      final take = math.min(count - written, _chunk.length - _offset);
      out.setRange(written, written + take, _chunk, _offset);
      _offset += take;
      written += take;
    }
    return out;
  }

  Future<Uint8List> readExact(int count) async {
    final bytes = await tryReadExact(count);
    if (bytes == null) {
      throw const EndOfStreamException('stream ended before expected bytes');
    }
    return bytes;
  }

  /// Streams exactly [count] bytes to [sink] without buffering the whole run.
  ///
  /// [sink] receives views into the reader's current chunk. It must copy or
  /// consume them before returning; awaiting inside it is fine, the view stays
  /// valid until the next read.
  Future<void> pipeExact(
    int count,
    FutureOr<void> Function(Uint8List view) sink,
  ) async {
    var remaining = count;
    while (remaining > 0) {
      if (!await _fill()) {
        throw const EndOfStreamException('stream ended mid-body');
      }
      final take = math.min(remaining, _chunk.length - _offset);
      final view = Uint8List.sublistView(_chunk, _offset, _offset + take);
      _offset += take;
      remaining -= take;
      await sink(view);
    }
  }

  Future<void> cancel() => _iterator.cancel();
}

class EndOfStreamException implements Exception {
  const EndOfStreamException(this.message);
  final String message;
  @override
  String toString() => 'EndOfStreamException: $message';
}
