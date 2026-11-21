import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pasteboard/pasteboard.dart';

/// Clipboard helpers for the PC app (Windows, Linux).
abstract final class DesktopClipboard {
  /// Windows bumps this number on every clipboard change, so a poll can
  /// skip reading anything until it moves. Null where there's no such
  /// counter (Linux): read every time.
  static int? sequenceNumber() => _getClipboardSequenceNumber?.call();

  static final int Function()? _getClipboardSequenceNumber = () {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('user32.dll')
          .lookupFunction<Uint32 Function(), int Function()>('GetClipboardSequenceNumber');
    } on Object {
      return null;
    }
  }();

  /// The picture on the clipboard as raw bytes (BMP on Windows), or null.
  static Future<Uint8List?> image() => Pasteboard.image;

  /// [image] as a PNG of at most [maxBytes], scaled down if it has to be.
  /// Devices exchange PNG; Windows hands the clipboard over as BMP.
  static Future<Uint8List?> toPng(Uint8List image, {required int maxBytes}) async {
    if (_isPng(image) && image.length <= maxBytes) return image;
    final buffer = await ui.ImmutableBuffer.fromUint8List(image);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final longest = max(descriptor.width, descriptor.height);
      for (final side in [longest, 4096, 3072, 2048, 1536, 1024]) {
        if (side > longest) continue;
        final scale = side / longest;
        final codec = await descriptor.instantiateCodec(
          targetWidth: max(1, (descriptor.width * scale).round()),
          targetHeight: max(1, (descriptor.height * scale).round()),
        );
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        frame.image.dispose();
        codec.dispose();
        if (data != null && data.lengthInBytes <= maxBytes) return data.buffer.asUint8List();
      }
      return null;
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }

  /// Cheap identity for clipboard images: size plus a sample of the bytes.
  static String? fingerprint(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    var hash = 0;
    final step = (bytes.length ~/ 4096).clamp(1, 1 << 20);
    for (var i = 0; i < bytes.length; i += step) {
      hash = (hash * 31 + bytes[i]) & 0x3fffffff;
    }
    return '${bytes.length}:$hash';
  }

  static bool _isPng(Uint8List bytes) =>
      bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;
}
