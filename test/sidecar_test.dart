import 'dart:io';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lsync-sidecar-');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('sits beside the .part file it describes (D-12)', () {
    final partPath = p.join(directory.path, 'holiday.zip.part');
    final sidecar = TransferSidecar.forPartFile(partPath);
    expect(p.dirname(sidecar.path), directory.path);
    expect(p.basename(sidecar.path), startsWith('holiday.zip.part'));
  });

  test('round-trips what resume needs', () async {
    final sidecar = TransferSidecar.forPartFile(
      p.join(directory.path, 'file.part'),
    );
    await sidecar.write(
      size: 8388608,
      sha256: 'a' * 64,
      offset: 4194304,
      prefixSha256: 'b' * 64,
    );

    final record = await sidecar.read();
    expect(record, isNotNull);
    expect(record!.size, 8388608);
    expect(record.sha256, 'a' * 64);
    expect(record.offset, 4194304);
    expect(record.prefixSha256, 'b' * 64);
    expect(record.isResumable, isTrue);
  });

  test('a checkpoint without a prefix digest is not resumable', () async {
    // Written periodically so an abandoned .part always has a sidecar beside
    // it. It exists to be recognised, not to be trusted.
    final sidecar = TransferSidecar.forPartFile(
      p.join(directory.path, 'file.part'),
    );
    await sidecar.write(size: 100, sha256: 'a' * 64, offset: 50);

    final record = await sidecar.read();
    expect(record!.isResumable, isFalse);
  });

  test('describes() distinguishes a same-named different file', () async {
    final sidecar = TransferSidecar.forPartFile(
      p.join(directory.path, 'file.part'),
    );
    await sidecar.write(
      size: 100,
      sha256: 'a' * 64,
      offset: 50,
      prefixSha256: 'b' * 64,
    );
    final record = (await sidecar.read())!;
    expect(record.describes(size: 100, sha256: 'a' * 64), isTrue);
    expect(record.describes(size: 100, sha256: 'c' * 64), isFalse);
    expect(record.describes(size: 200, sha256: 'a' * 64), isFalse);
  });

  test('a version 1 sidecar reads as absent', () async {
    // The old format held a transfer ID and could not support resume. Treating
    // it as no sidecar discards the partial rather than guessing.
    final sidecar = TransferSidecar.forPartFile(
      p.join(directory.path, 'file.part'),
    );
    await File(sidecar.path)
        .writeAsString('{"version":1,"id":"abc","offset":42}');
    expect(await sidecar.read(), isNull);
  });

  test('reads as absent when there is no sidecar', () async {
    final sidecar = TransferSidecar.forPartFile(
      p.join(directory.path, 'missing.part'),
    );
    expect(await sidecar.read(), isNull);
  });

  test('a corrupt sidecar reads as absent rather than throwing', () async {
    final sidecar = TransferSidecar.forPartFile(
      p.join(directory.path, 'file.part'),
    );
    await File(sidecar.path).writeAsString('{ not json');
    expect(await sidecar.read(), isNull);
  });

  test('deleting a sidecar that is already gone is not an error', () async {
    final sidecar = TransferSidecar.forPartFile(
      p.join(directory.path, 'file.part'),
    );
    await sidecar.delete();
    await sidecar.delete();
  });
}
