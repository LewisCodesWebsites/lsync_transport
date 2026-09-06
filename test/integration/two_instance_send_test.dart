import 'dart:io';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/harness.dart';

/// D-13: two instances of the core, a generated file with a known SHA-256, and
/// an assertion that the hash on the far side matches.
void main() {
  late Directory root;
  late Instance alpha; // dials
  late Instance beta; // listens
  late Directory downloads;

  // Generating two RSA keys takes a moment and happens once.
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lsync-it-');
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

  test(
    'two instances pair, transfer a file, and agree on its SHA-256',
    () async {
      // Pairing: both ends must show the same six digits (D-02).
      final sasSeen = <String, String>{};

      final server = await ReceivingServer.start(
        instance: beta,
        destination: downloads.path,
        confirmPairing: (prompt) async {
          sasSeen['listener'] = prompt.sas;
          return true;
        },
      );
      addTearDown(server.close);

      final pairing = await Dialler.connect(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        identity: alpha.identity,
        trustStore: alpha.trustStore,
        confirmPairing: (prompt) async {
          sasSeen['dialler'] = prompt.sas;
          return true;
        },
      );
      await pairing.close();

      expect(
        sasSeen['dialler'],
        isNotNull,
        reason: 'the dialling side must show a number to compare',
      );
      expect(
        sasSeen['dialler'],
        sasSeen['listener'],
        reason: 'both devices derive the digits from both fingerprints (D-02)',
      );

      // Both sides persisted the pin, and only what D-06 permits.
      expect(
        (await alpha.reloadTrustStore()).isPinned(beta.fingerprint),
        isTrue,
      );
      expect(
        (await beta.reloadTrustStore()).isPinned(alpha.fingerprint),
        isTrue,
      );

      // A second connection, now on the pinned path with pairing switched off.
      final source = await generateFile(
        Directory(p.join(root.path, 'outbox')),
        'payload.bin',
        (8 * 1024 * 1024) + 1234, // Not a whole number of 64 KiB chunks.
      );

      final session = await Dialler.connect(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        identity: alpha.identity,
        trustStore: alpha.trustStore,
        expectFingerprint: beta.fingerprint,
      );
      try {
        await FileSender.send(session: session, file: source.file);
      } finally {
        await session.close();
      }

      final received = await server.firstFile;

      // The assertion D-13 exists for.
      expect(received.sha256, source.sha256);
      expect(received.size, await source.file.length());
      expect(p.basename(received.path), 'payload.bin');
      expect(p.dirname(received.path), downloads.path);

      // And the bytes on disk really are those bytes, not just a matching
      // hash the receiver reported.
      expect(await sha256OfFile(File(received.path)), source.sha256);

      // D-06: nothing survives a finished transfer.
      expect(await transferLeftovers(downloads), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'an unpaired dialler is refused when the listener is not pairing',
    () async {
      final stranger = await createInstance(root, 'stranger');

      final server = await ReceivingServer.start(
        instance: beta,
        destination: downloads.path,
        // No confirmPairing: pairing is a mode the user opts into.
      );
      addTearDown(server.close);

      await expectLater(
        Dialler.connect(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          identity: stranger.identity,
          trustStore: stranger.trustStore,
          confirmPairing: (_) async => true,
        ),
        throwsA(isA<HandshakeException>()),
      );

      expect(
        server.refusals,
        isNotEmpty,
        reason: 'the listener must refuse, not just let the dialler give up',
      );
      expect(
        (await beta.reloadTrustStore()).isPinned(stranger.fingerprint),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a fingerprint that does not match the certificate aborts the dial',
    () async {
      final server = await ReceivingServer.start(
        instance: beta,
        destination: downloads.path,
        confirmPairing: (_) async => true,
      );
      addTearDown(server.close);

      // What a swapped certificate looks like to the dialler: it pinned one
      // key and something else answered.
      await expectLater(
        Dialler.connect(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          identity: alpha.identity,
          trustStore: alpha.trustStore,
          expectFingerprint: 'f' * 64,
          confirmPairing: (_) async => true,
        ),
        throwsA(isA<HandshakeException>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'declining the comparison pins nothing on either side',
    () async {
      final refuser = await createInstance(root, 'refuser');

      final server = await ReceivingServer.start(
        instance: beta,
        destination: downloads.path,
        confirmPairing: (_) async => true,
      );
      addTearDown(server.close);

      await expectLater(
        Dialler.connect(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          identity: refuser.identity,
          trustStore: refuser.trustStore,
          // The user says the numbers do not match.
          confirmPairing: (_) async => false,
        ),
        throwsA(isA<HandshakeException>()),
      );

      expect(
        (await refuser.reloadTrustStore()).isPinned(beta.fingerprint),
        isFalse,
      );
      expect(
        (await beta.reloadTrustStore()).isPinned(refuser.fingerprint),
        isFalse,
        reason: 'the listener must not pin when the other user declined',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
