import 'dart:typed_data';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:test/test.dart';

/// Builds a query the way a browsing client would, so the responder's parser is
/// tested against the shape it will actually see.
Uint8List query(String name, int type, {bool compressed = false}) {
  final encoded = encodeDnsName(name);
  final header = Uint8List(12);
  ByteData.sublistView(header)
    ..setUint16(0, 0x1234, Endian.big)
    ..setUint16(2, 0, Endian.big)
    ..setUint16(4, compressed ? 2 : 1, Endian.big);

  final body = <int>[...encoded, 0, type, 0, 1];
  if (compressed) {
    // A second question pointing back at the first question's name.
    body.addAll(<int>[0xc0, 12, 0, type, 0, 1]);
  }
  return Uint8List.fromList(<int>[...header, ...body]);
}

void main() {
  group('names', () {
    test('round-trip', () {
      final encoded = encodeDnsName('laptop._lsync._tcp.local');
      final (name, offset) = decodeDnsName(encoded, 0);
      expect(name, 'laptop._lsync._tcp.local');
      expect(offset, encoded.length);
    });

    test('a trailing dot is not a fifth empty label', () {
      expect(
        encodeDnsName('_lsync._tcp.local.'),
        encodeDnsName('_lsync._tcp.local'),
      );
    });

    test('a label over 63 bytes is refused', () {
      expect(() => encodeDnsName('a' * 64), throwsArgumentError);
    });
  });

  group('questions', () {
    test('a single question is parsed', () {
      final questions = parseQuestions(query(serviceType, dnsTypePtr));
      expect(questions, hasLength(1));
      expect(questions.single.name, serviceType);
      expect(questions.single.asksFor(dnsTypePtr), isTrue);
      expect(questions.single.asksFor(dnsTypeSrv), isFalse);
    });

    test('ANY matches every type we answer', () {
      final questions = parseQuestions(query(serviceType, dnsTypeAny));
      expect(questions.single.asksFor(dnsTypePtr), isTrue);
      expect(questions.single.asksFor(dnsTypeSrv), isTrue);
      expect(questions.single.asksFor(dnsTypeA), isTrue);
    });

    test('compression pointers are followed', () {
      final questions = parseQuestions(
        query(serviceType, dnsTypePtr, compressed: true),
      );
      expect(questions, hasLength(2));
      expect(questions[1].name, serviceType);
    });

    test('responses are ignored, so we do not answer ourselves', () {
      final message = query(serviceType, dnsTypePtr);
      // Set the QR bit.
      ByteData.sublistView(message).setUint16(2, 0x8400, Endian.big);
      expect(parseQuestions(message), isEmpty);
    });

    test('a forward-pointing compression pointer is refused', () {
      // Pointers that do not go backwards can be made to loop, which is a way
      // to hang a responder with one datagram.
      final message = Uint8List.fromList(<int>[
        ...Uint8List(12),
        0xc0, 40,
        0, dnsTypePtr, 0, 1,
      ]);
      ByteData.sublistView(message).setUint16(4, 1, Endian.big);
      expect(() => parseQuestions(message), throwsFormatException);
    });

    test('a truncated message yields nothing rather than throwing', () {
      expect(parseQuestions(Uint8List(4)), isEmpty);
    });
  });

  group('records', () {
    test('an SRV record carries the port and target', () {
      final record = DnsRecord.srv(
        name: 'laptop.$serviceType',
        target: 'laptop.local',
        port: defaultPort,
      );
      final view = ByteData.sublistView(record.rdata);
      expect(view.getUint16(4, Endian.big), defaultPort);
      final (target, _) = decodeDnsName(record.rdata, 6);
      expect(target, 'laptop.local');
    });

    test('a TXT record encodes length-prefixed key=value strings', () {
      final record = DnsRecord.txt(
        name: 'laptop.$serviceType',
        entries: <String, String>{'fp': 'abcd', 'name': 'laptop'},
      );
      final rdata = record.rdata;
      expect(rdata[0], 'fp=abcd'.length);
      expect(
        String.fromCharCodes(rdata.sublist(1, 1 + rdata[0])),
        'fp=abcd',
      );
    });

    test('an A record needs four bytes', () {
      expect(
        () => DnsRecord.a(name: 'laptop.local', address: <int>[1, 2, 3]),
        throwsArgumentError,
      );
    });

    test('unique records set the cache-flush bit, shared ones do not', () {
      // PTR is shared: several devices answer for the same service type, and
      // flushing would make them evict each other.
      final ptr = DnsRecord.ptr(name: serviceType, target: 'a.$serviceType');
      expect(ptr.cacheFlush, isFalse);
      expect(
        DnsRecord.srv(name: 'a', target: 'b', port: 1).cacheFlush,
        isTrue,
      );
    });
  });

  test('a response declares its answer count and is parseable', () {
    final response = buildResponse(<DnsRecord>[
      DnsRecord.ptr(name: serviceType, target: 'laptop.$serviceType'),
      DnsRecord.srv(
        name: 'laptop.$serviceType',
        target: 'laptop.local',
        port: defaultPort,
      ),
    ]);
    final view = ByteData.sublistView(response);
    expect(view.getUint16(2, Endian.big) & 0x8000, 0x8000, reason: 'QR bit');
    expect(view.getUint16(4, Endian.big), 0, reason: 'no questions');
    expect(view.getUint16(6, Endian.big), 2, reason: 'two answers');

    final (name, _) = decodeDnsName(response, 12);
    expect(name, serviceType);
  });
}
