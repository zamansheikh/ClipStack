#if DEBUG
import AppKit
import SwiftUI

/// DEBUG-only visual check for the Settings window. With
/// CLIPSTACK_SNAPSHOT_DIR set, ClipStack renders every Settings tab and every
/// pairing-sheet state, in light and dark mode, to PNGs in that directory and
/// quits — before the clipboard watcher or sync start. Pair it with
/// CLIPSTACK_SUPPORT_DIR so the panes read test data, not the real history.
///
/// Uses an offscreen NSWindow + cacheDisplay rather than ImageRenderer,
/// which can't draw AppKit-backed controls (switches, pickers, recorders).
@MainActor
enum SettingsSnapshots {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CLIPSTACK_SNAPSHOT_DIR"], !path.isEmpty else {
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let environment = AppEnvironment.shared
        let devices = environment.sync.pairedDevices
        // Show the first device as connected so both row styles are visible.
        let online = Set(devices.prefix(1).map(\.id))
        let link = "clipstack://pair?v=1&id=00000000-0000-4000-8000-000000000000&name=Snapshot%20Mac&pf=macos"
            + "&pk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&token=AAAAAAAAAAAAAAAAAAAAAA&port=47474&hosts=192.168.68.53"

        let views: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettingsPane())),
            ("devices", AnyView(DevicesSettingsPane(
                isEnabled: .constant(true), isListening: true, macName: SyncIdentity.deviceName,
                devices: devices, onlineIds: online))),
            ("devices-empty", AnyView(DevicesSettingsPane(
                isEnabled: .constant(true), isListening: true, macName: SyncIdentity.deviceName,
                devices: [], onlineIds: []))),
            ("devices-off", AnyView(DevicesSettingsPane(
                isEnabled: .constant(false), isListening: false, macName: SyncIdentity.deviceName,
                devices: devices, onlineIds: []))),
            ("capture", AnyView(CaptureSettingsPane(settings: environment.settings))),
            ("history", AnyView(HistorySettingsPane(settings: environment.settings))),
            ("pairing-waiting", AnyView(PairingContent(
                state: .waiting(link: link, expiresAt: Date().addingTimeInterval(272))))),
            ("pairing-starting", AnyView(PairingContent(state: .starting))),
            ("pairing-expired", AnyView(PairingContent(state: .expired))),
            ("pairing-paired", AnyView(PairingContent(state: .paired(name: "Pixel 6")))),
        ]

        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, view) in views {
                render(view, appearance: NSAppearance(named: appearance)!,
                       to: directory.appendingPathComponent("\(name)-\(appearanceName).png"))
            }
        }
        NSLog("ClipStack: wrote Settings snapshots to \(directory.path)")
        exit(0)
    }

    private static func render(_ view: AnyView, appearance: NSAppearance, to url: URL) {
        // A sheet's window background isn't part of its view tree; paint it so
        // light and dark snapshots look like the real thing.
        let hosting = NSHostingView(rootView: AnyView(
            view
                .environment(\.controlActiveState, .key)
                .background(Color(nsColor: .windowBackgroundColor))
        ))
        hosting.appearance = appearance
        let window = SnapshotWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = hosting
        let size = hosting.fittingSize
        window.setContentSize(size)
        // Ordered in (far off screen) so AppKit-backed controls get a real
        // layout and draw pass, then give SwiftUI a moment to settle.
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

/// Claims to be key so controls draw in their active colours (accent-blue
/// switches and prominent buttons) without activating the app and stealing
/// focus from whatever the developer is doing.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
#endif
