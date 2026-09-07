import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/harness.dart';

/// D-06: "the test is that they are deleted on both completion and failure.
/// Nothing survives a finished or failed transfer."
///
/// Completion is covered by the D-13 test. This is the failure half, driven by
/// sending frames by hand so the receiver can be put in states a well-behaved
/// [FileSender] never produces.
void main() {
  late Directory root;
  late Instance alpha;
  late Instance beta;
  late Directory downloads;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lsync-cleanup-');
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

  Future<({ReceivingServer server, PeerSession session})> connect() async {
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
    addTearDown(session.close);
    return (server: server, session: session);
  }

  /// Offers a file by hand so the declared hash can be made to disagree with
  /// the bytes that follow.
  Future<Frame> offerByHand(
    PeerSession session, {
    required String name,
    required int size,
    required String declaredSha256,
  }) async {
    await session.send(<String, Object?>{
      't': msgFileOffer,
      'v': protocolVersion,
      'id': 'a' * 32,
      'name': name,
      'size': size,
      'sha256': declaredSha256,
    });
    final response = await session.reader.readFrame();
    return response!;
  }

  Future<void> sendChunks(PeerSession session, int size, {int seed = 3}) async {
    final random = Random(seed);
    var offset = 0;
    while (offset < size) {
      final length = min(chunkSize, size - offset);
      final block = Uint8List(length);
      for (var i = 0; i < length; i++) {
        block[i] = random.nextInt(256);
      }
      session.writer.writeWithBody(
        <String, Object?>{'t': msgFileChunk, 'id': 'a' * 32, 'off': offset},
        block,
      );
      await session.socket.flush();
      offset += length;
    }
  }

  test(
    'a hash mismatch leaves no .part and no sidecar behind',
    () async {
      final connection = await connect();
      const size = 200000;

      final accept = await offerByHand(
        connection.session,
        name: 'corrupt.bin',
        size: size,
        // Bytes that will not hash to this.
        declaredSha256: '0' * 64,
      );
      expect(accept.type, msgFileAccept);

      await sendChunks(connection.session, size);
      await connection.session.send(<String, Object?>{
        't': msgFileDone,
        'id': 'a' * 32,
      });

      final result = await connection.session.reader.readFrame();
      expect(result!.type, msgFileResult);
      expect(result.header['ok'], isFalse, reason: 'the receiver must refuse');

      expect(
        await File(p.join(downloads.path, 'corrupt.bin')).exists(),
        isFalse,
        reason: 'a file that failed its hash must never be renamed into place',
      );
      expect(
        await transferLeftovers(downloads),
        isEmpty,
        reason: 'a content error still discards: those bytes are known bad, '
            'and resuming from them would fail the same way forever',
      );
      expect(
        connection.server.failures,
        isNotEmpty,
        reason: 'the receiver must record the rejection, not swallow it',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a connection dropped mid-transfer keeps a resumable partial',
    () async {
      // Changed with the D-06 amendment. Before resume this asserted that
      // nothing survived; now an interruption must keep the partial, because
      // that partial is the whole point of D-07. A named, obviously incomplete
      // file beside its destination is not hidden state.
      final connection = await connect();
      const size = 8 * 1024 * 1024;

      final accept = await offerByHand(
        connection.session,
        name: 'interrupted.bin',
        size: size,
        declaredSha256: '0' * 64,
      );
      expect(accept.type, msgFileAccept);
      expect(accept.header['have'], 0, reason: 'nothing to resume from yet');

      await sendChunks(connection.session, 5 * 1024 * 1024);
      connection.session.socket.destroy();

      // Give the receiver a moment to notice and write its checkpoint.
      SidecarRecord? record;
      final sidecar = TransferSidecar.forPartFile(
        p.join(downloads.path, 'interrupted.bin.part'),
      );
      for (var attempt = 0; attempt < 60; attempt++) {
        record = await sidecar.read();
        if (record != null && record.isResumable) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(
        await File(p.join(downloads.path, 'interrupted.bin.part')).exists(),
        isTrue,
        reason: 'an interrupted transfer must keep its partial',
      );
      expect(record, isNotNull);
      expect(
        record!.isResumable,
        isTrue,
        reason: 'the sidecar must carry a prefix digest, or the next attempt '
            'cannot check the partial before appending to it',
      );
      expect(record.offset, greaterThan(0));

      // Still not renamed into place: incomplete is not complete.
      expect(
        await File(p.join(downloads.path, 'interrupted.bin')).exists(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a name that would escape the destination directory is refused',
    () async {
      final connection = await connect();

      final response = await offerByHand(
        connection.session,
        name: '../escaped.bin',
        size: 10,
        declaredSha256: '0' * 64,
      );

      // Reduced to a basename inside the destination, never written above it.
      if (response.type == msgFileAccept) {
        await sendChunks(connection.session, 10);
        await connection.session.send(<String, Object?>{
          't': msgFileDone,
          'id': 'a' * 32,
        });
        await connection.session.reader.readFrame();
      }

      expect(
        await File(p.join(root.path, 'escaped.bin')).exists(),
        isFalse,
        reason: 'nothing may be written outside the destination directory',
      );
      expect(await transferLeftovers(downloads), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
