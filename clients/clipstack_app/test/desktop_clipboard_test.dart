import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clipstack_app/src/desktop_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bottom-up 32 bpp BI_RGB bitmap, the way the Windows clipboard hands
/// images over: the alpha byte is unused (zero).
Uint8List bmp(int width, int height, {int seed = 0}) {
  const header = 14 + 40;
  final pixels = width * height * 4;
  final data = ByteData(header + pixels);
  data
    ..setUint8(0, 0x42) // 'B'
    ..setUint8(1, 0x4D) // 'M'
    ..setUint32(2, header + pixels, Endian.little)
    ..setUint32(10, header, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little)
    ..setUint32(30, 0, Endian.little) // BI_RGB
    ..setUint32(34, pixels, Endian.little);
  // Noise, so PNG size follows pixel count as it does for photos.
  var state = 0x2545F491 ^ seed;
  for (var i = 0; i < width * height; i++) {
    final offset = header + i * 4;
    for (var channel = 0; channel < 3; channel++) {
      state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
      data.setUint8(offset + channel, state >> 16);
    }
  }
  return data.buffer.asUint8List();
}

Future<ui.Image> decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  return (await codec.getNextFrame()).image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a Windows clipboard bitmap becomes an opaque PNG of the same size', () async {
    final png = await DesktopClipboard.toPng(bmp(64, 48), maxBytes: 10 << 20);
    expect(png, isNotNull);
    expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    final image = await decode(png);
    expect([image.width, image.height], [64, 48]);
    final rgba = (await image.toByteData())!;
    expect(rgba.getUint8(3), 255, reason: 'the unused alpha byte must not make it transparent');
  });

  test('a picture too big for the limit is scaled down to fit', () async {
    final raw = bmp(5000, 2500, seed: 3);
    final full = await DesktopClipboard.toPng(raw, maxBytes: 1 << 30);
    final png = await DesktopClipboard.toPng(raw, maxBytes: full!.length - 1);
    expect(png, isNotNull);
    expect(png!.length, lessThan(full.length));
    final image = await decode(png);
    expect(image.width, lessThanOrEqualTo(4096));
    expect(image.width / image.height, closeTo(2, 0.01));
  });

  test('a PNG that already fits is passed through unchanged', () async {
    final png = (await DesktopClipboard.toPng(bmp(8, 8), maxBytes: 1 << 20))!;
    expect(identical(await DesktopClipboard.toPng(png, maxBytes: 1 << 20), png), isTrue);
  });

  test('fingerprints tell different images apart', () {
    expect(DesktopClipboard.fingerprint(bmp(8, 8)), DesktopClipboard.fingerprint(bmp(8, 8)));
    expect(DesktopClipboard.fingerprint(bmp(8, 8)), isNot(DesktopClipboard.fingerprint(bmp(8, 8, seed: 1))));
    expect(DesktopClipboard.fingerprint(null), isNull);
  });

  test('there is no sequence number off Windows', () {
    expect(DesktopClipboard.sequenceNumber(), isNull);
  });
}
