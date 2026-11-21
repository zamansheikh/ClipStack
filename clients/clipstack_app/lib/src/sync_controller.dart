import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:clipstack_sync/clipstack_sync.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'discovery.dart';
import 'native.dart';
import 'storage.dart';

enum LinkState { notPaired, searching, connected }

/// Everything the app does: pairing, staying connected to paired computers,
/// sending (button, share sheet, on open) and applying received clips.
class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  SyncController({NativeBridge? native, AppStorage? storage})
      : native = native ?? NativeBridge(),
        storage = storage ?? AppStorage();

  static const appVersion = '0.1.0';

  final NativeBridge native;
  final AppStorage storage;
  final PeerDiscovery discovery = PeerDiscovery();

  DeviceIdentity? _identity;
  List<PairedPeer> peers = [];
  List<HistoryItem> history = [];
  bool autoSendOnOpen = true;
  bool ready = false;

  final _sessions = <String, SyncSession>{};
  final _loops = <String, _PeerLoop>{};
  final _messages = StreamController<String>.broadcast();
  /// What the phone's clipboard held when it was last synced (received from
  /// a computer, or read and sent). Auto-send skips it, so clips never echo
  /// back. Sending shared text doesn't touch the clipboard, so it doesn't
  /// change this.
  String? _clipboardSynced;

  /// Received clips are applied through this chain, strictly in order.
  Future<void> _receiveChain = Future.value();

  /// When a share or pairing link last arrived; the resume it causes must
  /// not also auto-send the clipboard.
  DateTime _intentAt = DateTime(0);

  /// Short user-facing notices ("Sent to …"), shown as snack bars.
  Stream<String> get messages => _messages.stream;

  LinkState get state =>
      peers.isEmpty ? LinkState.notPaired : (_sessions.isEmpty ? LinkState.searching : LinkState.connected);

  bool isConnected(PairedPeer peer) => _sessions.containsKey(peer.device.id);

  /// This phone's name as computers see it.
  String get phoneName => _identity?.device.name ?? 'This phone';

  /// Try every paired computer now instead of waiting out the backoff.
  void retryNow() {
    for (final loop in _loops.values) {
      loop.wake();
    }
  }

  String get connectedNames => peers.where(isConnected).map((p) => p.device.name).join(', ');

  String get statusText => switch (state) {
        LinkState.notPaired => 'Not paired with a computer yet',
        LinkState.searching => 'Looking for ${peers.map((p) => p.device.name).join(', ')}…',
        LinkState.connected => 'Connected to $connectedNames',
      };

  // MARK: - Startup

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    final platform = Platform.isAndroid ? Platforms.android : (Platform.isIOS ? Platforms.ios : Platforms.linux);
    _identity = await storage.loadIdentity(name: await native.deviceName(), platform: platform);
    peers = await storage.loadPeers();
    history = await storage.loadHistory();
    autoSendOnOpen = await storage.autoSendOnOpen();
    _clipboardSynced = await storage.lastSyncedText();
    native.onIntent = (intent) {
      _intentAt = DateTime.now();
      _handleIntent(intent);
    };

    discovery.found.listen((id) => _loops[id]?.wake());
    unawaited(discovery.start().catchError((Object e) => debugPrint('ClipStack: discovery unavailable: $e')));
    for (final peer in peers) {
      _startLoop(peer);
    }
    if (peers.isNotEmpty) unawaited(native.startKeepAlive(statusText));

    ready = true;
    notifyListeners();

    final initial = await native.takeInitialIntent();
    if (initial != null) {
      _intentAt = DateTime.now();
      await _handleIntent(initial);
    } else {
      unawaited(_autoSendIfChanged());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    for (final loop in _loops.values) {
      loop.wake(); // reconnect right away instead of waiting out the backoff
    }
    unawaited(_autoSendIfChanged());
  }

  // MARK: - Pairing

  /// Pair using a `clipstack://pair?...` link (QR code, camera app, or pasted).
  Future<PairedPeer> pair(String linkText) async {
    final link = PairingLink.parse(linkText);
    final found = discovery.lookup(link.device.id);
    final targets = <PeerAddress>[
      ?found,
      for (final host in link.hosts) (host: host, port: link.port),
    ];
    if (targets.isEmpty) throw const FormatException('The pairing link has no address');

    Object? lastError;
    for (final target in targets) {
      try {
        final session = await SyncSession.connect(
          host: target.host,
          port: target.port,
          identity: _identity!,
          peerStaticKey: link.publicKey,
          expectedPeerId: link.device.id,
          pairingToken: link.token,
          appVersion: appVersion,
        );
        final peer = PairedPeer(
          device: session.peer,
          publicKey: link.publicKey,
          hosts: [target.host, ...link.hosts.where((h) => h != target.host)],
          port: target.port,
        );
        await _forget(peer.device.id, notifyPeer: false); // re-pairing replaces the old entry
        peers = [...peers, peer];
        await storage.savePeers(peers);
        _startLoop(peer, initial: session);
        unawaited(native.requestNotificationPermission());
        unawaited(native.startKeepAlive(statusText));
        notifyListeners();
        return peer;
      } on ProtocolException catch (error) {
        // The computer answered and refused: no point trying other addresses.
        throw error.code == 'bad_token'
            ? const FormatException('That pairing code has expired. Open "Pair a Device" again on your computer.')
            : FormatException('Pairing failed: ${error.message}');
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw FormatException("Couldn't reach ${link.device.name}. Is it on the same Wi-Fi? ($lastError)");
  }

  /// Remove a pairing on both sides (the computer is told if it's online).
  Future<void> unpair(PairedPeer peer) => _forget(peer.device.id, notifyPeer: true);

  Future<void> _forget(String deviceId, {required bool notifyPeer}) async {
    _loops.remove(deviceId)?.stop();
    final session = _sessions.remove(deviceId);
    if (session != null) {
      if (notifyPeer) {
        await session.sendUnpair().catchError((_) {});
      } else {
        await session.close();
      }
    }
    final before = peers.length;
    peers = peers.where((p) => p.device.id != deviceId).toList();
    if (peers.length != before) await storage.savePeers(peers);
    if (peers.isEmpty) unawaited(native.stopKeepAlive());
    notifyListeners();
  }

  // MARK: - Connections

  void _startLoop(PairedPeer peer, {SyncSession? initial}) {
    final loop = _PeerLoop();
    _loops[peer.device.id] = loop;
    unawaited(_run(peer.device.id, loop, initial));
  }

  /// Keeps one session per paired computer: connect, serve until it drops,
  /// back off, repeat. Discovery and app resume cut the backoff short.
  Future<void> _run(String deviceId, _PeerLoop loop, SyncSession? initial) async {
    var backoff = 1;
    var session = initial;
    while (!loop.stopped) {
      session ??= await _connect(deviceId);
      if (loop.stopped) {
        await session?.close();
        return;
      }
      if (session == null) {
        await loop.sleep(Duration(seconds: backoff));
        backoff = min(backoff * 2, 30);
        continue;
      }
      backoff = 1;
      final peer = _peer(deviceId);
      if (peer == null) {
        await session.close();
        return;
      }
      _sessions[deviceId] = session;
      _statusChanged();
      // One at a time, in order: a big image must not let a later text clip
      // finish first (wrong clipboard, lost history update).
      final subscription = session.clips.listen((clip) {
        _receiveChain = _receiveChain
            .then((_) => _receive(peer, clip))
            .catchError((Object e) => debugPrint('ClipStack: applying a clip failed: $e'));
      });
      await session.done;
      await subscription.cancel();
      if (_sessions[deviceId] == session) _sessions.remove(deviceId);
      debugPrint('ClipStack: session with ${peer.device.name} ended: ${session.closeReason}');
      if (session.peerUnpaired) {
        _messages.add('${peer.device.name} removed this phone');
        await _forget(deviceId, notifyPeer: false);
        return;
      }
      session = null;
      _statusChanged();
      await loop.sleep(const Duration(seconds: 1));
    }
  }

  Future<SyncSession?> _connect(String deviceId) async {
    final peer = _peer(deviceId);
    if (peer == null) return null;
    final found = discovery.lookup(deviceId);
    final targets = <PeerAddress>{
      ?found,
      for (final host in peer.hosts) (host: host, port: peer.port),
    };
    for (final target in targets) {
      try {
        final session = await SyncSession.connect(
          host: target.host,
          port: target.port,
          identity: _identity!,
          peerStaticKey: peer.publicKey,
          expectedPeerId: deviceId,
          appVersion: appVersion,
          timeout: const Duration(seconds: 5),
        );
        await _rememberAddress(deviceId, target, session.peer);
        return session;
      } on Object catch (error) {
        debugPrint('ClipStack: ${target.host}:${target.port} failed: $error');
      }
    }
    return null;
  }

  /// Put the address that worked first, and pick up a renamed computer.
  Future<void> _rememberAddress(String deviceId, PeerAddress address, DeviceInfo device) async {
    final index = peers.indexWhere((p) => p.device.id == deviceId);
    if (index < 0) return;
    final peer = peers[index];
    final hosts = [address.host, ...peer.hosts.where((h) => h != address.host)].take(4).toList();
    if (hosts.first == peer.hosts.firstOrNull && address.port == peer.port && device.name == peer.device.name) return;
    peers = [...peers]..[index] = peer.copyWith(hosts: hosts, port: address.port, device: device);
    await storage.savePeers(peers);
  }

  PairedPeer? _peer(String deviceId) => peers.where((p) => p.device.id == deviceId).firstOrNull;

  void _statusChanged() {
    if (peers.isNotEmpty) unawaited(native.updateKeepAlive(statusText));
    notifyListeners();
  }

  /// Wait (briefly) for at least one connection, e.g. right after launch
  /// from the share sheet.
  Future<bool> _waitForConnection(Duration timeout) async {
    if (_sessions.isNotEmpty) return true;
    for (final loop in _loops.values) {
      loop.wake();
    }
    final deadline = DateTime.now().add(timeout);
    while (_sessions.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return _sessions.isNotEmpty;
  }

  // MARK: - Receiving

  Future<void> _receive(PairedPeer peer, ClipMessage clip) async {
    String? imagePath;
    switch (clip.kind) {
      case ClipKinds.image:
        await native.setClipboardImage(clip.body);
        imagePath = await storage.saveImage(clip.id, clip.body);
      default:
        final text = clip.text ?? '';
        await _markClipboardSynced(text);
        await Clipboard.setData(ClipboardData(text: text));
    }
    await _addHistory(HistoryItem(
      id: clip.id,
      kind: clip.kind,
      text: clip.text,
      imagePath: imagePath,
      deviceName: peer.device.name,
      incoming: true,
      at: DateTime.now(),
    ));
  }

  // MARK: - Sending

  /// Send text to every connected computer. Returns their names.
  Future<List<String>> sendText(String text) async {
    final clip = ClipMessage.text(text, origin: _identity!.device.id);
    final names = await _broadcast(clip);
    await _addHistory(HistoryItem(
      id: clip.id,
      kind: clip.kind,
      text: text,
      deviceName: names.join(', '),
      incoming: false,
      at: DateTime.now(),
    ));
    return names;
  }

  Future<List<String>> sendImage(Uint8List png) async {
    final clip = ClipMessage.png(png, origin: _identity!.device.id);
    final names = await _broadcast(clip);
    await _addHistory(HistoryItem(
      id: clip.id,
      kind: clip.kind,
      imagePath: await storage.saveImage(clip.id, png),
      deviceName: names.join(', '),
      incoming: false,
      at: DateTime.now(),
    ));
    return names;
  }

  /// Send whatever text is on the phone's clipboard.
  Future<String> sendClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) return 'The clipboard has no text to send';
    try {
      final names = await sendText(text);
      await _markClipboardSynced(text);
      return 'Sent to ${names.join(', ')}';
    } on StateError catch (error) {
      return error.message;
    }
  }

  Future<List<String>> _broadcast(ClipMessage clip) async {
    if (!await _waitForConnection(const Duration(seconds: 6))) {
      throw StateError(peers.isEmpty ? 'Pair with a computer first' : "Can't reach ${peers.first.device.name} right now");
    }
    final names = <String>[];
    for (final entry in _sessions.entries.toList()) {
      try {
        await entry.value.sendClip(clip);
        names.add(entry.value.peer.name);
      } on Object catch (error) {
        debugPrint('ClipStack: send to ${entry.value.peer.name} failed: $error');
      }
    }
    if (names.isEmpty) throw StateError('Sending failed; trying to reconnect');
    return names;
  }

  /// Android lets apps read the clipboard only while in front, so "send on
  /// open" is how a phone copy reaches the computer without extra taps.
  Future<void> _autoSendIfChanged() async {
    if (!autoSendOnOpen || peers.isEmpty) return;
    // The window must have focus before Android allows the read.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // Opened by a share or pairing link: that is the action, not "send on open".
    if (DateTime.now().difference(_intentAt) < const Duration(seconds: 3)) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || text == _clipboardSynced) return;
    try {
      final names = await sendText(text);
      await _markClipboardSynced(text);
      _messages.add('Sent your clipboard to ${names.join(', ')}');
    } on StateError {
      // not connected; the user can tap Send later
    }
  }

  Future<void> setAutoSendOnOpen(bool value) async {
    autoSendOnOpen = value;
    await storage.setAutoSendOnOpen(value);
    notifyListeners();
  }

  // MARK: - Share sheet and links

  Future<void> _handleIntent(Map<String, Object?> intent) async {
    try {
      switch (intent['kind']) {
        case 'pair':
          final peer = await pair(intent['link'] as String);
          _messages.add('Paired with ${peer.device.name}');
          return;
        case 'text':
          final names = await sendText(intent['text'] as String);
          _messages.add('Sent to ${names.join(', ')}');
        case 'image':
          final png = await native.pngFromUri(intent['uri'] as String, maxBytes: maxBodyLength);
          final names = await sendImage(png);
          _messages.add('Image sent to ${names.join(', ')}');
        default:
          return;
      }
      // A share is a quick action: return to the app the user came from.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await native.moveToBack();
    } on FormatException catch (error) {
      _messages.add(error.message);
    } on StateError catch (error) {
      _messages.add(error.message);
    } on Object catch (error) {
      _messages.add('$error');
    }
  }

  // MARK: - History

  /// Copy a history item back onto the phone's clipboard.
  Future<void> copyToClipboard(HistoryItem item) async {
    if (item.imagePath != null) {
      await native.setClipboardImage(await File(item.imagePath!).readAsBytes());
    } else {
      await _markClipboardSynced(item.text ?? '');
      await Clipboard.setData(ClipboardData(text: item.text ?? ''));
    }
  }

  /// Forget every clip on this phone (computers keep their own history).
  Future<void> clearHistory() async {
    for (final item in history) {
      if (item.imagePath != null) await storage.deleteImage(item.imagePath!);
    }
    history = [];
    notifyListeners();
    await storage.saveHistory(history);
    notifyListeners();
  }

  Future<void> deleteHistoryItem(HistoryItem item) async {
    history = history.where((h) => h.id != item.id).toList();
    if (item.imagePath != null) await storage.deleteImage(item.imagePath!);
    notifyListeners();
    await storage.saveHistory(history);
    notifyListeners();
  }

  /// Updates the list synchronously before any await, so clips added close
  /// together can't overwrite each other's update.
  Future<void> _addHistory(HistoryItem item) async {
    final all = [item, ...history.where((h) => h.id != item.id)];
    history = all.take(AppStorage.historyLimit).toList();
    final dropped = all.skip(AppStorage.historyLimit).toList();
    notifyListeners();
    await storage.saveHistory(history);
    for (final old in dropped) {
      if (old.imagePath != null) await storage.deleteImage(old.imagePath!);
    }
    notifyListeners();
  }

  Future<void> _markClipboardSynced(String text) async {
    _clipboardSynced = text;
    await storage.setLastSyncedText(text);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final loop in _loops.values) {
      loop.stop();
    }
    for (final session in _sessions.values) {
      session.close();
    }
    discovery.stop();
    _messages.close();
    super.dispose();
  }
}

/// Sleep that can be cut short (network found, app resumed).
class _PeerLoop {
  bool stopped = false;
  Completer<void>? _wake;

  Future<void> sleep(Duration duration) {
    final wake = _wake = Completer<void>();
    return Future.any([wake.future, Future<void>.delayed(duration)]);
  }

  void wake() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void stop() {
    stopped = true;
    wake();
  }
}
