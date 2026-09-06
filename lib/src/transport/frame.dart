import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'byte_reader.dart';

/// D-10 wire format.
///
///     +--------------------+-------------------+------------------------+
///     | 4-byte big-endian  | JSON header       | optional binary body   |
///     | header length      | (that many bytes) | (header['body'] bytes) |
///     +--------------------+-------------------+------------------------+
///
/// The length prefix measures the JSON header only. The body length is a field
/// inside the header, because a body is streamed in 64 KiB chunks and its total
/// size is known to the header rather than to the prefix.

/// Body chunk size (D-10).
const int chunkSize = 64 * 1024;

/// Largest JSON header accepted. Headers are small; the cap exists so a peer
/// cannot make us allocate on a whim.
const int maxHeaderBytes = 64 * 1024;

/// Largest body accepted on one frame. Bodies are chunked at [chunkSize]; the
/// slack allows for a future frame type that needs a little more.
const int maxBodyBytes = 1024 * 1024;

class ProtocolException implements Exception {
  const ProtocolException(this.message);
  final String message;
  @override
  String toString() => 'ProtocolException: $message';
}

/// A decoded header plus the length of the body that follows it.
class Frame {
  const Frame(this.header, this.bodyLength);

  final Map<String, Object?> header;
  final int bodyLength;

  bool get hasBody => bodyLength > 0;

  String get type {
    final value = header['t'];
    if (value is! String) throw const ProtocolException('frame has no type');
    return value;
  }

  String requireString(String key) {
    final value = header[key];
    if (value is! String) {
      throw ProtocolException('frame field "$key" is not a string');
    }
    return value;
  }

  int requireInt(String key) {
    final value = header[key];
    if (value is! int) {
      throw ProtocolException('frame field "$key" is not an integer');
    }
    return value;
  }

  Uint8List requireBytes(String key) {
    try {
      return base64.decode(requireString(key));
    } on FormatException {
      throw ProtocolException('frame field "$key" is not valid base64');
    }
  }
}

/// Encodes a header into its length prefix plus JSON bytes.
Uint8List encodeHeader(Map<String, Object?> header) {
  final json = utf8.encode(jsonEncode(header));
  if (json.length > maxHeaderBytes) {
    throw ProtocolException('header of ${json.length} bytes exceeds the cap');
  }
  final out = Uint8List(4 + json.length);
  ByteData.sublistView(out).setUint32(0, json.length, Endian.big);
  out.setRange(4, out.length, json);
  return out;
}

/// Reads frames off a byte stream.
///
/// A body must be consumed with [readBodyInto] or [discardBody] before the next
/// [readFrame]; the reader refuses to skip past one, since silently dropping a
/// body would desynchronise the stream.
class FrameReader {
  FrameReader(Stream<List<int>> stream) : _bytes = ByteReader(stream);

  final ByteReader _bytes;
  int _pendingBody = 0;

  /// Next frame, or null when the peer closed cleanly between frames.
  Future<Frame?> readFrame() async {
    if (_pendingBody > 0) {
      throw const ProtocolException(
        'previous frame body was not consumed',
      );
    }

    final prefix = await _bytes.tryReadExact(4);
    if (prefix == null) return null;

    final headerLength = ByteData.sublistView(prefix).getUint32(0, Endian.big);
    if (headerLength == 0) {
      throw const ProtocolException('empty header');
    }
    if (headerLength > maxHeaderBytes) {
      throw ProtocolException('header of $headerLength bytes exceeds the cap');
    }

    final headerBytes = await _bytes.readExact(headerLength);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(headerBytes));
    } on FormatException catch (error) {
      throw ProtocolException('header is not valid JSON: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const ProtocolException('header is not a JSON object');
    }

    final rawBody = decoded['body'] ?? 0;
    if (rawBody is! int || rawBody < 0) {
      throw const ProtocolException('body length is not a non-negative int');
    }
    if (rawBody > maxBodyBytes) {
      throw ProtocolException('body of $rawBody bytes exceeds the cap');
    }

    _pendingBody = rawBody;
    return Frame(decoded, rawBody);
  }

  /// Streams the current frame's body to [sink] without buffering it.
  Future<void> readBodyInto(FutureOr<void> Function(Uint8List view) sink) async {
    final length = _pendingBody;
    _pendingBody = 0;
    if (length == 0) return;
    await _bytes.pipeExact(length, sink);
  }

  Future<void> discardBody() => readBodyInto((_) {});

  Future<void> cancel() => _bytes.cancel();
}

/// Writes frames to a byte sink.
class FrameWriter {
  FrameWriter(this._sink);

  final StreamSink<List<int>> _sink;

  void writeHeader(Map<String, Object?> header) {
    _sink.add(encodeHeader(header));
  }

  /// Writes a header whose body follows immediately. [body] must be exactly
  /// the length declared, or the peer's next frame read will desynchronise.
  void writeWithBody(Map<String, Object?> header, List<int> body) {
    _sink.add(encodeHeader(<String, Object?>{...header, 'body': body.length}));
    _sink.add(body);
  }
}
