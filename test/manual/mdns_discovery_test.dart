@Tags(<String>['mdns'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Discovery against live sockets (D-01).
///
/// Tagged rather than in the default run, per D-13's reasoning: mDNS needs a
/// joinable interface, inbound UDP 5353 through the host firewall, and no VPN
/// adapter swallowing the group. A discovery test that finds nothing passes for
/// the wrong reason, so this one is opt-in:
///
///     dart test -P mdns
///
/// Only one responder can hold port 5353 on a machine without reusePort, which
/// Windows does not have. So these tests run a single responder and browse from
/// the other side, exercising the unicast-reply path: the browser cannot take
/// 5353, so it never sees the group reply and only hears us because the
/// responder answers its source port directly.
void main() {
  late Directory root;
  late Instance alpha;
  late Instance beta;
  late Directory downloads;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lsync-mdns-');
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
    'multicast reaches a listener on this host at all',
    () async {
      // The precondition for everything below. Checked first so a host that
      // simply drops multicast fails here, with an obvious message, rather
      // than as a mysteriously empty browse further down.
      final group = InternetAddress('224.0.0.251');
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
        includeLinkLocal: true,
      );

      final listener = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        5353,
        reuseAddress: true,
      );
      listener.multicastLoopback = true;
      for (final interface in interfaces) {
        try {
          listener.joinMulticast(group, interface);
        } on Object {
          // Stale adapters refuse; the others carry us.
        }
      }
      addTearDown(listener.close);

      final received = <String>[];
      listener.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = listener.receive();
        if (datagram == null) return;
        received.add('${datagram.address.address}:${datagram.port}');
      });

      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
        ..multicastLoopback = true;
      addTearDown(sender.close);
      sender.send(Uint8List.fromList(List<int>.filled(16, 7)), group, 5353);

      for (var attempt = 0; attempt < 40 && received.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(
        received,
        isNotEmpty,
        reason: 'multicast to 224.0.0.251:5353 never arrived. Check the host '
            'firewall allows inbound UDP 5353 for the Dart VM, and that no '
            'VPN adapter is holding the lowest-metric multicast route.',
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a browser finds an advertised instance and reads its TXT record',
    () async {
      final responder = await MdnsResponder.start(
        deviceName: 'beta',
        fingerprint: beta.fingerprint,
        port: 4917,
      );
      addTearDown(() async {
        await responder.stop();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      final peers = await MdnsBrowser.browse(
        timeout: const Duration(seconds: 6),
      );

      final found = peers.where((peer) => peer.fingerprint == beta.fingerprint);
      expect(
        found,
        isNotEmpty,
        reason: 'advertised as ${responder.instanceName} but the browse, '
            'which cannot hold 5353, saw: $peers',
      );
      expect(found.first.deviceName, 'beta');
      expect(found.first.port, 4917);
      expect(found.first.host, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the responder stays silent for another service type',
    () async {
      // The socket-free ServiceAdvertisement tests already assert this, but
      // only about the decision. This asserts it about the wire: a real query
      // for _ipp._tcp goes out, and nothing about us comes back.
      final responder = await MdnsResponder.start(
        deviceName: 'beta',
        fingerprint: beta.fingerprint,
        port: 4917,
      );
      addTearDown(() async {
        await responder.stop();
        // Give 5353 time to come free before the next test rebinds it.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      final probe = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
        ..multicastLoopback = true;
      addTearDown(probe.close);

      final ourReplies = <String>[];
      final anyReply = <String>[];
      probe.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = probe.receive();
        if (datagram == null) return;
        anyReply.add(datagram.address.address);
        final text = String.fromCharCodes(
          datagram.data.where((b) => b >= 32 && b < 127),
        );
        if (text.contains('lsync')) ourReplies.add(text);
      });

      Uint8List ptrQuery(String service) {
        final message = Uint8List.fromList(<int>[
          ...Uint8List(12),
          ...encodeDnsName(service),
          0, dnsTypePtr,
          0, 1,
        ]);
        ByteData.sublistView(message).setUint16(4, 1);
        return message;
      }

      final group = InternetAddress('224.0.0.251');

      // Queries are retransmitted rather than sent once. Only one socket can
      // hold 5353 on Windows, which has no reusePort, so a datagram can be
      // delivered to a responder socket that is on its way out and go
      // unanswered. Real mDNS clients retransmit for the same reason.
      Future<void> askRepeatedly(
        String service, {
        required bool until,
        int attempts = 8,
      }) async {
        for (var attempt = 0; attempt < attempts; attempt++) {
          probe.send(ptrQuery(service), group, 5353);
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (until && ourReplies.isNotEmpty) return;
        }
      }

      // A well-formed PTR query for a service we do not offer.
      await askRepeatedly('_ipp._tcp.local', until: false, attempts: 4);

      expect(
        ourReplies,
        isEmpty,
        reason: 'the responder answered a question it was not asked; it said '
            '$ourReplies',
      );

      // Silence proves nothing if the responder is simply unreachable from
      // this probe, so ask something it should answer and require a reply.
      // Note this can only arrive by the unicast path: the probe is on an
      // ephemeral port, and multicast is delivered by destination port, so it
      // never sees the group reply.
      await askRepeatedly(serviceType, until: true);

      expect(
        ourReplies,
        isNotEmpty,
        reason: 'the probe never heard the responder even for our own service '
            'type, so the silence above was vacuous. Datagrams seen from: '
            '$anyReply',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'full flow over a discovered peer: browse, pair, send, verify',
    () async {
      // beta listens for connections and advertises itself.
      final server = await ReceivingServer.start(
        instance: beta,
        destination: downloads.path,
        // Must accept on the address the A record advertises, not loopback.
        address: InternetAddress.anyIPv4,
        confirmPairing: (_) async => true,
      );
      addTearDown(server.close);

      final responder = await MdnsResponder.start(
        deviceName: 'beta',
        fingerprint: beta.fingerprint,
        port: server.port,
      );
      addTearDown(responder.stop);

      // alpha finds it. Nothing below uses a hand-typed host or port.
      final peers = await MdnsBrowser.browse(
        timeout: const Duration(seconds: 6),
      );
      final discovered = peers.firstWhere(
        (peer) => peer.fingerprint == beta.fingerprint,
        orElse: () => throw StateError('beta was not discovered: $peers'),
      );

      expect(
        discovered.port,
        server.port,
        reason: 'the SRV record must carry the port we are listening on',
      );

      // Pair, comparing the digits both sides derive (D-02). The fingerprint
      // from the TXT record is a hint the dialler checks the certificate
      // against; the certificate is still what decides (D-09).
      final sasSeen = <String, String>{};
      final pairing = await Dialler.connect(
        host: discovered.host,
        port: discovered.port,
        identity: alpha.identity,
        trustStore: alpha.trustStore,
        expectFingerprint: discovered.fingerprint,
        confirmPairing: (prompt) async {
          sasSeen['dialler'] = prompt.sas;
          return true;
        },
      );
      await pairing.close();

      expect(sasSeen['dialler'], matches(RegExp(r'^\d{6}$')));
      expect(
        (await alpha.reloadTrustStore()).isPinned(beta.fingerprint),
        isTrue,
      );

      // Send over a second connection, on the pinned path.
      final source = await generateFile(
        Directory(p.join(root.path, 'outbox')),
        'discovered.bin',
        (4 * 1024 * 1024) + 777,
      );

      final session = await Dialler.connect(
        host: discovered.host,
        port: discovered.port,
        identity: alpha.identity,
        trustStore: alpha.trustStore,
        expectFingerprint: discovered.fingerprint,
      );
      try {
        await FileSender.send(session: session, file: source.file);
      } finally {
        await session.close();
      }

      final received = await server.firstFile;
      expect(received.sha256, source.sha256);
      expect(await sha256OfFile(File(received.path)), source.sha256);
      expect(p.basename(received.path), 'discovered.bin');

      // D-06: discovery changed nothing about what is stored.
      expect(await transferLeftovers(downloads), isEmpty);
      for (final instance in <Instance>[alpha, beta]) {
        final stored = <String>[
          for (final entry
              in await Directory(instance.configDir).list().toList())
            p.basename(entry.path),
        ]..sort();
        expect(
          stored,
          <String>['device.crt.pem', 'device.key.pem', 'peers.json'],
          reason: '${instance.identity.name} stored something D-06 does not '
              'permit',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
