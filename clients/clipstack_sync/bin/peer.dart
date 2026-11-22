// Command-line ClipStack peer, for testing a listening device (the Mac app)
// without a phone. Prints one JSON object per line on stdout.
//
//   dart run clipstack_sync:peer pair '<clipstack://pair?... link>'
//   dart run clipstack_sync:peer send 'some text'
//   dart run clipstack_sync:peer send-image picture.png
//   dart run clipstack_sync:peer listen [--seconds 30]   # stdin lines are sent as clips
//
// Options: --state FILE (default peer_state.json), --host HOST and --port PORT
// to override the saved address, --name NAME for this peer's device name.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipstack_sync/clipstack_sync.dart';

Future<void> main(List<String> argv) async {
  final args = _Args(argv);
  if (args.positional.isEmpty) {
    stderr.writeln('usage: peer pair <link> | send <text> | send-image <png> | listen [--seconds N]');
    exit(64);
  }
  try {
    switch (args.positional.first) {
      case 'pair':
        await _pair(args);
      case 'send':
        await _withSession(args, (session, identity) async {
          await session.sendClip(ClipMessage.text(args.positional[1], origin: identity.device.id));
          _emit({'event': 'sent', 'kind': 'text'});
        });
      case 'send-image':
        final png = await File(args.positional[1]).readAsBytes();
        await _withSession(args, (session, identity) async {
          await session.sendClip(ClipMessage.png(png, origin: identity.device.id));
          _emit({'event': 'sent', 'kind': 'image', 'bytes': png.length});
        });
      case 'listen':
        await _withSession(args, (session, identity) async {
          final lines = stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
            if (line.isNotEmpty) session.sendClip(ClipMessage.text(line, origin: identity.device.id));
          });
          final seconds = int.tryParse(args.options['seconds'] ?? '');
          await (seconds == null ? session.done : session.done.timeout(Duration(seconds: seconds), onTimeout: () {}));
          await lines.cancel();
        }, keepOpen: true);
      default:
        stderr.writeln('unknown command ${args.positional.first}');
        exit(64);
    }
  } on Object catch (error) {
    _emit({'event': 'error', 'message': '$error'});
    exit(1);
  }
  exit(0);
}

Future<void> _pair(_Args args) async {
  final link = PairingLink.parse(args.positional[1]);
  final state = await _State.load(args.stateFile, name: args.options['name']);
  final hosts = args.options['host'] != null ? [args.options['host']!] : link.hosts;
  final port = int.tryParse(args.options['port'] ?? '') ?? link.port;
  final session = await _connectAny(hosts, port, (host) => SyncSession.connect(
        host: host,
        port: port,
        identity: state.identity,
        peerStaticKey: link.publicKey,
        expectedPeerId: link.device.id,
        pairingToken: link.token,
      ));
  state.peer = {
    'device': session.peer.toJson(),
    'publicKey': b64urlEncode(link.publicKey),
    'hosts': hosts,
    'port': port,
  };
  await state.save(args.stateFile);
  _emit({'event': 'paired', 'peer': session.peer.toJson(), 'me': state.identity.device.toJson()});
  await session.close();
}

Future<void> _withSession(
  _Args args,
  Future<void> Function(SyncSession session, DeviceIdentity identity) body, {
  bool keepOpen = false,
}) async {
  final state = await _State.load(args.stateFile, name: args.options['name']);
  final peer = state.peer;
  if (peer == null) throw StateError('not paired yet: run `peer pair <link>` first');
  final hosts = args.options['host'] != null ? [args.options['host']!] : (peer['hosts'] as List).cast<String>();
  final port = int.tryParse(args.options['port'] ?? '') ?? peer['port'] as int;
  final peerDevice = DeviceInfo.fromJson(peer['device']);
  final session = await _connectAny(hosts, port, (host) => SyncSession.connect(
        host: host,
        port: port,
        identity: state.identity,
        peerStaticKey: b64urlDecode(peer['publicKey'] as String),
        expectedPeerId: peerDevice.id,
      ));
  _emit({'event': 'connected', 'peer': session.peer.toJson()});
  final clips = session.clips.listen((clip) {
    final size = _pngSize(clip.body);
    _emit({
      'event': 'clip',
      'kind': clip.kind,
      if (clip.text != null) 'text': clip.text,
      if (clip.body.isNotEmpty) 'bytes': clip.body.length,
      if (size != null) 'width': size.width,
      if (size != null) 'height': size.height,
      if (clip.mime != null) 'mime': clip.mime,
      'origin': clip.origin,
    });
  });
  await body(session, state.identity);
  if (!keepOpen) await session.close();
  await session.done;
  await clips.cancel();
  if (session.peerUnpaired) {
    state.peer = null;
    await state.save(args.stateFile);
  }
  _emit({'event': 'closed', if (session.closeReason != null) 'reason': '${session.closeReason}', 'unpaired': session.peerUnpaired});
}

Future<SyncSession> _connectAny(List<String> hosts, int port, Future<SyncSession> Function(String host) connect) async {
  Object? lastError;
  for (final host in hosts) {
    try {
      return await connect(host);
    } on SocketException catch (error) {
      lastError = error; // try the next address
    }
  }
  throw lastError ?? StateError('no host to connect to');
}

void _emit(Map<String, Object?> event) => stdout.writeln(jsonEncode(event));

/// A PNG's size from its IHDR chunk (right after the signature); null for
/// anything else. Lets a test check, say, that a photo arrived upright.
({int width, int height})? _pngSize(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  final header = ByteData.sublistView(bytes, 16, 24);
  return (width: header.getUint32(0), height: header.getUint32(4));
}

class _Args {
  _Args(List<String> argv) {
    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      if (arg.startsWith('--') && i + 1 < argv.length) {
        options[arg.substring(2)] = argv[++i];
      } else {
        positional.add(arg);
      }
    }
  }

  final positional = <String>[];
  final options = <String, String>{};
  String get stateFile => options['state'] ?? 'peer_state.json';
}

/// This peer's identity and its one paired device, as JSON on disk.
class _State {
  _State(this.identity, this.peer);

  final DeviceIdentity identity;
  Map<String, Object?>? peer;

  static Future<_State> load(String path, {String? name}) async {
    final file = File(path);
    if (await file.exists()) {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final identity = await DeviceIdentity.restore(
        DeviceInfo.fromJson(json['device']),
        b64urlDecode(json['privateKey'] as String),
      );
      return _State(name == null ? identity : identity.renamed(name), json['peer'] as Map<String, Object?>?);
    }
    final hostName = Platform.localHostname.split('.').first;
    return _State(await DeviceIdentity.generate(name: name ?? 'Test peer ($hostName)', platform: Platforms.linux), null);
  }

  Future<void> save(String path) async {
    final json = {
      'device': identity.device.toJson(),
      'privateKey': b64urlEncode(identity.privateKeyBytes),
      'peer': peer,
    };
    await File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  }
}

// Keeps Uint8List in scope for readers of this file.
typedef Bytes = Uint8List;
