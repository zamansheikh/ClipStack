import SwiftUI

struct MenuContent: View {
    @State private var isPaused = false

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

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit ClipStack") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
