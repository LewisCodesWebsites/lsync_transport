import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../transport/frame.dart';
import '../transport/protocol.dart';
import '../transport/session.dart';
import 'messages.dart';
import 'sender.dart' show TransferException;
import 'sidecar.dart';
import 'streaming_digest.dart';

/// How often the offset checkpoint is written, in bytes received.
const int sidecarInterval = 4 * 1024 * 1024;

/// A file that arrived intact and has been renamed into place.
class ReceivedFile {
  const ReceivedFile({
    required this.path,
    required this.size,
    required this.sha256,
    required this.resumedFrom,
  });

  final String path;
  final int size;
  final String sha256;

  /// Bytes that were already on disk when this transfer started. Zero for a
  /// transfer that ran start to finish.
  final int resumedFrom;

  bool get wasResumed => resumedFrom > 0;
}

/// Receives one offered file, resuming a previous attempt where it can (D-07).
///
/// In-progress bytes go to `<name>.part` in the destination directory with a
/// sidecar (D-12). On success the `.part` is renamed and the sidecar removed.
///
/// Since the D-06 amendment an interrupted transfer *keeps* both, so it can be
/// resumed: a named, obviously incomplete file next to its destination, exactly
/// as a browser leaves `.crdownload` or `.part`. A transfer that fails because
/// the *content* is wrong still deletes both, because those bytes are not worth
/// resuming.
class FileReceiver {
  static Future<ReceivedFile> receive({
    required PeerSession session,
    required Frame offerFrame,
    required String destinationDirectory,
    Future<bool> Function(FileOffer offer)? accept,
    void Function(int received, int total)? onProgress,
  }) async {
    final offer = FileOffer.fromFrame(offerFrame);
    final name = sanitiseFileName(offer.name);

    final directory = Directory(destinationDirectory);
    await directory.create(recursive: true);

    final finalPath = p.join(directory.path, name);
    final partPath = '$finalPath.part';
    final sidecar = TransferSidecar.forPartFile(partPath);

    Future<Never> refuse(String message) async {
      await session.send(<String, Object?>{'t': msgError, 'message': message});
      throw TransferException(message);
    }

    if (await File(finalPath).exists()) {
      await refuse('a file named "$name" is already in the destination');
    }
    if (accept != null && !await accept(offer)) {
      await refuse('the receiving device declined the transfer');
    }

    // How much of a previous attempt can be trusted. Everything past this is
    // discarded, including a partial whose sidecar cannot vouch for it.
    final resumeFrom = await _usableOffset(offer, partPath, sidecar);

    final handle = await File(partPath).open(
      mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
    );
    final digest = StreamingSha256();
    var received = resumeFrom;
    var checkpoint = resumeFrom;

    Future<void> discard() async {
      try {
        await handle.close();
      } on FileSystemException {
        // Already closed.
      }
      try {
        await File(partPath).delete();
      } on FileSystemException {
        // Already gone.
      }
      await sidecar.delete();
    }

    try {
      if (resumeFrom > 0) {
        // One read of the partial, doing two jobs at once: it proves the bytes
        // still hash to what the sidecar recorded, and it leaves the running
        // digest positioned to continue over the rest of the file.
        await _replayInto(digest, partPath, resumeFrom);
      }

      await session.send(<String, Object?>{
        't': msgFileAccept,
        'v': protocolVersion,
        'id': offer.transferId,
        // The receiver decides the offset. It holds the bytes, so only it
        // knows how many survived; the sender cannot know what a crash left.
        'have': resumeFrom,
      });
      onProgress?.call(received, offer.size);

      while (true) {
        final frame = await session.reader.readFrame();
        if (frame == null) {
          throw const TransferException('sender closed mid-transfer');
        }
        if (frame.type == msgError) {
          final message = frame.header['message'];
          throw TransferException(
            'sender aborted: '
            '${message is String ? message : 'no reason given'}',
          );
        }

        if (frame.type == msgFileDone) {
          if (frame.requireString('id') != offer.transferId) {
            throw const TransferException('done frame names another transfer');
          }
          break;
        }

        if (frame.type != msgFileChunk) {
          throw TransferException('expected a chunk, got "${frame.type}"');
        }
        if (frame.requireString('id') != offer.transferId) {
          throw const TransferException('chunk names another transfer');
        }
        final offset = frame.requireInt('off');
        if (offset != received) {
          throw _ContentException(
            'chunk out of order: expected offset $received, got $offset',
          );
        }
        if (received + frame.bodyLength > offer.size) {
          throw const _ContentException('sender sent more than it offered');
        }

        await session.reader.readBodyInto((view) async {
          await handle.writeFrom(view);
          digest.add(view);
        });
        received += frame.bodyLength;
        onProgress?.call(received, offer.size);

        if (received - checkpoint >= sidecarInterval) {
          // Flush first: the recorded offset must never run ahead of the bytes
          // actually on disk, or resume would skip a gap.
          await handle.flush();
          await sidecar.write(
            size: offer.size,
            sha256: offer.sha256,
            offset: received,
          );
          checkpoint = received;
        }
      }

      if (received != offer.size) {
        throw _ContentException(
          'size mismatch: offered ${offer.size} bytes, received $received',
        );
      }

      final actual = digest.finish();
      if (actual != offer.sha256) {
        throw _ContentException(
          'hash mismatch\n'
          '  offered:  ${offer.sha256}\n'
          '  received: $actual',
        );
      }

      await handle.flush();
      await handle.close();
      await File(partPath).rename(finalPath);
      await sidecar.delete();

      await session.send(<String, Object?>{
        't': msgFileResult,
        'v': protocolVersion,
        'id': offer.transferId,
        'ok': true,
        'sha256': actual,
      });

      return ReceivedFile(
        path: finalPath,
        size: received,
        sha256: actual,
        resumedFrom: resumeFrom,
      );
    } on _ContentException catch (error) {
      // The bytes themselves are wrong. Keeping them would mean resuming from
      // known-bad data forever, so this is the one failure that still discards.
      await discard();
      await _reportFailure(session, offer, error.message);
      throw TransferException(error.message);
    } on Object catch (error) {
      // An interruption. Keep the partial and record a verified offset so the
      // next attempt can pick it up. The running digest can be finalised here
      // and only here, which is what makes the prefix cheap: no re-read.
      await _preserve(handle, sidecar, offer, digest, received);
      await _reportFailure(session, offer, '$error');
      rethrow;
    }
  }

  /// Decides how many bytes of an existing partial may be kept.
  ///
  /// Returns zero unless every condition holds: a readable version 2 sidecar,
  /// carrying a prefix digest, describing this exact file, with a `.part` at
  /// least that long. Anything else discards, because appending to a partial
  /// that cannot be checked is how resume turns into corruption.
  static Future<int> _usableOffset(
    FileOffer offer,
    String partPath,
    TransferSidecar sidecar,
  ) async {
    final part = File(partPath);
    if (!await part.exists()) {
      await sidecar.delete();
      return 0;
    }

    final record = await sidecar.read();
    if (record == null || !record.isResumable) {
      await _discardPartial(part, sidecar);
      return 0;
    }
    // Same name, different content. Discard rather than append, or the result
    // is a silently corrupt hybrid that only the final digest would catch.
    if (!record.describes(size: offer.size, sha256: offer.sha256)) {
      await _discardPartial(part, sidecar);
      return 0;
    }
    if (await part.length() < record.offset) {
      await _discardPartial(part, sidecar);
      return 0;
    }

    final actual = await _digestOfPrefix(partPath, record.offset);
    if (actual != record.prefixSha256) {
      await _discardPartial(part, sidecar);
      return 0;
    }

    // Trim anything written past the verified offset. Those bytes were never
    // vouched for and must not end up in the middle of the file.
    if (await part.length() > record.offset) {
      final handle = await part.open(mode: FileMode.append);
      try {
        await handle.truncate(record.offset);
      } finally {
        await handle.close();
      }
    }
    return record.offset;
  }

  static Future<void> _discardPartial(
    File part,
    TransferSidecar sidecar,
  ) async {
    try {
      await part.delete();
    } on FileSystemException {
      // Already gone.
    }
    await sidecar.delete();
  }

  /// Hashes the first [length] bytes of a file without holding them in memory.
  static Future<String> _digestOfPrefix(String path, int length) async {
    final digest = StreamingSha256();
    await _readPrefix(path, length, digest.add);
    return digest.finish();
  }

  /// Feeds an existing partial into [digest] so it can continue over the rest.
  static Future<void> _replayInto(
    StreamingSha256 digest,
    String path,
    int length,
  ) =>
      _readPrefix(path, length, digest.add);

  static Future<void> _readPrefix(
    String path,
    int length,
    void Function(Uint8List block) sink,
  ) async {
    final handle = await File(path).open();
    try {
      var read = 0;
      while (read < length) {
        final want =
            length - read < chunkSize ? length - read : chunkSize;
        final block = await handle.read(want);
        if (block.isEmpty) {
          throw TransferException(
            'partial file ended at $read bytes, expected $length',
          );
        }
        sink(block);
        read += block.length;
      }
    } finally {
      await handle.close();
    }
  }

  /// Keeps an interrupted partial, with an offset the next attempt can trust.
  static Future<void> _preserve(
    RandomAccessFile handle,
    TransferSidecar sidecar,
    FileOffer offer,
    StreamingSha256 digest,
    int received,
  ) async {
    try {
      await handle.flush();
      await handle.close();
      if (received == 0) return;
      await sidecar.write(
        size: offer.size,
        sha256: offer.sha256,
        offset: received,
        prefixSha256: digest.finish(),
      );
    } on Object {
      // Preserving is best effort. If it fails the partial simply is not
      // resumable, which the next attempt detects and discards.
    }
  }

  static Future<void> _reportFailure(
    PeerSession session,
    FileOffer offer,
    String message,
  ) async {
    try {
      await session.send(<String, Object?>{
        't': msgFileResult,
        'v': protocolVersion,
        'id': offer.transferId,
        'ok': false,
        'message': message,
      });
    } on Object {
      // The sender is already gone; the local outcome is what mattered.
    }
  }
}

/// A failure caused by the bytes being wrong rather than the connection
/// breaking. These discard the partial; everything else keeps it.
class _ContentException implements Exception {
  const _ContentException(this.message);
  final String message;
  @override
  String toString() => 'TransferException: $message';
}
