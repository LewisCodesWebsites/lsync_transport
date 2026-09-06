import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import '../transport/protocol.dart';
import 'peer.dart';

/// Browses the LAN for `_lsync._tcp.local.` (D-01).
///
/// Querying is `multicast_dns`'s job: it already handles query scheduling and
/// cache coherence, which is real work for no gain if reimplemented. Only the
/// advertising side is hand-written, because no non-Flutter package does it.
class MdnsBrowser {
  /// Collects every peer that answers within [timeout].
  ///
  /// mDNS has no "that is all of them" signal, so this is a fixed listening
  /// window rather than a query with an answer.
  static Future<List<DiscoveredPeer>> browse({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = MDnsClient();
    await client.start(
      // Same reason as the responder: the default interface list hides
      // link-local addresses, and on a machine with a VPN adapter that can be
      // exactly where multicast arrives.
      interfacesFactory: (type) => NetworkInterface.list(
        type: type,
        includeLoopback: true,
        includeLinkLocal: true,
      ),
    );
    try {
      final pointers = await _collect(
        client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(serviceType),
        ),
        timeout,
      );

      // Instances can be announced more than once in one window.
      final instances = <String>{
        for (final pointer in pointers) pointer.domainName,
      };

      final resolveWindow = Duration(
        milliseconds: (timeout.inMilliseconds ~/ 2).clamp(500, 3000),
      );

      final peers = <DiscoveredPeer>[];
      for (final instance in instances) {
        final peer = await _resolve(client, instance, resolveWindow);
        if (peer != null) peers.add(peer);
      }
      return peers;
    } finally {
      client.stop();
    }
  }

  static Future<DiscoveredPeer?> _resolve(
    MDnsClient client,
    String instance,
    Duration window,
  ) async {
    final services = await _collect(
      client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(instance)),
      window,
    );
    if (services.isEmpty) return null;
    final service = services.first;

    final texts = await _collect(
      client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(instance)),
      window,
    );
    final txt = _parseTxt(texts);

    final addresses = await _collect(
      client.lookup<IPAddressResourceRecord>(
        ResourceRecordQuery.addressIPv4(service.target),
      ),
      window,
    );
    if (addresses.isEmpty) return null;

    return DiscoveredPeer(
      host: addresses.first.address.address,
      port: service.port,
      deviceName: txt['name'],
      fingerprint: txt['fp'],
    );
  }

  /// multicast_dns hands TXT records back as newline-separated `key=value`.
  static Map<String, String> _parseTxt(List<TxtResourceRecord> records) {
    final entries = <String, String>{};
    for (final record in records) {
      for (final line in record.text.split('\n')) {
        final split = line.indexOf('=');
        if (split <= 0) continue;
        entries[line.substring(0, split)] = line.substring(split + 1);
      }
    }
    return entries;
  }

  /// Listens for a fixed window and returns whatever arrived.
  ///
  /// The lookup streams never end on their own, so a plain `toList()` would
  /// hang and a `Future.timeout` would throw away everything collected.
  static Future<List<T>> _collect<T>(Stream<T> stream, Duration window) async {
    final collected = <T>[];
    final subscription = stream.listen(
      collected.add,
      onError: (Object _) {
        // One unparseable answer should not end the browse.
      },
    );
    await Future<void>.delayed(window);
    await subscription.cancel();
    return collected;
  }
}
