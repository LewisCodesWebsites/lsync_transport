import 'dart:io';

import 'package:path/path.dart' as p;

/// Directory holding the retained state D-06 permits: this device's private
/// key and certificate, peer fingerprints, peer names, and the clipboard bond.
///
/// Nothing else is written here. In-flight transfer artifacts live beside the
/// destination file instead (D-12).
String defaultConfigDir() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final base = env['APPDATA'] ?? env['USERPROFILE'];
    if (base == null || base.isEmpty) {
      throw StateError('Neither APPDATA nor USERPROFILE is set.');
    }
    return p.join(base, 'lsync');
  }
  final xdg = env['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'lsync');
  final home = env['HOME'];
  if (home == null || home.isEmpty) throw StateError('HOME is not set.');
  return p.join(home, '.config', 'lsync');
}
