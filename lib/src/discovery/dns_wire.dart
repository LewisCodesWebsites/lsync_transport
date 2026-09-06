import 'dart:convert';
import 'dart:typed_data';

/// Just enough of the DNS wire format to answer mDNS queries.
///
/// This exists because no Dart package can advertise a service without Flutter:
/// `multicast_dns` queries but never publishes, and `nsd` and `bonsoir` are both
/// Flutter plugins. Querying stays with `multicast_dns`; only the responder is
/// hand-written, and only the four record types a service needs.

const int dnsTypeA = 1;
const int dnsTypePtr = 12;
const int dnsTypeTxt = 16;
const int dnsTypeSrv = 33;
const int dnsTypeAny = 255;

const int dnsClassIn = 1;

/// Set on records this device is authoritative for, telling receivers to
/// replace rather than accumulate. Shared records such as PTR omit it.
const int dnsCacheFlush = 0x8000;

/// QR + AA: an authoritative response.
const int _responseFlags = 0x8400;

const int _maxCompressionJumps = 16;

class DnsQuestion {
  const DnsQuestion(this.name, this.type, this.questionClass);

  final String name;
  final int type;
  final int questionClass;

  bool get wantsUnicastResponse => questionClass & 0x8000 != 0;

  /// True when this question asks for [wanted], allowing for ANY.
  bool asksFor(int wanted) => type == wanted || type == dnsTypeAny;
}

class DnsRecord {
  const DnsRecord({
    required this.name,
    required this.type,
    required this.rdata,
    this.ttl = 120,
    this.cacheFlush = false,
  });

  final String name;
  final int type;
  final Uint8List rdata;
  final int ttl;
  final bool cacheFlush;

  Uint8List encode() {
    final name = encodeDnsName(this.name);
    final out = Uint8List(name.length + 10 + rdata.length);
    final view = ByteData.sublistView(out);
    out.setRange(0, name.length, name);
    var at = name.length;
    view
      ..setUint16(at, type, Endian.big)
      ..setUint16(at + 2, dnsClassIn | (cacheFlush ? dnsCacheFlush : 0),
          Endian.big)
      ..setUint32(at + 4, ttl, Endian.big)
      ..setUint16(at + 8, rdata.length, Endian.big);
    at += 10;
    out.setRange(at, at + rdata.length, rdata);
    return out;
  }

  static DnsRecord ptr({required String name, required String target}) =>
      DnsRecord(name: name, type: dnsTypePtr, rdata: encodeDnsName(target));

  static DnsRecord srv({
    required String name,
    required String target,
    required int port,
    int priority = 0,
    int weight = 0,
  }) {
    final targetName = encodeDnsName(target);
    final rdata = Uint8List(6 + targetName.length);
    ByteData.sublistView(rdata)
      ..setUint16(0, priority, Endian.big)
      ..setUint16(2, weight, Endian.big)
      ..setUint16(4, port, Endian.big);
    rdata.setRange(6, rdata.length, targetName);
    return DnsRecord(
      name: name,
      type: dnsTypeSrv,
      rdata: rdata,
      cacheFlush: true,
    );
  }

  static DnsRecord txt({
    required String name,
    required Map<String, String> entries,
  }) {
    final builder = BytesBuilder();
    for (final entry in entries.entries) {
      final bytes = utf8.encode('${entry.key}=${entry.value}');
      if (bytes.length > 255) {
        throw ArgumentError('TXT entry "${entry.key}" is longer than 255 bytes');
      }
      builder
        ..addByte(bytes.length)
        ..add(bytes);
    }
    if (builder.isEmpty) builder.addByte(0);
    return DnsRecord(
      name: name,
      type: dnsTypeTxt,
      rdata: builder.toBytes(),
      cacheFlush: true,
    );
  }

  static DnsRecord a({required String name, required List<int> address}) {
    if (address.length != 4) {
      throw ArgumentError('an A record needs four bytes');
    }
    return DnsRecord(
      name: name,
      type: dnsTypeA,
      rdata: Uint8List.fromList(address),
      cacheFlush: true,
    );
  }
}

/// Encodes a dotted name as length-prefixed labels. No compression: responses
/// here are small, and emitting pointers would buy nothing.
Uint8List encodeDnsName(String name) {
  final trimmed = name.endsWith('.')
      ? name.substring(0, name.length - 1)
      : name;
  final builder = BytesBuilder();
  for (final label in trimmed.split('.')) {
    if (label.isEmpty) continue;
    final bytes = utf8.encode(label);
    if (bytes.length > 63) {
      throw ArgumentError('DNS label "$label" is longer than 63 bytes');
    }
    builder
      ..addByte(bytes.length)
      ..add(bytes);
  }
  builder.addByte(0);
  return builder.toBytes();
}

/// Decodes a name, following compression pointers.
///
/// Returns the name and the offset just past it in the message, which is not
/// the same thing once a pointer has been followed.
(String, int) decodeDnsName(Uint8List message, int offset) {
  final labels = <String>[];
  var at = offset;
  var after = -1;
  var jumps = 0;

  while (true) {
    if (at >= message.length) {
      throw const FormatException('DNS name runs past the message');
    }
    final length = message[at];

    if (length == 0) {
      at += 1;
      break;
    }
    if (length & 0xc0 == 0xc0) {
      if (at + 1 >= message.length) {
        throw const FormatException('DNS compression pointer is truncated');
      }
      if (++jumps > _maxCompressionJumps) {
        throw const FormatException('DNS compression pointer loop');
      }
      final target = ((length & 0x3f) << 8) | message[at + 1];
      if (after < 0) after = at + 2;
      if (target >= at) {
        // Pointers must point backwards; anything else can be made to loop.
        throw const FormatException('DNS compression pointer does not go back');
      }
      at = target;
      continue;
    }
    if (length & 0xc0 != 0) {
      throw const FormatException('DNS label has reserved bits set');
    }
    if (at + 1 + length > message.length) {
      throw const FormatException('DNS label runs past the message');
    }
    labels.add(utf8.decode(
      message.sublist(at + 1, at + 1 + length),
      allowMalformed: true,
    ));
    at += 1 + length;
  }

  return (labels.join('.'), after >= 0 ? after : at);
}

/// Pulls the questions out of an incoming message, ignoring every other
/// section. A responder only needs to know what was asked.
List<DnsQuestion> parseQuestions(Uint8List message) {
  if (message.length < 12) return const <DnsQuestion>[];
  final view = ByteData.sublistView(message);

  // Ignore responses; we only answer queries.
  if (view.getUint16(2, Endian.big) & 0x8000 != 0) {
    return const <DnsQuestion>[];
  }

  final count = view.getUint16(4, Endian.big);
  final questions = <DnsQuestion>[];
  var at = 12;
  for (var i = 0; i < count; i++) {
    final (name, next) = decodeDnsName(message, at);
    at = next;
    if (at + 4 > message.length) break;
    questions.add(DnsQuestion(
      name,
      view.getUint16(at, Endian.big),
      view.getUint16(at + 2, Endian.big),
    ));
    at += 4;
  }
  return questions;
}

/// Assembles an authoritative response carrying [answers].
Uint8List buildResponse(List<DnsRecord> answers) {
  final encoded = answers.map((record) => record.encode()).toList();
  final total = encoded.fold<int>(12, (sum, bytes) => sum + bytes.length);
  final out = Uint8List(total);
  ByteData.sublistView(out)
    // mDNS responses carry a zero ID; they are matched by content, not by ID.
    ..setUint16(0, 0, Endian.big)
    ..setUint16(2, _responseFlags, Endian.big)
    ..setUint16(4, 0, Endian.big)
    ..setUint16(6, answers.length, Endian.big)
    ..setUint16(8, 0, Endian.big)
    ..setUint16(10, 0, Endian.big);
  var at = 12;
  for (final bytes in encoded) {
    out.setRange(at, at + bytes.length, bytes);
    at += bytes.length;
  }
  return out;
}
