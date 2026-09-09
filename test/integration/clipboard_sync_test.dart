import 'dart:async';
import 'dart:io';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:test/test.dart';

import '../support/fake_clipboard.dart';
import '../support/harness.dart';

/// One end of a bonded pair: a session, a fake clipboard, an engine, and the
/// read loop that feeds it.
///
/// The loop lives here rather than inside [ClipboardSync] because a session
/// also carries file transfers, so the engine is handed frames rather than
/// pulling them. Two readers on one stream would desynchronise it.
class Endpoint {
  Endpoint({
    required this.session,
    required this.clipboard,
    required this.sync,
    required this.refusals,
    required this.errors,
  });

  final PeerSession session;
  final FakeClipboard clipboard;
  final ClipboardSync sync;
  final List<ClipboardRefusal> refusals;
  final List<Object> errors;

  void pump() {
    unawaited(() async {
      try {
        while (true) {
          final frame = await session.reader.readFrame();
          if (frame == null) break;
          await sync.handleFrame(frame);
        }
      } on Object catch (error) {
        errors.add(error);
      }
    }());
  }

  Future<void> close() async {
    await sync.close();
    await session.close();
    await clipboard.dispose();
  }
}

Endpoint _endpoint(PeerSession session, Instance instance, bool watchable) {
  final clipboard = FakeClipboard(watchable: watchable);
  final refusals = <ClipboardRefusal>[];
  final errors = <Object>[];
  return Endpoint(
    session: session,
    clipboard: clipboard,
    sync: ClipboardSync(
      session: session,
      clipboard: clipboard,
      bond: ClipboardBond(instance.trustStore),
      localFingerprint: instance.fingerprint,
      onRefused: refusals.add,
      onError: errors.add,
    ),
    refusals: refusals,
    errors: errors,
  );
}

void main() {
  late Directory root;
  late Instance alpha;
  late Instance beta;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lsync-clipboard-');
    alpha = await createInstance(root, 'alpha');
    beta = await createInstance(root, 'beta');
  });

  tearDownAll(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Connects the two instances and wires an engine to each side.
  ///
  /// The two bonds are set independently, because the bond is decided locally
  /// (D-03) and the interesting cases are the ones where the ends disagree.
  Future<({Endpoint a, Endpoint b})> connect({
    bool bondAlpha = true,
    bool bondBeta = true,
    bool alphaWatchable = true,
    bool betaWatchable = true,
  }) async {
    final listenerSession = Completer<PeerSession>();
    final server = await LsyncServer.bind(
      identity: beta.identity,
      trustStore: beta.trustStore,
      address: InternetAddress.loopbackIPv4,
      port: 0,
      confirmPairing: (_) async => true,
      onSession: listenerSession.complete,
    );
    addTearDown(server.close);

    final diallerSession = await Dialler.connect(
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      identity: alpha.identity,
      trustStore: alpha.trustStore,
      confirmPairing: (_) async => true,
    );

    final listener = await listenerSession.future;

    // Bonds are set after the handshake, not before: a bond names a *paired*
    // device, and these two pair as part of connecting.
    final alphaBond = ClipboardBond(alpha.trustStore);
    final betaBond = ClipboardBond(beta.trustStore);
    await (bondAlpha ? alphaBond.bondTo(beta.fingerprint) : alphaBond.release());
    await (bondBeta ? betaBond.bondTo(alpha.fingerprint) : betaBond.release());

    final a = _endpoint(diallerSession, alpha, alphaWatchable);
    final b = _endpoint(listener, beta, betaWatchable);

    a.sync.start();
    b.sync.start();
    a.pump();
    b.pump();
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    return (a: a, b: b);
  }

  test(
    'copying on one device puts it on the other, and the loop stops there',
    () async {
      // The test D-11 exists for. The fakes fire their change stream on write,
      // exactly as a real clipboard does, so without loop prevention the item
      // would bounce between the two indefinitely.
      final pair = await connect();

      pair.a.clipboard.copy('hello from alpha');

      await waitFor(
        () => pair.b.clipboard.current?.text == 'hello from alpha',
        describe: 'beta to receive the copy',
      );
      await settle();

      expect(
        pair.b.clipboard.writes.length,
        1,
        reason: 'beta must apply it once, not once per lap of a loop',
      );
      expect(
        pair.a.clipboard.writes,
        isEmpty,
        reason: 'the item started on alpha; it must never be written back',
      );
      expect(pair.a.sync.history.length, 1);
      expect(pair.a.sync.history.newest!.direction, ClipboardDirection.sent);
      expect(pair.b.sync.history.length, 1);
      expect(pair.b.sync.history.newest!.direction, ClipboardDirection.received);
      expect(pair.b.sync.history.newest!.origin, alpha.fingerprint);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the clipboard keeps syncing in both directions afterwards',
    () async {
      // A loop stopped by wedging the engine shut would pass the test above.
      final pair = await connect();

      pair.a.clipboard.copy('first, alpha to beta');
      await waitFor(
        () => pair.b.clipboard.current?.text == 'first, alpha to beta',
        describe: 'the first item',
      );

      pair.b.clipboard.copy('second, beta to alpha');
      await waitFor(
        () => pair.a.clipboard.current?.text == 'second, beta to alpha',
        describe: 'the reply',
      );

      pair.a.clipboard.copy('third, alpha again');
      await waitFor(
        () => pair.b.clipboard.current?.text == 'third, alpha again',
        describe: 'the third item',
      );
      await settle();

      expect(pair.a.clipboard.writes.length, 1);
      expect(pair.b.clipboard.writes.length, 2);
      expect(pair.a.errors, isEmpty);
      expect(pair.b.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'both devices legitimately holding the same content does not jam it',
    () async {
      // D-11 chose hash comparison over a bare origin check for this case.
      final pair = await connect();

      pair.b.clipboard.setSilently('the same thing');
      pair.a.clipboard.copy('the same thing');
      await waitFor(
        () => pair.b.clipboard.writes.isNotEmpty,
        describe: 'beta to apply the duplicate',
      );

      // The next item must still cross, which is the part that would break if
      // holding the same content had jammed the state.
      pair.a.clipboard.copy('something new');
      await waitFor(
        () => pair.b.clipboard.current?.text == 'something new',
        describe: 'the following item',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a device that is no longer the partner is told, not ignored (D-03)',
    () async {
      // The bond is decided locally, so the two ends can disagree. An explicit
      // refusal is what stops that disagreement being silent.
      final pair = await connect(bondBeta: false);

      pair.a.clipboard.copy('alpha still thinks it is bonded');
      await waitFor(
        () => pair.a.refusals.isNotEmpty,
        describe: 'alpha to be told it is no longer the partner',
      );

      expect(pair.a.refusals.single.reason, ClipboardRefusal.notBonded);
      expect(
        pair.b.clipboard.writes,
        isEmpty,
        reason: 'nothing may be applied from a device that is not the partner',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a refused update leaves the session usable, not desynchronised',
    () async {
      // A refusal must still consume the body: the reader will not skip an
      // unread one, so a refusal that forgot would break every later frame.
      final pair = await connect(bondBeta: false);

      pair.a.clipboard.copy('refused, body still on the wire');
      await waitFor(
        () => pair.a.refusals.isNotEmpty,
        describe: 'the refusal',
      );

      // Bond beta and send again. If the stream had desynchronised on the
      // unread body, this would fail rather than arrive.
      await ClipboardBond(beta.trustStore).bondTo(alpha.fingerprint);
      pair.a.clipboard.copy('accepted, after the refusal');

      await waitFor(
        () => pair.b.clipboard.current?.text == 'accepted, after the refusal',
        describe: 'the frame following a refusal',
      );
      expect(pair.a.errors, isEmpty);
      expect(pair.b.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a phone with no change stream still sends on a tap (D-04)',
    () async {
      // Android cannot watch the clipboard in the background, so alpha here
      // has no stream at all and sends only when asked.
      final pair = await connect(alphaWatchable: false);

      pair.a.clipboard.setSilently('typed on the phone');
      await settle();
      expect(
        pair.b.clipboard.writes,
        isEmpty,
        reason: 'without a watcher, nothing may be sent unprompted',
      );

      await pair.a.sync.sendCurrent();
      await waitFor(
        () => pair.b.clipboard.current?.text == 'typed on the phone',
        describe: 'the tap-driven send',
      );

      // Tapping again with the same content must not re-send it.
      await pair.a.sync.sendCurrent();
      await settle();
      expect(pair.b.clipboard.writes.length, 1);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'content above the cap is refused whole, and never truncated',
    () async {
      final pair = await connect(alphaWatchable: false);

      pair.a.clipboard.setSilently('x' * (maxClipboardBytes + 1));
      await pair.a.sync.sendCurrent();
      await settle();

      expect(pair.a.errors, hasLength(1));
      expect('${pair.a.errors.single}', contains('exceeds'));
      expect(
        pair.b.clipboard.writes,
        isEmpty,
        reason: 'nothing partial may arrive; half a key is worse than none',
      );
      expect(
        pair.a.sync.pending,
        isNull,
        reason: 'oversized content must not occupy the depth-one slot',
      );

      // The engine is still usable, which it would not be if the oversized
      // item had wedged the send path.
      pair.a.clipboard.setSilently('something sendable');
      await pair.a.sync.sendCurrent();
      await waitFor(
        () => pair.b.clipboard.current?.text == 'something sendable',
        describe: 'a normal send after an oversized one',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'closing clears the history and drops anything pending (D-05)',
    () async {
      final pair = await connect();
      pair.a.clipboard.copy('something private');
      await waitFor(
        () => pair.b.sync.history.length == 1,
        describe: 'beta to record it',
      );

      await pair.b.sync.close();
      expect(pair.b.sync.history.isEmpty, isTrue);
      expect(pair.b.sync.pending, isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a failing send remembers one item, not a queue',
    () async {
      final pair = await connect(alphaWatchable: false);
      // Close the sink under the engine so writes raise. Nothing reconnects it:
      // this object is handed a session and does not own one.
      //
      // Note the mechanism. A *destroyed* socket swallows writes without
      // raising, so a send into one looks like it succeeded and the item is
      // dropped rather than remembered. The engine cannot tell; what notices a
      // dead peer is the read loop reaching EOF, which belongs to the caller.
      await pair.a.session.socket.close();

      pair.a.clipboard.setSilently('first while down');
      await pair.a.sync.sendCurrent();
      pair.a.clipboard.setSilently('second while down');
      await pair.a.sync.sendCurrent();
      pair.a.clipboard.setSilently('third while down');
      await pair.a.sync.sendCurrent();
      await settle();

      expect(
        pair.a.errors,
        hasLength(3),
        reason: 'each failed send is reported rather than swallowed',
      );
      expect(
        pair.a.sync.pending?.text,
        'third while down',
        reason: 'a clipboard has a current value, not a backlog: depth one, '
            'and the newest wins',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
