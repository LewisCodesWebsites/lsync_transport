import 'package:lsync_transport/lsync_transport.dart';
import 'package:test/test.dart';

Frame _frame(Map<String, Object?> header, {int body = 0}) =>
    Frame(<String, Object?>{'t': msgClipboardUpdate, ...header}, body);

void main() {
  final digest = 'a' * 64;
  final origin = 'b' * 64;

  Map<String, Object?> valid() => <String, Object?>{
        'mime': clipboardTextMime,
        'sha256': digest,
        'origin': origin,
      };

  group('a well-formed update parses', () {
    test('carrying type, digest, origin and the body length', () {
      final update = ClipboardUpdate.fromFrame(_frame(valid(), body: 11));
      expect(update.mime, clipboardTextMime);
      expect(update.sha256, digest);
      expect(update.origin, origin);
      expect(update.size, 11);
    });

    test('an unknown type is well-formed, not malformed', () {
      // A peer running a later version is not misbehaving. Whether we can use
      // the content is the engine's call, and it is a refusal with a reason.
      final update = ClipboardUpdate.fromFrame(
        _frame(<String, Object?>{...valid(), 'mime': 'image/png'}, body: 4),
      );
      expect(update.mime, 'image/png');
    });

    test('an empty clipboard is a legal update, not an absent one', () {
      expect(ClipboardUpdate.fromFrame(_frame(valid())).size, 0);
    });
  });

  group('a malformed update is refused at the boundary', () {
    test('a digest of the wrong length', () {
      expect(
        () => ClipboardUpdate.fromFrame(
          _frame(<String, Object?>{...valid(), 'sha256': 'abc'}),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a digest that is not hex', () {
      expect(
        () => ClipboardUpdate.fromFrame(
          _frame(<String, Object?>{...valid(), 'sha256': 'z' * 64}),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('an uppercase digest, which would compare unequal to our own', () {
      // Our digests are lowercase hex everywhere. Accepting uppercase would
      // make loop prevention miss a match it should have made.
      expect(
        () => ClipboardUpdate.fromFrame(
          _frame(<String, Object?>{...valid(), 'sha256': 'A' * 64}),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a missing type', () {
      expect(
        () => ClipboardUpdate.fromFrame(
          _frame(<String, Object?>{'sha256': digest, 'origin': origin}),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a missing origin', () {
      expect(
        () => ClipboardUpdate.fromFrame(
          _frame(<String, Object?>{
            'mime': clipboardTextMime,
            'sha256': digest,
          }),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a numeric field where a string belongs', () {
      expect(
        () => ClipboardUpdate.fromFrame(
          _frame(<String, Object?>{...valid(), 'origin': 7}),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('refusals', () {
    test('carry a reason and a message', () {
      final refusal = ClipboardRefusal.fromFrame(Frame(<String, Object?>{
        't': msgClipboardRefused,
        'reason': ClipboardRefusal.notBonded,
        'message': 'this device is bonded elsewhere',
      }, 0));
      expect(refusal.reason, ClipboardRefusal.notBonded);
      expect(refusal.message, contains('bonded elsewhere'));
    });

    test('survive a peer that sends no message', () {
      final refusal = ClipboardRefusal.fromFrame(Frame(<String, Object?>{
        't': msgClipboardRefused,
        'reason': ClipboardRefusal.tooLarge,
      }, 0));
      expect(refusal.reason, ClipboardRefusal.tooLarge);
      expect(refusal.message, isNotEmpty);
    });

    test('a reason is required, since a refusal without one says nothing', () {
      expect(
        () => ClipboardRefusal.fromFrame(
          Frame(<String, Object?>{'t': msgClipboardRefused}, 0),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('content', () {
    test('hashes its encoded bytes, not its characters', () {
      // The two ends may run different platforms; the digest has to be over
      // something both compute identically.
      final content = ClipboardContent.text('héllo');
      expect(content.size, 6, reason: 'e-acute is two bytes in UTF-8');
      expect(content.sha256.length, 64);
      expect(content.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('identical text hashes identically, which is what D-11 relies on', () {
      expect(
        ClipboardContent.text('same').sha256,
        ClipboardContent.text('same').sha256,
      );
    });

    test('knows when it is too large to send', () {
      expect(ClipboardContent.text('x' * 100).isWithinLimit, isTrue);
      expect(
        ClipboardContent.text('x' * (maxClipboardBytes + 1)).isWithinLimit,
        isFalse,
      );
      expect(
        ClipboardContent.text('x' * maxClipboardBytes).isWithinLimit,
        isTrue,
        reason: 'the limit is inclusive',
      );
    });
  });
}
