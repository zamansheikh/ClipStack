import AppKit

/// Resolves and caches source-app icons by bundle identifier.
@MainActor
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    /// Clips received over Wi-Fi sync have no source app. They carry
    /// "clipstack.device.<platform>" as their source bundle instead and get a
    /// drawn device badge (phone, laptop…) rather than a blank placeholder.
    nonisolated static let deviceBundlePrefix = "clipstack.device."

    nonisolated static func deviceBundle(forPlatform platform: String) -> String {
        deviceBundlePrefix + platform
    }

    static func icon(forBundleIdentifier bundleID: String?) -> NSImage {
        guard let bundleID, !bundleID.isEmpty else { return genericIcon }
        if let cached = cache[bundleID] { return cached }

        let icon: NSImage
        if bundleID.hasPrefix(deviceBundlePrefix) {
            icon = deviceIcon(platform: String(bundleID.dropFirst(deviceBundlePrefix.count)))
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
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

    /// An app-icon-like badge: the ClipStack gradient in a rounded square with
    /// the device's SF Symbol in white, so synced clips read as "from my phone".
    private static func deviceIcon(platform: String) -> NSImage {
        let candidates: [String] = switch platform {
        case "android": ["smartphone", "iphone"]
        case "ios": ["iphone"]
        case "macos": ["laptopcomputer"]
        case "windows": ["pc", "desktopcomputer"]
        case "linux": ["desktopcomputer"]
        default: ["display"]
        }
        let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let glyph = candidates.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            .first?
            .withSymbolConfiguration(config)

        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            // Same inset and gradient family as the app icons drawn next to it.
            let badge = NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: 14, yRadius: 14)
            NSGradient(
                starting: NSColor(srgbRed: 0.55, green: 0.70, blue: 0.98, alpha: 1),
                ending: NSColor(srgbRed: 0.58, green: 0.40, blue: 0.92, alpha: 1)
            )?.draw(in: badge, angle: -75)
            if let glyph {
                let size = glyph.size
                glyph.draw(in: NSRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ))
            }
            return true
        }
    }
}
