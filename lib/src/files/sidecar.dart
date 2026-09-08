import 'dart:convert';
import 'dart:io';

/// The record that sits beside an in-progress `.part` file (D-12), and what
/// makes resume possible (D-07).
///
/// It identifies the transfer by what the offer carries — size and whole-file
/// digest — rather than by a transfer ID. The content is the thing resume needs
/// to recognise: an ID identifies an *attempt*, and two attempts at the same
/// file should share a partial rather than fork it. A random per-send ID would
/// actively prevent resume, since a reconnect generates a new one.
///
/// Since the D-06 amendment this outlives a failed transfer, so it is retained
/// state in the ordinary sense. It is deleted on success, on a content error,
/// and by the user.
class TransferSidecar {
  TransferSidecar(this.path);

  /// Bumped from 1, which held a transfer ID and an offset and could not
  /// support resume. A version 1 file is unreadable here and is treated as no
  /// sidecar at all, which discards the partial rather than guessing.
  static const int formatVersion = 2;

  factory TransferSidecar.forPartFile(String partPath) =>
      TransferSidecar('$partPath.json');

  final String path;

  File get file => File(path);

  /// Records progress.
  ///
  /// [prefixSha256] is the digest of the first [offset] bytes. It can only be
  /// produced when a session ends in a way the receiver catches, because the
  /// running digest can be finalised then and not before: SHA-256 state cannot
  /// be snapshotted mid-stream without re-reading the file, which on a large
  /// partial would cost a full read per checkpoint. A periodic checkpoint
  /// therefore writes the offset with no prefix, and is still resumable — see
  /// [SidecarRecord.isResumable].
  ///
  /// Written to a temporary file and renamed, the same way [TrustStore] saves,
  /// because this is the record resume trusts. A plain overwrite is
  /// open-with-truncate then write: a process killed inside that window leaves
  /// a truncated record *and* has already destroyed the previous good one, so
  /// the partial beside it becomes unresumable. The rename makes the swap a
  /// single step — the reader sees the old record or the new one, never a torn
  /// one.
  Future<void> write({
    required int size,
    required String sha256,
    required int offset,
    String? prefixSha256,
  }) async {
    final temporary = File('$path.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{
        'version': formatVersion,
        'size': size,
        'sha256': sha256,
        'offset': offset,
        if (prefixSha256 != null) 'prefixSha256': prefixSha256,
      }),
      flush: true,
    );
    await temporary.rename(path);
  }

  /// Reads the record back, or null when there is none or it is unusable.
  ///
  /// Anything malformed reads as absent. A partial with an unreadable sidecar
  /// is discarded, which is the safe direction.
  Future<SidecarRecord?> read() async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['version'] != formatVersion) return null;

      final size = decoded['size'];
      final sha256 = decoded['sha256'];
      final offset = decoded['offset'];
      final prefix = decoded['prefixSha256'];

      if (size is! int || size < 0) return null;
      if (sha256 is! String || sha256.length != 64) return null;
      if (offset is! int || offset < 0 || offset > size) return null;
      if (prefix != null && (prefix is! String || prefix.length != 64)) {
        return null;
      }

      return SidecarRecord(
        size: size,
        sha256: sha256,
        offset: offset,
        prefixSha256: prefix as String?,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> delete() async {
    for (final target in <File>[file, File('$path.tmp')]) {
      try {
        await target.delete();
      } on FileSystemException {
        // Already gone, which is the state we wanted. The temporary only
        // exists at all if a write was killed between writing and renaming.
      }
    }
  }
}

class SidecarRecord {
  const SidecarRecord({
    required this.size,
    required this.sha256,
    required this.offset,
    this.prefixSha256,
  });

  /// Size of the whole file, from the offer that created this partial.
  final int size;

  /// Whole-file digest, from the offer (D-17).
  final String sha256;

  /// Bytes durably written.
  final int offset;

  /// Digest of the first [offset] bytes, when the session ended cleanly enough
  /// to compute one. Absent on a periodic checkpoint, which is the record a
  /// hard kill leaves behind. Verified before anything is appended when it is
  /// present; not required for the partial to be usable.
  final String? prefixSha256;

  /// Any record naming bytes on disk can be resumed. The prefix digest is not
  /// a precondition, because it answers a different question.
  ///
  /// Crash consistency — are the first [offset] bytes durably written? — comes
  /// from D-12's flush ordering: the receiver flushes before it records, so the
  /// recorded offset can never run ahead of the file. That holds with no digest
  /// at all. Tamper detection — are those bytes still the ones we wrote? — is
  /// what the prefix digest answers, and it is a check, not a licence.
  ///
  /// Requiring the second to get the first is what once made a hard kill lose
  /// the whole partial. See D-07.
  bool get isResumable => offset > 0;

  /// True when this record describes the file now being offered. Same name but
  /// different content must discard the partial, never append to it.
  bool describes({required int size, required String sha256}) =>
      this.size == size && this.sha256 == sha256;
}
