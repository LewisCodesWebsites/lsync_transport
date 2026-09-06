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

  test('round-trips the transfer ID and offset', () async {
    final sidecar = TransferSidecar.forPartFile(
      p.join(directory.path, 'file.part'),
    );
    await sidecar.write(transferId: 'abc123', offset: 4194304);

    final record = await sidecar.read();
    expect(record, isNotNull);
    expect(record!.transferId, 'abc123');
    expect(record.offset, 4194304);
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
