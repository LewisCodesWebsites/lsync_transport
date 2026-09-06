# Working on this project

## DESIGN.md is authoritative

Read it before anything else. Every decision is recorded there with what was
chosen, what was rejected, why, what it cost, and what would change the answer.

Do not revisit settled decisions. Do not "improve" them. If a decision looks
wrong, that is a conversation to have, not a change to make.

Where the doc does not cover a call you have to make, make it and then **list it
at the end of your response under "Decisions I made", with the alternatives you
rejected**, so it can be folded into the doc. Do not bury it in a comment and
hope someone notices.

If the doc is ambiguous or contradicts itself, **stop and ask**. Do not resolve
it yourself. It has contradicted itself before, and guessing produced work that
had to be undone.

## Debugging

**Split before fixing.** When something fails, isolate which half is broken
before changing any code. Observation-only instrumentation first: log what
arrives and what goes out, change no behaviour, then decide. Every wrong turn in
this project's history came from fixing before splitting.

**Measure a rate, never a single run.** For anything intermittent, run it six
times and report the count. This project has produced *four* confident wrong
answers from single samples, including one "demonstration" that reversed itself
on the next attempt. A single green run is not evidence.

**Record the machine's IPv4 address at the start and end of any network
experiment, and discard the run if it changed.** An adapter re-association
silently invalidated two complete sets of conclusions. This is cheap; do it
every time.

**A tool's UI label is not evidence of what happened on the wire.** Verify what
was actually sent. A browser app reporting that it browsed one service type had
in fact queried a different one, and that gap cost two rounds of investigation.
The same applies to your own output: check the bytes, not the intent.

**Empty output is not a result.** Confirm your measurement can produce a
positive before trusting a negative. A `dns-sd` browse that printed nothing was
read as "the service is invisible" when the output had simply been swallowed by
a pipe buffer.

## This machine

**Never blanket-kill processes.** No `taskkill /F /IM dart.exe`. Scope cleanup
to PIDs you started and recorded. A blanket kill in one background task killed
the sockets a later task had just opened, and cost a whole test window.

**Do not change the user's machine settings without asking** — firewall rules,
services, running applications. Ask first, every time, and say what you are
changing and why.

## Tests

The **default suite must stay green**: `dart test`.

mDNS tests are tagged and excluded from it by design (D-13), because a
discovery test that silently finds nothing passes for the wrong reason. Run them
deliberately with `dart test -P mdns`, and only on a machine set up for it. The
first test in that file checks the multicast precondition directly so a
misconfigured host fails with a usable message rather than an empty browse.

## pubspec.lock is committed, deliberately

The usual Dart advice is that packages do not commit their lock file. That
advice is about packages other things depend on, and nothing depends on this
one. The CLI is how every test and every device run actually happens, so it
behaves as an application, and pinned resolution is what makes those runs
reproducible.

This is not an oversight to tidy up. The pub cache was emptied during
development and `dart pub get` restored the exact versions from this file.

## Scope

Transport layer only: discovery, pairing, TLS, framing, file transfer. No UI, no
clipboard, no Flutter, no Android. Those are separate work and out of scope here
unless the doc says otherwise.
