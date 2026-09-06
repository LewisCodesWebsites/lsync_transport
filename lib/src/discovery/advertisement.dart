import 'dart:io';

import '../transport/protocol.dart';
import 'dns_wire.dart';

/// What this device publishes as `_lsync._tcp.local.`, and which records answer
/// which question (D-01).
///
/// Kept apart from the socket so the decision "this query deserves these
/// records" can be tested directly. The socket half is in [MdnsResponder].
class ServiceAdvertisement {
  ServiceAdvertisement({
    required String deviceName,
    required String fingerprint,
    required this.port,
    required this.addresses,
    String? hostName,
  })  : instanceName = '${toDnsLabel(deviceName)}.$serviceType',
        hostName = hostName ?? '${toDnsLabel(deviceName)}.local',
        txt = <String, String>{'fp': fingerprint, 'name': deviceName};

  /// `<device>._lsync._tcp.local`.
  final String instanceName;

  /// Defaults to a name derived from the instance rather than the machine's,
  /// so two instances on one laptop do not claim the same host record.
  final String hostName;

  final int port;
  final List<InternetAddress> addresses;
  final Map<String, String> txt;

  /// Answers the service-type enumeration query with our type (D-24).
  ///
  /// Shared rather than unique, like the service-type PTR: several devices
  /// legitimately answer this, so no cache-flush bit.
  List<DnsRecord> enumerationRecords() => <DnsRecord>[
        DnsRecord.ptr(name: serviceEnumerationType, target: serviceType),
      ];

  /// PTR, plus everything a browser needs next, so one round trip is enough.
  List<DnsRecord> serviceRecords() => <DnsRecord>[
        DnsRecord.ptr(name: serviceType, target: instanceName),
        ...instanceRecords(),
        ...addressRecords(),
      ];

  List<DnsRecord> instanceRecords() => <DnsRecord>[
        DnsRecord.srv(name: instanceName, target: hostName, port: port),
        DnsRecord.txt(name: instanceName, entries: txt),
      ];

  List<DnsRecord> addressRecords() => <DnsRecord>[
        for (final address in addresses)
          DnsRecord.a(name: hostName, address: address.rawAddress),
      ];

  /// The records that answer [questions]. Empty means stay quiet: a responder
  /// that replies to questions it was not asked is just noise on the LAN.
  List<DnsRecord> answersFor(Iterable<DnsQuestion> questions) {
    final answers = <DnsRecord>[];
    for (final question in questions) {
      final name = stripTrailingDot(question.name);
      if (name == serviceEnumerationType && question.asksFor(dnsTypePtr)) {
        // "What service types exist here?" - answer with ours and nothing
        // else. This is a list of types, not of instances, so no SRV/TXT/A.
        answers.addAll(enumerationRecords());
      } else if (name == serviceType && question.asksFor(dnsTypePtr)) {
        answers.addAll(serviceRecords());
      } else if (name == instanceName &&
          (question.asksFor(dnsTypeSrv) || question.asksFor(dnsTypeTxt))) {
        answers.addAll(instanceRecords());
      } else if (name == hostName && question.asksFor(dnsTypeA)) {
        answers.addAll(addressRecords());
      }
    }
    return answers;
  }
}

/// Makes a DNS label out of a device name. A dot would split it into two
/// labels, and the label limit is 63 bytes.
String toDnsLabel(String deviceName) {
  final label = deviceName.replaceAll('.', '-').trim();
  if (label.isEmpty) return 'lsync';
  return label.length > 63 ? label.substring(0, 63) : label;
}

String stripTrailingDot(String name) =>
    name.endsWith('.') ? name.substring(0, name.length - 1) : name;
