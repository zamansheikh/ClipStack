// Wire-level types for ClipStack sync protocol v1. The normative description
// is docs/05-lan-sync.md; names here follow it.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// "CSv1": first four bytes of both handshake frames; doubles as the
/// protocol version.
final Uint8List protocolMagic = Uint8List.fromList(ascii.encode('CSv1'));
const String serviceType = '_clipstack._tcp';
const int defaultPort = 47474;
const int maxFrameLength = 16 * 1024 * 1024;

/// v1 senders never send a clip body larger than this.
const int maxBodyLength = 10 * 1024 * 1024;
const int deviceIdLength = 36;
const int keyLength = 32;
const int frame1Length = 4 + keyLength + keyLength + deviceIdLength; // 104
const int frame2Length = 4 + keyLength; // 36

/// Send a ping after this long without receiving anything…
const Duration pingAfter = Duration(seconds: 25);

/// …and give up on the peer after this long.
const Duration idleTimeout = Duration(seconds: 60);

/// Thrown when a peer breaks the protocol (bad frame, failed decryption,
/// unexpected message). The session is closed.
class ProtocolException implements Exception {
  ProtocolException(this.message, {this.code});
  final String message;

  /// The `error` message code, when the peer sent one.
  final String? code;

  @override
  String toString() => code == null ? 'ProtocolException: $message' : 'ProtocolException($code): $message';
}

String b64urlEncode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List b64urlDecode(String text) => base64Url.decode(base64Url.normalize(text));

/// Random lowercase UUID v4 — the device id format.
String newDeviceId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Platform strings used in `device.platform` and the `pf` TXT key.
abstract final class Platforms {
  static const macos = 'macos';
  static const android = 'android';
  static const ios = 'ios';
  static const windows = 'windows';
  static const linux = 'linux';
}

/// The `device` object carried by `hello`, `pair` and `paired`.
class DeviceInfo {
  const DeviceInfo({required this.id, required this.name, required this.platform});

  final String id;
  final String name;
  final String platform;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'platform': platform};

  static DeviceInfo fromJson(Object? json) {
    if (json is! Map) throw ProtocolException('device must be an object');
    final id = json['id'];
    if (id is! String || id.length != deviceIdLength) {
      throw ProtocolException('device.id must be a 36-character UUID');
    }
    return DeviceInfo(
      id: id,
      name: json['name'] is String ? json['name'] as String : 'Unknown device',
      platform: json['platform'] is String ? json['platform'] as String : 'unknown',
    );
  }

  @override
  String toString() => '$name ($platform, $id)';
}

/// The `clipstack://pair?...` link shown as a QR code by a listening device.
class PairingLink {
  PairingLink({
    required this.device,
    required this.publicKey,
    required this.token,
    required this.port,
    required this.hosts,
  });

  final DeviceInfo device;
  final Uint8List publicKey;
  final Uint8List token;
  final int port;
  final List<String> hosts;

  static PairingLink parse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'clipstack' || uri.host != 'pair') {
      throw const FormatException('Not a ClipStack pairing link');
    }
    final q = uri.queryParameters;
    if (q['v'] != '1') throw FormatException('Unsupported pairing link version ${q['v']}');
    String need(String key) {
      final value = q[key];
      if (value == null || value.isEmpty) throw FormatException('Pairing link is missing "$key"');
      return value;
    }

    final publicKey = b64urlDecode(need('pk'));
    final token = b64urlDecode(need('token'));
    final id = need('id');
    final port = int.tryParse(need('port'));
    if (publicKey.length != keyLength) throw const FormatException('Bad public key in pairing link');
    if (token.length != 16) throw const FormatException('Bad token in pairing link');
    if (id.length != deviceIdLength) throw const FormatException('Bad device id in pairing link');
    if (port == null || port <= 0 || port > 65535) throw const FormatException('Bad port in pairing link');
    return PairingLink(
      device: DeviceInfo(id: id, name: q['name'] ?? 'ClipStack', platform: q['pf'] ?? Platforms.macos),
      publicKey: publicKey,
      token: token,
      port: port,
      hosts: (q['hosts'] ?? '').split(',').map((h) => h.trim()).where((h) => h.isNotEmpty).toList(),
    );
  }

  String toUri() => Uri(scheme: 'clipstack', host: 'pair', queryParameters: {
        'v': '1',
        'id': device.id,
        'name': device.name,
        'pf': device.platform,
        'pk': b64urlEncode(publicKey),
        'token': b64urlEncode(token),
        'port': '$port',
        'hosts': hosts.join(','),
      }).toString();
}

// MARK: - Frames

/// u32 big-endian length prefix + payload.
Uint8List encodeFrame(List<int> payload) {
  if (payload.length > maxFrameLength) throw ProtocolException('frame too large');
  final out = Uint8List(4 + payload.length);
  ByteData.sublistView(out).setUint32(0, payload.length);
  out.setRange(4, out.length, payload);
  return out;
}

/// Splits a TCP byte stream into frames.
class FrameDecoder extends StreamTransformerBase<Uint8List, Uint8List> {
  const FrameDecoder();

  @override
  Stream<Uint8List> bind(Stream<Uint8List> stream) {
    late StreamController<Uint8List> controller;
    StreamSubscription<Uint8List>? subscription;
    var buffer = Uint8List(0);

    void onData(Uint8List chunk) {
      buffer = buffer.isEmpty ? chunk : (BytesBuilder(copy: false)..add(buffer)..add(chunk)).takeBytes();
      var offset = 0;
      while (buffer.length - offset >= 4) {
        final length = ByteData.sublistView(buffer, offset, offset + 4).getUint32(0);
        if (length > maxFrameLength) {
          controller.addError(ProtocolException('frame length $length exceeds limit'));
          subscription?.cancel();
          controller.close();
          return;
        }
        if (buffer.length - offset - 4 < length) break;
        controller.add(Uint8List.sublistView(buffer, offset + 4, offset + 4 + length));
        offset += 4 + length;
      }
      // Copy the remainder so the delivered frames' backing buffer can be freed.
      buffer = offset == 0 ? buffer : Uint8List.fromList(Uint8List.sublistView(buffer, offset));
    }

    controller = StreamController<Uint8List>(
      onListen: () {
        subscription = stream.listen(
          onData,
          onError: controller.addError,
          onDone: controller.close,
          cancelOnError: true,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }
}

// MARK: - Messages

/// Decrypted frame contents: u32 header length + JSON header + body.
class Message {
  Message(this.header, [Uint8List? body]) : body = body ?? Uint8List(0);

  final Map<String, Object?> header;
  final Uint8List body;

  String get type => header['t'] is String ? header['t'] as String : '';

  Uint8List encode() {
    final json = utf8.encode(jsonEncode(header));
    final out = Uint8List(4 + json.length + body.length);
    ByteData.sublistView(out).setUint32(0, json.length);
    out.setRange(4, 4 + json.length, json);
    out.setRange(4 + json.length, out.length, body);
    return out;
  }

  static Message decode(Uint8List plaintext) {
    if (plaintext.length < 4) throw ProtocolException('message too short');
    final headerLength = ByteData.sublistView(plaintext, 0, 4).getUint32(0);
    if (headerLength > plaintext.length - 4) throw ProtocolException('header length out of range');
    final Object? header;
    try {
      header = jsonDecode(utf8.decode(Uint8List.sublistView(plaintext, 4, 4 + headerLength)));
    } on FormatException {
      throw ProtocolException('header is not valid JSON');
    }
    if (header is! Map<String, Object?>) throw ProtocolException('header must be a JSON object');
    return Message(header, Uint8List.sublistView(plaintext, 4 + headerLength));
  }

  // [port]: the sender's own listening port, when it accepts connections
  // too (phones that pair with each other). Optional; older peers ignore it.
  static Message hello(DeviceInfo device, String appVersion, {int? port}) =>
      Message({'t': 'hello', 'device': device.toJson(), 'app': appVersion, 'port': ?port});
  static Message pair(DeviceInfo device, Uint8List token, {int? port}) =>
      Message({'t': 'pair', 'token': b64urlEncode(token), 'device': device.toJson(), 'port': ?port});
  static Message paired(DeviceInfo device, {int? port}) =>
      Message({'t': 'paired', 'device': device.toJson(), 'port': ?port});

  /// The `port` field, when present and valid.
  int? get listenPort {
    final port = header['port'];
    return port is int && port > 0 && port <= 65535 ? port : null;
  }
  static Message ping() => Message({'t': 'ping'});
  static Message pong() => Message({'t': 'pong'});
  static Message unpair() => Message({'t': 'unpair'});
  static Message error(String code, String message) => Message({'t': 'error', 'code': code, 'message': message});
}

/// Clip kinds that travel over the wire (files are local-only in v1).
abstract final class ClipKinds {
  static const text = 'text';
  static const url = 'url';
  static const rtf = 'rtf';
  static const image = 'image';
  static const all = {text, url, rtf, image};
}

/// A `clip` message.
class ClipMessage {
  ClipMessage({
    required this.id,
    required this.origin,
    required this.kind,
    this.text,
    this.mime,
    Uint8List? body,
    DateTime? createdAt,
  })  : body = body ?? Uint8List(0),
        createdAt = createdAt ?? DateTime.now();

  /// A text clip originating on [origin], with a fresh id.
  factory ClipMessage.text(String text, {required String origin}) =>
      ClipMessage(id: newDeviceId(), origin: origin, kind: _looksLikeUrl(text) ? ClipKinds.url : ClipKinds.text, text: text);

  /// A PNG image clip originating on [origin], with a fresh id.
  factory ClipMessage.png(Uint8List png, {required String origin}) =>
      ClipMessage(id: newDeviceId(), origin: origin, kind: ClipKinds.image, mime: 'image/png', body: png);

  final String id;
  final String origin;
  final String kind;
  final String? text;
  final String? mime;
  final Uint8List body;
  final DateTime createdAt;

  Message toMessage() => Message({
        't': 'clip',
        'id': id,
        'origin': origin,
        'kind': kind,
        if (text != null) 'text': text,
        if (body.isNotEmpty && mime != null) 'mime': mime,
        'createdAt': createdAt.millisecondsSinceEpoch,
      }, body);

  static ClipMessage fromMessage(Message message) {
    final h = message.header;
    final id = h['id'], origin = h['origin'], kind = h['kind'];
    if (id is! String || origin is! String || kind is! String) {
      throw ProtocolException('clip needs id, origin and kind');
    }
    final text = h['text'] is String ? h['text'] as String : null;
    if (kind != ClipKinds.image && text == null) throw ProtocolException('$kind clip without text');
    if (kind == ClipKinds.image && message.body.isEmpty) throw ProtocolException('image clip without body');
    final createdAt = h['createdAt'];
    return ClipMessage(
      id: id,
      origin: origin,
      kind: kind,
      text: text,
      mime: h['mime'] is String ? h['mime'] as String : null,
      body: message.body,
      createdAt: createdAt is int ? DateTime.fromMillisecondsSinceEpoch(createdAt) : null,
    );
  }

  static bool _looksLikeUrl(String text) {
    final trimmed = text.trim();
    if (trimmed.contains(RegExp(r'\s'))) return false;
    final uri = Uri.tryParse(trimmed);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
  }

  @override
  String toString() => kind == ClipKinds.image ? 'image (${body.length} bytes)' : '$kind: $text';
}
