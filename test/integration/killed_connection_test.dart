import 'package:test/test.dart';

/// D-13's second test: kill the connection at roughly 50% and assert that
/// resume produces an identical hash.
///
/// Pending by design, not by oversight. D-07 sequences resume as the second
/// pass, so there is nothing here to test yet: this pass fails loudly and
/// deletes the partial file. The sidecar is already written and kept current
/// during a transfer (see `TransferSidecar`), so the work this test is waiting
/// on is teaching the receiver to read it back, not restructuring the receiver.
///
/// What it will need when resume lands:
///
///   - a transfer ID that survives the reconnect, which the offer already
///     carries;
///   - the receiver reopening `<name>.part` in append mode at the sidecar's
///     offset instead of truncating;
///   - the sender seeking to that offset rather than starting at zero;
///   - the running SHA-256 rebuilt over the bytes already on disk, since the
///     digest cannot itself be resumed across a restart;
///   - and the assertion that matters: the final hash equals the source hash,
///     which is what would catch the corruption D-07 warns about.
void main() {
  test(
    'a connection killed at 50% resumes to an identical hash',
    () {
      fail('not implemented: resume is the second pass (D-07)');
    },
    skip: 'Resume is deliberately sequenced after the end-to-end pipeline '
        '(D-07). Enable with the resume implementation.',
  );
}
