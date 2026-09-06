/// Message types and transcript labels for the lsync wire protocol.
library;

/// Bumped when the frame vocabulary changes incompatibly. Both sides send it
/// in the opening frames and refuse a mismatch rather than guessing.
const int protocolVersion = 1;

/// ALPN protocol name. Both ends offer exactly this, so a handshake against
/// something that is not lsync fails at the TLS layer rather than later.
const String alpnProtocol = 'lsync/1';

/// Default advertised port (D-01).
const int defaultPort = 4917;

/// mDNS service type (D-01).
const String serviceType = '_lsync._tcp.local';

/// The DNS-SD service-type enumeration query, RFC 6763 section 9.
///
/// A browser asks this to populate its list of service types, then browses the
/// types it got back. Until we answered it, lsync never appeared in that list,
/// so no client ever generated a query for [serviceType] and the service was
/// unbrowsable from a phone (D-24).
const String serviceEnumerationType = '_services._dns-sd._udp.local';

// Handshake (D-09).

/// Listener to dialler: version, listener fingerprint, name, and the nonce the
/// dialler must sign.
const String msgHello = 'hello';

/// Dialler to listener: its certificate and the signature over the transcript.
const String msgAuth = 'auth';

/// Listener to dialler: the dialler is authenticated. Carries whether the
/// listener already has it pinned.
const String msgAuthOk = 'auth-ok';

// Pairing (D-02).

/// Either side: this end's user confirmed the short authentication string.
const String msgPairConfirm = 'pair-confirm';

// File transfer (D-12).

const String msgFileOffer = 'file-offer';
const String msgFileAccept = 'file-accept';
const String msgFileChunk = 'file-chunk';
const String msgFileDone = 'file-done';
const String msgFileResult = 'file-result';

/// Either side, at any point: the sender is abandoning the exchange.
const String msgError = 'error';

/// Domain separator for the signature the dialler makes over the listener's
/// nonce (D-09).
///
/// The listener's fingerprint is part of the signed transcript so a signature
/// is only valid for the listener that issued the nonce. Without it a hostile
/// listener could relay a dialler's signature to a third device and pass as
/// that dialler.
const String authTranscriptLabel = 'lsync-auth-v1';

/// Domain separator for the short authentication string (D-02).
const String sasLabel = 'lsync-sas-v1';
