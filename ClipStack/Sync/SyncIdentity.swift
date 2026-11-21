import CryptoKit
import Foundation
import Security
import SystemConfiguration

/// This Mac's sync identity: a stable device id and a static X25519 key pair.
/// The private key lives in the Keychain; only the public half ever leaves
/// the device (in the pairing link and the handshake).
struct SyncIdentity {
    let deviceId: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    private static let keychainService = "com.zamansheikh.ClipStack.sync"
    private static let keychainAccount = "static-key-x25519"
    private static let deviceIdKey = "syncDeviceId"

    /// The computer name from System Settings ("Zaman's MacBook Pro").
    /// SCDynamicStore is instant, unlike Host.current(), which can block on
    /// reverse DNS lookups.
    static var deviceName: String {
        // Test hook (store screenshots): show a neutral name instead of the
        // owner's computer name. Inert unless set.
        if let override = ProcessInfo.processInfo.environment["CLIPSTACK_DEVICE_NAME"], !override.isEmpty {
            return override
        }
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName
    }

    static func loadOrCreate() -> SyncIdentity {
        // Test hook: with CLIPSTACK_SUPPORT_DIR set, keep the identity in that
        // folder so a test instance is a separate device from the real app
        // and never touches the Keychain or the real defaults.
        if AppDatabase.isUsingTestSupportDirectory {
            return loadOrCreateFileIdentity(
                at: AppDatabase.supportDirectory.appendingPathComponent("sync-identity.json")
            )
        }

        let defaults = UserDefaults.standard
        let deviceId: String
        if let stored = defaults.string(forKey: deviceIdKey), stored.count == 36 {
            deviceId = stored
        } else {
            deviceId = UUID().uuidString.lowercased()
            defaults.set(deviceId, forKey: deviceIdKey)
        }

        if let raw = readKeychainKey(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        {
            return SyncIdentity(deviceId: deviceId, privateKey: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        if !writeKeychainKey(key.rawRepresentation) {
            // Without a stored key every launch would be a new identity and
            // all pairings would break, so fall back to a private file.
            NSLog("ClipStack sync: Keychain unavailable, storing identity key in a file")
            return loadOrCreateFileIdentity(
                at: AppDatabase.supportDirectory.appendingPathComponent("sync-identity.json"),
                deviceId: deviceId,
                newKey: key
            )
        }
        return SyncIdentity(deviceId: deviceId, privateKey: key)
    }

    // MARK: - Keychain

    private static func readKeychainKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeKeychainKey(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrLabel as String: "ClipStack sync key",
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    // MARK: - File fallback

    private struct FileIdentity: Codable {
        var deviceId: String
        var privateKey: String // base64url
    }

    private static func loadOrCreateFileIdentity(
        at url: URL,
        deviceId: String? = nil,
        newKey: Curve25519.KeyAgreement.PrivateKey? = nil
    ) -> SyncIdentity {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(FileIdentity.self, from: data),
           let raw = Data(base64URLEncoded: stored.privateKey),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        {
            return SyncIdentity(deviceId: stored.deviceId, privateKey: key)
        }
        let identity = SyncIdentity(
            deviceId: deviceId ?? UUID().uuidString.lowercased(),
            privateKey: newKey ?? Curve25519.KeyAgreement.PrivateKey()
        )
        let file = FileIdentity(
            deviceId: identity.deviceId,
            privateKey: identity.privateKey.rawRepresentation.base64URLEncoded
        )
        if let data = try? JSONEncoder().encode(file) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return identity
    }
}
