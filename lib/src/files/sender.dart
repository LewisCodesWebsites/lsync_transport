import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../identity/device_identity.dart';
import '../transport/frame.dart';
import '../transport/protocol.dart';
import '../transport/session.dart';
import 'streaming_digest.dart';

/// Sends one file over an authenticated session (D-10, D-12).
class FileSender {
  /// Transfers [file] and returns once the receiver has confirmed the hash.
  ///
  /// The file is hashed in a first pass and the digest travels in the offer, so
  /// the receiver can check what it stored against what was promised before it
  /// renames anything into place. That costs one extra read of the file; the
  /// alternative, a trailing digest sent after the body, saves the read but
  /// leaves the receiver unable to reject a bad transfer until the end anyway.
  ///
  /// Throws [TransferException] if the receiver refuses or the hashes differ.
  static Future<void> send({
    required PeerSession session,
    required File file,
    String? asName,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (!await file.exists()) {
      throw TransferException('no such file: ${file.path}');
    }

    final size = await file.length();
    final sha256 = await sha256OfFile(file);
    final transferId = toHex(randomBytes(16));
    final name = asName ?? p.basename(file.path);

    await session.send(<String, Object?>{
      't': msgFileOffer,
      'v': protocolVersion,
      'id': transferId,
      'name': name,
      'size': size,
      'sha256': sha256,
    });

    final response = await session.reader.readFrame();
    if (response == null) {
      throw const TransferException('receiver closed before answering');
    }
    if (response.type == msgError) {
      final message = response.header['message'];
      throw TransferException(
        'receiver refused: ${message is String ? message : 'no reason given'}',
      );
    }
    if (response.type != msgFileAccept) {
      throw TransferException('expected an accept, got "${response.type}"');
    }

    final handle = await file.open();
    try {
      var offset = 0;
      onProgress?.call(0, size);
      while (offset < size) {
        final want = math.min(chunkSize, size - offset);
        final bytes = await handle.read(want);
        if (bytes.length != want) {
          throw TransferException(
            'file shrank while being sent: wanted $want bytes at $offset, '
            'read ${bytes.length}',
          );
        }
        session.writer.writeWithBody(
          <String, Object?>{
            't': msgFileChunk,
            'id': transferId,
            'off': offset,
          },
          bytes,
        );
        // Flushing each chunk is what applies backpressure: without it the whole
        // file would queue in the socket's write buffer, which is exactly the
        // memory blow-up D-10 exists to avoid.
        await session.socket.flush();
        offset += bytes.length;
        onProgress?.call(offset, size);
      }
    } finally {
      await handle.close();
    }

    await session.send(<String, Object?>{
      't': msgFileDone,
      'id': transferId,
    });

    final result = await session.reader.readFrame();
    if (result == null) {
      throw const TransferException('receiver closed before confirming');
    }
    if (result.type == msgError) {
      final message = result.header['message'];
      throw TransferException(
        'receiver failed: ${message is String ? message : 'no reason given'}',
      );
    }
    if (result.type != msgFileResult) {
      throw TransferException('expected a result, got "${result.type}"');
    }
    if (result.header['ok'] != true) {
      final message = result.header['message'];
      throw TransferException(
        'receiver rejected the transfer: '
        '${message is String ? message : 'no reason given'}',
      );
    }
    final received = result.header['sha256'];
    if (received != sha256) {
      throw TransferException(
        'hash mismatch\n  sent:     $sha256\n  received: $received',
      );
    }
  }
}

class TransferException implements Exception {
  const TransferException(this.message);
  final String message;
  @override
  String toString() => 'TransferException: $message';
}
