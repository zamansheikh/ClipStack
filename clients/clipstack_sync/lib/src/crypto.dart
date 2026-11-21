// Identity keys, the v1 handshake key schedule and per-direction frame
// encryption (docs/05-lan-sync.md, "Handshake" and "Encrypted frames").

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'protocol.dart';

final X25519 _x25519 = X25519();
final Chacha20 _aead = Chacha20.poly1305Aead();
final List<int> _handshakeLabel = ascii.encode('ClipStack v1 handshake');
final List<int> _sessionKeysInfo = ascii.encode('ClipStack v1 session keys');

/// This device's long-term identity: device info + static X25519 key pair.
/// Apps persist [privateKeyBytes] in secure storage and restore with
/// [DeviceIdentity.restore].
class DeviceIdentity {
  DeviceIdentity._(this.device, this._keyPair, this._privateKey, this.publicKey);

  final DeviceInfo device;
  final SimpleKeyPair _keyPair;
  final Uint8List _privateKey;
  final Uint8List publicKey;

  SimpleKeyPair get keyPair => _keyPair;

  /// 32-byte private key, for the app's secure storage only.
  Uint8List get privateKeyBytes => Uint8List.fromList(_privateKey);

  static Future<DeviceIdentity> generate({required String name, required String platform}) async {
    final keyPair = await _x25519.newKeyPair();
    final privateKey = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    return _from(DeviceInfo(id: newDeviceId(), name: name, platform: platform), keyPair, privateKey);
  }

  static Future<DeviceIdentity> restore(DeviceInfo device, Uint8List privateKey) async {
    if (privateKey.length != keyLength) throw ArgumentError('private key must be 32 bytes');
    return _from(device, await _x25519.newKeyPairFromSeed(privateKey), privateKey);
  }

  /// Same keys, different display name (the user renamed the device).
  DeviceIdentity renamed(String name) =>
      DeviceIdentity._(DeviceInfo(id: device.id, name: name, platform: device.platform), _keyPair, _privateKey, publicKey);

  static Future<DeviceIdentity> _from(DeviceInfo device, SimpleKeyPair keyPair, Uint8List privateKey) async {
    final publicKey = Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
    return DeviceIdentity._(device, keyPair, privateKey, publicKey);
  }
}

/// A fresh ephemeral key pair for one handshake.
Future<SimpleKeyPair> newEphemeralKeyPair() => _x25519.newKeyPair();

Future<Uint8List> publicKeyOf(SimpleKeyPair keyPair) async =>
    Uint8List.fromList((await keyPair.extractPublicKey()).bytes);

/// Frame 1 (initiator → responder): "CSv1" ‖ E_I ‖ S_I ‖ id_I.
Uint8List buildFrame1({required Uint8List ephemeralPublic, required Uint8List staticPublic, required String deviceId}) {
  final id = ascii.encode(deviceId);
  if (ephemeralPublic.length != keyLength || staticPublic.length != keyLength || id.length != deviceIdLength) {
    throw ArgumentError('bad frame 1 inputs');
  }
  return Uint8List.fromList([...protocolMagic, ...ephemeralPublic, ...staticPublic, ...id]);
}

typedef Frame1 = ({Uint8List ephemeralPublic, Uint8List staticPublic, String deviceId});

Frame1 parseFrame1(Uint8List frame) {
  if (frame.length != frame1Length || !_hasMagic(frame)) {
    throw ProtocolException('bad handshake frame 1', code: 'unsupported');
  }
  final String deviceId;
  try {
    deviceId = ascii.decode(frame.sublist(4 + 2 * keyLength));
  } on FormatException {
    throw ProtocolException('device id is not ASCII');
  }
  return (
    ephemeralPublic: frame.sublist(4, 4 + keyLength),
    staticPublic: frame.sublist(4 + keyLength, 4 + 2 * keyLength),
    deviceId: deviceId,
  );
}

/// Frame 2 (responder → initiator): "CSv1" ‖ E_R.
Uint8List buildFrame2(Uint8List ephemeralPublic) => Uint8List.fromList([...protocolMagic, ...ephemeralPublic]);

Uint8List parseFrame2(Uint8List frame) {
  if (frame.length != frame2Length || !_hasMagic(frame)) {
    throw ProtocolException('bad handshake frame 2', code: 'unsupported');
  }
  return frame.sublist(4);
}

bool _hasMagic(Uint8List frame) {
  for (var i = 0; i < protocolMagic.length; i++) {
    if (frame[i] != protocolMagic[i]) return false;
  }
  return true;
}

/// Session keys from one side's point of view.
class SessionKeys {
  SessionKeys({required this.send, required this.receive});
  final SecretKey send;
  final SecretKey receive;
}

/// Initiator: ee = DH(e_I, E_R), es = DH(e_I, S_R), se = DH(s_I, E_R).
Future<SessionKeys> deriveInitiatorKeys({
  required SimpleKeyPair ephemeral,
  required SimpleKeyPair static,
  required Uint8List responderStatic,
  required Uint8List responderEphemeral,
  required Uint8List frame1,
  required Uint8List frame2,
}) async {
  final ee = await _dh(ephemeral, responderEphemeral);
  final es = await _dh(ephemeral, responderStatic);
  final se = await _dh(static, responderEphemeral);
  final okm = await _schedule(ee, es, se, frame1, frame2);
  return SessionKeys(send: SecretKey(okm.sublist(0, 32)), receive: SecretKey(okm.sublist(32, 64)));
}

/// Responder: ee = DH(e_R, E_I), es = DH(s_R, E_I), se = DH(e_R, S_I).
Future<SessionKeys> deriveResponderKeys({
  required SimpleKeyPair ephemeral,
  required SimpleKeyPair static,
  required Uint8List initiatorStatic,
  required Uint8List initiatorEphemeral,
  required Uint8List frame1,
  required Uint8List frame2,
}) async {
  final ee = await _dh(ephemeral, initiatorEphemeral);
  final es = await _dh(static, initiatorEphemeral);
  final se = await _dh(ephemeral, initiatorStatic);
  final okm = await _schedule(ee, es, se, frame1, frame2);
  return SessionKeys(send: SecretKey(okm.sublist(32, 64)), receive: SecretKey(okm.sublist(0, 32)));
}

Future<List<int>> _dh(SimpleKeyPair ours, Uint8List theirPublic) async {
  final secret = await _x25519.sharedSecretKey(
    keyPair: ours,
    remotePublicKey: SimplePublicKey(theirPublic, type: KeyPairType.x25519),
  );
  final bytes = await secret.extractBytes();
  if (bytes.every((b) => b == 0)) throw ProtocolException('low-order key in handshake');
  return bytes;
}

Future<List<int>> _schedule(List<int> ee, List<int> es, List<int> se, Uint8List frame1, Uint8List frame2) async {
  final transcript = await Sha256().hash([..._handshakeLabel, ...frame1, ...frame2]);
  final okm = await Hkdf(hmac: Hmac.sha256(), outputLength: 64).deriveKey(
    secretKey: SecretKey([...ee, ...es, ...se]),
    nonce: transcript.bytes,
    info: _sessionKeysInfo,
  );
  return okm.bytes;
}

/// ChaCha20-Poly1305 for one direction. Nonce = 4 zero bytes ‖ u64 BE
/// counter, starting at 0; ciphertext ‖ 16-byte tag on the wire. Calls must
/// be made in frame order.
class FrameCipher {
  FrameCipher(this._key);

  final SecretKey _key;
  int _counter = 0;

  List<int> _nextNonce() {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, _counter++);
    return nonce;
  }

  Future<Uint8List> seal(List<int> plaintext) async {
    final box = await _aead.encrypt(plaintext, secretKey: _key, nonce: _nextNonce());
    final cipherText = box.cipherText;
    return Uint8List(cipherText.length + 16)
      ..setRange(0, cipherText.length, cipherText)
      ..setRange(cipherText.length, cipherText.length + 16, box.mac.bytes);
  }

  Future<Uint8List> open(Uint8List frame) async {
    if (frame.length < 16) throw ProtocolException('encrypted frame too short');
    final box = SecretBox(
      frame.sublist(0, frame.length - 16),
      nonce: _nextNonce(),
      mac: Mac(frame.sublist(frame.length - 16)),
    );
    try {
      return Uint8List.fromList(await _aead.decrypt(box, secretKey: _key));
    } on SecretBoxAuthenticationError {
      throw ProtocolException('frame failed to decrypt (wrong keys or tampering)');
    }
  }
}
