/// Transport layer for LAN clipboard and file sync.
///
/// Discovery (D-01), pairing (D-02), TLS with pinned self-signed certificates
/// (D-09), length-prefixed framing (D-10) and file transfer (D-12). No UI, no
/// clipboard, no platform channels.
library;

export 'src/discovery/advertisement.dart';
export 'src/discovery/browser.dart';
export 'src/discovery/dns_wire.dart';
export 'src/discovery/peer.dart';
export 'src/discovery/responder.dart';
export 'src/files/messages.dart';
export 'src/files/receiver.dart';
export 'src/files/sender.dart';
export 'src/files/sidecar.dart';
export 'src/files/streaming_digest.dart';
export 'src/identity/device_identity.dart';
export 'src/pairing/pairing_code.dart';
export 'src/pairing/pairing_service.dart';
export 'src/store/config_dir.dart';
export 'src/store/trust_store.dart';
export 'src/transport/client.dart';
export 'src/transport/frame.dart';
export 'src/transport/protocol.dart';
export 'src/transport/server.dart';
export 'src/transport/session.dart';
