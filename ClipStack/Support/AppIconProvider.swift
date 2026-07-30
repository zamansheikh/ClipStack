import AppKit

/// Resolves and caches source-app icons by bundle identifier.
@MainActor
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleIdentifier bundleID: String?) -> NSImage {
        guard let bundleID, !bundleID.isEmpty else { return genericIcon }
        if let cached = cache[bundleID] { return cached }

        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = genericIcon
        }
        cache[bundleID] = icon
        return icon
    }

    private static var genericIcon: NSImage {
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            ?? NSImage()
    }
}
