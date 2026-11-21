import AppKit
import Foundation
import UniformTypeIdentifiers

/// Reads the pasteboard, classifies content (fileURL > image > rtf > string),
/// captures the source app, and writes a deduplicated row to the database.
final class IngestPipeline {
    private let database: AppDatabase
    private let settings: AppSettings

    /// Called with each clip captured from the local clipboard (Wi-Fi sync
    /// sends it to paired devices). Runs on the main thread: capture is driven
    /// by the watcher's main-run-loop timer.
    var onCaptured: ((Clip) -> Void)?

    init(database: AppDatabase, settings: AppSettings) {
        self.database = database
        self.settings = settings
        BlobStore.prepare()
    }

    func capture(from pasteboard: NSPasteboard) {
        let source = NSWorkspace.shared.frontmostApplication

        // Rules: never capture from excluded apps.
        if let bundle = source?.bundleIdentifier, settings.excludedBundles.contains(bundle) {
            return
        }

        guard let clip = makeClip(from: pasteboard, source: source) else { return }

        do {
            try database.ingest(clip)
            var evicted = try database.enforceLimit(settings.historyLimit)
            evicted += try database.enforceRetention(seconds: settings.retentionSeconds)
            BlobStore.deleteFiles(for: evicted, database: database)
        } catch {
            NSLog("ClipStack ingest error: \(error)")
            return
        }
        onCaptured?(clip)
    }

    private func makeClip(from pasteboard: NSPasteboard, source: NSRunningApplication?) -> Clip? {
        let now = Date()

        func base(kind: ClipKind, text: String?, hash: String, byteSize: Int) -> Clip {
            Clip(
                id: UUID().uuidString,
                kind: kind,
                textContent: text,
                dataPath: nil,
                previewPath: nil,
                contentHash: hash,
                sourceBundle: source?.bundleIdentifier,
                sourceName: source?.localizedName,
                byteSize: byteSize,
                createdAt: now,
                lastUsedAt: now,
                pinboardId: nil
            )
        }

        // 1. File URLs
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
           !urls.isEmpty
        {
            // A file copy is still a file copy when disabled or oversized —
            // don't fall through and capture its path as text.
            guard settings.captureFiles else { return nil }
            if settings.maxItemBytes > 0, totalFileSize(of: urls) > settings.maxItemBytes {
                return nil
            }
            let paths = urls.map(\.path).joined(separator: "\n")
            return base(
                kind: .file,
                text: paths,
                hash: BlobStore.sha256("file:" + paths),
                byteSize: paths.utf8.count
            )
        }

        // 2. Images
        if settings.captureImages, let imageData = readImageData(from: pasteboard) {
            if settings.maxItemBytes > 0, imageData.data.count > settings.maxItemBytes {
                return nil
            }
            let hash = BlobStore.sha256(imageData.data)
            var clip = base(kind: .image, text: nil, hash: hash, byteSize: imageData.data.count)
            do {
                clip.dataPath = try BlobStore.writeBlob(imageData.data, hash: hash, fileExtension: imageData.fileExtension)
                clip.previewPath = BlobStore.writeThumbnail(for: imageData.data, hash: hash)
                return clip
            } catch {
                NSLog("ClipStack image blob write failed: \(error)")
                return nil
            }
        }

        // 3. Strings (plain, URL, or RTF-backed)
        if let string = pasteboard.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            // Hash the plain text so a rich and plain copy of the same text dedupe.
            let hash = BlobStore.sha256("text:" + string)

            if isWebURL(trimmed) {
                return base(kind: .url, text: trimmed, hash: hash, byteSize: trimmed.utf8.count)
            }

            var clip = base(kind: .text, text: string, hash: hash, byteSize: string.utf8.count)
            if let rtfData = pasteboard.data(forType: .rtf) {
                clip.kind = .rtf
                do {
                    clip.dataPath = try BlobStore.writeBlob(rtfData, hash: hash, fileExtension: "rtf")
                } catch {
                    clip.kind = .text // fall back to plain text on blob failure
                }
            }
            return clip
        }

        return nil
    }

    private func readImageData(from pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        if let png = pasteboard.data(forType: .png) {
            return (png, "png")
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            // Normalize TIFF to PNG for smaller storage and easy previewing.
            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:])
            {
                return (png, "png")
            }
            return (tiff, "tiff")
        }
        return nil
    }

    /// Sum of on-disk sizes for copied files. Directories count their (shallow
    /// enumerated) contents; unreadable entries count as 0 rather than
    /// blocking capture.
    private func totalFileSize(of urls: [URL]) -> Int {
        let fm = FileManager.default
        var total = 0
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for child in contents {
                    total += (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
            } else {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    private func isWebURL(_ string: String) -> Bool {
        guard !string.contains("\n"), !string.contains(" "),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased()
        else { return false }
        return scheme == "http" || scheme == "https"
    }
}
