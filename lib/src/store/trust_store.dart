import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The complete D-06 retained surface, apart from the key and certificate that
/// [DeviceIdentity] owns.
///
/// What this file holds: peer certificate fingerprints, peer device names, and
/// which pairing is the current clipboard bond. Nothing else. There is
/// deliberately no paired-at timestamp and no transfer log; both would be a
/// record of user activity, which D-06 excludes.
class TrustStore {
  TrustStore._(this._file, this._peers, this._clipboardBond);

  static const int _formatVersion = 1;

  final File _file;
  final Map<String, String> _peers;
  String? _clipboardBond;

  static String storePath(String configDir) => p.join(configDir, 'peers.json');

  static Future<TrustStore> open(String configDir) async {
    final file = File(storePath(configDir));
    if (!await file.exists()) {
      return TrustStore._(file, <String, String>{}, null);
    }

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw FormatException('${file.path}: not a JSON object');
    }
    final version = decoded['version'];
    if (version != _formatVersion) {
      throw FormatException(
        '${file.path}: unsupported format version $version',
      );
    }

    final peers = <String, String>{};
    final rawPeers = decoded['peers'];
    if (rawPeers is Map<String, Object?>) {
      for (final entry in rawPeers.entries) {
        final value = entry.value;
        if (value is Map<String, Object?>) {
          final name = value['name'];
          if (name is String) peers[entry.key] = name;
        }
      }
    }

    final bond = decoded['clipboardBond'];
    return TrustStore._(file, peers, bond is String ? bond : null);
  }

  /// Fingerprint to device name, for every pinned peer.
  Map<String, String> get peers => Map.unmodifiable(_peers);

  bool isPinned(String fingerprint) => _peers.containsKey(fingerprint);

  String? nameOf(String fingerprint) => _peers[fingerprint];

  /// The pairing currently carrying the clipboard (D-03). The transport layer
  /// does not use this; it lives here because D-06 says it is stored.
  String? get clipboardBond => _clipboardBond;

  Future<void> pin(String fingerprint, String deviceName) async {
    _peers[fingerprint] = deviceName;
    await _save();
  }

  Future<void> unpin(String fingerprint) async {
    _peers.remove(fingerprint);
    if (_clipboardBond == fingerprint) _clipboardBond = null;
    await _save();
  }

  Future<void> setClipboardBond(String? fingerprint) async {
    if (fingerprint != null && !_peers.containsKey(fingerprint)) {
      throw ArgumentError('cannot bond to an unpaired device: $fingerprint');
    }
    _clipboardBond = fingerprint;
    await _save();
  }

  /// Writes to a temporary file and renames, so a crash mid-write cannot leave
  /// a truncated trust store behind.
  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final payload = <String, Object?>{
      'version': _formatVersion,
      'peers': <String, Object?>{
        for (final entry in _peers.entries)
          entry.key: <String, Object?>{'name': entry.value},
      },
      'clipboardBond': _clipboardBond,
    };
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    await temporary.rename(_file.path);
  }
}
