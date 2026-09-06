import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:path/path.dart' as p;

/// One instance of the core, with its own config directory (D-13).
///
/// Two of these against each other is the whole integration setup: separate
/// keys, separate certificates, separate trust stores, one process.
class Instance {
  Instance(this.identity, this.trustStore, this.configDir);

  final DeviceIdentity identity;
  final TrustStore trustStore;
  final String configDir;

  String get fingerprint => identity.fingerprint;

  /// Reloads the trust store from disk, to check what was actually persisted
  /// rather than what is in memory.
  Future<TrustStore> reloadTrustStore() => TrustStore.open(configDir);
}

/// Creates an instance under [root].
///
/// Key generation is the slow part, so tests should build these once in
/// setUpAll rather than per test.
Future<Instance> createInstance(Directory root, String name) async {
  final configDir = p.join(root.path, name);
  final identity = await DeviceIdentity.loadOrCreate(
    configDir: configDir,
    deviceName: name,
  );
  return Instance(identity, await TrustStore.open(configDir), configDir);
}

/// Writes a file of [size] bytes with reproducible contents, and returns it
/// alongside its SHA-256 (D-13).
Future<({File file, String sha256})> generateFile(
  Directory directory,
  String name,
  int size, {
  int seed = 1,
}) async {
  final random = Random(seed);
  final file = File(p.join(directory.path, name));
  await file.parent.create(recursive: true);

  final handle = await file.open(mode: FileMode.write);
  const blockSize = 64 * 1024;
  try {
    var written = 0;
    while (written < size) {
      final length = size - written < blockSize ? size - written : blockSize;
      final block = Uint8List(length);
      for (var i = 0; i < length; i++) {
        block[i] = random.nextInt(256);
      }
      await handle.writeFrom(block);
      written += length;
    }
  } finally {
    await handle.close();
  }

  return (file: file, sha256: await sha256OfFile(file));
}

/// Runs a listener that receives whatever is offered into [destination].
///
/// Returns a future completing with the first file received, which is what the
/// D-13 assertion is made against.
class ReceivingServer {
  ReceivingServer._(this.server, this._firstFile, this.refusals, this.failures);

  final LsyncServer server;
  final Future<ReceivedFile> _firstFile;

  /// Connections the listener turned away. Refusing an unpaired or declining
  /// dialler is correct behaviour, so these are recorded rather than thrown:
  /// routing them into [firstFile] would surface a working refusal as an
  /// unhandled async error.
  final List<Object> refusals;

  /// Transfers the receiver rejected or lost. Recorded rather than thrown for
  /// the same reason as [refusals]: a correct refusal must not surface as an
  /// unhandled async error in a test that is asserting the refusal happened.
  final List<Object> failures;

  int get port => server.port;
  Future<ReceivedFile> get firstFile => _firstFile;

  /// [address] defaults to loopback, which is what the offline tests want.
  /// A discovery test must pass a wider one: the peer is reached at the
  /// address the A record advertises, and a listener bound to 127.0.0.1 is not
  /// there.
  static Future<ReceivingServer> start({
    required Instance instance,
    required String destination,
    InternetAddress? address,
    SasConfirm? confirmPairing,
    void Function(PeerSession session)? onConnected,
  }) async {
    final completer = Completer<ReceivedFile>();
    final refusals = <Object>[];
    final failures = <Object>[];

    final server = await LsyncServer.bind(
      identity: instance.identity,
      trustStore: instance.trustStore,
      address: address ?? InternetAddress.loopbackIPv4,
      port: 0,
      confirmPairing: confirmPairing,
      onError: (error, _) => refusals.add(error),
      onSession: (session) {
        onConnected?.call(session);
        unawaited(_serve(session, destination, completer, failures));
      },
    );

    return ReceivingServer._(server, completer.future, refusals, failures);
  }

  static Future<void> _serve(
    PeerSession session,
    String destination,
    Completer<ReceivedFile> completer,
    List<Object> failures,
  ) async {
    try {
      while (true) {
        final frame = await session.reader.readFrame();
        if (frame == null) break;
        if (frame.type != msgFileOffer) continue;

        final received = await FileReceiver.receive(
          session: session,
          offerFrame: frame,
          destinationDirectory: destination,
        );
        if (!completer.isCompleted) completer.complete(received);
      }
    } on Object catch (error) {
      failures.add(error);
    } finally {
      await session.close();
    }
  }

  Future<void> close() => server.close();
}

/// Every leftover in [directory] that a finished transfer should have removed
/// (D-06: nothing survives a finished or failed transfer).
Future<List<String>> transferLeftovers(Directory directory) async {
  if (!await directory.exists()) return const <String>[];
  return <String>[
    for (final entry in await directory.list().toList())
      if (entry.path.endsWith('.part') || entry.path.endsWith('.part.json'))
        p.basename(entry.path),
  ];
}
