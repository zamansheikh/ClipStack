import ApplicationServices
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Categories offered by "Clear by Category" — user-facing groupings of ClipKind.
enum ClipCategory: String, CaseIterable, Identifiable {
    case text = "Text"
    case links = "Links"
    case images = "Images"
    case files = "Files"

    var id: String { rawValue }

    var kinds: [ClipKind] {
        switch self {
        case .text: return [.text, .rtf]
        case .links: return [.url]
        case .images: return [.image]
        case .files: return [.file]
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppEnvironment.shared.settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var showClearConfirmation = false
    @State private var pendingClearCategory: ClipCategory?

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

                Picker("Delete items after:", selection: $settings.retentionSeconds) {
                    Text("Never").tag(0)
                    Text("1 hour").tag(3600)
                    Text("6 hours").tag(21600)
                    Text("24 hours").tag(86400)
                    Text("3 days").tag(259200)
                    Text("1 week").tag(604800)
                    Text("1 month").tag(2592000)
                }

                Text("Pinned clips never expire and are kept when clearing history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
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
                        Text("Pinned clips are kept. This cannot be undone.")
                    }

                    Menu("Clear by Category…") {
                        ForEach(ClipCategory.allCases) { category in
                            Button(category.rawValue) {
                                pendingClearCategory = category
                            }
                        }
                    }
                    .fixedSize()
                    .confirmationDialog(
                        "Delete all \(pendingClearCategory?.rawValue.lowercased() ?? "") clips?",
                        isPresented: Binding(
                            get: { pendingClearCategory != nil },
                            set: { if !$0 { pendingClearCategory = nil } }
                        ),
                        presenting: pendingClearCategory
                    ) { category in
                        Button("Delete All \(category.rawValue)", role: .destructive) {
                            AppEnvironment.shared.clearHistory(kinds: category.kinds)
                        }
                    } message: { _ in
                        Text("Pinned clips are kept. This cannot be undone.")
                    }
                }
            }

            Section("Excluded Apps") {
                if settings.excludedBundles.isEmpty {
                    Text("Copies from excluded apps are never recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.excludedBundles, id: \.self) { bundle in
                    HStack {
                        Image(nsImage: AppIconProvider.icon(forBundleIdentifier: bundle))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(displayName(forBundle: bundle))
                        Spacer()
                        Button {
                            settings.excludedBundles.removeAll { $0 == bundle }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Menu("Exclude a Running App…") {
                    ForEach(runningApps, id: \.bundle) { app in
                        Button(app.name) {
                            settings.excludedBundles.append(app.bundle)
                        }
                    }
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

    private func displayName(forBundle bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundle
    }

    /// Currently running regular apps not yet excluded, for the picker menu.
    private var runningApps: [(name: String, bundle: String)] {
        var seen = Set<String>(settings.excludedBundles)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundle: String)? in
                guard let bundle = app.bundleIdentifier, seen.insert(bundle).inserted else { return nil }
                return (app.localizedName ?? bundle, bundle)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
