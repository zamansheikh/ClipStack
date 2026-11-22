import AppKit
import SwiftUI

struct MenuContent: View {
    @State private var isPaused = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Clipboard History") {
            AppEnvironment.shared.overlayController.toggle()
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])

        Button(isPaused ? "Resume Capture" : "Pause Capture") {
            isPaused.toggle()
            AppEnvironment.shared.watcher.isPaused = isPaused
        }

        Divider()

        Button("Pair a Phone…") {
            PairingWindow.show()
        }

        Divider()

        Button("Settings…") {
            SettingsWindow.show(using: openSettings)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit ClipStack") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

/// ClipStack lives only in the menu bar (LSUIElement), so it is never the
/// active app by itself: SwiftUI's SettingsLink opens the Settings window
/// *behind* whatever the user is working in (VS Code, Safari…). Activate the
/// app, open the window, then raise it once SwiftUI has created it.
@MainActor
enum SettingsWindow {
    static func show(using openSettings: OpenSettingsAction) {
        NSApp.activate()
        openSettings()
        // SwiftUI creates the window asynchronously on first open.
        raise()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { raise() }
    }

    private static func raise() {
        guard let window = NSApp.windows.first(where: isSettingsWindow) else { return }
        window.makeKeyAndOrderFront(nil)
        // Raises the window even if macOS declined to activate the app.
        window.orderFrontRegardless()
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            || window.title.hasSuffix("Settings")
    }
}
