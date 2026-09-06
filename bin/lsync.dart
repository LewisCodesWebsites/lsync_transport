import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:lsync_transport/lsync_transport.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<int>(
    'lsync',
    'Transport harness for LAN clipboard and file sync.',
  )
    ..argParser.addOption(
      'config',
      help: 'Directory holding the key, certificate and paired peers.\n'
          'Use a separate one per instance to run two on one machine.',
    )
    ..argParser.addOption(
      'name',
      help: 'This device\'s name, as shown to peers.',
    )
    ..addCommand(IdentityCommand())
    ..addCommand(PeersCommand())
    ..addCommand(DiscoverCommand())
    ..addCommand(ListenCommand())
    ..addCommand(PairCommand())
    ..addCommand(SendCommand());

  try {
    exitCode = await runner.run(arguments) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = 64;
  } on Object catch (error) {
    stderr.writeln('error: $error');
    exitCode = 1;
  } finally {
    await _releaseStdin();
  }
}

/// Everything a command needs from disk, loaded once.
class Harness {
  Harness(this.identity, this.trustStore, this.configDir);

  final DeviceIdentity identity;
  final TrustStore trustStore;
  final String configDir;

  static Future<Harness> load(ArgResults? globals) async {
    final configDir =
        (globals?['config'] as String?) ?? defaultConfigDir();
    final deviceName =
        (globals?['name'] as String?) ?? Platform.localHostname;

    final identity = await DeviceIdentity.loadOrCreate(
      configDir: configDir,
      deviceName: deviceName,
    );
    final trustStore = await TrustStore.open(configDir);
    return Harness(identity, trustStore, configDir);
  }
}

/// stdin, one line at a time.
///
/// Created on first use and cancelled before exit. A live stdin subscription
/// keeps the Dart event loop alive, so a command that prompted once would
/// otherwise sit there after finishing its work instead of returning.
///
/// Pulled asynchronously rather than with readLineSync so waiting for an answer
/// does not stall the socket the answer is about.
StreamIterator<String>? _stdinLines;

Future<String?> _readLine() async {
  final lines = _stdinLines ??= StreamIterator<String>(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  return await lines.moveNext() ? lines.current : null;
}

Future<void> _releaseStdin() async {
  await _stdinLines?.cancel();
  _stdinLines = null;
}

/// Shows the D-02 digits and asks whether the other screen matches.
Future<bool> _confirmAtTerminal(SasPrompt prompt) async {
  stdout
    ..writeln()
    ..writeln('Pairing with "${prompt.peerName}"')
    ..writeln('  their fingerprint: ${prompt.peerFingerprint}')
    ..writeln('  your fingerprint:  ${prompt.localFingerprint}')
    ..writeln()
    ..writeln('  ${formatSas(prompt.sas)}')
    ..writeln()
    ..writeln('Both devices must show exactly this number. If they differ,')
    ..writeln('someone is between you: answer no.')
    ..write('Does it match? [y/N] ');
  final answer = await _readLine();
  final accepted = answer != null && answer.trim().toLowerCase() == 'y';
  stdout.writeln(accepted ? 'Confirmed.' : 'Declined.');
  return accepted;
}

/// Resolves the target of `pair` and `send`.
///
/// `--to` is D-01's manual fallback. `--peer` goes through mDNS, which is the
/// path the real app uses; without it `discover` could list peers that nothing
/// was able to act on.
Future<DiscoveredPeer> resolveTarget(ArgResults results) async {
  final manual = results['to'] as String?;
  final wanted = results['peer'] as String?;

  if (manual != null && wanted != null) {
    throw UsageException('Pass --to or --peer, not both.', '');
  }
  if (manual != null) {
    return parseHostPort(manual, defaultPort: defaultPort);
  }
  if (wanted == null) {
    throw UsageException('Pass --to host:port or --peer <name>.', '');
  }

  stdout.writeln('Looking for "$wanted"...');
  final peers = await MdnsBrowser.browse(timeout: const Duration(seconds: 5));

  final needle = wanted.toLowerCase();
  final matches = peers
      .where((peer) =>
          (peer.deviceName?.toLowerCase() == needle) ||
          (peer.fingerprint?.startsWith(needle) ?? false))
      .toList();

  if (matches.isEmpty) {
    throw StateError(
      peers.isEmpty
          ? 'No devices found. Some networks filter mDNS; use --to host:port.'
          : 'No device matched "$wanted". Found: '
              '${peers.map((p) => p.deviceName ?? p.host).join(", ")}',
    );
  }
  if (matches.length > 1) {
    // Names are user-chosen and need not be unique; the fingerprint is.
    throw StateError(
      '"$wanted" matched ${matches.length} devices. Use a fingerprint prefix: '
      '${matches.map((p) => p.fingerprint?.substring(0, 12)).join(", ")}',
    );
  }

  final peer = matches.single;
  stdout.writeln('Found ${peer.deviceName} at ${peer.host}:${peer.port}');
  return peer;
}

class IdentityCommand extends Command<int> {
  @override
  String get name => 'identity';

  @override
  String get description => 'Show this device\'s name and fingerprint.';

  @override
  Future<int> run() async {
    final harness = await Harness.load(globalResults);
    stdout
      ..writeln('name:        ${harness.identity.name}')
      ..writeln('fingerprint: ${harness.identity.fingerprint}')
      ..writeln('config:      ${harness.configDir}');
    return 0;
  }
}

class PeersCommand extends Command<int> {
  @override
  String get name => 'peers';

  @override
  String get description => 'List paired devices.';

  @override
  Future<int> run() async {
    final harness = await Harness.load(globalResults);
    final peers = harness.trustStore.peers;
    if (peers.isEmpty) {
      stdout.writeln('No paired devices. Run "lsync pair --to host:port".');
      return 0;
    }
    for (final entry in peers.entries) {
      final bond = harness.trustStore.clipboardBond == entry.key
          ? '  (clipboard bond)'
          : '';
      stdout.writeln('${entry.value}$bond\n  ${entry.key}');
    }
    return 0;
  }
}

class DiscoverCommand extends Command<int> {
  DiscoverCommand() {
    argParser.addOption(
      'timeout',
      defaultsTo: '4',
      help: 'Seconds to listen for answers.',
    );
  }

  @override
  String get name => 'discover';

  @override
  String get description => 'Browse the LAN for lsync devices over mDNS.';

  @override
  Future<int> run() async {
    final seconds = int.tryParse(argResults!['timeout'] as String) ?? 4;
    stdout.writeln('Browsing for $serviceType for ${seconds}s...');
    final peers = await MdnsBrowser.browse(
      timeout: Duration(seconds: seconds),
    );
    if (peers.isEmpty) {
      stdout.writeln(
        'Nothing found. Some networks filter mDNS; use --to host:port.',
      );
      return 0;
    }
    for (final peer in peers) {
      stdout.writeln(peer);
    }
    return 0;
  }
}

class ListenCommand extends Command<int> {
  ListenCommand() {
    argParser
      ..addOption(
        'dir',
        abbr: 'd',
        help: 'Directory to write received files into (D-15).',
        mandatory: true,
      )
      ..addOption(
        'port',
        defaultsTo: '$defaultPort',
        help: 'Port to listen on. 0 picks a free one.',
      )
      ..addFlag(
        'pair',
        help: 'Accept pairing from unpaired devices while running.',
      )
      ..addFlag(
        'mdns',
        defaultsTo: true,
        help: 'Advertise over mDNS.',
      );
  }

  @override
  String get name => 'listen';

  @override
  String get description => 'Accept connections and receive files.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final harness = await Harness.load(globalResults);
    final destination = results['dir'] as String;
    final port = int.parse(results['port'] as String);
    final allowPairing = results['pair'] as bool;

    final server = await LsyncServer.bind(
      identity: harness.identity,
      trustStore: harness.trustStore,
      port: port,
      confirmPairing: allowPairing ? _confirmAtTerminal : null,
      onError: (error, _) => stderr.writeln('connection failed: $error'),
      onSession: (session) => unawaited(_serve(session, destination)),
    );

    stdout
      ..writeln('${harness.identity.name} listening on port ${server.port}')
      ..writeln('fingerprint: ${harness.identity.fingerprint}')
      ..writeln('receiving into: $destination')
      ..writeln(
        allowPairing
            ? 'pairing: open'
            : 'pairing: closed (restart with --pair to allow new devices)',
      );

    MdnsResponder? responder;
    if (results['mdns'] as bool) {
      try {
        responder = await MdnsResponder.start(
          deviceName: harness.identity.name,
          fingerprint: harness.identity.fingerprint,
          port: server.port,
        );
        stdout.writeln('advertising as ${responder.instanceName}');
      } on Object catch (error) {
        stderr.writeln(
          'mDNS advertising unavailable ($error); peers can still use '
          '--to host:port',
        );
      }
    }

    // Runs until interrupted.
    await ProcessSignal.sigint.watch().first;
    stdout.writeln('\nstopping');
    await responder?.stop();
    await server.close();
    return 0;
  }

  Future<void> _serve(PeerSession session, String destination) async {
    stdout.writeln(
      'connected: ${session.peerName} (${session.peerFingerprint})',
    );
    try {
      while (true) {
        final frame = await session.reader.readFrame();
        if (frame == null) break;

        if (frame.type == msgError) {
          final message = frame.header['message'];
          stderr.writeln('peer aborted: $message');
          break;
        }
        if (frame.type != msgFileOffer) {
          await session.abort('unexpected frame "${frame.type}"');
          break;
        }

        final received = await FileReceiver.receive(
          session: session,
          offerFrame: frame,
          destinationDirectory: destination,
          onProgress: _progress('receiving'),
        );
        stdout.writeln(
          '\nreceived ${received.path} (${received.size} bytes, '
          'sha256 ${received.sha256})',
        );
      }
    } on Object catch (error) {
      stderr.writeln('\ntransfer failed: $error');
    } finally {
      await session.close();
      stdout.writeln('disconnected: ${session.peerName}');
    }
  }
}

class PairCommand extends Command<int> {
  PairCommand() {
    argParser
      ..addOption('to', help: 'host:port of the device to pair with.')
      ..addOption(
        'peer',
        help: 'Name or fingerprint prefix of a device to find over mDNS.',
      )
      ..addOption(
        'expect',
        help: 'Fingerprint the peer must present, if you already know it.',
      );
  }

  @override
  String get name => 'pair';

  @override
  String get description => 'Pair with another device (D-02).';

  @override
  Future<int> run() async {
    final harness = await Harness.load(globalResults);
    final target = await resolveTarget(argResults!);

    final session = await Dialler.connect(
      host: target.host,
      port: target.port,
      identity: harness.identity,
      trustStore: harness.trustStore,
      // A fingerprint from a TXT record is only a hint; the certificate still
      // decides (D-09). Checking it early turns a wrong device into a clear
      // error instead of a confusing comparison mismatch.
      expectFingerprint:
          (argResults!['expect'] as String?) ?? target.fingerprint,
      confirmPairing: _confirmAtTerminal,
    );
    try {
      stdout.writeln(
        'Paired with ${session.peerName} (${session.peerFingerprint}).',
      );
    } finally {
      await session.close();
    }
    return 0;
  }
}

class SendCommand extends Command<int> {
  SendCommand() {
    argParser
      ..addOption('to', help: 'host:port of the receiving device.')
      ..addOption(
        'peer',
        help: 'Name or fingerprint prefix of a device to find over mDNS.',
      )
      ..addOption('file', abbr: 'f', help: 'File to send.', mandatory: true)
      ..addOption('as', help: 'Name to send it under.');
  }

  @override
  String get name => 'send';

  @override
  String get description => 'Send a file to a paired device.';

  @override
  Future<int> run() async {
    final harness = await Harness.load(globalResults);
    final target = await resolveTarget(argResults!);

    // No confirmPairing: send only talks to devices already paired.
    final session = await Dialler.connect(
      host: target.host,
      port: target.port,
      identity: harness.identity,
      trustStore: harness.trustStore,
      expectFingerprint: target.fingerprint,
    );
    try {
      await FileSender.send(
        session: session,
        file: File(argResults!['file'] as String),
        asName: argResults!['as'] as String?,
        onProgress: _progress('sending'),
      );
      stdout.writeln('\nsent to ${session.peerName}.');
    } finally {
      await session.close();
    }
    return 0;
  }
}

/// Prints a percentage, redrawing one line rather than scrolling.
void Function(int done, int total) _progress(String label) {
  var lastShown = -1;
  return (done, total) {
    final percent = total == 0 ? 100 : (done * 100) ~/ total;
    if (percent == lastShown) return;
    lastShown = percent;
    stdout.write('\r$label: $percent%  ');
  };
}
