import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:clipstack_sync/clipstack_sync.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pasteboard/pasteboard.dart';

import 'desktop_clipboard.dart';
import 'discovery.dart';
import 'native.dart';
import 'storage.dart';

enum LinkState { notPaired, searching, connected }

/// Everything the app does: pairing (with computers and other phones),
/// staying connected, sending (button, share sheet, on open) and applying
/// received clips.
class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  SyncController({NativeBridge? native, AppStorage? storage})
      : native = native ?? NativeBridge(),
        storage = storage ?? AppStorage();

  /// Windows / Linux: the clipboard can be read any time, so copies sync
  /// automatically both ways (like the Mac app), and the PC always accepts
  /// connections so phones can pair with it.
  static final bool isDesktop = Platform.isWindows || Platform.isLinux;

  static const appVersion = '0.4.0';

  final NativeBridge native;
  final AppStorage storage;
  final PeerDiscovery discovery = PeerDiscovery();

  DeviceIdentity? _identity;
  List<PairedPeer> peers = [];
  List<HistoryItem> history = [];
  bool autoSendOnOpen = true;

  /// The floating bubble (send clipboard / copy a recent clip from any app).
  bool bubbleEnabled = false;
  bool _bubblePermissionPending = false;

  /// Whether "ClipStack paste" is on in Accessibility (the bubble's Paste).
  bool pasteServiceEnabled = false;
  String _bubbleSignature = '';
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

  /// This phone's name as other devices see it.
  String get phoneName => _identity?.device.name ?? 'This phone';

  /// Try every paired computer now instead of waiting out the backoff.
  void retryNow() {
    for (final loop in _loops.values) {
      loop.wake();
    }
  }

  String get connectedNames => peers.where(isConnected).map((p) => p.device.name).join(', ');

  String get statusText => switch (state) {
        LinkState.notPaired => 'Not paired yet',
        LinkState.searching => 'Looking for ${peers.map((p) => p.device.name).join(', ')}…',
        LinkState.connected => 'Connected to $connectedNames',
      };

  // MARK: - Startup

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    final platform = Platform.isAndroid
        ? Platforms.android
        : Platform.isIOS
            ? Platforms.ios
            : Platform.isWindows
                ? Platforms.windows
                : Platforms.linux;
    _identity = await storage.loadIdentity(name: await native.deviceName(), platform: platform);
    peers = await storage.loadPeers();
    history = await _loadHistoryWithoutRepeats();
    autoSendOnOpen = await storage.autoSendOnOpen();
    bubbleEnabled = await storage.bubbleEnabled() && await native.canDrawOverlays();
    unawaited(native.setBubble(bubbleEnabled));
    pasteServiceEnabled = await native.isPasteServiceEnabled();
    _clipboardSynced = await storage.lastSyncedText();
    native.onIntent = (intent) {
      _intentAt = DateTime.now();
      _handleIntent(intent);
    };

    discovery.ownId = _identity!.device.id;
    discovery.found.listen((id) => _loops[id]?.wake());
    unawaited(discovery.start().catchError((Object e) => debugPrint('ClipStack: discovery unavailable: $e')));
    await _updateListening();
    for (final peer in peers) {
      _startLoop(peer.device.id);
    }
    if (peers.isNotEmpty) unawaited(native.startKeepAlive(statusText));
    if (isDesktop) unawaited(_startDesktopClipboardWatch());

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
    unawaited(_finishBubblePermission());
    unawaited(_refreshPasteService());
  }

  /// Re-checked on every return to the app: the user flips it in system settings.
  Future<void> _refreshPasteService() async {
    final enabled = await native.isPasteServiceEnabled();
    if (enabled == pasteServiceEnabled) return;
    pasteServiceEnabled = enabled;
    notifyListeners();
  }

  Future<void> openPasteServiceSettings() => native.openAccessibilitySettings();

  // MARK: - Floating bubble

  /// Turning it on first needs "Display over other apps"; Android shows that
  /// as a settings page, and the bubble appears when the user comes back.
  Future<void> setBubbleEnabled(bool value) async {
    if (value && !await native.canDrawOverlays()) {
      _bubblePermissionPending = true;
      await native.requestOverlayPermission();
      return;
    }
    bubbleEnabled = value;
    await storage.setBubbleEnabled(value);
    await native.setBubble(value);
    notifyListeners();
  }

  Future<void> _finishBubblePermission() async {
    if (!_bubblePermissionPending) return;
    _bubblePermissionPending = false;
    if (await native.canDrawOverlays()) {
      await setBubbleEnabled(true);
      _messages.add('Bubble on. Drag it anywhere; tap it to send or copy.');
    } else {
      _messages.add('The bubble needs "Display over other apps" to be allowed.');
    }
  }

  /// Every state change also refreshes the bubble's panel (status + the five
  /// newest clips), skipped when nothing it shows has changed.
  @override
  void notifyListeners() {
    super.notifyListeners();
    final recent = history.take(5).toList();
    final signature = '$statusText|${recent.map((h) => h.id).join(',')}';
    if (signature == _bubbleSignature) return;
    _bubbleSignature = signature;
    unawaited(native.updateBubble(statusText, [
      for (final item in recent)
        {'id': item.id, 'kind': item.kind, 'text': item.text, 'imagePath': item.imagePath},
    ]));
  }

  // MARK: - Pairing

  /// Pair using a `clipstack://pair?...` link (QR code, camera app, or pasted)
  /// from a computer or from another phone's "Show my pairing code".
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
          listenPort: listenPort,
        );
        final peer = PairedPeer(
          device: session.peer,
          publicKey: link.publicKey,
          hosts: [target.host, ...link.hosts.where((h) => h != target.host)],
          port: target.port,
        );
        await _addPeer(peer, session);
        return peer;
      } on ProtocolException catch (error) {
        // The other device answered and refused: no point trying other addresses.
        throw error.code == 'bad_token'
            ? const FormatException('That pairing code has expired. Show a new code on the other device.')
            : FormatException('Pairing failed: ${error.message}');
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw FormatException("Couldn't reach ${link.device.name}. Is it on the same Wi-Fi? ($lastError)");
  }

  /// Store a new pairing (replacing an old one with the same device), adopt
  /// the session that paired, then start the reconnect loop. Adopting first
  /// matters: a loop that saw no session would dial a second connection.
  Future<void> _addPeer(PairedPeer peer, SyncSession session) async {
    await _forget(peer.device.id, notifyPeer: false);
    peers = [...peers, peer];
    await storage.savePeers(peers);
    _adopt(peer.device.id, session);
    _startLoop(peer.device.id);
    await _updateListening();
    unawaited(native.requestNotificationPermission());
    unawaited(native.startKeepAlive(statusText));
    notifyListeners();
  }

  /// Remove a pairing on both sides (the other device is told if it's online).
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
    if (peers.length != before) {
      await storage.savePeers(peers);
      await _updateListening();
    }
    if (peers.isEmpty) unawaited(native.stopKeepAlive());
    notifyListeners();
  }

  // MARK: - Pairing code (another phone scans this one)

  static const pairingCodeLifetime = Duration(minutes: 5);
  Uint8List? _codeToken;
  DateTime _codeExpires = DateTime(0);
  final _pairedByCode = StreamController<PairedPeer>.broadcast();

  /// Fires when another device pairs using this phone's code.
  Stream<PairedPeer> get pairedByCode => _pairedByCode.stream;
  DateTime get pairingCodeExpires => _codeExpires;

  /// Opens a pairing window and returns the one-time link to show as a QR
  /// code. The token is single-use and expires after [pairingCodeLifetime].
  Future<PairingLink> openPairingCode() async {
    final rng = Random.secure();
    _codeToken = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
    _codeExpires = DateTime.now().add(pairingCodeLifetime);
    await _updateListening();
    final port = listenPort;
    if (port == null) throw StateError("ClipStack can't accept connections right now");
    final hosts = await _localAddresses();
    if (hosts.isEmpty) throw StateError('Connect to Wi-Fi to show a pairing code');
    return PairingLink(
      device: _identity!.device,
      publicKey: _identity!.publicKey,
      token: _codeToken!,
      port: port,
      hosts: hosts,
    );
  }

  Future<void> closePairingCode() async {
    _codeToken = null;
    await _updateListening();
  }

  bool get _pairingOpen => _codeToken != null && DateTime.now().isBefore(_codeExpires);

  bool _consumePairingToken(Uint8List token) {
    final expected = _codeToken;
    if (expected == null || !_pairingOpen || token.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < token.length; i++) {
      diff |= token[i] ^ expected[i];
    }
    if (diff != 0) return false;
    _codeToken = null; // single use
    return true;
  }

  /// This device's IPv4 addresses, Wi-Fi and Ethernet first. Skipped:
  /// cellular, VPN tunnels and virtual adapters (Hyper-V, WSL, VirtualBox,
  /// VMware), which another device on the same Wi-Fi can't reach.
  static Future<List<String>> _localAddresses() async {
    const skip = ['rmnet', 'ccmni', 'tun', 'vethernet', 'virtualbox', 'vmware', 'bluetooth', 'loopback'];
    const lan = ['wlan', 'en', 'wi-fi', 'wifi', 'ethernet', 'wireless'];
    final wifi = <String>[], other = <String>[];
    for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      final name = interface.name.toLowerCase();
      if (skip.any((prefix) => name.startsWith(prefix) || name.contains(' $prefix'))) continue;
      for (final address in interface.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        (lan.any(name.startsWith) ? wifi : other).add(address.address);
      }
    }
    return [...wifi, ...other];
  }

  // MARK: - Listening (phones that pair with each other)

  ServerSocket? _server;
  BonsoirBroadcast? _advert;

  /// The port other phones dial; null while not listening.
  int? get listenPort => _server?.port;

  bool isComputer(PairedPeer peer) =>
      const {Platforms.macos, Platforms.windows, Platforms.linux}.contains(peer.device.platform);

  /// Listen and advertise only while it's useful: a phone is paired, or this
  /// phone is showing its pairing code. Paired only with computers, the
  /// phone stays invisible on the network.
  Future<void> _updateListening() async {
    final needed = isDesktop || _pairingOpen || peers.any((p) => !isComputer(p));
    if (needed && _server == null) {
      await _startListening();
    } else if (!needed && _server != null) {
      await _stopListening();
    }
  }

  Future<void> _startListening() async {
    try {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, defaultPort);
      } on SocketException {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0); // 47474 taken
      }
    } on SocketException catch (error) {
      debugPrint('ClipStack: cannot listen: $error');
      return;
    }
    _server!.listen(_accept, onError: (Object e) => debugPrint('ClipStack: listener error: $e'));
    debugPrint('ClipStack: listening on ${_server!.port}');
    final me = _identity!.device;
    final advert = BonsoirBroadcast(
      service: BonsoirService(
        name: me.name,
        type: serviceType,
        port: _server!.port,
        attributes: {'v': '1', 'id': me.id, 'name': me.name, 'pf': me.platform},
      ),
    );
    _advert = advert;
    try {
      await advert.initialize();
      await advert.start();
    } on Object catch (error) {
      debugPrint('ClipStack: advertising failed: $error'); // still reachable by address
    }
  }

  Future<void> _stopListening() async {
    await _advert?.stop().catchError((_) {});
    _advert = null;
    await _server?.close();
    _server = null;
    debugPrint('ClipStack: stopped listening');
  }

  Future<void> _accept(Socket socket) async {
    try {
      final session = await SyncSession.accept(
        socket,
        identity: _identity!,
        policy: _PhonePolicy(this),
        appVersion: appVersion,
        listenPort: listenPort,
      );
      if (session.pairedNow) {
        final peer = PairedPeer(
          device: session.peer,
          publicKey: session.peerStaticKey,
          hosts: [session.remoteAddress],
          port: session.peerListenPort ?? defaultPort,
        );
        await _addPeer(peer, session);
        _pairedByCode.add(peer);
        return;
      }
      if (session.peerListenPort != null) {
        await _rememberAddress(
            session.peer.id, (host: session.remoteAddress, port: session.peerListenPort!), session.peer);
      }
      _adopt(session.peer.id, session);
    } on Object catch (error) {
      debugPrint('ClipStack: incoming connection refused: $error');
    }
  }

  // MARK: - Connections

  void _startLoop(String deviceId) {
    _loops.remove(deviceId)?.stop();
    final loop = _PeerLoop();
    _loops[deviceId] = loop;
    unawaited(_run(deviceId, loop));
  }

  /// Keeps this phone connected to one paired device. Either side may dial —
  /// whoever can reach the other does (a phone behind a router can still dial
  /// out) — and while a session exists, dialled or accepted, the loop waits.
  /// Discovery and app resume cut the backoff short.
  Future<void> _run(String deviceId, _PeerLoop loop) async {
    var backoff = 1;
    while (!loop.stopped) {
      final current = _sessions[deviceId];
      if (current != null && current.isOpen) {
        await Future.any([current.done, loop.stopped$]);
        backoff = 1;
        if (!loop.stopped) await loop.sleep(const Duration(seconds: 1));
        continue;
      }
      final session = await _connect(deviceId);
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
      _adopt(deviceId, session);
    }
  }

  /// Make [session] the live connection to [deviceId]. If both sides dialled
  /// at once, keep the session dialled by the lower device id — both ends
  /// apply the same rule, so they agree on which one survives.
  void _adopt(String deviceId, SyncSession session) {
    final peer = _peer(deviceId);
    if (peer == null) {
      session.close();
      return;
    }
    final existing = _sessions[deviceId];
    if (existing != null && existing.isOpen && existing != session) {
      String dialer(SyncSession s) => s.isInitiator ? _identity!.device.id : deviceId;
      final keepNew = dialer(existing) == dialer(session) || dialer(session).compareTo(dialer(existing)) < 0;
      if (!keepNew) {
        session.close();
        return;
      }
      existing.close();
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
    session.done.then((_) async {
      await subscription.cancel();
      debugPrint('ClipStack: session with ${peer.device.name} ended: ${session.closeReason}');
      if (_sessions[deviceId] == session) {
        _sessions.remove(deviceId);
        _statusChanged();
      }
      if (session.peerUnpaired && _peer(deviceId) != null) {
        _messages.add('${peer.device.name} removed this phone');
        await _forget(deviceId, notifyPeer: false);
      }
    });
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
      // A loopback address on our own port is this phone's listener (seen
      // when the peer reached us through a local tunnel), not the peer.
      if (target.port == listenPort && (InternetAddress.tryParse(target.host)?.isLoopback ?? false)) continue;
      try {
        final session = await SyncSession.connect(
          host: target.host,
          port: target.port,
          identity: _identity!,
          peerStaticKey: peer.publicKey,
          expectedPeerId: deviceId,
          appVersion: appVersion,
          listenPort: listenPort,
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

  /// Put the address that worked first, and pick up a renamed device.
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
    debugPrint('ClipStack: received ${clip.kind} from ${peer.device.name}'); // never the content
    String? imagePath;
    switch (clip.kind) {
      case ClipKinds.image:
        await _writeClipboardImage(clip.body);
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
      fingerprint: imagePath == null ? null : DesktopClipboard.fingerprint(clip.body),
      deviceName: peer.device.name,
      devicePlatform: peer.device.platform,
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
      fingerprint: DesktopClipboard.fingerprint(png),
      deviceName: names.join(', '),
      incoming: false,
      at: DateTime.now(),
    ));
    return names;
  }

  /// Send whatever is on the clipboard: an image, or text.
  Future<String> sendClipboard() async {
    // Flutter reads only text; on Android the native side sees images too.
    final clipboard = Platform.isAndroid ? await native.readClipboard() : null;
    final imageUri = clipboard?['uri'] as String?;
    if (imageUri != null) {
      try {
        final png = await native.pngFromUri(imageUri, maxBytes: maxBodyLength);
        final names = await sendImage(png);
        return 'Image sent to ${names.join(', ')}';
      } on StateError catch (error) {
        return error.message;
      } on PlatformException {
        return "Couldn't read the copied image";
      }
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) {
      // A PC can read an image off the clipboard too.
      final raw = isDesktop ? await DesktopClipboard.image() : null;
      final image = raw == null ? null : await DesktopClipboard.toPng(raw, maxBytes: maxBodyLength);
      if (image == null) return 'The clipboard is empty';
      try {
        final names = await sendImage(image);
        return 'Image sent to ${names.join(', ')}';
      } on StateError catch (error) {
        return error.message;
      }
    }
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
      throw StateError(peers.isEmpty ? 'Pair a device first' : "Can't reach ${peers.first.device.name} right now");
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
    if (!Platform.isAndroid || !autoSendOnOpen || peers.isEmpty) return;
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

  Future<void> _sendFromClipboard(Map<String, Object?> event) async {
    try {
      final text = event['text'] as String?;
      final List<String> names;
      if (text != null) {
        names = await sendText(text);
        await _markClipboardSynced(text);
      } else {
        final png = await native.pngFromUri(event['uri'] as String, maxBytes: maxBodyLength);
        names = await sendImage(png);
      }
      await native.showToast('Sent to ${names.map(_shortName).join(', ')}');
    } on StateError catch (error) {
      await native.showToast(error.message);
    } on Object catch (error) {
      await native.showToast("Couldn't send: $error");
    }
  }

  /// "Zaman’s MacBook Air" → "MacBook Air", for short toasts.
  static String _shortName(String name) {
    for (final separator in const ['’s ', "'s "]) {
      final i = name.indexOf(separator);
      if (i > 0 && i + separator.length < name.length) return name.substring(i + separator.length);
    }
    return name;
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
        case 'clipboard':
          // Read by the bubble, the Quick Settings tile or the notification.
          // No screen is open, so the result shows as a toast.
          await _sendFromClipboard(intent);
          return;
        case 'copied':
          // Copied from the bubble's recent list: don't send it back on open.
          await _markClipboardSynced(intent['text'] as String);
          return;
        case 'bubbleHidden':
          bubbleEnabled = false;
          await storage.setBubbleEnabled(false);
          notifyListeners();
          return;
        case 'pair':
          final peer = await pair(intent['link'] as String);
          _messages.add('Paired with ${peer.device.name}');
          return;
        case 'text':
          final names = await sendText(intent['text'] as String);
          _messages.add('Sent to ${names.join(', ')}');
        case 'textFile':
          final names = await sendText(await native.textFromUri(intent['uri'] as String));
          _messages.add('Sent to ${names.join(', ')}');
        case 'image':
          final png = await native.pngFromUri(intent['uri'] as String, maxBytes: maxBodyLength);
          final names = await sendImage(png);
          _messages.add('Image sent to ${names.join(', ')}');
        case 'images':
          _messages.add(await _sendSharedImages((intent['uris'] as List).cast<String>()));
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
    } on PlatformException catch (error) {
      _messages.add(error.code == 'image' ? "Couldn't read the picture" : error.message ?? "Couldn't send it");
    } on Object catch (error) {
      _messages.add('$error');
    }
  }

  /// Several photos shared from the gallery, sent one by one in order (the
  /// last one ends up on the other devices' clipboard). A photo that can't be
  /// read is skipped; losing the connection stops the rest.
  Future<String> _sendSharedImages(List<String> uris) async {
    var sent = 0;
    var names = <String>[];
    for (final uri in uris) {
      final Uint8List png;
      try {
        png = await native.pngFromUri(uri, maxBytes: maxBodyLength);
      } on PlatformException {
        continue;
      }
      names = await sendImage(png);
      sent++;
    }
    final to = names.join(', ');
    if (sent == 0) return "Couldn't read the pictures";
    if (sent == uris.length) return sent == 1 ? 'Image sent to $to' : '$sent images sent to $to';
    return '$sent of ${uris.length} images sent to $to';
  }

  // MARK: - Desktop clipboard (Windows / Linux)

  Timer? _desktopWatch;
  bool _desktopChecking = false;
  int? _desktopSequence;
  String? _desktopText;
  String? _desktopImage; // fingerprint of the raw image on the clipboard
  DateTime _nextImageCheck = DateTime(0);

  /// Polls the clipboard like the Mac app does (Flutter exposes no change
  /// event). What's on it at start-up is the baseline, not a new copy. On
  /// Windows nothing is read until the clipboard's sequence number moves;
  /// elsewhere text is read every 0.8 s and images every 3 s.
  Future<void> _startDesktopClipboardWatch() async {
    _desktopSequence = DesktopClipboard.sequenceNumber();
    _desktopText = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    _desktopImage = DesktopClipboard.fingerprint(await DesktopClipboard.image());
    _desktopWatch = Timer.periodic(const Duration(milliseconds: 800), (_) => _checkDesktopClipboard());
  }

  Future<void> _checkDesktopClipboard() async {
    if (_desktopChecking) return;
    final sequence = DesktopClipboard.sequenceNumber();
    if (sequence != null && sequence == _desktopSequence) return;
    _desktopSequence = sequence;
    _desktopChecking = true;
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (text != null && text.isNotEmpty) {
        if (text == _desktopText) return;
        _desktopText = text;
        _desktopImage = null;
        // Our own write of a received clip is not a new copy.
        if (text == _clipboardSynced || _sessions.isEmpty) return;
        await _markClipboardSynced(text);
        await sendText(text);
        return;
      }
      if (sequence == null) {
        if (DateTime.now().isBefore(_nextImageCheck)) return;
        _nextImageCheck = DateTime.now().add(const Duration(seconds: 3));
      }
      final image = await DesktopClipboard.image();
      final fingerprint = DesktopClipboard.fingerprint(image);
      if (image == null || fingerprint == _desktopImage) return;
      _desktopImage = fingerprint;
      _desktopText = null;
      if (_sessions.isEmpty) return;
      final png = await DesktopClipboard.toPng(image, maxBytes: maxBodyLength);
      if (png != null) await sendImage(png);
    } on Object catch (error) {
      debugPrint('ClipStack: clipboard check failed: $error');
    } finally {
      _desktopChecking = false;
    }
  }

  /// Puts an image on the clipboard: Android through the native bridge
  /// (FileProvider), PCs through pasteboard. On a PC the next watcher read
  /// becomes the baseline, so a received image isn't sent back.
  Future<void> _writeClipboardImage(Uint8List png) async {
    if (isDesktop) {
      await Pasteboard.writeImage(png);
      _desktopImage = DesktopClipboard.fingerprint(await DesktopClipboard.image());
      _desktopText = null;
      _desktopSequence = DesktopClipboard.sequenceNumber();
    } else {
      await native.setClipboardImage(png);
    }
  }

  // MARK: - History

  /// Copy a history item back onto the phone's clipboard.
  Future<void> copyToClipboard(HistoryItem item) async {
    if (item.imagePath != null) {
      await _writeClipboardImage(await File(item.imagePath!).readAsBytes());
    } else {
      await _markClipboardSynced(item.text ?? '');
      await Clipboard.setData(ClipboardData(text: item.text ?? ''));
    }
  }

  /// Put a history picture in the phone's gallery; says what to tell the user.
  Future<({bool saved, String message})> saveToGallery(HistoryItem item) async {
    try {
      await native.saveToGallery(item.imagePath!);
      return (saved: true, message: 'Saved to Gallery');
    } on PlatformException catch (error) {
      return (saved: false, message: error.message ?? "Couldn't save the picture");
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
  /// together can't overwrite each other's update. A repeat of a clip
  /// already in the list moves it to the top instead of adding a copy.
  Future<void> _addHistory(HistoryItem item) async {
    final (:kept, :dropped) = HistoryItem.add(history, item);
    history = kept;
    notifyListeners();
    await storage.saveHistory(history);
    for (final old in dropped) {
      if (old.imagePath != null && old.imagePath != item.imagePath) await storage.deleteImage(old.imagePath!);
    }
    notifyListeners();
  }

  /// History saved before repeats were merged may hold the same clip many
  /// times; keep only the newest of each.
  Future<List<HistoryItem>> _loadHistoryWithoutRepeats() async {
    final saved = await storage.loadHistory();
    var kept = <HistoryItem>[];
    final dropped = <HistoryItem>[];
    for (final item in saved.reversed) {
      final result = HistoryItem.add(kept, item);
      kept = result.kept;
      dropped.addAll(result.dropped);
    }
    if (dropped.isNotEmpty) {
      await storage.saveHistory(kept);
      for (final old in dropped) {
        if (old.imagePath != null && !kept.any((h) => h.imagePath == old.imagePath)) {
          await storage.deleteImage(old.imagePath!);
        }
      }
    }
    return kept;
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
    _stopListening();
    _desktopWatch?.cancel();
    _messages.close();
    _pairedByCode.close();
    super.dispose();
  }
}

/// Sleep that can be cut short (network found, app resumed).
class _PeerLoop {
  bool stopped = false;
  Completer<void>? _wake;
  final _stopped = Completer<void>();

  /// Completes when the loop is stopped (the pairing was removed).
  Future<void> get stopped$ => _stopped.future;

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
    if (!_stopped.isCompleted) _stopped.complete();
    wake();
  }
}

/// Whom this phone lets in when another phone dials it.
class _PhonePolicy implements ResponderPolicy {
  _PhonePolicy(this._controller);
  final SyncController _controller;

  @override
  Uint8List? pairedKey(String deviceId) => _controller._peer(deviceId)?.publicKey;

  @override
  bool get pairingOpen => _controller._pairingOpen;

  @override
  bool consumePairingToken(Uint8List token) => _controller._consumePairingToken(token);

  @override
  void onPaired(DeviceInfo device, Uint8List staticKey) {
    // Stored once accept() returns, together with the peer's address.
  }
}
