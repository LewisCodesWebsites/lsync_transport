import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// SHA-256 over data that arrives in pieces.
///
/// Wraps the chunked converter so neither the sender nor the receiver ever has
/// the whole file in memory, which is the constraint D-10 exists to satisfy.
class StreamingSha256 {
  StreamingSha256() {
    _input = sha256.startChunkedConversion(_output);
  }

  // Both sinks are closed by finish(), which every caller reaches; the
  // analyzer cannot see the close propagate through the chunked converter.
  // ignore: close_sinks
  final _DigestCollector _output = _DigestCollector();
  late final ByteConversionSink _input;
  bool _closed = false;

  void add(List<int> bytes) {
    if (_closed) throw StateError('digest is already closed');
    _input.add(bytes);
  }

  /// Lowercase hex digest. Closes the conversion; call once.
  String finish() {
    if (!_closed) {
      _closed = true;
      _input.close();
    }
    final digest = _output.value;
    if (digest == null) throw StateError('digest produced no value');
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Reads [file] once and returns its lowercase hex SHA-256.
Future<String> sha256OfFile(File file) async {
  final digest = StreamingSha256();
  await for (final Uint8List chunk in file.openRead().cast<Uint8List>()) {
    digest.add(chunk);
  }
  return digest.finish();
}
