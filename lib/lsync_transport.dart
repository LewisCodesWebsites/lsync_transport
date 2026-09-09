/// Transport layer for LAN clipboard and file sync.
///
/// Discovery (D-01), pairing (D-02), TLS with pinned self-signed certificates
/// (D-09), length-prefixed framing (D-10), file transfer (D-12) and clipboard
/// sync (D-03, D-05, D-11). No UI, no platform channels: the OS clipboard is
/// supplied by the app through [ClipboardAccess], the way the config directory
/// is.
library;

export 'src/clipboard/bond.dart';
export 'src/clipboard/clipboard_access.dart';
export 'src/clipboard/history.dart';
export 'src/clipboard/messages.dart';
export 'src/clipboard/sync_engine.dart';
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
