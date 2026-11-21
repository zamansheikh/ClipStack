import 'dart:io';

import 'package:flutter/services.dart';

/// Dart side of the "clipstack/native" channel (NativeBridge.kt on Android).
/// On other platforms every call is a harmless no-op until they get their
/// own native side.
class NativeBridge {
  NativeBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'intentReceived' && call.arguments is Map) {
        onIntent?.call(Map<String, Object?>.from(call.arguments as Map));
      }
    });
  }

  static const _channel = MethodChannel('clipstack/native');
  static final bool _supported = Platform.isAndroid;

  /// A share, pairing link or clipboard read (bubble, tile, notification)
  /// that arrived while the app was running.
  void Function(Map<String, Object?> intent)? onIntent;

  /// The share or pairing link the app was launched with, once.
  Future<Map<String, Object?>?> takeInitialIntent() async {
    if (!_supported) return null;
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('takeInitialIntent');
    return result == null ? null : Map<String, Object?>.from(result);
  }

  Future<String> deviceName() async {
    if (!_supported) return Platform.localHostname;
    return await _channel.invokeMethod<String>('deviceName') ?? 'Android phone';
  }

  Future<void> startKeepAlive(String text) => _call('startKeepAlive', {'text': text});
  Future<void> updateKeepAlive(String text) => _call('updateKeepAlive', {'text': text});
  Future<void> stopKeepAlive() => _call('stopKeepAlive');
  Future<void> requestNotificationPermission() => _call('requestNotificationPermission');
  Future<void> setClipboardImage(Uint8List png) => _call('setClipboardImage', {'png': png});
  Future<void> moveToBack() => _call('moveToBack');
  Future<void> showToast(String text) => _call('showToast', {'text': text});

  // The floating bubble ("Display over other apps").
  Future<bool> canDrawOverlays() async =>
      _supported && (await _channel.invokeMethod<bool>('canDrawOverlays') ?? false);
  Future<void> requestOverlayPermission() => _call('requestOverlayPermission');
  Future<void> setBubble(bool enabled) => _call('setBubble', {'enabled': enabled});

  /// The optional "ClipStack paste" Accessibility service (bubble → Paste).
  Future<bool> isPasteServiceEnabled() async =>
      _supported && (await _channel.invokeMethod<bool>('isPasteServiceEnabled') ?? false);
  Future<void> openAccessibilitySettings() => _call('openAccessibilitySettings');

  /// What the bubble's panel shows: connection status and recent clips.
  Future<void> updateBubble(String status, List<Map<String, Object?>> items) =>
      _call('updateBubble', {'status': status, 'items': items});

  /// Shared image (any format) → PNG that fits the protocol's size limit.
  Future<Uint8List> pngFromUri(String uri, {required int maxBytes}) async {
    final png = await _channel.invokeMethod<Uint8List>('pngFromUri', {'uri': uri, 'maxBytes': maxBytes});
    if (png == null) throw StateError('could not read the shared image');
    return png;
  }

  Future<void> _call(String method, [Map<String, Object?>? args]) async {
    if (_supported) await _channel.invokeMethod<void>(method, args);
  }
}
