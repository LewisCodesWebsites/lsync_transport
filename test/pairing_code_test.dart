import 'package:lsync_transport/lsync_transport.dart';
import 'package:test/test.dart';

/// A fingerprint-shaped string. The value never matters, only that two of them
/// differ.
String fp(int seed) => seed.toRadixString(16).padLeft(64, '0');

void main() {
  test('both devices derive the same digits from the same pair', () {
    // The whole mechanism: each side hashes both fingerprints, sorted, so
    // neither has to be told which order to use.
    expect(
      shortAuthenticationString(fp(1), fp(2)),
      shortAuthenticationString(fp(2), fp(1)),
    );
  });

  test('it is always six digits', () {
    for (var seed = 1; seed < 200; seed++) {
      final sas = shortAuthenticationString(fp(seed), fp(seed + 1000));
      expect(sas, matches(RegExp(r'^\d{6}$')), reason: 'seed $seed');
    }
  });

  test('a different peer gives different digits', () {
    // This is what a device in the middle runs into: it holds one fingerprint
    // towards the phone and another towards the laptop, so the two screens
    // disagree and the user sees it.
    final honest = shortAuthenticationString(fp(1), fp(2));
    final attacker = shortAuthenticationString(fp(1), fp(3));
    expect(honest, isNot(attacker));
  });

  test('a man in the middle cannot match both sides at once', () {
    // Two legitimate devices, and an attacker terminating TLS in between with
    // its own certificate. Each honest device compares against the attacker,
    // not against each other.
    const phone = 'aa';
    const laptop = 'bb';
    const attacker = 'cc';

    final phoneShows = shortAuthenticationString(phone, attacker);
    final laptopShows = shortAuthenticationString(laptop, attacker);
    final expected = shortAuthenticationString(phone, laptop);

    expect(phoneShows, isNot(expected));
    expect(laptopShows, isNot(expected));
  });

  test('pairing a device with itself is refused', () {
    expect(
      () => shortAuthenticationString(fp(7), fp(7)),
      throwsArgumentError,
    );
  });

  test('display grouping keeps every digit', () {
    expect(formatSas('012345'), '012 345');
  });
}
