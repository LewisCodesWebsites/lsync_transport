import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../identity/device_identity.dart';
import '../transport/frame.dart';
import '../transport/protocol.dart';
import '../transport/session.dart';
import 'streaming_digest.dart';

/// Remembers a file's digest for the life of the process, so repeated
/// reconnects do not each pay D-17's full read.
///
/// In memory only, deliberately. Persisting it would be new retained state of
/// exactly the kind D-06 refuses, and the case worth covering is several
/// reconnects within one session on a flaky link, which memory covers. Keyed on
/// path, size and modification time, so an edited file is re-hashed rather than
/// sent under a stale digest.
class _DigestCache {
  static final Map<String, String> _entries = <String, String>{};

  static String _key(String path, int size, DateTime modified) =>
      '$path|$size|${modified.microsecondsSinceEpoch}';

  static String? get(String path, int size, DateTime modified) =>
      _entries[_key(path, size, modified)];

  static void put(String path, int size, DateTime modified, String digest) {
    _entries[_key(path, size, modified)] = digest;
  }
}

/// Sends one file over an authenticated session (D-10, D-12, D-07).
class FileSender {
  /// Transfers [file] and returns once the receiver has confirmed the hash.
  ///
  /// The digest travels in the offer (D-17), which is what lets the receiver
  /// recognise a partial it already holds before any bytes move. The receiver
  /// replies with how much it has, and the send starts there.
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
    final modified = await file.lastModified();
    var sha256 = _DigestCache.get(file.path, size, modified);
    if (sha256 == null) {
      sha256 = await sha256OfFile(file);
      _DigestCache.put(file.path, size, modified, sha256);
    }

    // Correlates the frames of one session. Deliberately not the resume key:
    // an ID identifies an attempt, and two attempts at the same file should
    // share a partial rather than fork it. Resume is keyed on name, size and
    // digest, all of which the offer already carries.
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

    final have = response.header['have'];
    if (have is! int || have < 0 || have > size) {
      throw TransferException(
        'receiver asked to resume from an impossible offset: $have',
      );
    }

    final handle = await file.open();
    try {
      var offset = have;
      if (offset > 0) await handle.setPosition(offset);
      onProgress?.call(offset, size);

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
        // Flushing each chunk is what applies backpressure: without it the
        // whole file would queue in the socket's write buffer, which is exactly
        // the memory blow-up D-10 exists to avoid.
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
