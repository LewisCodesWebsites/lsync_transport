import '../transport/frame.dart';

/// What the sender declares before any bytes move.
class FileOffer {
  const FileOffer({
    required this.transferId,
    required this.name,
    required this.size,
    required this.sha256,
  });

  /// Stable across reconnects, which is what resume will need (D-07).
  final String transferId;

  /// The name the sender proposes. Untrusted; run it through
  /// [sanitiseFileName] before it touches a path.
  final String name;

  final int size;

  /// Lowercase hex SHA-256 over the whole file, computed by the sender before
  /// sending (D-12).
  final String sha256;

  static FileOffer fromFrame(Frame frame) {
    final size = frame.requireInt('size');
    if (size < 0) {
      throw const ProtocolException('file offer has a negative size');
    }
    final sha256 = frame.requireString('sha256');
    if (sha256.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(sha256)) {
      throw const ProtocolException('file offer has a malformed SHA-256');
    }
    return FileOffer(
      transferId: frame.requireString('id'),
      name: frame.requireString('name'),
      size: size,
      sha256: sha256,
    );
  }
}

/// Windows device names, which are reserved at any extension.
final RegExp _windowsReservedName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
  caseSensitive: false,
);

final RegExp _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');

/// Reduces a peer-supplied file name to something safe to join onto the
/// destination directory.
///
/// The name arrives from the network and the receiver writes it to disk, so
/// this is the boundary that stops `../../.bashrc` and friends. Directory
/// components are dropped rather than rejected, because a sender on a different
/// platform may legitimately include them; everything else that could escape
/// the directory or name a device is refused outright.
///
/// Both separators are treated as separators regardless of local platform: the
/// sender may be Windows and the receiver Linux, or the reverse.
String sanitiseFileName(String proposed) {
  final lastSeparator =
      proposed.lastIndexOf(RegExp(r'[/\\]'));
  var name = lastSeparator >= 0
      ? proposed.substring(lastSeparator + 1)
      : proposed;

  // Windows alternate data streams, and drive-relative paths like `C:file`.
  final colon = name.lastIndexOf(':');
  if (colon >= 0) name = name.substring(colon + 1);

  name = name.trim();
  // Trailing dots and spaces are silently stripped by Windows, which would
  // make the final name differ from the one that was checked.
  while (name.isNotEmpty &&
      (name.endsWith('.') || name.endsWith(' '))) {
    name = name.substring(0, name.length - 1);
  }

  if (name.isEmpty) {
    throw const ProtocolException('file name is empty after sanitising');
  }
  if (name == '.' || name == '..') {
    throw const ProtocolException('file name is a directory reference');
  }
  if (_controlCharacters.hasMatch(name)) {
    throw const ProtocolException('file name contains control characters');
  }
  if (_windowsReservedName.hasMatch(name)) {
    throw ProtocolException('file name "$name" is a reserved device name');
  }
  if (name.length > 200) {
    throw const ProtocolException('file name is too long');
  }
  return name;
}
