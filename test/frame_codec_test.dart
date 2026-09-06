import 'dart:convert';
import 'dart:typed_data';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:lsync_transport/src/transport/byte_reader.dart';
import 'package:test/test.dart';

/// Feeds bytes in fixed-size pieces so the reader has to stitch frames back
/// together across chunk boundaries, which is what a real socket does.
Stream<List<int>> inPieces(List<int> bytes, int pieceSize) async* {
  for (var at = 0; at < bytes.length; at += pieceSize) {
    yield bytes.sublist(
      at,
      at + pieceSize > bytes.length ? bytes.length : at + pieceSize,
    );
  }
}

List<int> frameBytes(Map<String, Object?> header, [List<int>? body]) => <int>[
      ...encodeHeader(
        body == null ? header : <String, Object?>{...header, 'body': body.length},
      ),
      ...?body,
    ];

void main() {
  group('header framing', () {
    test('round-trips a header', () async {
      final reader = FrameReader(
        Stream<List<int>>.value(frameBytes(<String, Object?>{
          't': 'hello',
          'v': 1,
          'name': 'laptop',
        })),
      );

      final frame = await reader.readFrame();
      expect(frame, isNotNull);
      expect(frame!.type, 'hello');
      expect(frame.requireString('name'), 'laptop');
      expect(frame.hasBody, isFalse);
      expect(await reader.readFrame(), isNull);
    });

    test('reads frames split across arbitrary chunk boundaries', () async {
      final bytes = <int>[
        ...frameBytes(<String, Object?>{'t': 'one'}),
        ...frameBytes(<String, Object?>{'t': 'two'}, utf8.encode('body!')),
        ...frameBytes(<String, Object?>{'t': 'three'}),
      ];

      for (final pieceSize in <int>[1, 3, 7, 64, 4096]) {
        final reader = FrameReader(inPieces(bytes, pieceSize));

        expect((await reader.readFrame())!.type, 'one', reason: '$pieceSize');

        final second = await reader.readFrame();
        expect(second!.type, 'two');
        final collected = <int>[];
        await reader.readBodyInto(collected.addAll);
        expect(utf8.decode(collected), 'body!');

        expect((await reader.readFrame())!.type, 'three');
        expect(await reader.readFrame(), isNull);
      }
    });

    test('a clean close between frames reads as end of stream', () async {
      final reader = FrameReader(const Stream<List<int>>.empty());
      expect(await reader.readFrame(), isNull);
    });
  });

  group('framing refuses malformed input', () {
    test('a header longer than the cap', () async {
      final prefix = Uint8List(4);
      ByteData.sublistView(prefix)
          .setUint32(0, maxHeaderBytes + 1, Endian.big);
      final reader = FrameReader(Stream<List<int>>.value(prefix));

      await expectLater(
        reader.readFrame(),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a zero-length header', () async {
      final reader = FrameReader(
        Stream<List<int>>.value(Uint8List(4)),
      );
      await expectLater(
        reader.readFrame(),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a header that is not JSON', () async {
      final body = utf8.encode('not json');
      final prefix = Uint8List(4);
      ByteData.sublistView(prefix).setUint32(0, body.length, Endian.big);
      final reader = FrameReader(
        Stream<List<int>>.value(<int>[...prefix, ...body]),
      );
      await expectLater(
        reader.readFrame(),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a body longer than the cap', () async {
      final reader = FrameReader(
        Stream<List<int>>.value(
          encodeHeader(<String, Object?>{'t': 'x', 'body': maxBodyBytes + 1}),
        ),
      );
      await expectLater(
        reader.readFrame(),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a stream that ends part way through a frame', () async {
      final complete = frameBytes(<String, Object?>{'t': 'truncated'});
      final reader = FrameReader(
        Stream<List<int>>.value(complete.sublist(0, complete.length - 2)),
      );
      await expectLater(
        reader.readFrame(),
        throwsA(isA<EndOfStreamException>()),
      );
    });

    test('a stream that ends part way through a body', () async {
      final bytes = frameBytes(<String, Object?>{'t': 'x'}, <int>[1, 2, 3, 4]);
      final reader = FrameReader(
        Stream<List<int>>.value(bytes.sublist(0, bytes.length - 2)),
      );
      expect((await reader.readFrame())!.bodyLength, 4);
      await expectLater(
        reader.readBodyInto((_) {}),
        throwsA(isA<EndOfStreamException>()),
      );
    });
  });

  test('skipping an unconsumed body is refused', () async {
    // Silently dropping a body would leave the stream desynchronised, and every
    // frame after it would be garbage.
    final reader = FrameReader(
      Stream<List<int>>.value(<int>[
        ...frameBytes(<String, Object?>{'t': 'one'}, <int>[9, 9, 9]),
        ...frameBytes(<String, Object?>{'t': 'two'}),
      ]),
    );

    expect((await reader.readFrame())!.bodyLength, 3);
    await expectLater(
      reader.readFrame(),
      throwsA(isA<ProtocolException>()),
    );
  });

  test('encodeHeader writes a four-byte big-endian length (D-10)', () {
    final encoded = encodeHeader(<String, Object?>{'t': 'x'});
    final declared = ByteData.sublistView(encoded).getUint32(0, Endian.big);
    expect(declared, encoded.length - 4);
    expect(jsonDecode(utf8.decode(encoded.sublist(4))), <String, Object?>{
      't': 'x',
    });
  });

  test('the chunk size is the 64 KiB D-10 specifies', () {
    expect(chunkSize, 64 * 1024);
  });
}
