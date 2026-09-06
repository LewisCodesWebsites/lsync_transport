import '../identity/device_identity.dart';
import '../store/trust_store.dart';
import '../transport/protocol.dart';
import '../transport/session.dart';
import 'pairing_code.dart';

/// The D-02 comparison, run identically on both ends of the connection.
///
/// Each side derives the six digits from the two fingerprints it already holds,
/// shows them to its user, and tells the other side whether that user accepted.
/// Only if both accepted does either side pin. Nothing secret crosses the wire,
/// which is the point: there is no code to intercept and relay.
///
/// An attacker terminating TLS in the middle presents a different certificate
/// to each side. Each side then hashes a different pair of fingerprints and
/// displays a different number, and the user comparing the two screens sees it.
Future<void> runPairing({
  required PeerSession session,
  required DeviceIdentity identity,
  required TrustStore trustStore,
  required SasConfirm confirmPairing,
}) async {
  final sas = shortAuthenticationString(
    identity.fingerprint,
    session.peerFingerprint,
  );

  final accepted = await confirmPairing(
    SasPrompt(
      sas: sas,
      peerName: session.peerName,
      peerFingerprint: session.peerFingerprint,
      localFingerprint: identity.fingerprint,
    ),
  );

  // Send our answer before reading theirs. Both sides do the same, so neither
  // ends up waiting on the other.
  await session.send(<String, Object?>{
    't': msgPairConfirm,
    'v': protocolVersion,
    'accepted': accepted,
  });

  final reply =
      await readExpected(session.reader, const <String>{msgPairConfirm});
  requireVersion(reply);
  final peerAccepted = reply.header['accepted'] == true;

  if (!accepted) {
    await session.close();
    throw const HandshakeException('pairing declined on this device');
  }
  if (!peerAccepted) {
    await session.close();
    throw const HandshakeException('pairing declined on the other device');
  }

  await trustStore.pin(session.peerFingerprint, session.peerName);
}
