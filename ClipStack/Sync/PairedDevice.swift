import Foundation
import GRDB

/// A device this Mac has paired with. Its static public key is what the
/// handshake checks; the name and platform refresh on every `hello`.
struct PairedDevice: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "device"

    var id: String
    var name: String
    var platform: String
    var publicKey: Data
    var pairedAt: Date
    var lastSeenAt: Date?
}

extension PairedDevice {
    /// SF Symbol for the device list.
    var symbolName: String {
        switch platform {
        case "android": return "candybarphone"
        case "ios": return "iphone"
        case "macos": return "laptopcomputer"
        case "windows", "linux": return "desktopcomputer"
        default: return "questionmark.square.dashed"
        }
    }
}
