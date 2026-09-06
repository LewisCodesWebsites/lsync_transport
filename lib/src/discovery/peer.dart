/// A device found on the network, or typed in by hand (D-01).
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.host,
    required this.port,
    this.deviceName,
    this.fingerprint,
  });

  final String host;
  final int port;

  /// From the mDNS TXT record. Null on the manual path.
  final String? deviceName;

  /// From the mDNS TXT record. A hint only: it lets the dialler notice a
  /// mismatch before connecting, but the certificate is what actually decides
  /// (D-09). An attacker can put anything in a TXT record.
  final String? fingerprint;

  @override
  String toString() {
    final name = deviceName ?? '(unnamed)';
    final fp = fingerprint == null
        ? ''
        : '  ${fingerprint!.substring(0, 16)}...';
    return '$name  $host:$port$fp';
  }
}

/// Parses the manual fallback field: `host:port`, or `host` for the default
/// port. IPv6 goes in brackets, as it does everywhere else.
DiscoveredPeer parseHostPort(String input, {required int defaultPort}) {
  final text = input.trim();
  if (text.isEmpty) throw const FormatException('empty address');

  if (text.startsWith('[')) {
    final close = text.indexOf(']');
    if (close < 0) throw const FormatException('unclosed [ in IPv6 address');
    final host = text.substring(1, close);
    final rest = text.substring(close + 1);
    if (rest.isEmpty) {
      return DiscoveredPeer(host: host, port: defaultPort);
    }
    if (!rest.startsWith(':')) {
      throw const FormatException('expected :port after ]');
    }
    return DiscoveredPeer(host: host, port: _port(rest.substring(1)));
  }

  final colon = text.lastIndexOf(':');
  if (colon < 0) return DiscoveredPeer(host: text, port: defaultPort);

  final host = text.substring(0, colon);
  if (host.isEmpty) throw const FormatException('empty host');
  return DiscoveredPeer(host: host, port: _port(text.substring(colon + 1)));
}

int _port(String text) {
  final port = int.tryParse(text);
  if (port == null || port < 1 || port > 65535) {
    throw FormatException('"$text" is not a port number');
  }
  return port;
}
