import SwiftUI

@main
struct ClipStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ClipStack", systemImage: "doc.on.clipboard") {
            MenuContent()
        }

        Settings {
            SettingsView()
        }
    }
}
