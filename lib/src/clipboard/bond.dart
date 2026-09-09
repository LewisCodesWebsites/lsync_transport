import '../store/trust_store.dart';
import '../transport/session.dart' show constantTimeEquals;

/// Which paired device is the current clipboard partner (D-03).
///
/// A thin reading of state [TrustStore] already held: the bond has been
/// persisted and validated since pairing was built, and nothing read it until
/// now. It lives in `peers.json` and is the only clipboard state that touches
/// disk, which is what D-06 already declares.
///
/// **The bond is decided locally, not negotiated.** Each device stores its own
/// and refuses updates from anyone else. That means the two ends can disagree —
/// switch a phone from the laptop to the desktop and the laptop still believes
/// it is bonded — and the cost of a negotiated bond, a state machine on both
/// sides, buys only that consistency. An explicit refusal carrying a reason
/// buys the part that matters instead: the stale side finds out on its next
/// send rather than pushing into silence.
class ClipboardBond {
  const ClipboardBond(this._store);

  final TrustStore _store;

  /// The bonded device's fingerprint, or null when there is no partner.
  String? get partner => _store.clipboardBond;

  bool get isBonded => partner != null;

  /// Whether [fingerprint] is the current partner.
  ///
  /// Constant-time for the same reason the handshake's fingerprint check is:
  /// these are public values, but the habit is cheap.
  bool isPartner(String fingerprint) {
    final current = partner;
    return current != null && constantTimeEquals(current, fingerprint);
  }

  /// Makes [fingerprint] the clipboard partner, replacing any previous one.
  ///
  /// Switching is a single call because that is what D-03 asks for — bonded to
  /// a laptop today and a desktop tomorrow. The previous partner is not told;
  /// it finds out when it next sends and is refused.
  ///
  /// Throws if the device is not paired: a clipboard bond to an unpinned
  /// fingerprint would be a channel to a device nobody confirmed.
  Future<void> bondTo(String fingerprint) =>
      _store.setClipboardBond(fingerprint);

  /// Drops the bond without unpairing. The devices stay paired for file
  /// transfer, which D-03 keeps separate on purpose.
  Future<void> release() => _store.setClipboardBond(null);
}
