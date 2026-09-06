import 'dart:convert';
import 'dart:io';

/// The offset record that sits beside an in-progress `.part` file (D-12).
///
/// Nothing reads this back yet. Resume is the second pass (D-07), and this is
/// the piece that lets it be added without restructuring the receiver: the file
/// is written and kept current now, so resume only has to learn to read it.
///
/// It is an in-flight artifact, so D-06 does not retain it: it is deleted on
/// completion and on failure alike, and nothing survives a finished or failed
/// transfer.
class TransferSidecar {
  TransferSidecar(this.path);

  static const int _formatVersion = 1;

  /// Sidecar for a given `.part` file. Sits beside it, in the destination
  /// directory, for the reasons D-12 gives for the `.part` file itself.
  factory TransferSidecar.forPartFile(String partPath) =>
      TransferSidecar('$partPath.json');

  final String path;

  File get file => File(path);

  /// Records that [offset] bytes are durably on disk.
  ///
  /// Call only after flushing the `.part` file. The recorded offset must never
  /// run ahead of what is actually written, or resume would later skip bytes
  /// that were never stored.
  Future<void> write({
    required String transferId,
    required int offset,
  }) async {
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'version': _formatVersion,
        'id': transferId,
        'offset': offset,
      }),
      flush: true,
    );
  }

  /// Reads the record back, or null when there is none or it is unusable.
  ///
  /// Unused in this pass. Present so the shape of the file is fixed now rather
  /// than negotiated later.
  Future<SidecarRecord?> read() async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['version'] != _formatVersion) return null;
      final id = decoded['id'];
      final offset = decoded['offset'];
      if (id is! String || offset is! int || offset < 0) return null;
      return SidecarRecord(transferId: id, offset: offset);
    } on FormatException {
      return null;
    }
  }

  Future<void> delete() async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone, which is the state we wanted.
    }
  }
}

class SidecarRecord {
  const SidecarRecord({required this.transferId, required this.offset});

  final String transferId;
  final int offset;
}
