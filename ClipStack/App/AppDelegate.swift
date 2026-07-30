import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.shared
        environment.start()

        if !environment.settings.hasCompletedOnboarding {
            environment.settings.hasCompletedOnboarding = true
            runAccessibilityOnboarding()
        }
    }

    /// First-run flow: explain why we need Accessibility, with a copy-only skip path.
    private func runAccessibilityOnboarding() {
        guard !AXIsProcessTrusted() else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enable Direct Paste?"
        alert.informativeText = """
        ClipStack can paste items straight into the app you're working in (press ⌘⇧V, pick an item, hit Return).

        That requires the Accessibility permission, which macOS will ask you to grant in System Settings.

        You can skip this — ClipStack still records history and copies items to the clipboard, you just press ⌘V yourself.
        """
        alert.addButton(withTitle: "Enable Direct Paste")
        alert.addButton(withTitle: "Skip — Copy-Only Mode")

        if alert.runModal() == .alertFirstButtonReturn {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }
}
