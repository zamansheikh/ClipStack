import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipstack_sync/clipstack_sync.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A computer this phone is paired with.
class PairedPeer {
  PairedPeer({required this.device, required this.publicKey, required this.hosts, required this.port});

  final DeviceInfo device;
  final Uint8List publicKey;

  /// Addresses it was last reached at, best first (fallback when mDNS is blocked).
  final List<String> hosts;
  final int port;

  PairedPeer copyWith({List<String>? hosts, int? port, DeviceInfo? device}) => PairedPeer(
        device: device ?? this.device,
        publicKey: publicKey,
        hosts: hosts ?? this.hosts,
        port: port ?? this.port,
      );

  Map<String, Object?> toJson() =>
      {'device': device.toJson(), 'publicKey': b64urlEncode(publicKey), 'hosts': hosts, 'port': port};

  static PairedPeer fromJson(Map<String, Object?> json) => PairedPeer(
        device: DeviceInfo.fromJson(json['device']),
        publicKey: b64urlDecode(json['publicKey'] as String),
        hosts: (json['hosts'] as List).cast<String>(),
        port: json['port'] as int,
      );
}

/// One clip in the phone's history: sent from here or received.
class HistoryItem {
  HistoryItem({
    required this.id,
    required this.kind,
    required this.deviceName,
    required this.incoming,
    required this.at,
    this.text,
    this.imagePath,
    this.fingerprint,
    this.devicePlatform,
  });

  final String id;
  final String kind;
  final String? text;
  final String? imagePath;

  /// Identity of an image's bytes, to spot the same picture again; null for
  /// text, and for images saved before history merged repeats.
  final String? fingerprint;

  /// The other device: where it came from, or where it was sent.
  final String deviceName;

  /// Platform of [deviceName] ("macos", "android"…) for its icon; null for
  /// clips saved before phones could pair with each other.
  final String? devicePlatform;
  final bool incoming;
  final DateTime at;

  bool get isImage => imagePath != null;

  /// The same clip again: the same picture, or the same text (a link and
  /// the same text copied plainly count as one, as on the Mac).
  bool sameContent(HistoryItem other) {
    if (isImage || other.isImage) return isImage && other.isImage && fingerprint != null && fingerprint == other.fingerprint;
    return text == other.text;
  }

  /// [history] with [item] on top. An item with the same content moves up
  /// as [item] (new time and device) instead of appearing twice. Returns
  /// the new list and the items that left it, whose images can be deleted.
  static ({List<HistoryItem> kept, List<HistoryItem> dropped}) add(List<HistoryItem> history, HistoryItem item,
      {int limit = AppStorage.historyLimit}) {
    final replaced = history.where((h) => h.id == item.id || h.sameContent(item)).toSet();
    final all = [item, ...history.where((h) => !replaced.contains(h))];
    return (kept: all.take(limit).toList(), dropped: [...replaced, ...all.skip(limit)]);
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'text': text,
        'imagePath': imagePath,
        'fingerprint': fingerprint,
        'deviceName': deviceName,
        'devicePlatform': devicePlatform,
        'incoming': incoming,
        'at': at.millisecondsSinceEpoch,
      };

  static HistoryItem fromJson(Map<String, Object?> json) => HistoryItem(
        id: json['id'] as String,
        kind: json['kind'] as String,
        text: json['text'] as String?,
        imagePath: json['imagePath'] as String?,
        fingerprint: json['fingerprint'] as String?,
        deviceName: json['deviceName'] as String,
        devicePlatform: json['devicePlatform'] as String?,
        incoming: json['incoming'] as bool,
        at: DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
      );
}

/// Persistence: the private key in the platform keystore, everything else
/// in shared preferences, history images as files.
class AppStorage {
  static const _secure = FlutterSecureStorage();
  static const historyLimit = 100;

  Future<DeviceIdentity> loadIdentity({required String name, required String platform}) async {
    final prefs = await SharedPreferences.getInstance();
    final deviceJson = prefs.getString('device');
    final privateKey = await _secure.read(key: 'privateKey');
    if (deviceJson != null && privateKey != null) {
      final identity = await DeviceIdentity.restore(
        DeviceInfo.fromJson(jsonDecode(deviceJson)),
        b64urlDecode(privateKey),
      );
      // Follow the phone's current name (the user may have renamed it).
      return identity.device.name == name ? identity : identity.renamed(name);
    }
    final identity = await DeviceIdentity.generate(name: name, platform: platform);
    await _secure.write(key: 'privateKey', value: b64urlEncode(identity.privateKeyBytes));
    await prefs.setString('device', jsonEncode(identity.device.toJson()));
    return identity;
  }

  Future<List<PairedPeer>> loadPeers() async {
    final prefs = await SharedPreferences.getInstance();
    final list = jsonDecode(prefs.getString('peers') ?? '[]') as List;
    return list.map((e) => PairedPeer.fromJson(Map<String, Object?>.from(e as Map))).toList();
  }

  Future<void> savePeers(List<PairedPeer> peers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('peers', jsonEncode(peers.map((p) => p.toJson()).toList()));
  }

  Future<List<HistoryItem>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = jsonDecode(prefs.getString('history') ?? '[]') as List;
    return list.map((e) => HistoryItem.fromJson(Map<String, Object?>.from(e as Map))).toList();
  }

  /// Persists the history list (the controller trims it to [historyLimit]).
  Future<void> saveHistory(List<HistoryItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('history', jsonEncode(items.map((i) => i.toJson()).toList()));
  }

  Future<String> saveImage(String id, Uint8List png) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/history');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$id.png');
    await file.writeAsBytes(png, flush: true);
    return file.path;
  }

  Future<void> deleteImage(String path) => _deleteQuietly(path);

  Future<bool> autoSendOnOpen() async => (await SharedPreferences.getInstance()).getBool('autoSendOnOpen') ?? true;

  Future<bool> bubbleEnabled() async => (await SharedPreferences.getInstance()).getBool('bubbleEnabled') ?? false;

  Future<void> setBubbleEnabled(bool value) async =>
      (await SharedPreferences.getInstance()).setBool('bubbleEnabled', value);

  Future<void> setAutoSendOnOpen(bool value) async =>
      (await SharedPreferences.getInstance()).setBool('autoSendOnOpen', value);

  /// The last text sent or received, so opening the app doesn't echo it back.
  Future<String?> lastSyncedText() async => (await SharedPreferences.getInstance()).getString('lastSyncedText');

  Future<void> setLastSyncedText(String text) async =>
      (await SharedPreferences.getInstance()).setString('lastSyncedText', text);

  Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // already gone
    }
  }
}
