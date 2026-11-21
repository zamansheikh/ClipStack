// One encrypted connection to a peer: handshake (either role), first
// messages, then clips both ways with keep-alive.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:cryptography/cryptography.dart';

import 'crypto.dart';
import 'protocol.dart';

/// How a listening device decides whom to let in.
abstract class ResponderPolicy {
  /// The static key stored for a paired device, or null if not paired.
  FutureOr<Uint8List?> pairedKey(String deviceId);

  /// True while this device's "Pair a device" window is open.
  bool get pairingOpen;

  /// Check and use up a pairing token. Returns false for a wrong or expired one.
  bool consumePairingToken(Uint8List token);

  /// Store a new pairing.
  FutureOr<void> onPaired(DeviceInfo device, Uint8List staticKey);
}

class SyncSession {
  SyncSession._({
    required Socket socket,
    required StreamQueue<Uint8List> frames,
    required FrameCipher sendCipher,
    required FrameCipher receiveCipher,
    required this.peer,
    required this.peerStaticKey,
    required this.isInitiator,
    required this.pairedNow,
    required this.peerListenPort,
  })  : _socket = socket,
        _frames = frames,
        _sendCipher = sendCipher,
        _receiveCipher = receiveCipher;

  final Socket _socket;
  final StreamQueue<Uint8List> _frames;
  final FrameCipher _sendCipher;
  final FrameCipher _receiveCipher;

  /// The device on the other end, as it described itself.
  final DeviceInfo peer;
  final Uint8List peerStaticKey;
  final bool isInitiator;

  /// True when this session created the pairing.
  final bool pairedNow;

  /// The port the peer listens on, if it said (phones that accept
  /// connections); null for peers that only dial out or don't say.
  final int? peerListenPort;

  /// The peer's IP address as seen on this connection.
  String get remoteAddress => _socket.remoteAddress.address;

  final _clips = StreamController<ClipMessage>.broadcast();
  final _done = Completer<void>();
  final _seenClipIds = <String>[];
  StreamSubscription<Uint8List>? _subscription;
  Timer? _keepAlive;
  DateTime _lastReceived = DateTime.now();
  bool _pingOutstanding = false;
  Future<void> _sendChain = Future.value();

  /// Clips the peer sent, already de-duplicated.
  Stream<ClipMessage> get clips => _clips.stream;

  /// Completes when the session ends, for any reason.
  Future<void> get done => _done.future;
  bool get isOpen => !_done.isCompleted;

  /// Why the session ended (null for a clean close).
  Object? closeReason;

  /// The peer removed this pairing (`unpair`); forget it.
  bool peerUnpaired = false;

  // MARK: - Initiator

  /// Connect to a listening peer whose static key is known. Pass
  /// [pairingToken] (from its pairing link) to pair; otherwise the two
  /// devices must already be paired. [expectedPeerId] guards against a
  /// different device answering on that address.
  static Future<SyncSession> connect({
    required String host,
    required int port,
    required DeviceIdentity identity,
    required Uint8List peerStaticKey,
    String? expectedPeerId,
    Uint8List? pairingToken,
    String appVersion = '0.1.0',
    int? listenPort,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.done.catchError((_) => null); // errors surface through the read side
    final frames = StreamQueue(socket.transform(const FrameDecoder()));
    try {
      return await _initiate(socket, frames, identity, peerStaticKey, expectedPeerId, pairingToken, appVersion, listenPort)
          .timeout(timeout, onTimeout: () => throw ProtocolException('handshake timed out'));
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  static Future<SyncSession> _initiate(
    Socket socket,
    StreamQueue<Uint8List> frames,
    DeviceIdentity identity,
    Uint8List peerStaticKey,
    String? expectedPeerId,
    Uint8List? pairingToken,
    String appVersion,
    int? listenPort,
  ) async {
    final ephemeral = await newEphemeralKeyPair();
    final frame1 = buildFrame1(
      ephemeralPublic: await publicKeyOf(ephemeral),
      staticPublic: identity.publicKey,
      deviceId: identity.device.id,
    );
    socket.add(encodeFrame(frame1));
    final frame2 = await _nextFrame(frames);
    final keys = await deriveInitiatorKeys(
      ephemeral: ephemeral,
      static: identity.keyPair,
      responderStatic: peerStaticKey,
      responderEphemeral: parseFrame2(frame2),
      frame1: frame1,
      frame2: frame2,
    );
    final send = FrameCipher(keys.send);
    final receive = FrameCipher(keys.receive);

    final first = pairingToken == null
        ? Message.hello(identity.device, appVersion, port: listenPort)
        : Message.pair(identity.device, pairingToken, port: listenPort);
    socket.add(encodeFrame(await send.seal(first.encode())));

    final reply = Message.decode(await receive.open(await _nextFrame(frames)));
    if (reply.type == 'error') {
      throw ProtocolException('${reply.header['message'] ?? 'peer refused'}', code: '${reply.header['code']}');
    }
    final expectedType = pairingToken == null ? 'hello' : 'paired';
    if (reply.type != expectedType) throw ProtocolException('expected $expectedType, got ${reply.type}');
    final peer = DeviceInfo.fromJson(reply.header['device']);
    if (expectedPeerId != null && peer.id != expectedPeerId) {
      throw ProtocolException('a different device answered (${peer.id})');
    }

    return SyncSession._(
      socket: socket,
      frames: frames,
      sendCipher: send,
      receiveCipher: receive,
      peer: peer,
      peerStaticKey: peerStaticKey,
      isInitiator: true,
      pairedNow: pairingToken != null,
      peerListenPort: reply.listenPort,
    ).._start();
  }

  // MARK: - Responder

  /// Run the responder side on an accepted socket.
  static Future<SyncSession> accept(
    Socket socket, {
    required DeviceIdentity identity,
    required ResponderPolicy policy,
    String appVersion = '0.1.0',
    int? listenPort,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.done.catchError((_) => null);
    final frames = StreamQueue(socket.transform(const FrameDecoder()));
    try {
      return await _respond(socket, frames, identity, policy, appVersion, listenPort)
          .timeout(timeout, onTimeout: () => throw ProtocolException('handshake timed out'));
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  static Future<SyncSession> _respond(
    Socket socket,
    StreamQueue<Uint8List> frames,
    DeviceIdentity identity,
    ResponderPolicy policy,
    String appVersion,
    int? listenPort,
  ) async {
    final frame1 = await _nextFrame(frames);
    final hello = parseFrame1(frame1);
    final storedKey = await policy.pairedKey(hello.deviceId);
    final isPaired = storedKey != null && _sameBytes(storedKey, hello.staticPublic);
    // Spec step 2: strangers are dropped before any key work, unless pairing.
    if (!isPaired && !policy.pairingOpen) throw ProtocolException('unknown device ${hello.deviceId}', code: 'not_paired');

    final ephemeral = await newEphemeralKeyPair();
    final frame2 = buildFrame2(await publicKeyOf(ephemeral));
    socket.add(encodeFrame(frame2));
    final keys = await deriveResponderKeys(
      ephemeral: ephemeral,
      static: identity.keyPair,
      initiatorStatic: hello.staticPublic,
      initiatorEphemeral: hello.ephemeralPublic,
      frame1: frame1,
      frame2: frame2,
    );
    final send = FrameCipher(keys.send);
    final receive = FrameCipher(keys.receive);

    Future<Never> refuse(String code, String message) async {
      socket.add(encodeFrame(await send.seal(Message.error(code, message).encode())));
      await socket.flush();
      throw ProtocolException(message, code: code);
    }

    final first = Message.decode(await receive.open(await _nextFrame(frames)));
    final device = DeviceInfo.fromJson(first.header['device']);
    if (device.id != hello.deviceId) await refuse('unsupported', 'device id does not match handshake');

    final bool pairedNow;
    if (first.type == 'pair') {
      final token = first.header['token'];
      final tokenBytes = token is String ? _tryDecode(token) : null;
      if (tokenBytes == null || !policy.consumePairingToken(tokenBytes)) {
        await refuse('bad_token', 'pairing code expired or already used');
      }
      await policy.onPaired(device, hello.staticPublic);
      socket.add(encodeFrame(await send.seal(Message.paired(identity.device, port: listenPort).encode())));
      pairedNow = true;
    } else if (first.type == 'hello' && isPaired) {
      socket.add(encodeFrame(await send.seal(Message.hello(identity.device, appVersion, port: listenPort).encode())));
      pairedNow = false;
    } else {
      await refuse('not_paired', 'this device is not paired');
    }

    return SyncSession._(
      socket: socket,
      frames: frames,
      sendCipher: send,
      receiveCipher: receive,
      peer: device,
      peerStaticKey: hello.staticPublic,
      isInitiator: false,
      pairedNow: pairedNow,
      peerListenPort: first.listenPort,
    ).._start();
  }

  // MARK: - Running session

  void _start() {
    _lastReceived = DateTime.now();
    // asyncMap keeps frames in order, which the nonce counter requires.
    _subscription = _frames.rest.asyncMap(_receiveCipher.open).listen(
          _onPlaintext,
          onError: (Object error) => _finish(error),
          onDone: () => _finish(null),
          cancelOnError: true,
        );
    _keepAlive = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  void _onPlaintext(Uint8List plaintext) {
    _lastReceived = DateTime.now();
    _pingOutstanding = false;
    final Message message;
    try {
      message = Message.decode(plaintext);
    } on ProtocolException catch (error) {
      _finish(error);
      return;
    }
    switch (message.type) {
      case 'clip':
        final ClipMessage clip;
        try {
          clip = ClipMessage.fromMessage(message);
        } on ProtocolException {
          return; // a malformed clip is dropped, not fatal
        }
        if (_seenClipIds.contains(clip.id)) return;
        _seenClipIds.add(clip.id);
        if (_seenClipIds.length > 200) _seenClipIds.removeAt(0);
        _clips.add(clip);
      case 'ping':
        _send(Message.pong());
      case 'unpair':
        peerUnpaired = true;
        _finish(null);
      case 'error':
        _finish(ProtocolException('${message.header['message']}', code: '${message.header['code']}'));
      default:
        break; // pong and unknown types
    }
  }

  void _tick() {
    final idle = DateTime.now().difference(_lastReceived);
    if (idle > idleTimeout) {
      _finish(ProtocolException('peer stopped responding'));
    } else if (idle > pingAfter && !_pingOutstanding) {
      _pingOutstanding = true;
      _send(Message.ping());
    }
  }

  /// Send a clip. Bodies over [maxBodyLength] are refused.
  Future<void> sendClip(ClipMessage clip) {
    if (clip.body.length > maxBodyLength) {
      return Future.error(ArgumentError('clip body exceeds ${maxBodyLength ~/ (1024 * 1024)} MiB'));
    }
    return _send(clip.toMessage());
  }

  /// Tell the peer this pairing was removed, then close.
  Future<void> sendUnpair() async {
    try {
      await _send(Message.unpair());
    } finally {
      await close();
    }
  }

  /// Close after pending sends go out (up to 2 s).
  Future<void> close() async {
    await _sendChain.timeout(const Duration(seconds: 2), onTimeout: () {});
    _finish(null);
  }

  /// Frames are sealed and written strictly one at a time, in nonce order.
  Future<void> _send(Message message) {
    if (!isOpen) return Future.error(StateError('session is closed'));
    final sent = _sendChain.then((_) async {
      if (!isOpen) throw StateError('session is closed');
      _socket.add(encodeFrame(await _sendCipher.seal(message.encode())));
      await _socket.flush();
    });
    _sendChain = sent.catchError((Object error) => _finish(error));
    return sent;
  }

  void _finish(Object? reason) {
    if (_done.isCompleted) return;
    closeReason = reason;
    _keepAlive?.cancel();
    _subscription?.cancel();
    _socket.destroy();
    _clips.close();
    _done.complete();
  }
}

Future<Uint8List> _nextFrame(StreamQueue<Uint8List> frames) async {
  if (!await frames.hasNext) throw ProtocolException('connection closed during handshake');
  return frames.next;
}

Uint8List? _tryDecode(String text) {
  try {
    return b64urlDecode(text);
  } on FormatException {
    return null;
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Re-exported so apps can hold keys without importing cryptography.
typedef SyncSecretKey = SecretKey;
