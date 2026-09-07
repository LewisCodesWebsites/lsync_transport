import 'dart:async';
import 'dart:io';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/harness.dart';

/// D-13's second test, live since resume landed (D-07).
///
/// "CI starts two instances of the core... A second test kills the connection
/// at roughly 50% and asserts that resume produces an identical hash." D-13
/// calls this the case that matters, because D-07 is where corruption would
/// come from.
///
/// The assertion is deliberately against an *uninterrupted* transfer of the
/// same bytes rather than against the sender's own claim: a resumed file that
/// merely matches what the sender said is only evidence that both sides agree,
/// not that the bytes on disk are right.
void main() {
  late Directory root;
  late Instance alpha;
  late Instance beta;
  late Directory downloads;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lsync-resume-');
    alpha = await createInstance(root, 'alpha');
    beta = await createInstance(root, 'beta');
  });

  setUp(() async {
    downloads = Directory(p.join(root.path, 'downloads'));
    if (await downloads.exists()) await downloads.delete(recursive: true);
    await downloads.create(recursive: true);
  });

  tearDownAll(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Sends [file], dropping the connection once [killAfter] bytes have moved.
  /// Returns the offset the receiver reached.
  Future<void> sendAndKill(
    ({File file, String sha256}) source,
    int killAfter,
  ) async {
    final server = await ReceivingServer.start(
      instance: beta,
      destination: downloads.path,
      confirmPairing: (_) async => true,
    );
    addTearDown(server.close);

    final session = await Dialler.connect(
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      identity: alpha.identity,
      trustStore: alpha.trustStore,
      confirmPairing: (_) async => true,
    );

    var killed = false;
    try {
      await FileSender.send(
        session: session,
        file: source.file,
        onProgress: (sent, total) {
          if (!killed && sent >= killAfter) {
            killed = true;
            // Pull the socket out from under the transfer, which is what a
            // dropped Wi-Fi connection looks like from here.
            session.socket.destroy();
          }
        },
      );
    } on Object {
      // Expected: the send cannot finish through a destroyed socket.
    }
    await session.close();

    // Let the receiver notice and write its verified checkpoint.
    for (var attempt = 0; attempt < 60; attempt++) {
      final sidecar = File(p.join(downloads.path, 'payload.bin.part.json'));
      if (await sidecar.exists()) {
        final record = await TransferSidecar(sidecar.path).read();
        if (record != null && record.isResumable) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test(
    'a transfer killed at 50% resumes to a digest identical to an '
    'uninterrupted one',
    () async {
      final source = await generateFile(
        Directory(p.join(root.path, 'outbox')),
        'payload.bin',
        (8 * 1024 * 1024) + 1234,
        seed: 99,
      );
      final size = await source.file.length();

      await sendAndKill(source, size ~/ 2);

      // The partial survived, which is the D-06 amendment working.
      final part = File(p.join(downloads.path, 'payload.bin.part'));
      expect(
        await part.exists(),
        isTrue,
        reason: 'an interrupted transfer must keep its partial (D-06, amended)',
      );
      final record =
          await TransferSidecar.forPartFile(part.path).read();
      expect(record, isNotNull);
      expect(record!.isResumable, isTrue,
          reason: 'the sidecar must carry a prefix digest to be resumable');
      expect(record.offset, greaterThan(0));
      expect(record.offset, lessThan(size),
          reason: 'the kill must land partway, or this tests nothing');
      expect(record.sha256, source.sha256);

      final resumedFrom = record.offset;

      // Second attempt, uninterrupted.
      final server = await ReceivingServer.start(
        instance: beta,
        destination: downloads.path,
        confirmPairing: (_) async => true,
      );
      addTearDown(server.close);

      final session = await Dialler.connect(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        identity: alpha.identity,
        trustStore: alpha.trustStore,
        confirmPairing: (_) async => true,
      );
      try {
        await FileSender.send(session: session, file: source.file);
      } finally {
        await session.close();
      }

      final received = await server.firstFile;

      // The assertion D-13 exists for.
      expect(received.sha256, source.sha256);
      expect(
        await sha256OfFile(File(received.path)),
        source.sha256,
        reason: 'the bytes on disk must match, not just the reported digest',
      );
      expect(await File(received.path).length(), size);

      // It genuinely resumed rather than quietly starting over, which would
      // pass every assertion above while testing nothing.
      expect(
        received.resumedFrom,
        resumedFrom,
        reason: 'the second attempt must continue from the verified offset',
      );
      expect(received.wasResumed, isTrue);

      // Nothing survives a completed transfer.
      expect(await transferLeftovers(downloads), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a partial whose sidecar describes a different file is discarded',
    () async {
      // Same name, different content. Appending would produce a hybrid that
      // only the final digest catches, and only after sending everything.
      final first = await generateFile(
        Directory(p.join(root.path, 'outbox-a')),
        'payload.bin',
        4 * 1024 * 1024,
        seed: 1,
      );
      await sendAndKill(first, (4 * 1024 * 1024) ~/ 2);

      final part = File(p.join(downloads.path, 'payload.bin.part'));
      expect(await part.exists(), isTrue);

      final second = await generateFile(
        Directory(p.join(root.path, 'outbox-b')),
        'payload.bin',
        4 * 1024 * 1024,
        seed: 2,
      );
      expect(second.sha256, isNot(first.sha256));

      final server = await ReceivingServer.start(
        instance: beta,
        destination: downloads.path,
        confirmPairing: (_) async => true,
      );
      addTearDown(server.close);

      final session = await Dialler.connect(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        identity: alpha.identity,
        trustStore: alpha.trustStore,
        confirmPairing: (_) async => true,
      );
      try {
        await FileSender.send(session: session, file: second.file);
      } finally {
        await session.close();
      }

      final received = await server.firstFile;
      expect(received.sha256, second.sha256);
      expect(await sha256OfFile(File(received.path)), second.sha256);
      expect(
        received.resumedFrom,
        0,
        reason: 'a partial of a different file must be discarded, not appended',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a partial with a tampered prefix is discarded rather than appended to',
    () async {
      // The reason the prefix digest is in the sidecar at all. Since the D-06
      // amendment the partial sits in a folder the user chose and can edit.
      final source = await generateFile(
        Directory(p.join(root.path, 'outbox-c')),
        'payload.bin',
        4 * 1024 * 1024,
        seed: 3,
      );
      await sendAndKill(source, (4 * 1024 * 1024) ~/ 2);

      final part = File(p.join(downloads.path, 'payload.bin.part'));
      final handle = await part.open(mode: FileMode.append);
      try {
        await handle.setPosition(0);
        await handle.writeFrom(<int>[0xff, 0xff, 0xff, 0xff]);
      } finally {
        await handle.close();
      }

      final server = await ReceivingServer.start(
        instance: beta,
        destination: downloads.path,
        confirmPairing: (_) async => true,
      );
      addTearDown(server.close);

      final session = await Dialler.connect(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        identity: alpha.identity,
        trustStore: alpha.trustStore,
        confirmPairing: (_) async => true,
      );
      try {
        await FileSender.send(session: session, file: source.file);
      } finally {
        await session.close();
      }

      final received = await server.firstFile;
      expect(
        received.resumedFrom,
        0,
        reason: 'a partial that fails its prefix digest must be discarded',
      );
      expect(await sha256OfFile(File(received.path)), source.sha256);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
