import Foundation
import GRDB

enum ClipKind: String, Codable, CaseIterable {
    case text
    case rtf
    case url
    case image
    case file
    case color
}

struct Clip: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clip"

    var id: String
    var kind: ClipKind
    var textContent: String?
    var dataPath: String?
    var previewPath: String?
    var contentHash: String
    var sourceBundle: String?
    var sourceName: String?
    var byteSize: Int
    var createdAt: Date
    var lastUsedAt: Date
    var pinboardId: String?
}

extension Clip {
    /// Short one-line title used in card headers and accessibility labels.
    var displayTitle: String {
        switch kind {
        case .text, .rtf:
            let firstLine = (textContent ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? ""
            return firstLine.isEmpty ? "Text" : firstLine
        case .url:
            return textContent ?? "Link"
        case .image:
            return "Image"
        case .file:
            let names = fileURLs.map(\.lastPathComponent)
            return names.isEmpty ? "File" : names.joined(separator: ", ")
        case .color:
            return textContent ?? "Color"
        }
    }

    /// File clips store newline-separated absolute paths in textContent.
    var fileURLs: [URL] {
        guard kind == .file, let text = textContent else { return [] }
        return text
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }
}

struct Pinboard: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pinboard"

    var id: String
    var name: String
    var sortOrder: Int
}
