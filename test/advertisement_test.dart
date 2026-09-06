import 'dart:io';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:test/test.dart';

/// The responder's decision logic, without a socket.
///
/// Worth testing on its own because the socket half cannot run everywhere: a
/// host firewall that drops inbound UDP 5353 makes an end-to-end mDNS test
/// silently vacuous, whereas this fails honestly if the wrong records go out.
ServiceAdvertisement advertisement({String deviceName = 'laptop'}) =>
    ServiceAdvertisement(
      deviceName: deviceName,
      fingerprint: 'ab' * 32,
      port: defaultPort,
      addresses: <InternetAddress>[InternetAddress('192.168.1.5')],
    );

List<DnsQuestion> ask(String name, int type) =>
    <DnsQuestion>[DnsQuestion(name, type, 1)];

void main() {
  test('names follow the D-01 service type', () {
    final service = advertisement();
    expect(service.instanceName, 'laptop.$serviceType');
    expect(service.hostName, 'laptop.local');
  });

  test('a dot in the device name would split the label, so it is replaced', () {
    expect(
      advertisement(deviceName: 'my.laptop').instanceName,
      'my-laptop.$serviceType',
    );
  });

  test('the host name is derived from the instance, not the machine', () {
    // Two instances on one laptop must not claim the same A record.
    expect(
      advertisement(deviceName: 'alpha').hostName,
      isNot(advertisement(deviceName: 'beta').hostName),
    );
  });

  group('answers', () {
    test('a PTR query gets everything needed to connect in one go', () {
      final service = advertisement();
      final answers = service.answersFor(ask(serviceType, dnsTypePtr));

      expect(
        answers.map((r) => r.type),
        containsAll(<int>[dnsTypePtr, dnsTypeSrv, dnsTypeTxt, dnsTypeA]),
      );
    });

    test('a trailing dot on the query name still matches', () {
      final answers = advertisement().answersFor(
        ask('$serviceType.', dnsTypePtr),
      );
      expect(answers, isNotEmpty);
    });

    test('an SRV query for our instance gets SRV and TXT', () {
      final service = advertisement();
      final answers = service.answersFor(
        ask(service.instanceName, dnsTypeSrv),
      );
      expect(
        answers.map((r) => r.type),
        <int>[dnsTypeSrv, dnsTypeTxt],
      );
    });

    test('an A query for our host gets the address', () {
      final service = advertisement();
      final answers = service.answersFor(ask(service.hostName, dnsTypeA));
      expect(answers, hasLength(1));
      expect(answers.single.rdata, <int>[192, 168, 1, 5]);
    });

    test('the service-type enumeration query gets our type (D-24)', () {
      // RFC 6763 section 9. A browser asks this to build its list of service
      // types; without an answer lsync never appears in that list, so nothing
      // ever browses it and no query for the service type is ever generated.
      // That, not the network, is why the phone saw nothing.
      final service = advertisement();
      final answers = service.answersFor(
        ask(serviceEnumerationType, dnsTypePtr),
      );

      expect(answers, hasLength(1));
      expect(answers.single.type, dnsTypePtr);
      expect(answers.single.name, serviceEnumerationType);

      final (target, _) = decodeDnsName(answers.single.rdata, 0);
      expect(target, serviceType);
    });

    test('the enumeration answer lists a type, not an instance', () {
      // The reply to the meta-query is a list of service types. Sending SRV,
      // TXT or A here would be answering a question that was not asked.
      final answers = advertisement().answersFor(
        ask(serviceEnumerationType, dnsTypePtr),
      );
      expect(
        answers.map((r) => r.type),
        everyElement(dnsTypePtr),
      );
      final (target, _) = decodeDnsName(answers.single.rdata, 0);
      expect(target, isNot(advertisement().instanceName));
    });

    test('a trailing dot on the enumeration query still matches', () {
      expect(
        advertisement().answersFor(ask('$serviceEnumerationType.', dnsTypePtr)),
        isNotEmpty,
      );
    });

    test('the enumeration answer is shared, so no cache-flush bit', () {
      // Every device on the LAN answers this one; flushing would make them
      // evict each other's types.
      final answers = advertisement().answersFor(
        ask(serviceEnumerationType, dnsTypePtr),
      );
      expect(answers.single.cacheFlush, isFalse);
    });

    test('enumeration is answered for PTR only, not for SRV', () {
      expect(
        advertisement().answersFor(ask(serviceEnumerationType, dnsTypeSrv)),
        isEmpty,
      );
    });

    test('another service on the LAN gets no answer', () {
      // Answering questions we were not asked is just noise.
      expect(
        advertisement().answersFor(ask('_ipp._tcp.local', dnsTypePtr)),
        isEmpty,
      );
    });

    test('another service type is still not enumerated for us', () {
      // Answering the meta-query must not turn into answering every PTR.
      for (final other in <String>[
        '_ipp._tcp.local',
        '_airplay._tcp.local',
        '_apple-mobdev2._tcp.local',
      ]) {
        expect(
          advertisement().answersFor(ask(other, dnsTypePtr)),
          isEmpty,
          reason: 'answered a PTR query for $other',
        );
      }
    });

    test('another device instance gets no answer', () {
      expect(
        advertisement().answersFor(
          ask('someone-else.$serviceType', dnsTypeSrv),
        ),
        isEmpty,
      );
    });

    test('a PTR query for our instance name is not a service query', () {
      final service = advertisement();
      expect(
        service.answersFor(ask(service.instanceName, dnsTypePtr)),
        isEmpty,
      );
    });
  });

  test('the TXT record carries the fingerprint and name', () {
    final service = advertisement();
    expect(service.txt['fp'], 'ab' * 32);
    expect(service.txt['name'], 'laptop');
  });

  test('the SRV record points at the port we are listening on', () {
    final service = advertisement();
    final srv = service
        .instanceRecords()
        .firstWhere((record) => record.type == dnsTypeSrv);
    expect(
      (srv.rdata[4] << 8) | srv.rdata[5],
      defaultPort,
    );
  });
}
