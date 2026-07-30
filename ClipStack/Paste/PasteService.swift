import AppKit
import ApplicationServices
import Foundation

/// Writes a clip back to the pasteboard and synthesizes ⌘V into the frontmost
/// app (requires Accessibility permission). Falls back to copy-only.
@MainActor
final class PasteService {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    var canDirectPaste: Bool {
        AXIsProcessTrusted()
    }

    /// Copy the clip to the pasteboard without pasting.
    func copy(_ clip: Clip, plainText: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch clip.kind {
        case .text, .url, .color:
            pasteboard.setString(clip.textContent ?? "", forType: .string)

        case .rtf:
            if !plainText,
               let path = clip.dataPath,
               let rtfData = try? Data(contentsOf: URL(fileURLWithPath: path))
            {
                pasteboard.setData(rtfData, forType: .rtf)
            }
            pasteboard.setString(clip.textContent ?? "", forType: .string)

        case .image:
            if let path = clip.dataPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            {
                let type: NSPasteboard.PasteboardType = path.hasSuffix(".tiff") ? .tiff : .png
                pasteboard.setData(data, forType: type)
            }

        case .file:
            let urls = clip.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls as [NSURL])
            }
        }

        // Mark as our own write so ClipboardWatcher doesn't re-ingest it.
        pasteboard.setString("1", forType: ClipboardWatcher.selfWriteType)

        try? database.bumpLastUsed(id: clip.id)
    }

    /// Copy, then synthesize ⌘V into the frontmost app. The overlay must be
    /// hidden before calling so the target app is key again.
    func paste(_ clip: Clip, plainText: Bool = false) {
        copy(clip, plainText: plainText)

        guard canDirectPaste else { return }

        // Small delay so the overlay panel has fully resigned key and the
        // target app receives the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.sendCmdV()
        }
    }

    private static func sendCmdV() {
        let vKeyCode: CGKeyCode = 9
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
