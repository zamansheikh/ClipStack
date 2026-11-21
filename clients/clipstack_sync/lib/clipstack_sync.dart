/// ClipStack Wi-Fi clipboard sync, protocol v1 (docs/05-lan-sync.md).
///
/// Pure Dart: used by the Flutter apps and by `dart run clipstack_sync:peer`,
/// a command-line peer for testing against the Mac app.
library;

export 'src/crypto.dart' show DeviceIdentity;
export 'src/protocol.dart'
    show
        ClipKinds,
        ClipMessage,
        DeviceInfo,
        PairingLink,
        Platforms,
        ProtocolException,
        b64urlDecode,
        b64urlEncode,
        defaultPort,
        maxBodyLength,
        serviceType;
export 'src/session.dart' show ResponderPolicy, SyncSession;
