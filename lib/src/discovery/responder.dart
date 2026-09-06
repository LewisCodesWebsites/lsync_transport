import 'dart:io';

import '../transport/protocol.dart';
import 'advertisement.dart';
import 'dns_wire.dart';

final InternetAddress mdnsGroupV4 = InternetAddress('224.0.0.251');
const int mdnsPort = 5353;

/// TEMPORARY diagnostic, enabled with LSYNC_MDNS_DEBUG=1.
///
/// Observation only: it changes no behaviour, it only reports what arrives and
/// what goes out. Here to split "inbound never reaches us" from "our reply is
/// wrong" for cross-machine discovery. Remove once that is settled.
final bool _mdnsDebug = Platform.environment['LSYNC_MDNS_DEBUG'] == '1';

void _log(String message) {
  if (_mdnsDebug) stdout.writeln('[mdns] $message');
}

/// Advertises `_lsync._tcp.local.` on the LAN (D-01).
///
/// Hand-written because `multicast_dns` only queries and every Dart package
/// that can publish a service is a Flutter plugin. This is the socket half;
/// which records answer which question lives in [ServiceAdvertisement], where
/// it can be tested without a network.
class MdnsResponder {
  MdnsResponder._(this._socket, this._egress, this.advertisement);

  final RawDatagramSocket _socket;

  /// One sending socket per interface, so a response goes out all of them
  /// rather than whichever one the routing table happens to prefer.
  ///
  /// This matters more than it looks: a machine with a VPN adapter can have a
  /// lower-metric multicast route than its real Wi-Fi, and then every reply
  /// leaves down a tunnel no peer is listening on.
  final List<RawDatagramSocket> _egress;

  final ServiceAdvertisement advertisement;

  String get instanceName => advertisement.instanceName;
  String get hostName => advertisement.hostName;

  static Future<MdnsResponder> start({
    required String deviceName,
    required String fingerprint,
    int port = defaultPort,
    String? hostName,
  }) async {
    final advertisement = ServiceAdvertisement(
      deviceName: deviceName,
      fingerprint: fingerprint,
      port: port,
      hostName: hostName,
      addresses: await _localIPv4Addresses(),
    );

    final socket = await _bindMulticast();
    socket.multicastLoopback = true;
    // RFC 6762 section 11: mDNS traffic goes out with IP TTL 255, and a
    // receiver is entitled to discard anything else as possible off-link
    // spoofing. Apple's mDNSResponder does check. Dart's default is 1 (D-22).
    socket.multicastHops = 255;

    // Join on every interface rather than trusting the default one, and
    // include link-local: Dart hides 169.254 addresses by default, but a
    // VPN or virtual adapter sitting on one can still be where multicast
    // actually leaves the machine. Joining only the "real" interfaces means
    // never seeing our own traffic, or a peer's.
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: true,
      includeLinkLocal: true,
    );
    var joined = 0;
    for (final interface in interfaces) {
      try {
        socket.joinMulticast(mdnsGroupV4, interface);
        joined++;
        _log('joined group on ${interface.name} '
            '(${interface.addresses.map((a) => a.address).join(",")})');
      } on Object catch (error) {
        _log('join FAILED on ${interface.name}: $error');
      }
    }
    if (joined == 0) {
      try {
        socket.joinMulticast(mdnsGroupV4);
      } on Object catch (error) {
        socket.close();
        throw StateError('could not join the mDNS group: $error');
      }
    }

    final egress = await _bindEgress(interfaces);
    _log('receive socket bound ${socket.address.address}:${socket.port} '
        'multicastHops=${socket.multicastHops} '
        'loopback=${socket.multicastLoopback}');
    for (final e in egress) {
      _log('egress socket ${e.address.address}:${e.port} '
          'multicastHops=${e.multicastHops}');
    }

    final responder = MdnsResponder._(socket, egress, advertisement);
    socket.listen(responder._onEvent);
    _log('sending unsolicited announcement');
    responder._announce();
    return responder;
  }

  /// A sending socket per interface address that will accept a bind. Stale
  /// adapters refuse, which is how they get filtered out.
  static Future<List<RawDatagramSocket>> _bindEgress(
    List<NetworkInterface> interfaces,
  ) async {
    final sockets = <RawDatagramSocket>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        try {
          final socket = await RawDatagramSocket.bind(address, 0);
          socket.multicastLoopback = true;
          socket.multicastHops = 255; // D-22, as above.
          sockets.add(socket);
        } on Object {
          // A stale adapter still holding an address it cannot bind.
        }
      }
    }
    return sockets;
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket.receive();
    if (datagram == null) return;

    final from = '${datagram.address.address}:${datagram.port}';
    final data = datagram.data;
    final isResponse =
        data.length >= 4 && (data[2] & 0x80) != 0;

    final List<DnsQuestion> questions;
    try {
      questions = parseQuestions(data);
    } on FormatException catch (error) {
      _log('IN  $from ${data.length}B UNPARSEABLE ($error) -> ignored');
      // A malformed query from somewhere on the LAN is not our problem.
      return;
    }

    final answers = advertisement.answersFor(questions);

    if (questions.isEmpty) {
      _log('IN  $from ${data.length}B '
          '${isResponse ? "response" : "query with no questions"} -> ignored');
    } else {
      _log('IN  $from ${data.length}B asks '
          '${questions.map((q) => "${q.name}/type=${q.type}").join(", ")} '
          '-> ${answers.isEmpty ? "NO ANSWER" : "answering ${answers.length} "
              "records"}');
    }

    if (answers.isEmpty) return;

    _send(answers);

    // Also answer the querier directly when it is not itself on 5353.
    //
    // Multicast is delivered by destination port, so a client that could not
    // take 5353 never sees the group reply. That is the normal case for a
    // second instance on one machine, since Windows has no reusePort and this
    // responder already holds the port.
    if (datagram.port != mdnsPort) {
      _send(answers, to: datagram.address, port: datagram.port);
    } else {
      _log('    (no unicast reply: source port is 5353, so the multicast '
          'reply is the only path to this querier)');
    }
  }

  /// Sent unprompted on startup so browsers already listening pick us up
  /// without waiting for their next query.
  void _announce() => _send(advertisement.serviceRecords());

  void _send(List<DnsRecord> answers, {InternetAddress? to, int? port}) {
    final message = buildResponse(answers);
    final target = to ?? mdnsGroupV4;
    final targetPort = port ?? mdnsPort;

    // From the bound socket first, so the response carries source port 5353,
    // which is what a strict client expects.
    try {
      final sent = _socket.send(message, target, targetPort);
      _log('OUT ${target.address}:$targetPort ${message.length}B '
          'from ${_socket.address.address}:${_socket.port} '
          'ttl=${_socket.multicastHops} wrote=$sent');
    } on SocketException catch (error) {
      _log('OUT ${target.address}:$targetPort FAILED from '
          '${_socket.address.address}: $error');
      // The interface went away mid-send. The next query will retry.
    }

    // A unicast reply is already going to a known address; only multicast
    // needs spraying across interfaces.
    if (to != null) return;

    for (final socket in _egress) {
      try {
        final sent = socket.send(message, target, targetPort);
        _log('OUT ${target.address}:$targetPort ${message.length}B '
            'from ${socket.address.address}:${socket.port} '
            'ttl=${socket.multicastHops} wrote=$sent');
      } on SocketException catch (error) {
        _log('OUT ${target.address}:$targetPort FAILED from '
            '${socket.address.address}: $error');
        // One interface failing does not stop the others.
      }
    }
  }

  Future<void> stop() async {
    try {
      _socket.leaveMulticast(mdnsGroupV4);
    } on Object {
      // Socket already gone.
    }
    _socket.close();
    for (final socket in _egress) {
      socket.close();
    }
  }

  static Future<RawDatagramSocket> _bindMulticast() {
    // reusePort lets several responders share 5353 where the platform has it.
    // Windows does not, and Dart writes a raw error to stderr before failing
    // the call, so ask for it only where it exists rather than catching.
    return RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      mdnsPort,
      reuseAddress: true,
      reusePort: !Platform.isWindows && !Platform.isAndroid,
    );
  }

  static Future<List<InternetAddress>> _localIPv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return <InternetAddress>[
      for (final interface in interfaces) ...interface.addresses,
    ];
  }
}
