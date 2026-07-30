import ApplicationServices
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppEnvironment.shared.settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var showClearConfirmation = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("General") {
                KeyboardShortcuts.Recorder("Show clipboard history:", name: .toggleOverlay)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Capture") {
                Toggle("Track copied files", isOn: $settings.captureFiles)
                Toggle("Track copied images", isOn: $settings.captureImages)

                Picker("Skip items larger than:", selection: $settings.maxItemMegabytes) {
                    Text("No limit").tag(0)
                    Text("5 MB").tag(5)
                    Text("10 MB").tag(10)
                    Text("20 MB").tag(20)
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                }
                .disabled(!settings.captureFiles && !settings.captureImages)

                Text("Applies to images and files. Text and links are always captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Picker("Keep history:", selection: $settings.historyLimit) {
                    Text("Unlimited").tag(0)
                    Text("100 items").tag(100)
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                    Text("5,000 items").tag(5000)
                }

                Button("Clear History…", role: .destructive) {
                    showClearConfirmation = true
                }
                .confirmationDialog(
                    "Delete all clipboard history?",
                    isPresented: $showClearConfirmation
                ) {
                    Button("Delete All History", role: .destructive) {
                        AppEnvironment.shared.clearHistory()
                    }
                } message: {
                    Text("This cannot be undone.")
                }
            }

            Section("Permissions") {
                LabeledContent("Direct paste (Accessibility):") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(accessibilityGranted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(accessibilityGranted ? "Enabled" : "Copy-only mode")
                        if !accessibilityGranted {
                            Button("Grant Access") {
                                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                                AXIsProcessTrustedWithOptions(options)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(timer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
