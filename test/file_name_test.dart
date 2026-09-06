import 'package:lsync_transport/lsync_transport.dart';
import 'package:test/test.dart';

void main() {
  group('accepts ordinary names', () {
    for (final name in <String>[
      'photo.jpg',
      'a report (final).pdf',
      'no-extension',
      'ünïcode.txt',
      '.gitignore',
    ]) {
      test('"$name"', () => expect(sanitiseFileName(name), name));
    }
  });

  group('strips directory components', () {
    // The sender may be on a different platform, so both separators count
    // regardless of where the receiver is running.
    test('posix', () => expect(sanitiseFileName('a/b/c.txt'), 'c.txt'));
    test('windows', () => expect(sanitiseFileName(r'a\b\c.txt'), 'c.txt'));
    test('mixed', () => expect(sanitiseFileName(r'a/b\c.txt'), 'c.txt'));

    // Traversal is defeated by dropping the components, not by refusing the
    // name: what is left lands inside the destination directory, which is the
    // property that matters.
    test(
      'traversal',
      () => expect(sanitiseFileName('../../.bashrc'), '.bashrc'),
    );
  });

  group('refuses names that would escape or collide', () {
    // The receiver joins this onto the destination directory, so this is the
    // boundary that stops a hostile sender writing outside it.
    for (final name in <String>[
      '..',
      '.',
      '',
      '   ',
      'C:',
      'con',
      'PRN.txt',
      'lpt1',
      'nul\u0000byte',
      'tab\tname',
    ]) {
      test('"$name"', () {
        expect(() => sanitiseFileName(name), throwsA(isA<ProtocolException>()));
      });
    }
  });

  test('drops a Windows alternate data stream', () {
    expect(sanitiseFileName(r'notes.txt:hidden'), 'hidden');
  });

  test('drops trailing dots and spaces Windows would strip anyway', () {
    expect(sanitiseFileName('report.pdf.'), 'report.pdf');
    expect(sanitiseFileName('report.pdf   '), 'report.pdf');
  });

  test('refuses an absurdly long name', () {
    expect(
      () => sanitiseFileName('${'a' * 300}.txt'),
      throwsA(isA<ProtocolException>()),
    );
  });
}
