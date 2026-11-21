import ApplicationServices
import Combine
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

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, devices, capture, history

    var id: String { rawValue }
}

/// The Settings window. SwiftUI shows a TabView in a Settings scene as the
/// native toolbar tabs; each tab sizes the window to its own height.
struct SettingsView: View {
    @ObservedObject private var settings = AppEnvironment.shared.settings
    @ObservedObject private var sync = AppEnvironment.shared.sync
    @State private var showPairingSheet = false

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }

            DevicesSettingsPane(
                isEnabled: $settings.syncEnabled,
                isListening: sync.isRunning && sync.port != nil,
                macName: SyncIdentity.deviceName,
                devices: sync.pairedDevices,
                onlineIds: sync.onlineDeviceIds,
                onPair: { showPairingSheet = true },
                onRemove: { sync.removeDevice(id: $0.id) }
            )
            .sheet(isPresented: $showPairingSheet) {
                PairingSheet(sync: sync)
            }
            .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }

            CaptureSettingsPane(settings: settings)
                .tabItem { Label("Capture", systemImage: "doc.on.clipboard") }

            HistorySettingsPane(settings: settings)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = AXIsProcessTrusted()

    /// Both permissions change outside the app (System Settings), so poll.
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        SettingsPage {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ClipStack")
                            .font(.title2.weight(.semibold))
                        Text("Your clipboard history, on every device.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text("Version \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Show clipboard history") {
                    KeyboardShortcuts.Recorder(for: .toggleOverlay)
                }
                Toggle("Open at login", isOn: $launchAtLogin)
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

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        StatusPill(
                            text: accessibilityGranted ? "Enabled" : "Not enabled",
                            color: accessibilityGranted ? .green : .orange
                        )
                        if !accessibilityGranted {
                            Button("Grant Access…") {
                                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                                AXIsProcessTrustedWithOptions(options)
                            }
                        }
                    }
                } label: {
                    Text("Direct paste")
                    Text(accessibilityGranted
                         ? "Picking a clip pastes it straight into the app you're using."
                         : "Without it, picking a clip copies it and you press ⌘V yourself.")
                }
            } header: {
                Text("Permissions")
            } footer: {
                if !accessibilityGranted {
                    // macOS keys the permission to the app's signature; after
                    // an update with a different signature the old switch
                    // stays ON but no longer applies to this copy.
                    Text("Already switched on in System Settings? That entry belongs to an older copy of ClipStack: select it there, remove it with −, then click Grant Access and switch it on again.")
                }
            }
        }
        .onReceive(timer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Capture

struct CaptureSettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            Section {
                Toggle("Files copied in Finder", isOn: $settings.captureFiles)
                Toggle("Images", isOn: $settings.captureImages)
                Picker("Skip items larger than", selection: $settings.maxItemMegabytes) {
                    Text("No limit").tag(0)
                    Text("5 MB").tag(5)
                    Text("10 MB").tag(10)
                    Text("20 MB").tag(20)
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                }
                .disabled(!settings.captureFiles && !settings.captureImages)
            } header: {
                Text("What to Record")
            } footer: {
                Text("Text and links are always recorded. The size limit applies to images and files.")
            }

            Section {
                if settings.excludedBundles.isEmpty {
                    Label {
                        Text("No excluded apps — copies from every app are recorded.")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "hand.raised")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(settings.excludedBundles, id: \.self) { bundle in
                    HStack(spacing: 10) {
                        Image(nsImage: AppIconProvider.icon(forBundleIdentifier: bundle))
                            .resizable()
                            .frame(width: 22, height: 22)
                        Text(Self.displayName(forBundle: bundle))
                        Spacer()
                        Button {
                            settings.excludedBundles.removeAll { $0 == bundle }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Record copies from this app again")
                    }
                }
                Menu {
                    ForEach(runningApps, id: \.bundle) { app in
                        Button(app.name) {
                            settings.excludedBundles.append(app.bundle)
                        }
                    }
                } label: {
                    Label("Exclude a Running App…", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } header: {
                Text("Excluded Apps")
            } footer: {
                Text("Copies made in these apps are never recorded. Password-manager copies are always skipped.")
            }
        }
    }

    static func displayName(forBundle bundle: String) -> String {
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

// MARK: - History

struct HistorySettingsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var showClearConfirmation = false
    @State private var pendingClearCategory: ClipCategory?

    var body: some View {
        SettingsPage {
            Section {
                Picker("History size", selection: $settings.historyLimit) {
                    Text("Unlimited").tag(0)
                    Text("100 clips").tag(100)
                    Text("500 clips").tag(500)
                    Text("1,000 clips").tag(1000)
                    Text("5,000 clips").tag(5000)
                }
                Picker("Delete clips after", selection: $settings.retentionSeconds) {
                    Text("Never").tag(0)
                    Text("1 hour").tag(3600)
                    Text("6 hours").tag(21600)
                    Text("24 hours").tag(86400)
                    Text("3 days").tag(259200)
                    Text("1 week").tag(604800)
                    Text("1 month").tag(2592000)
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("Pinned clips and pinboards are never deleted automatically.")
            }

            Section {
                LabeledContent {
                    Button("Clear History…", role: .destructive) {
                        showClearConfirmation = true
                    }
                } label: {
                    Text("Clear history")
                    Text("Deletes every clip except pinned ones.")
                }
                LabeledContent {
                    Menu("Choose…") {
                        ForEach(ClipCategory.allCases) { category in
                            Button(category.rawValue) { pendingClearCategory = category }
                        }
                    }
                    .fixedSize()
                } label: {
                    Text("Clear one kind")
                    Text("Only text, links, images or files.")
                }
            } header: {
                Text("Clear")
            } footer: {
                Text("Clearing can't be undone.")
            }
        }
        .confirmationDialog("Delete all clipboard history?", isPresented: $showClearConfirmation) {
            Button("Delete All History", role: .destructive) {
                AppEnvironment.shared.clearHistory()
            }
        } message: {
            Text("Pinned clips are kept. This cannot be undone.")
        }
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
