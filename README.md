# lsync_transport

Transport layer for a LAN clipboard and file sync tool: discovery, pairing,
TLS with pinned self-signed certificates, length-prefixed framing, and file
transfer. No account, no server, no relay.

Every design decision — what was chosen, what was rejected, why, and what would
change the answer — is in [DESIGN.md](DESIGN.md). This README says what the code
does and how to run it; the reasoning lives there.

## Scope

**Transport only.** There is no UI, no clipboard integration, no Flutter and no
Android app in this repository. The clipboard layer is the only genuinely
platform-specific part of the design and it is separate work.

What is here:

| Area | Where |
| --- | --- |
| mDNS advertising and browsing, manual `host:port` fallback (D-01) | `lib/src/discovery/` |
| Pairing by compared short authentication string (D-02) | `lib/src/pairing/` |
| Retained state — keys, fingerprints, names, bond (D-06) | `lib/src/store/` |
| TLS 1.3, asymmetric authentication (D-09) | `lib/src/transport/` |
| Length-prefixed frames, JSON header, 64 KiB body chunks (D-10) | `lib/src/transport/frame.dart` |
| Partial files and offset sidecar (D-12) | `lib/src/files/` |

Resume (D-07) is deliberately not implemented. This pass fails loudly and
deletes the partial. The sidecar is written and kept current throughout a
transfer, so resume is a matter of teaching the receiver to read it back rather
than restructuring anything.

## Running it

Needs a Dart SDK. Two instances on one machine need two config directories.

```bash
dart pub get
```

Receiving side:

```bash
dart run bin/lsync.dart --config ./beta --name beta listen --dir ./received --pair
```

Sending side, in another terminal:

```bash
dart run bin/lsync.dart --config ./alpha --name alpha pair --to 127.0.0.1:4917
```

Both terminals print a six-digit number. **They must match** — comparing them is
the entire pairing check (D-02). Nothing secret crosses the wire; a device in
the middle holds a different certificate on each side, so the two numbers
differ. Answer `y` on both.

```bash
dart run bin/lsync.dart --config ./alpha --name alpha send --to 127.0.0.1:4917 --file ./report.pdf
```

`pair` and `send` also accept `--peer <name or fingerprint prefix>` to find a
device over mDNS instead of `--to`. Other commands: `identity`, `peers`,
`discover`.

Set `LSYNC_MDNS_DEBUG=1` to log every inbound and outbound mDNS datagram.

## Tests

Two suites, deliberately separated.

```bash
dart test
```

The default suite. It must stay green.

```bash
dart test -P mdns
```

The mDNS suite, excluded from the default run by design (D-13). Real discovery
needs multicast working on the host, and a discovery test that silently finds
nothing passes for the wrong reason — which is exactly the failure mode the
separation exists to avoid. The first test in that file checks the multicast
precondition directly, so a misconfigured machine fails with a usable message
rather than an empty browse.

The killed-connection test is skipped with a reason: it belongs to resume, which
D-07 sequences second. It documents what it will need.

## What touches disk

Per D-06, and asserted by the integration tests:

```
<config>/device.key.pem    this device's private key
<config>/device.crt.pem    its self-signed certificate
<config>/peers.json        peer fingerprints, device names, clipboard bond
```

Nothing else is retained. During a transfer, and only during one, `<name>.part`
and `<name>.part.json` sit in the destination directory; both are removed on
completion and on failure alike.

## Known limitations

These are open or partially resolved. Full reasoning in DESIGN.md.

- **Discovery fails silently (D-19, open).** Firewall, interface metrics,
  multicast filtering and client isolation all produce the same empty list, and
  none of them are the user's fault or within their knowledge to diagnose.
  Distinguishing "no peers found" from "could not use multicast at all" is not
  yet designed.
- **Inbound multicast starvation (D-21, real but unattributed).** On Windows,
  inbound multicast was observed going missing entirely while the host kept
  receiving it. A suspected cause was investigated and the attribution did not
  hold up. Affects only the interop layer once D-23 lands.
- **Unicast reply TTL (D-22, partially fixed).** Multicast now leaves with IP
  TTL 255 as RFC 6762 requires. Unicast replies still use the platform default.
- **Discovery is moving to a private group and port (D-23, decided, not built).**
  Every problem below D-19 came from trying to be a correct participant in a
  discovery ecosystem the product never needed. mDNS will be kept as
  best-effort interop and is explicitly permitted to stay imperfect; nothing
  will depend on it.
- **IPv6 mDNS is not required (D-25, closed).** Investigated and rejected — the
  IPv4-only responder hears Apple devices perfectly well.

Also worth knowing: Dart's public API cannot enforce a minimum TLS version or
report the negotiated one, so D-09's "TLS 1.3 throughout" is not assertable from
code.

## Verification

The mDNS responder is hand-written, because no Dart package advertises a service
outside Flutter. It has been validated against Apple's Bonjour — an independent
implementation sharing none of this codebase's assumptions — both via `dns-sd`
on the same host and from an iPhone on the same Wi-Fi, which enumerated the
service type, resolved the instance, and displayed the port and TXT records with
the fingerprint matching the running advertiser.

## Verified against

The suite was last green against:

| | |
| --- | --- |
| Dart | 3.13.2 (stable) |
| Flutter | 3.47.2 (stable) — supplies the Dart above |
| Android SDK | platform 36, build-tools 36.0.0, platform-tools 37.0.1 |
| JDK | 21.0.7 (Android Gradle Plugin does not support JDK 25) |

Only the Dart version matters to this package today; the rest is recorded
because the Android app in D-08 will need it.

## Licence

MIT. See [LICENSE](LICENSE).
