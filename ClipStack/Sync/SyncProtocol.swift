import CryptoKit
import Foundation

/// Wire-level pieces of Wi-Fi sync protocol v1 (docs/05-lan-sync.md): the
/// handshake math, the per-direction cipher and the message layout. Pure
/// value code with no networking, so it can be exercised without sockets.
enum SyncProtocol {
    static let serviceType = "_clipstack._tcp"
    static let defaultPort: UInt16 = 47474
    static let platform = "macos"

    /// Frame 1 / frame 2 magic; doubles as the protocol version.
    static let magic = Data("CSv1".utf8)
    static let transcriptLabel = Data("ClipStack v1 handshake".utf8)
    static let sessionKeysInfo = Data("ClipStack v1 session keys".utf8)

    /// Largest frame accepted on the wire (spec: N ≤ 16 MiB).
    static let maxFrameLength = 16 * 1024 * 1024
    /// Largest clip body we send in v1.
    static let maxBodyLength = 10 * 1024 * 1024

    static let frame1Length = 4 + 32 + 32 + 36
    static let frame2Length = 4 + 32
}

enum SyncProtocolError: Error, CustomStringConvertible {
    case malformedFrame(String)
    case weakKey
    case decryptFailed
    case malformedMessage(String)

    var description: String {
        switch self {
        case .malformedFrame(let why): return "malformed frame: \(why)"
        case .weakKey: return "all-zero X25519 result"
        case .decryptFailed: return "decrypt failed"
        case .malformedMessage(let why): return "malformed message: \(why)"
        }
    }
}

// MARK: - Device description

/// The `device` object carried in `hello`, `pair` and `paired`.
struct SyncDevice: Equatable {
    var id: String
    var name: String
    var platform: String

    var json: [String: Any] {
        ["id": id, "name": name, "platform": platform]
    }

    init(id: String, name: String, platform: String) {
        self.id = id
        self.name = name
        self.platform = platform
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty
        else { return nil }
        self.id = id
        self.name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown device"
        self.platform = object["platform"] as? String ?? "unknown"
    }
}

// MARK: - Messages

/// Decrypted frame plaintext: u32 BE header length ‖ JSON header ‖ body.
struct SyncMessage {
    var type: String
    /// Header fields other than "t".
    var fields: [String: Any]
    var body: Data

    init(type: String, fields: [String: Any] = [:], body: Data = Data()) {
        self.type = type
        self.fields = fields
        self.body = body
    }

    func encoded() throws -> Data {
        var header = fields
        header["t"] = type
        let json = try JSONSerialization.data(withJSONObject: header)
        var data = Data(capacity: 4 + json.count + body.count)
        data.appendUInt32BE(UInt32(json.count))
        data.append(json)
        data.append(body)
        return data
    }

    static func decode(_ plaintext: Data) throws -> SyncMessage {
        let data = Data(plaintext)
        guard data.count >= 4 else { throw SyncProtocolError.malformedMessage("short") }
        let headerLength = Int(data.readUInt32BE(at: 0))
        guard headerLength <= data.count - 4 else {
            throw SyncProtocolError.malformedMessage("header length past end")
        }
        let headerData = data.subdata(in: 4 ..< 4 + headerLength)
        guard var header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let type = header["t"] as? String
        else { throw SyncProtocolError.malformedMessage("header is not an object with t") }
        header["t"] = nil
        return SyncMessage(type: type, fields: header, body: data.subdata(in: 4 + headerLength ..< data.count))
    }

    func string(_ key: String) -> String? {
        fields[key] as? String
    }
}

// MARK: - Cipher

/// One direction of an encrypted session: ChaCha20-Poly1305 with the nonce
/// 4 zero bytes ‖ u64 BE counter, counter starting at 0, empty AAD. Frames
/// carry ciphertext ‖ 16-byte tag.
struct SyncCipher {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    private func nonce() throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.appendUInt64BE(counter)
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce())
        counter += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ frame: Data) throws -> Data {
        let data = Data(frame)
        guard data.count >= 16 else { throw SyncProtocolError.decryptFailed }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce(),
                ciphertext: data.prefix(data.count - 16),
                tag: data.suffix(16)
            )
            let plaintext = try ChaChaPoly.open(box, using: key)
            counter += 1
            return plaintext
        } catch {
            throw SyncProtocolError.decryptFailed
        }
    }
}

// MARK: - Handshake

enum SyncHandshake {
    typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey
    typealias PublicKey = Curve25519.KeyAgreement.PublicKey

    /// Contents of frame 1 (initiator → responder).
    struct InitiatorHello {
        let ephemeralKey: Data
        let staticKey: Data
        let deviceId: String
    }

    struct SessionKeys {
        /// k_IR: initiator → responder.
        let initiatorToResponder: SymmetricKey
        /// k_RI: responder → initiator.
        let responderToInitiator: SymmetricKey
    }

    /// Frame 1: "CSv1" ‖ E_I ‖ S_I ‖ id_I (36 ASCII bytes).
    static func makeInitiatorHello(ephemeral: PublicKey, staticKey: PublicKey, deviceId: String) throws -> Data {
        let id = Data(deviceId.utf8)
        guard id.count == 36 else { throw SyncProtocolError.malformedFrame("device id must be 36 bytes") }
        return SyncProtocol.magic + ephemeral.rawRepresentation + staticKey.rawRepresentation + id
    }

    static func parseInitiatorHello(_ frame: Data) throws -> InitiatorHello {
        let data = Data(frame)
        guard data.count == SyncProtocol.frame1Length else {
            throw SyncProtocolError.malformedFrame("frame 1 is \(data.count) bytes")
        }
        guard data.prefix(4) == SyncProtocol.magic else {
            throw SyncProtocolError.malformedFrame("bad magic")
        }
        guard let id = String(data: data.subdata(in: 68 ..< 104), encoding: .ascii) else {
            throw SyncProtocolError.malformedFrame("device id is not ASCII")
        }
        return InitiatorHello(
            ephemeralKey: data.subdata(in: 4 ..< 36),
            staticKey: data.subdata(in: 36 ..< 68),
            deviceId: id
        )
    }

    /// Responder side: builds frame 2 ("CSv1" ‖ E_R) and the session keys.
    static func respond(
        to frame1: Data,
        staticKey: PrivateKey,
        ephemeral: PrivateKey = PrivateKey()
    ) throws -> (frame2: Data, keys: SessionKeys) {
        let hello = try parseInitiatorHello(frame1)
        let initiatorEphemeral = try PublicKey(rawRepresentation: hello.ephemeralKey)
        let initiatorStatic = try PublicKey(rawRepresentation: hello.staticKey)
        let frame2 = SyncProtocol.magic + ephemeral.publicKey.rawRepresentation

        let ee = try dh(ephemeral, initiatorEphemeral)
        let es = try dh(staticKey, initiatorEphemeral)
        let se = try dh(ephemeral, initiatorStatic)
        return (frame2, deriveKeys(frame1: Data(frame1), frame2: frame2, ee: ee, es: es, se: se))
    }

    /// Initiator side (not used by the Mac in v1, which only listens; kept
    /// so the handshake can be checked end to end without a second device).
    static func finishInitiator(
        frame1: Data,
        frame2: Data,
        ephemeral: PrivateKey,
        staticKey: PrivateKey,
        responderStaticKey: Data
    ) throws -> SessionKeys {
        let reply = Data(frame2)
        guard reply.count == SyncProtocol.frame2Length, reply.prefix(4) == SyncProtocol.magic else {
            throw SyncProtocolError.malformedFrame("bad frame 2")
        }
        let responderEphemeral = try PublicKey(rawRepresentation: reply.subdata(in: 4 ..< 36))
        let responderStatic = try PublicKey(rawRepresentation: responderStaticKey)

        let ee = try dh(ephemeral, responderEphemeral)
        let es = try dh(ephemeral, responderStatic)
        let se = try dh(staticKey, responderEphemeral)
        return deriveKeys(frame1: Data(frame1), frame2: reply, ee: ee, es: es, se: se)
    }

    static func deriveKeys(frame1: Data, frame2: Data, ee: Data, es: Data, se: Data) -> SessionKeys {
        let transcript = SHA256.hash(data: SyncProtocol.transcriptLabel + frame1 + frame2)
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ee + es + se),
            salt: Data(transcript),
            info: SyncProtocol.sessionKeysInfo,
            outputByteCount: 64
        )
        let bytes = okm.withUnsafeBytes { Data($0) }
        return SessionKeys(
            initiatorToResponder: SymmetricKey(data: bytes.prefix(32)),
            responderToInitiator: SymmetricKey(data: bytes.suffix(32))
        )
    }

    static func dh(_ privateKey: PrivateKey, _ publicKey: PublicKey) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let bytes = secret.withUnsafeBytes { Data($0) }
        guard bytes.contains(where: { $0 != 0 }) else { throw SyncProtocolError.weakKey }
        return bytes
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    /// Reads a big-endian u32 at an offset from startIndex.
    func readUInt32BE(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start ..< start + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// base64url without padding (spec encoding for keys and tokens).
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
