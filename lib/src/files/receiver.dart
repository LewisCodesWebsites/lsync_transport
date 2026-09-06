import 'dart:io';

import 'package:path/path.dart' as p;

import '../transport/frame.dart';
import '../transport/protocol.dart';
import '../transport/session.dart';
import 'messages.dart';
import 'sender.dart' show TransferException;
import 'sidecar.dart';
import 'streaming_digest.dart';

/// How often the sidecar is brought up to date, in bytes received.
///
/// Every chunk would mean a flush and a small write per 64 KiB, which is a lot
/// of syscalls for an offset nothing reads yet. Once resume exists this is the
/// dial that trades rewind distance against write traffic.
const int sidecarInterval = 4 * 1024 * 1024;

/// A file that arrived intact and has been renamed into place.
class ReceivedFile {
  const ReceivedFile({
    required this.path,
    required this.size,
    required this.sha256,
  });

  final String path;
  final int size;
  final String sha256;
}

/// Receives one offered file (D-12).
///
/// In-progress bytes go to `<name>.part` in the destination directory with a
/// sidecar holding the transfer ID and offset. On success the `.part` file is
/// renamed to its final name and the sidecar is removed. On any failure both
/// are deleted: resume is the second pass (D-07), so this pass fails loudly and
/// leaves nothing behind, which is also what keeps D-06's claim true.
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
      // Fail loudly rather than inventing "name (1)". Overwriting silently is
      // worse, and a rename policy is a product decision this layer should not
      // be making on its own.
      await refuse('a file named "$name" is already in the destination');
    }
    if (accept != null && !await accept(offer)) {
      await refuse('the receiving device declined the transfer');
    }

    final handle = await File(partPath).open(mode: FileMode.write);
    final digest = StreamingSha256();
    var received = 0;
    var sidecarWatermark = 0;

    Future<void> cleanUp() async {
      try {
        await handle.close();
      } on FileSystemException {
        // Already closed.
      }
      // D-06: nothing survives a failed transfer.
      try {
        await File(partPath).delete();
      } on FileSystemException {
        // Already gone.
      }
      await sidecar.delete();
    }

    try {
      await sidecar.write(transferId: offer.transferId, offset: 0);

      await session.send(<String, Object?>{
        't': msgFileAccept,
        'v': protocolVersion,
        'id': offer.transferId,
      });
      onProgress?.call(0, offer.size);

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
          // Out-of-order chunks are what resume will have to cope with. In this
          // pass they mean the stream is wrong, so say so rather than seek.
          throw TransferException(
            'chunk out of order: expected offset $received, got $offset',
          );
        }
        if (received + frame.bodyLength > offer.size) {
          throw const TransferException('sender sent more than it offered');
        }

        await session.reader.readBodyInto((view) async {
          await handle.writeFrom(view);
          digest.add(view);
        });
        received += frame.bodyLength;
        onProgress?.call(received, offer.size);

        if (received - sidecarWatermark >= sidecarInterval) {
          // Flush first: the recorded offset must never run ahead of the bytes
          // actually on disk, or resume would skip a gap.
          await handle.flush();
          await sidecar.write(
            transferId: offer.transferId,
            offset: received,
          );
          sidecarWatermark = received;
        }
      }

      if (received != offer.size) {
        throw TransferException(
          'size mismatch: offered ${offer.size} bytes, received $received',
        );
      }

      final actual = digest.finish();
      if (actual != offer.sha256) {
        throw TransferException(
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
      );
    } on Object catch (error) {
      await cleanUp();
      try {
        await session.send(<String, Object?>{
          't': msgFileResult,
          'v': protocolVersion,
          'id': offer.transferId,
          'ok': false,
          'message': '$error',
        });
      } on Object {
        // The sender is already gone; the local cleanup is what mattered.
      }
      rethrow;
    }
  }
}
