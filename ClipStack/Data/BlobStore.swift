import AppKit
import CryptoKit
import Foundation

/// Stores large binary content (images, RTF) on disk next to the database,
/// keyed by content hash. DB rows keep only the relative path.
enum BlobStore {
    static var blobsDirectory: URL {
        AppDatabase.supportDirectory.appendingPathComponent("blobs", isDirectory: true)
    }

    static var previewsDirectory: URL {
        AppDatabase.supportDirectory.appendingPathComponent("previews", isDirectory: true)
    }

    static func prepare() {
        try? FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: previewsDirectory, withIntermediateDirectories: true)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    /// Write blob data, returns the absolute path stored in the DB row.
    static func writeBlob(_ data: Data, hash: String, fileExtension: String) throws -> String {
        let url = blobsDirectory.appendingPathComponent("\(hash).\(fileExtension)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url.path
    }

    /// Generate and save a downscaled PNG thumbnail for an image blob.
    /// Returns the preview path, or nil if the data isn't a decodable image.
    static func writeThumbnail(for imageData: Data, hash: String, maxDimension: CGFloat = 600) -> String? {
        guard let image = NSImage(data: imageData) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(size.width, size.height))
        let targetSize = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: targetSize))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = previewsDirectory.appendingPathComponent("\(hash).png")
        do {
            try png.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    /// Remove blob/preview files belonging to deleted clips — but only files
    /// no remaining row points at. Files are content-addressed, so a pinboard
    /// copy and a history row of the same image share one file; deleting the
    /// history row must not break the pinboard copy.
    static func deleteFiles(for clips: [Clip], database: AppDatabase) {
        let candidates = Set(clips.flatMap { [$0.dataPath, $0.previewPath].compactMap { $0 } })
        guard !candidates.isEmpty,
              // If the check fails, keep everything: a stray file is harmless,
              // a missing one breaks a clip.
              let stillUsed = try? database.referencedFilePaths()
        else { return }
        let fm = FileManager.default
        for path in candidates.subtracting(stillUsed) {
            try? fm.removeItem(atPath: path)
        }
    }

    /// Delete files in blobs/ and previews/ that no clip row references:
    /// leftovers from older builds or interrupted writes. Matches on
    /// "folder/file name" only, so a differently spelled support-directory
    /// path can never make a referenced file look unreferenced.
    static func sweepOrphans(database: AppDatabase) {
        guard let referenced = try? database.referencedFilePaths() else { return }
        func key(_ url: URL) -> String {
            url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        }
        let keep = Set(referenced.map { key(URL(fileURLWithPath: $0)) })
        let fm = FileManager.default
        for directory in [blobsDirectory, previewsDirectory] {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where !keep.contains(key(file)) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
