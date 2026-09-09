# Design doc: LAN clipboard and file sync

Last updated: 2026-09-09 (rev 22)

## Problem

Moving a link, a screenshot, or a file between an Android phone and a Windows or
Linux machine currently means emailing it to yourself. KDE Connect and Phone Link
both exist and both have gaps: Phone Link is Windows-only and depends on OEM
integration, KDE Connect's Windows client is the weakest part of an otherwise
good project.

## Scope

Clipboard sync and file transfer between Android, Windows and Linux, over the
local network, with no account and no server.

## Non-goals

These are deliberate exclusions, not missing features.

- **SMS and calling.** Requires default-SMS-handler status, and RCS has no
  third-party API at all, so an SMS-only bridge would ship visibly broken in 2026.
- **App mirroring.** Requires ADB wireless debugging, which needs re-pairing after
  reboot on many devices. That is precisely the setup overhead this tool exists to
  avoid, and it is imposed by Android rather than by any design choice.
- **Cross-network sync.** Phone on mobile data cannot reach the laptop. Supporting
  it means running a relay server, which means an account, a hosting bill, and my
  server sitting in the path of the user's clipboard.
- **More than one clipboard partner.** See D-03.

Phone Link does the first two well because Microsoft ships a privileged
system-level component through OEM agreements with Samsung and Honor. That access
is not available to third parties, so competing on those features is not an
engineering problem, it is a contractual one.

## Architecture

    Android app            Desktop app (Windows / Linux)
    +-----------+          +-----------+
    | clipboard |          | clipboard |
    | files     |          | files     |
    +-----+-----+          +-----+-----+
          |                      |
       +--+----- transport ------+--+
       |  mDNS discovery            |
       |  TLS 1.3, pinned certs     |
       |  length-prefixed frames    |
       +----------------------------+

One protocol implementation, two front ends. Discovery, pairing and transport are
shared; only the clipboard access layer is platform-specific, because that is the
only place the operating systems genuinely differ.

---

## Decisions

Each entry: what was chosen, what was rejected, why, what it cost, and what would
change the answer.

### D-01 Discovery over mDNS, with manual IP fallback

**Status:** decided

**Decision.** Advertise `_lsync._tcp.local.` over mDNS. Offer a manual IP entry
field for networks where that fails.

**Rejected.** *UDP broadcast:* simpler, but blocked or rate-limited by many
consumer routers and dead on any network with client isolation. *Cloud
rendezvous:* works across networks, but needs an account, a paid host, and puts a
third-party server in the path of the clipboard. *Manual IP only:* trivial, and
contradicts the no-configuration goal outright.

**Why.** mDNS is what the LAN already speaks, so the common case needs no setup at
all, and the fallback field covers filtered networks without running any
infrastructure.

**Cost.** LAN only. Does not work away from home. Listed under non-goals.

**Implementation notes.** No Dart package advertises an mDNS service outside
Flutter, so the responder is hand-written over `RawDatagramSocket`; `multicast_dns`
covers querying only. Windows has no `reusePort`, so two instances on one machine
cannot both bind 5353. The responder therefore also answers by unicast when a
query arrives from a source port other than 5353, which is what RFC 6762 section
6.7 requires anyway.

**Proven cross-machine, in two halves.** The two halves prove different things
and neither substitutes for the other.

*Discovery and resolution (rev 13).* An iPhone on the same Wi-Fi, running a
third-party DNS-SD browser, enumerated `_lsync._tcp` in its service type list,
resolved the instance, and displayed `lsync31136.local:4917`, address
`192.168.1.241`, and both TXT keys with the fingerprint matching the running
advertiser character for character. Apple's implementation is independent of this
codebase and shares none of its assumptions, so this validates the hand-written
responder, and the records it emits, against something we do not control on a
machine we do not control. It proves the advertisement is correct. It proves
nothing about connecting, because the iPhone never opened a socket to us: every
byte of it was multicast.

*Connection and transfer (rev 18).* The Android app dialled a typed
`192.168.1.241:4917` over Wi-Fi, paired with digits compared on both screens
(`480 747`), and transferred an 8 MB file. The digest agreed three ways: computed
before sending, recomputed by the receiver and echoed back, and checked
independently with `sha256sum` against the bytes on disk. No `.part` or sidecar
survived. `adb reverse --list` was empty for the whole run, so the USB tunnel used
in an earlier attempt could not have carried it. This proves the manual
`host:port` fallback carries a real connection between two machines, which is what
the rev 13 result could not show.

That result took from 2026-09-03 to 2026-09-06 and six wrong explanations to
reach. The history is preserved in D-19 through D-25 rather than tidied away,
because the sequence is more instructive than the conclusion.

**Proven on one host (rev 4, still true).** Two instances discover each other via
the unicast reply path, pair with compared digits, and transfer a file with a
matching digest, no address typed anywhere. Covered by tagged tests
(`dart test -P mdns`), kept out of the default run per D-13. Note this was
*recorded* as proof of the code in rev 4 when it was partly a property of that
day's environment; it holds now, but it did not establish what it claimed at the
time.

**Query answering proven (rev 10).** Instrumented logging recorded inbound queries
being received and answered, which had never been observed before. Prior to this,
Bonjour's ability to see the service could not be distinguished from it caching the
unsolicited startup announcement.

**Revisit if.** Cross-network sync is genuinely wanted, or the fallback field turns
out to be used constantly on school Wi-Fi.

### D-02 Pairing by short authentication string

**Status:** decided

**Decision.** Both devices independently derive six digits from a hash of both
certificate fingerprints, sorted so the two sides agree on order, and display the
result. The user confirms the two numbers match. Each side then pins the other's
fingerprint. Later connections are automatic. A QR code carries the fingerprint
directly, which skips the comparison step entirely.

**Rejected.** *A code generated on one device and typed into the other:* stops a
stranger pairing casually, but an attacker who intercepts the first connection can
terminate TLS on both sides and relay the code, and both users see a match.
*Accept-prompt on both ends,* as KDE Connect does: same weakness, with nothing
bound to the keys at all. *A PAKE such as SPAKE2:* immune to relay by
construction, and a whole subsystem for a threat that a compared number already
covers.

**Why.** Deriving the digits from both fingerprints binds the number to the actual
keys. An attacker in the middle holds a different fingerprint on each side, so the
two displayed numbers differ and the user sees it. This is the mechanism behind
Bluetooth numeric comparison and Signal safety numbers, and it costs about the
same as typing a code would have.

**Cost.** The user compares rather than types, so both screens must be visible at
once. Fine for a phone next to a laptop.

**Revisit if.** Comparing proves error-prone in practice, or QR becomes the path
almost everyone uses.

### D-03 Clipboard is a bond, files are a send

**Status:** decided

**Decision.** Clipboard syncs between exactly one pair of devices at a time. The
bond is switchable, so a phone can be bonded to a laptop today and a desktop
tomorrow. File transfer targets any paired device, chosen at send time, in the
manner of AirDrop.

**Rejected.** *One device model for both:* broadcasting the clipboard to every
paired device means every machine sees every copied item, and picking a target
each time you copy something is unusable.

**Why.** These are different kinds of thing. Clipboard is continuous shared state
between two endpoints, so it needs a bond with a direction. File transfer is a
discrete event with a recipient chosen at the moment of sending. Sharing the
discovery and trust layers while separating the behaviour above them is what makes
both usable.

**Cost.** A small amount of extra state: which pairing is currently the clipboard
bond, and a way to change it.

**Built (rev 22).** The bond reads and switches the `clipboardBond` field
`TrustStore` has persisted and validated since pairing was built and which
nothing had read until now. It is the only clipboard state that touches disk, and
D-06 already declares it. Bonding to an unpaired fingerprint is refused, and
unpairing the partner clears the bond: a bond to a device nobody confirmed is not
a bond.

**The bond is decided locally, not negotiated.** Each device stores its own and
refuses updates from anyone else. The two ends can therefore disagree — switch a
phone from the laptop to the desktop and the laptop still believes it is bonded.
A negotiated bond would prevent that at the cost of a state machine on both
sides; instead there is an explicit refusal carrying a reason, which buys the
part that matters. *Rejected: silent refusal*, which is the same disagreement
with no way for the stale side to learn about it — the failure would look like a
clipboard that had simply stopped working.

**Neither side pushes on reconnect.** The next copy syncs naturally. *Rejected:
the reconnecting side pushes its current clipboard*, which risks clobbering
something the user copied locally while the link was down; and *last-write-wins*,
which needs a timestamp on every update and therefore a clock to reason about
across two devices, for a race the user resolves themselves by copying again.

**An unreachable partner costs one remembered item, not a queue.** A clipboard
has a current value, not a backlog, so the pending slot has depth one and a newer
copy replaces a waiting one rather than stacking behind it. Nothing accumulates,
nothing is persisted, and it is dropped on close.

One honest limit found while testing it: the slot holds an item when a send
*raises*. A destroyed TCP socket accepts writes without raising, so a send into
one looks successful and the item is dropped rather than remembered. The engine
cannot detect that; what notices a dead peer is the read loop reaching EOF, which
belongs to the caller that owns the session.

**Revisit if.** Users turn out to want clipboard across three devices often enough
to justify the confusion.

### D-04 Phone-to-PC clipboard requires a tap

**Status:** decided, forced by the platform

**Decision.** On Android, sending the clipboard to the PC requires tapping a
persistent notification. PC-to-phone remains automatic.

**Rejected.** *ADB or Shizuku grant:* fully automatic afterwards, but requires
enabling developer mode and running a command per device, which is exactly the
setup overhead this project exists to remove. *Companion keyboard:* an active
input method may read the clipboard legitimately, but nobody switches keyboards
for a sync app. *Accessibility service:* works, and Play Store policy treats it as
API abuse.

**Why.** Android has blocked background clipboard reads since Android 10. Every
route around that is either a per-device setup burden, an adoption non-starter, or
a policy violation. An honest limitation beats a hack that undermines the tool's
own premise.

**Cost.** The headline feature is asymmetric, and that asymmetry has to be
explained in the UI rather than hidden.

**Two further costs, added after the test device was chosen.**

*The notification is a runtime permission, not a manifest line.* Android 13
(API 33) requires `POST_NOTIFICATIONS` to be requested at runtime. Declaring it in
the manifest alone means the notification silently never appears, so the headline
feature looks broken rather than unpermitted. The request has to be part of
first-run, and refusing it has to be handled rather than left to fail quietly.

*Every send shows a system toast the app cannot suppress.* Since Android 12, an
app reading clipboard content that originated elsewhere triggers a system message
naming both apps, for example "lsync pasted from Chrome". So a single clipboard
send costs the user a notification tap plus a toast they did not ask for, and half
of that is outside our control. It does not change the decision, since every
alternative is worse for the reasons above, but it is what the feature actually
feels like in use and should not surprise anyone reading this later.

**Revisit if.** Android ever exposes a sanctioned API for this. It has not in six
major versions.

### D-05 Clipboard history stays in memory

**Status:** decided

**Decision.** Keep the last twenty clipboard entries in memory. Cleared when the
app closes. Never written to disk.

**Rejected.** *On disk, encrypted at rest:* history would survive restarts, but
requires Android Keystore plus Windows DPAPI plus a Linux equivalent, and the
consequences of getting it wrong are severe. *On disk, plaintext:* a readable log
of every password and 2FA code the user has copied.

**Why.** People copy credentials. A persistent clipboard log is a high-value target
for a low-value feature. In-memory history delivers the useful part with none of
the liability, and keeps the storage claim in D-06 true.

**Cost.** History does not survive a restart.

**Built (rev 22).** Twenty entries, newest first, each recording the content, the
direction it travelled and the origin fingerprint. Cleared when the sync closes.
A suppressed echo is not an entry — it is the same item arriving back, and
recording it would fill the history with duplicates of whatever was copied last.

**Revisit if.** Users ask for persistence often, and only alongside proper
platform keychain integration.

### D-06 Only keys and device names touch disk

**Status:** decided

**Decision.** Persist the device's own private key and certificate, peer
certificate fingerprints, device names, and which pairing is the current clipboard
bond. Nothing else is retained.

This governs *retained* state, meaning anything the app keeps **invisibly**.
That is the distinction, and it is not the same as the original test.

**Amended for resume (rev 20).** The original wording said in-flight artifacts
were outside scope because "they are deleted on both completion and failure".
Resume (D-07) requires a partial to survive a failure, which by that test makes
it retained state and puts it inside a list that says "nothing else". The
distinction that survives is not *how long* something lasts but *whether the
user can see it*:

- **Invisible state** is what this entry restricts, and the list above is
  complete. Keys, fingerprints, device names, the clipboard bond. Nothing else.
- **A partial transfer is visible.** `<name>.part` sits in the destination the
  user chose (D-12), obviously incomplete and obviously named. They can see it
  and delete it.

**Partials therefore survive with no expiry**, until resumed, replaced, or
deleted by the user.

*Why no expiry.* This is what every browser already does: Chrome leaves
`.crdownload`, Firefox leaves `.part`, both indefinitely and both in the
download folder. Users recognise the pattern, and following an established
convention beats inventing an expiry policy that would need defending.

**Rejected.** *A fixed lifetime:* requires a timestamp in the sidecar, which is
the same class of field this entry refused for paired-at, so the entry would be
amended twice over, and the number chosen would be arbitrary. *Session-only
survival:* the cleanest privacy story, but it removes resume from precisely the
case D-07 exists for, a phone that drops Wi-Fi and is then killed by MIUI, and it
contradicts D-12's promise that the offset survives a restart.

**Still deleted immediately:** a completed transfer, and a transfer that failed
because the *content* was wrong rather than the connection breaking. A digest
mismatch, a size overrun or an out-of-order chunk all discard, because those
bytes are known bad and resuming from them would fail the same way forever.

**Revisit if.** A destination is ever somewhere the user cannot see. The argument
above holds only while the partial is visible; on desktop D-12 puts it in a real
folder, but if a future Android build writes into app-private storage the
partial becomes hidden and this reasoning stops applying. At that point the
partial is invisible retained state and this entry must be reopened.

**Rejected.** *Transfer history:* useful, but a log of filenames is still a record
of user activity, and it would need a clear-all to be defensible. *A paired-at
timestamp on each peer:* useful for debugging and for a future "forget devices not
seen since" feature, but "nothing else is retained" is worth more as a literally
true claim than as a nearly true one. Excluded deliberately rather than by
oversight.

**Why.** A short, complete list of what is stored is a claim that can be verified
by reading the code, which is worth more than a feature. Naming the private key
explicitly rather than folding it into "keys" keeps the list literally complete.

**Cost.** No record of what was sent or when.

**Revisit if.** Debugging in the field proves impossible without a log, in which
case it should be opt-in and clearable.

### D-07 Resume interrupted transfers, but not first

**Status:** decided, sequenced, **both passes built, amended rev 21**

**Decision.** A transfer interrupted by a dropped connection resumes from its last
confirmed offset. Implementation order: build fail-loudly-and-delete-the-partial
first, get the full pipeline working end to end, then add resume as a second pass.

**Rejected.** *Fail loudly, permanently:* least code, and a poor experience on
exactly the flaky networks this runs on. *Automatic retry from zero:* no offset
bookkeeping, but wasteful on large files and infuriating on a bad connection.

**Why.** Resume is the behaviour a real tool needs. Sequencing it second means the
project is never more than a day away from something demonstrable, which is the
main defence against it stalling half-built.

**Cost.** Requires a transfer ID stable across reconnects, offset tracking, a
holding location for partial files, and integrity checking that works across a
split session.

**Built (rev 20).** Transfer identity is name, size and whole-file digest, with
no transfer ID: an ID identifies an *attempt*, and two attempts at the same file
should share a partial rather than fork it. The receiver decides the offset,
because it holds the bytes and the sender cannot know what a crash left. The
sidecar carries a digest of the partial's first N bytes, verified before a single
byte is appended; without it corruption surfaces only at the end, unattributable,
forcing a full restart, which is the outcome named below as grounds for
abandoning the feature. The sender caches the whole-file digest in memory only,
keyed on path, size and mtime, so repeated reconnects in one session do not each
pay D-17's full read; it is never persisted, so it adds no retained state.

D-13's killed-connection test is live and passes 6/6: a transfer killed at 50%
resumes to a digest identical to an uninterrupted one, checked against the bytes
on disk rather than the sender's claim, and asserting that it genuinely resumed
rather than quietly starting over.

**Amended (rev 21): a hard kill resumes too.** Rev 20 recorded a known limit —
that `SIGKILL` left an unresumable partial — and proposed a per-block digest list
to close it. Both the limit and the proposal came from one conflation, which is
worth stating plainly because it is the reason the actual fix is about ten lines:

> **Crash consistency and tamper detection are different problems.** *Are the
> first N bytes durably on disk?* is answered by D-12's flush ordering: the
> receiver flushes before it records, so the recorded offset can never run ahead
> of the file. That holds with no digest at all. *Are those bytes still the ones
> we wrote?* is what the prefix digest answers, and it is a check, not a licence.
> Requiring the second in order to get the first is what made a kill throw away
> the whole partial.

The prefix digest can only be computed when a session ends in a way the receiver
catches, because SHA-256 state cannot be snapshotted mid-stream and recomputing
it per checkpoint would cost a full read each time. So a periodic checkpoint
carries no digest — and that is now fine. Two changes:

1. **The sidecar write is atomic**: temporary file, flush, rename, the same
   pattern `TrustStore._save` already used. A plain `writeAsString` is
   open-with-truncate then write, so a kill inside that window left a truncated
   record *and* had already destroyed the previous good one. `delete()` also
   removes a stranded temporary, so a killed write leaves nothing behind (D-06).
2. **`isResumable` is `offset > 0`.** A prefix digest is verified when present
   and is not required. Everything else still gates: a readable v2 sidecar, a
   matching name/size/whole-file digest, a `.part` at least that long, and
   truncation of anything written past the recorded offset.

**Why relaxing the gate is safe.** *The whole-file digest at the end always
runs.* An unverified resume therefore cannot produce a corrupt file that passes;
it can only append to bad bytes, fail the final check, and discard. The cost is
bounded to one wasted transfer, and the failure is loud. This is the load-bearing
argument for the whole amendment — the reason a missing early check downgrades an
outcome rather than endangering one — and it should not have to be rederived.

**Block-digest list: withdrawn.** A list of per-block digests in the sidecar
would have made a killed partial verifiable up front. It is withdrawn, not
deferred. It bought crash consistency that flush ordering already provides, and
its only remaining value was moving the kill-then-edited case's failure earlier —
converting one wasted transfer into a faster rejection — at roughly 32 KB of
sidecar per 2 GB transferred plus a second integrity scheme to keep correct
alongside the whole-file digest. Do not propose it again without new evidence:
specifically, evidence that partials are being edited or corrupted in practice,
or that the wasted-transfer cost is being paid often enough to matter.

**Known limit, platform.** `temp → flush → rename` makes the *contents* durable
and the swap single-step, but Dart exposes no way to `fsync` the containing
directory, so on POSIX the rename itself is not guaranteed durable across a power
cut or kernel panic. This is explicitly out of scope for the case being fixed:
`SIGKILL` kills a process, not the page cache, so a rename that has returned is
visible to every later reader. It would only matter for sudden machine death,
where the cost is one lost checkpoint interval — the same cost a kill already has.

**Tests (rev 21).** Two added, at 6/6 alongside the existing three: a partial
written by hand with a digest-less checkpoint — exactly the on-disk state a kill
leaves — resumes from its recorded offset; and the same partial with an edited
byte runs to completion, fails the whole-file digest, and leaves nothing behind.
Constructed on disk rather than by killing a real process, so the test does not
depend on where the checkpoint interval happens to fall.

One test bug surfaced with the change and is worth recording, because it was a
correctness signal and not noise. Two waits polled `isResumable` as a proxy for
*the receiver has finished preserving*. Relaxing the gate made a mid-transfer
checkpoint satisfy that proxy, so the waits returned while the receiver still
held the `.part` open. They now wait on the prefix digest, which is what they
meant. The proxy was wrong before the change too; it was merely not observable.

**The partial is read once (rev 21).** Checking a partial and seeding the running
digest with it were two separate passes over the same bytes. They are now one:
the offset and a digest already carrying those bytes are returned together, so an
offset can no longer be obtained without its seeded digest. Resume exists for
large files on bad connections, so reading the partial twice doubled the cost of
exactly the operation the feature makes cheap — and it did so on every reconnect,
which on a flaky link is the common case rather than the rare one.

Where a recorded prefix digest exists, that single read feeds two digest objects
rather than one: `finish()` closes the chunked conversion, and SHA-256 state
cannot be snapshotted or copied, so the value to compare and the state to
continue from cannot be the same object. Two hashes over bytes already in memory
is the cheap half; the read is the expensive half, and that is the half now paid
once. A digest-less checkpoint — the post-kill case — needs only one digest.

**Revisit if.** Resume proves to be a source of corruption bugs, in which case
fail-loudly is a legitimate place to stop.

### D-08 Flutter and Dart for all three platforms

**Status:** provisional

**Decision.** One Flutter codebase for Android, Windows and Linux, with platform
channels for clipboard access where the OS APIs differ.

**Rejected.** *Kotlin plus a Node desktop app:* two codebases means implementing
the protocol twice, which is where bugs live. *Go with a shared core:* the best
networking libraries of the options considered, but gomobile bindings are fiddly
and its concurrency errors are the least readable while learning. *Python
desktop:* distribution to someone else's machine is genuinely painful.

**Why.** One protocol implementation. LocalSend is a working open-source
implementation of a closely related app in the same stack, which means there is
something to read when behaviour is confusing.

**Cost.** Clipboard hooks still need small platform-specific pieces, so it is not
truly one codebase.

**Revisit if.** Platform channel work for clipboard grows large enough that native
apps would have been simpler.

### D-09 TLS 1.3 with self-signed certificates

**Status:** implementation detail

**Decision.** TLS 1.3 throughout. Each device generates a self-signed certificate
on first run. Fingerprints are pinned at pairing (D-02). No certificate authority
is involved.

Authentication is asymmetric by necessity. The dialling side pins the listener's
certificate at the TLS layer. The listening side cannot do the same, because
without a CA there is no clean way to have the TLS stack accept a self-signed
client certificate and then hand it over for a fingerprint check. So the listener
authenticates the dialler at the application layer: it sends a random nonce, and
the dialler signs a transcript with the private key behind its pinned certificate.

The transcript is a fixed context label, the listener's own fingerprint, and the
nonce. Signing the bare nonce is not sufficient: a hostile listener could relay a
dialler's signature to a third device and pass as that dialler. Binding the
listener's identity into the signed material closes that, and the context label
stops a signature being replayed against a future version of the protocol.

**Why.** There is no CA that can vouch for a laptop on a home network, and pinning
makes one unnecessary. The signed nonce is proof of key possession, so the
application-layer half is not weaker in substance, and it is safe here because the
channel is already authenticated to the listener's pinned key from the dialler's
side. Nobody can be in the middle to relay the challenge.

**Caveat, honestly recorded.** Dart's public API cannot enforce a minimum TLS
version or report the negotiated one, so "TLS 1.3" is what BoringSSL will
negotiate between two peers that both support it, not something the code asserts
or tests. Practical exposure is small, since both ends are this codebase and an
unpinned peer cannot pair at all, but the claim is unverifiable from inside the
program and should not be written as though it were checked.

### D-10 Length-prefixed frames, JSON header plus binary body

**Status:** implementation detail

**Decision.** Each message is a four-byte big-endian length prefix, a JSON header,
then an optional binary payload streamed in 64 KiB chunks. The chunk size is large
enough that per-frame overhead is noise and small enough to bound memory on a
phone.

The length prefix measures the JSON header only. The body length is declared as a
field inside the header. Prefixing the whole message would cap a frame at 4 GB and
force the sender to know the body length before writing the header, which defeats
streaming. Headers are capped at 64 KiB and frame bodies at 1 MiB, because an
unauthenticated peer must not be able to trigger an arbitrary allocation by
declaring a large length.

**Why.** Streaming file bodies rather than buffering them is what keeps a 2 GB
transfer from exhausting memory on a phone. JSON headers keep the protocol
readable during debugging, which matters more than the bytes saved by a binary
format at this scale.

### D-11 Clipboard loop prevention by content hash

**Status:** implementation detail

**Decision.** Each clipboard update carries a hash of its content and an origin
device ID. A device ignores an incoming update whose hash matches its current
clipboard.

**Why.** Without this, A sets B, B observes a change and sets A, indefinitely.
Hash comparison handles the case where both devices legitimately hold the same
content, which a naive origin check does not.

**Amended (rev 22): compare against the last hash applied or sent, not against
the clipboard.** The original rule said a device ignores an update "whose hash
matches its current clipboard". That is a correction rather than a refinement,
for two reasons.

*It could not be executed on the platform D-04 is about.* Evaluating it
literally means reading the local clipboard on every inbound update — and
reading the clipboard in the background is exactly what Android has blocked
since Android 10, which is the whole premise of D-04. So the rule as written was
unrunnable on the device the feature is for, and would have been discovered only
when the loop failed to terminate on a handset.

*It also had a race on the platforms where it could run.* Applying an incoming
item sets the clipboard, which fires the local change watcher. The watcher runs
before any read would reflect the new value, so the echo escapes the check and
goes back out — the loop the rule exists to stop, on a machine where the rule was
supposedly working.

The engine therefore keeps the digest of the last content it applied or sent, in
memory, and compares against that. It needs no clipboard read, so it runs
identically on every platform, and it is set *before* the write rather than
after, so the watcher's echo meets a value that already matches. Everything the
original rule bought is kept, including the both-devices-hold-the-same-content
case, which is why it was hash comparison rather than an origin check.

**Origin is checked, but not trusted as declared.** The update carries an origin
fingerprint (D-14) and the receiver compares it against the fingerprint the
handshake actually proved (D-09), refusing a mismatch. A header field can say
anything, and nothing in this design relays a clipboard on another device's
behalf, so the two must agree.

---

### D-12 Partial files land beside the destination

**Status:** implementation detail

**Decision.** An in-progress transfer writes to `<name>.part` in the destination
directory, with a sidecar holding the transfer ID and last confirmed offset. On
completion the file is atomically renamed to its final name and the sidecar is
removed.

**Why.** The user can see that something is in progress and where it will land. The
offset survives an app restart, not just a reconnect. A temp directory elsewhere
would need its own cleanup policy and would break when the destination is on a
different filesystem.

**Built (rev 21), and one invariant worth naming.** The sidecar holds size,
whole-file digest and offset rather than a transfer ID — D-07 explains why the ID
was dropped. The ordering rule is the part other entries lean on:

> **Flush before you record.** The receiver flushes the `.part` to disk *and then*
> writes the offset, never the reverse. So the recorded offset can never run ahead
> of the bytes actually on disk, and a reader may trust everything below it.

That one line is what makes a killed transfer resumable at all, and D-07's
amendment is mostly the consequence of taking it seriously. Written down here
because that is where it gets cited from. The sidecar write itself is
temp-then-rename for the same reason the rename of the `.part` is atomic: a
half-written record is worse than an old one.

### D-13 Integration tests run two instances against each other

**Status:** implementation detail

**Decision.** CI starts two instances of the core, transfers a generated file with
a known SHA-256, and asserts the received hash matches. A second test kills the
connection at roughly 50% and asserts that resume produces an identical hash.

**Why.** Sync has objective pass conditions, so the tests can be real rather than
decorative. The killed-connection case is the one that matters, because D-07 is
where corruption would come from.

### D-14 A device's identity is its certificate fingerprint

**Status:** implementation detail

**Decision.** The "origin device ID" referred to in D-11 is the device's
certificate fingerprint. There is no separate identifier.

**Rejected.** *A random UUID generated at first run:* a second identity to
generate, persist and keep unique, and an unauthenticated one, since anyone can
claim to be any UUID.

**Why.** The fingerprint is already pinned at pairing, already unique, and already
proven by the handshake, so an ID derived from it cannot be spoofed by a peer.

### D-15 Download location is passed in, not stored

**Status:** implementation detail, provisional

**Decision.** The destination directory for received files is supplied by the
caller (a CLI flag for now) rather than persisted.

**Why.** Persisting a configured path would be new retained state under D-06 for a
convenience, and a hardcoded `~/Downloads` is wrong on Android anyway.

**Revisit if.** The real app needs a remembered download location, which it
probably will, at which point D-06 gets an amendment rather than a quiet exception.

### D-16 Received filenames are untrusted input

**Status:** implementation detail

**Decision.** A filename arriving over the network is reduced to a basename on
both separator conventions, with Windows reserved device names, trailing dots and
control bytes refused. `../../.bashrc` becomes `.bashrc` inside the destination
directory. A name that collides with an existing file fails the transfer.

**Rejected.** *Trusting the sender's path:* the obvious directory traversal.
*Silently overwriting on collision:* destroys data without asking. *Automatic
`name (1)` renaming:* reasonable, but a product decision the transport layer
should not make by itself.

**Why.** The name arrives from the network and is used to write to disk. The doc
originally said nothing about this, which was an omission rather than a decision.

**Revisit if.** The UI layer is ready to own a collision policy, at which point
`name (1)` or a prompt belongs there rather than here.

### D-17 Pre-hash the file so the digest travels in the offer

**Status:** implementation detail

**Decision.** The sender hashes the whole file before transferring, and the offer
carries the SHA-256. Costs one extra read pass.

**Rejected.** *A trailing digest sent after the body:* no pre-pass, but the
receiver cannot validate a resumed transfer whose earlier bytes arrived in a
previous session, and cannot recognise a file it already holds before accepting
it.

**Why.** Resume (D-07) needs the expected digest known at the start, not the end.

**Cost.** An extra full read, which is slow and battery-hungry for a large file on
a phone.

### D-18 RSA-2048 rather than P-256

**Status:** implementation detail, provisional

**Decision.** Device keys are RSA-2048.

**Why.** `basic_utils` self-signed certificate generation is RSA-shaped and its
ECC support is thinner. Chosen for library support, not on merit.

**Cost.** Roughly a second of keygen on first run, larger certificates, larger
signatures. P-256 would be better on all three.

**Revisit if.** ECC certificate generation becomes workable in pure Dart, or
first-run keygen proves slow on a real phone.

### D-19 Discovery must fail legibly, whatever the cause

**Status:** open, needs a decision

**History.** This entry was originally written as "the Windows firewall blocks
inbound UDP 5353 on the Public profile". That diagnosis was wrong. Adding the
firewall rule changed nothing, and the real cause was interface selection (D-20).
The firewall concern is real in general, but it was not what was happening here,
and the entry is kept in corrected form rather than deleted because the mistake is
the point: an empty device list has many possible causes and looks identical for
all of them.

**Problem.** When discovery fails, the user sees an empty list. Firewall profile,
interface metric, client isolation, multicast filtering, a VPN adapter: every one
of these produces the same blank screen, and none of them is the user's fault or
within their knowledge to diagnose.

**Why it matters.** The premise is no manual configuration. A tool that silently
finds nothing, with no indication whether it is broken or simply alone on the
network, is worse than one that says what it could not do.

**Options.** Distinguish "no peers found" from "could not send or receive
multicast at all", since the second is diagnosable and the first is not. Surface
the manual `host:port` path as a designed fallback rather than a hidden feature.
Name the likely cause when one can be detected.

**Not yet decided.**

### D-20 Join and send on every interface, including link-local

**Status:** implementation detail

**Decision.** The responder joins the multicast group on all interfaces including
link-local ones, and sends replies out every bindable interface rather than
whichever the routing table prefers.

**Why.** Found by running it on a machine with Tailscale installed. The tunnel
adapter had a lower interface metric (25) than real Wi-Fi (35), so every reply
left down a tunnel no peer was listening on. Separately, Dart's
`NetworkInterface.list` omits link-local addresses by default, so the join set and
the send interface disagreed. Either bug alone makes discovery fail on any machine
with a VPN adapter, which is a large share of them.

**Cost, now measured.** The advertisement does reach the VPN tunnel. A Bonjour
browse returns the service on both the Wi-Fi interface and the Tailscale one, so
the device name and certificate fingerprint are published to the tailnet as well
as the LAN. The A record still carries only the Wi-Fi address, so a tunnel peer
sees the advertisement and cannot connect to it, but seeing it is itself the
disclosure.

**Sub-decision: keep advertising everywhere.** Tunnel and VPN adapters are not
excluded. Rejected: filtering them out, which would narrow the disclosure to the
actual local network but relies on adapter classification that is unreliable
across platforms, and an over-eager filter reintroduces exactly the bug this entry
exists to fix. The disclosure is accepted and recorded rather than mitigated with
a heuristic that could break discovery.

**Revisit if.** The app grows a settings surface where this can be offered as a
choice, or the tool is used on shared tailnets rather than personal ones.

**Revisit if.** Interface enumeration behaves differently on Android, which is
where it is most likely to.

### D-21 Inbound multicast starvation, Portmaster the leading cause

**Status:** real; leading explanation identified, unproven by choice; affects the
interop layer only after D-23

**Originally written as** "one lsync advertiser per host", which understated it by
a wide margin. The constraint is not that two lsync instances conflict. It is that
*any* other process bound to UDP 5353 can leave lsync receiving nothing, silently.

**Observed, before the confound was found.** With Brave holding `0.0.0.0:5353` and Apple's `mDNSResponder` holding
the specific interface addresses, lsync received no inbound multicast at all, while
the host demonstrably kept receiving it (mDNSResponder was resolving other hosts'
services throughout). Binding the specific Wi-Fi address instead did not help, so
"most specific bind wins" is not a sufficient explanation. Firewall and AP are
excluded by positive evidence: the process image matches the allow rules, no block
rules exist, and a purely local probe on an ephemeral port also failed to arrive.

**Attribution withdrawn (rev 10).** A four-condition table was recorded here in
rev 9 blaming an interaction between Brave and Portmaster. It does not stand. The
laptop's address changed from `192.168.1.123` to `192.168.1.241` at some point
during that sequence, meaning the Wi-Fi adapter re-associated and re-leased, which
resets interface state and multicast group memberships. The rows are therefore not
four measurements of one machine. The precondition test now scores 6/6 with Brave
running and holding `::5353`, the same holder configuration that scored 1/6
before.

The TTL change (D-22) does not explain the recovery either: `multicastHops` is
outbound-only and cannot affect inbound reception.

**What survives.** The starvation was real and thoroughly observed: zero inbound
datagrams from any source, including a local probe on an ephemeral port, while the
host's own `mDNSResponder` kept receiving normally. Windows Defender is still
excluded by positive evidence, and the "Windows does not fan multicast out to every
`SO_REUSEADDR` binder" hypothesis is still contradicted by `svchost` holding
`0.0.0.0:5353` during a passing run. What is *not* established is any cause. Brave,
Portmaster and adapter state are all still candidates.

**Methodological control, now mandatory for this entry.** Record the laptop's IPv4
address at the start and end of every condition, and discard any run where it
changed. The adapter re-associating is an invisible variable that silently
invalidates any experiment spanning more than a few minutes, and it has now
corrupted two separate sets of conclusions.

**What this means for the design, unchanged.** The cause matters less than the
symptom class. Whatever starves it, the user sees an empty device list, and the
combination cannot be enumerated on a stranger's machine. The right response is
D-19: distinguish "found nobody" from "cannot send or receive at all", and treat
the manual address path as designed rather than as a consolation. That conclusion
survives every revision of the mechanism because it never depended on one.

**Leading explanation (rev 18): Portmaster.** A third-party filtering driver was
installed on the laptop throughout the period this entry describes, and was
deleted before the D-27 LAN retest. With it gone and nothing else changed, two
separate things that had failed now work: the phone's ARP for the laptop resolves
where it previously returned FAILED, and TCP from the phone to port 4917 connects,
confirmed by negative controls that correctly fail on a closed port and a
nonexistent host, and by the listener logging the inbound connection itself.

One filtering driver, two symptoms, both absent once it was removed. It also fits
better than the alternatives already excluded here: it does not require the
"Windows does not fan multicast out to every `SO_REUSEADDR` binder" hypothesis,
which `svchost` holding `0.0.0.0:5353` during a passing run contradicts, and it
does not require Wi-Fi client isolation, which the hub exposes no setting for and
which the working LAN transfer now refutes outright.

**One part that does not fit cleanly.** Portmaster filters through the Windows
Filtering Platform, and ARP is resolved below the layers WFP normally reaches. No
mechanism has been established by which it would prevent ARP resolution. That
residual gap is a real weakness in this explanation and is the reason it is
recorded as leading rather than settled.

**Unproven, and staying that way by choice.** Confirming it means reinstalling the
driver that caused the problem and re-running the multicast precondition test
underneath it. Nobody is going to do that, and the entry should not pretend the
question is still open pending work that will not happen. Two further reasons it
could not be cleanly closed even then: the adapter re-association inside the
original sequence means those rows can never be re-read as measurements of one
machine, and the driver is gone, so the conditions cannot be reconstructed.

**Provenance of the rev 9 table (rev 19).** The table combined measurements from
two different operators and did not mark which came from where. Attributed:

| Condition | Result | Run by |
| --- | --- | --- |
| Baseline: Portmaster running, Brave running | 0/6 | assistant |
| Brave closed, Portmaster running | 6/6 | assistant |
| Brave restored, Portmaster running | 1/6 | assistant |
| **Portmaster stopped, Brave running** | **6/6** | **author, separately, on the 6th** |

The fourth row is the load-bearing one and was never the assistant's: it is the
only condition that varies Portmaster while holding Brave constant, and the
assistant never manipulated Portmaster or knew it was installed. It was reported
as a single unlabelled table, and the assistant later described the whole table as
its own work and then, on finding a row it could not reproduce, doubted the row
rather than the labelling.

**Mixing unlabelled sources is itself the error**, independently of whether any
row was right. A table whose rows come from different operators, machines states
and times reads as one experiment and cannot be audited as one. Every row in this
document should carry who ran it.

**What the attributed table actually says.** Taken at face value the four rows do
not blame Portmaster alone: closing Brave with Portmaster still running also gave
6/6. Failure needed both present, which is the interaction rev 9 originally
claimed. The independent D-27 result implicates Portmaster on its own for the
*unicast* symptom, so the cleanest reading is that Portmaster is necessary for the
multicast symptom and possibly not sufficient. The adapter re-association still
sits inside that sequence, so the rows remain uncomparable as a set and this
reading cannot be tightened.

**What this vindicates.** The withdrawn table pointed at Portmaster and was
withdrawn because of a real confound. The confound was genuine and withdrawing was
correct on the evidence available; the signal underneath it was not noise.
Withdrawing an attribution is not the same as the attribution being wrong.

**Options if confirmed.** Detect the starvation and fail legibly into the manual
address path (D-19). Move peer discovery to a private multicast group and port
where nothing competes, keeping 5353 advertising as best-effort interop. Use the
platform's own responder through its API rather than binding the port directly.

### D-22 Multicast TTL is 1 and should be 255

**Status:** fixed for multicast, outstanding for unicast; interop layer only after D-23

**Problem.** Every socket reports `multicastHops=1`, so replies leave with IP TTL
1. RFC 6762 specifies 255, and receivers are permitted to discard responses
arriving with anything else as possible off-link spoofing. Dart's default is 1 and
the code never overrides it.

**Fixed (rev 10).** `multicastHops = 255` is set on the bound socket and every
egress socket. Outbound legs now log `ttl=255`, the tagged tests pass, and `dns-sd`
still resolves the service.

**Still outstanding.** `multicastHops` covers multicast only. Unicast replies go
out with the default TTL, and RFC 6762 section 11 wants 255 for those too. That
path fires for queriers on source ports other than 5353, so it does not affect a
phone, but it is the other half of this entry.

**Attribution not yet established.** Two things changed between the last failed
phone test and now: this fix, and the adapter re-association described in D-21. A
successful phone test will therefore not prove the TTL was the cause. Setting
`multicastHops` back to 1 and re-testing is the clean way to attribute it.

### D-23 Discovery is two layers: a private protocol, plus mDNS for interop

**Status:** decided

**Decision.** Peer discovery between lsync instances runs on its own multicast
group and port, not on 5353 and not as mDNS. Alongside it, the existing mDNS
responder keeps advertising `_lsync._tcp` on 5353 as best-effort interop, so
standard browsers and an iPhone can still see the service. The private layer is
authoritative: the product works if mDNS is broken, missing, or starved.

**Why.** Every problem in this document below D-19 came from trying to be a correct
participant in Apple's discovery ecosystem, which the product never needed. Three
separate spec gaps surfaced only when a real Apple device refused to talk to us:
TTL 1 instead of 255 (D-22), the unicast reply TTL, and probably IPv6. Each was
invisible until tested against an implementation we do not control, and there is no
reason to believe the list is finished. Both ends of lsync are our code, so
discovery between them needs no standards compliance at all.

**What this fixes by construction.** A private port has no contention with Chromium
browsers or Bonjour (D-21). No spec-mandated hop limits (D-22). No service type
enumeration semantics, no IPv6 mDNS requirement, no cache coherence rules.

**Why keep mDNS at all.** Until lsync runs on a phone, the iPhone and `dns-sd` are
the only independent cross-machine verification available, and losing them would
mean discovery goes unverified until the Android app exists. Retaining mDNS
advertising keeps the test rig, and interop with standard tools is a genuine minor
feature.

**Cost.** Two discovery paths to maintain. The mDNS half is permitted to stay
imperfect, because nothing depends on it; that must be stated in the code and the
README so a future reader does not treat it as load-bearing.

**Revisit if.** The private layer turns out to need something mDNS already solves
well, or the mDNS half proves cheap enough to make fully compliant after the IPv6
question is settled.

### D-24 Answer the DNS-SD service-type enumeration query

**Status:** decided

**Decision.** The responder answers PTR queries for `_services._dns-sd._udp.local`
with `_lsync._tcp.local`, per RFC 6763 section 9. `ServiceAdvertisement.answersFor`
currently matches only the service type, the instance and the host, so the
meta-query falls through unanswered.

**Why this is the cause of the whole cross-machine failure.** Instrumented logging
caught the phone sending 11 queries in the browse window: eight for
`_services._dns-sd._udp.local` and three for `_apple-mobdev2._tcp.local`. It never
once asked for `_lsync._tcp`. A browser app populates its list by enumeration, and
since we never appear in that list, the service was never browsable and no query
for it was ever generated. `dns-sd` on the laptop found us only because the type
was typed explicitly, which is a direct PTR query that bypasses enumeration.

Every earlier suspect was looking at the wrong end of the exchange. The firewall,
the AP, the interface metrics, Brave, Portmaster, TTL 1 and IPv6 were all
investigated as reasons a question went unanswered. The question was never asked.

**Why fix it, given D-23 permits the mDNS layer to stay imperfect.** D-23 keeps
mDNS specifically to preserve the iPhone and `dns-sd` as cross-machine verification
until lsync runs on a phone. Without enumeration that rig does not function, so
this gap is the one part of the best-effort layer that earns its cost.

**Cost.** One more spec surface to maintain. Bounded, and unlike the others it is
a single well-defined query.

### D-25 IPv6 mDNS is not required

**Status:** closed, hypothesis rejected

**Investigated because** the phone was invisible on IPv4 while identifying itself
by link-local IPv6, and Apple devices were assumed to prefer IPv6 for mDNS.

**Result.** False. An observe-only IPv6 listener joined to `ff02::fb` recorded the
phone and an iPad sending the same queries on both families at matching counts and
moments. The IPv4-only responder heard the phone perfectly well throughout. No
`_lsync._tcp` query arrived on either family, because none was ever sent (D-24).

**Consequence.** No dual-stack responder is needed. `tool/ipv6_observe.dart`
remains as instrumentation for a closed question and can be deleted.

### D-26 Open source, MIT, public from the start

**Status:** decided, irrevocable

**Decision.** Public GitHub repository under the MIT licence, copyright
`LewisCodesWebsites`.

**Why.** D-06 claims that a short, complete list of what the app stores "is a claim
that can be verified by reading the code". That sentence is only true if the code
is readable. A closed-source build would make an entry in this document false.
Beyond that, every credible tool in this category is open — KDE Connect,
LocalSend, Syncthing — and a closed utility that asks people to pair devices and
trust it with their clipboard has a credibility problem it cannot argue its way
out of.

**Rejected.** *GPL-3.0,* which would force derivative works to stay open: a
reasonable choice for a project defending a commercial position, and this has none.
*A private repository,* which breaks D-06 and removes the only thing that makes the
storage claim checkable.

**Cost.** Irrevocable once published. The commit history is public and is part of
what a reader judges, so it is worth keeping legible rather than dumping work in
bulk.

### D-27 Android walking skeleton: passed, over the LAN

**Status:** milestone passed

**What passed.** The Redmi Note 11 running `lsync_app` paired with the laptop
over a typed `host:port` and sent an 8 MB generated file. Both ends displayed
`480 747`. The digest agreed three ways: computed on the phone before sending,
recomputed by the receiver and echoed back, and checked independently with
`sha256sum` against the file on disk
(`735b78c532f852de7390599dba6fe30d392dd8528d898386bb117ed8e6784390`, 8388608
bytes). No `.part` or sidecar survived, so D-06 held on a real handset.

**Over the LAN.** Phone `192.168.1.240` to laptop `192.168.1.241:4917` over
Wi-Fi, with `adb reverse --list` empty for the whole run so the USB path could
not have carried it. **D-01's manual `host:port` fallback is now proven between
two machines**, which it had never been.

This exercises the whole transport on Android: TLS with a pinned self-signed
certificate (D-09), the asymmetric handshake, the D-02 comparison as a real user
action, length-prefixed framing (D-10), chunked transfer, and atomic rename
(D-12). Built against `lsync_transport` commit
`dd311d297bb5ba38fb18c5182ebddfb6ed72fa42`.

**The earlier USB run.** An first attempt passed over an `adb reverse` tunnel
while the LAN was blocked. That result stands on its own but is now superseded,
and is kept here only because the reason the LAN was blocked is the instructive
part.

**A wrong conclusion, corrected.** The blockage was attributed to Wi-Fi client
isolation: the phone's ARP for the laptop returned FAILED while its ARP for the
router resolved, both devices reached the router and the internet, laptop routing
was correct and Tailscale was logged out. The hub exposes no isolation setting,
which seemed to close the case.

It was wrong. **Portmaster, a third-party filtering driver, was installed at the
time.** With it removed and nothing else changed, the phone's ARP for the laptop
resolves and a plain `nc` connects to port 4917, confirmed by negative controls
that correctly fail on a closed port and a nonexistent host, and by the listener
logging the inbound connection itself.

The gap in method was specific and worth naming: Windows Firewall rules and
profiles were enumerated thoroughly, and **the possibility of a third-party
filtering driver was never checked at all**. The ARP failure was the one result
that did not fit the isolation story, and it was treated as the strongest
evidence rather than as the anomaly it was. A ping test was also read as
corroboration when Windows blocks inbound ICMP on the Public profile by default,
so it could never have succeeded either way.

**Keygen, the number D-18 wanted.** 4199 ms on the Redmi against D-18's estimate
of roughly a second on the laptop: **4.2x slower**. Running it off the UI thread
was necessary rather than precautionary, since four seconds of frozen first launch
with nothing on screen reads as a broken app. One caveat: the figure was read off
a photograph of the handset rather than captured as text, and MIUI denies
`pm clear` to the shell user so the key could not be regenerated to measure it
again. It remains a single sample.

### D-28 Clipboard carries text only in v1, capped at 1 MiB

**Status:** decided, built (rev 22)

**Decision.** Clipboard content is `text/plain` and nothing else. The content type
travels on every update from the first version, so adding `image/png` later is not
a protocol break. Content is capped at 1 MiB and refused whole above it, never
truncated. Both ends validate independently.

**Rejected.** *Text only with no type field:* one string cheaper today and a
protocol version bump later, for a feature the doc already anticipates.
*Text plus images now, in one frame:* a full-screen PNG is routinely 1 to 3 MB, so
a single-frame image path would reject most of the case it was added for.
*Text plus images now, chunked like a file:* no practical cap and it reuses the
streaming path that already moves 2 GB files, so images are close to free on the
wire — but they are expensive in the platform layer, which needs Android bitmap to
PNG, Windows `CF_DIB` against `CF_PNG`, and X11 target negotiation, three pieces
of native work in the layer this package deliberately does not have. *Truncating
oversized content:* decisive against, because a clipboard that quietly delivers
half a key or half a command is worse than one that delivers nothing. The user
cannot see it happened until they paste, and by then the original is gone.

**Why.** The screenshot case is the interesting one and it is a platform problem
rather than a protocol problem. Reserving the type field costs one string and
keeps the decision open; building the platform half now would drag OS clipboard
code into a package that has none.

**Cost.** Screenshots do not sync in v1. Copying something large — a file in an
IDE, a long log — is refused rather than sent, and the user has to be told why.

**Where the cap comes from.** 1 MiB is D-10's frame body cap, because v1 sends an
update as a single frame with no chunked clipboard path. Content travels in the
body rather than the header, which is what gives it 1 MiB rather than the 64 KiB a
header gets. The frame reader enforces the same figure independently, so a peer's
declared size is checked twice by two mechanisms that do not share code.

**Revisit if.** The cap is actually hit in use, or images are wanted badly enough
to pay for the platform layer.

### D-29 The clipboard engine is handed a session and never owns one

**Status:** decided, built (rev 22)

**Decision.** `ClipboardSync` takes a live `PeerSession` and does not reconnect
it. A dropped session ends the object; the app builds another when it has a new
one. Frames are dispatched into it rather than pulled by it.

**Rejected.** *The engine owns a session and reconnects:* reconnect policy is
entangled with vendor power management — MIUI kills background services that stock
Android leaves running — so the piece would have become untestable anywhere except
on a handset, and CLAUDE.md already records that vendor policy is a confounder to
rule out first rather than debug through. *The engine owns the read loop:* a
session also carries file transfers, and two readers on one stream desynchronise
it.

**Why.** It keeps the hard part testable with `dart test` and fakes on both ends,
and it puts reconnect where the platform knowledge is.

**Cost.** The app is responsible for noticing a dead session and rebuilding, which
is also the only place a destroyed socket is detectable (see D-03).

**What PC-to-phone needs that phone-to-PC does not.** Nothing in the message
vocabulary: an update is the same frame in either direction, and this was worth
checking rather than assuming. The asymmetry is entirely in connection lifecycle.
Phone-to-PC can dial at tap time, send, and hang up. PC-to-phone is automatic
(D-04), which means the PC pushes unsolicited and the phone must already be
connected — a standing session on exactly the platform most likely to kill one.
That is a milestone-three problem, and naming it here is the point of the entry:
it is a lifecycle question, not a protocol gap, so no field was added for it.

**Where D-04's asymmetry actually lands.** In the shape of the clipboard
interface, not in the protocol. Writing is always available; *watching* is not, so
an Android implementation returns null for the change stream and the app drives
sends from the notification tap instead. Both routes emit identical frames.

---

## Open questions

- Is QR pairing in v1, or added later?
- Linux has no single keychain. Relevant only if D-05 is ever revisited.

## Dead ends

Things tried that did not work. Fill in as they happen, on the day they happen.

- 
