import SwiftUI

/// Settings → Devices: the Wi-Fi sharing switch, this Mac, paired devices and
/// the way into pairing. Takes plain values rather than the SyncService so
/// every state (empty, connected, sharing off) can be rendered in previews
/// and the DEBUG snapshot hook.
struct DevicesSettingsPane: View {
    @Binding var isEnabled: Bool
    /// The listener has a port, so devices can connect and pairing can start.
    let isListening: Bool
    let macName: String
    let devices: [PairedDevice]
    let onlineIds: Set<String>
    var onPair: () -> Void = {}
    var onRemove: (PairedDevice) -> Void = { _ in }

    @State private var pendingRemoval: PairedDevice?

    var body: some View {
        SettingsPage {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: "wifi", tint: .blue, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share clipboard over Wi-Fi")
                            .font(.headline)
                        Text("Copy on one device, paste on another.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("Share clipboard over Wi-Fi", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 4)

                if isEnabled {
                    DeviceRow(
                        symbol: "laptopcomputer",
                        tint: .gray,
                        name: macName,
                        status: isListening ? "This Mac · ready for your devices" : "This Mac · starting…",
                        isOnline: isListening
                    ) { EmptyView() }
                }
            } footer: {
                Text("Clips go straight from device to device on this network, end-to-end encrypted. Nothing passes through a server, and password-manager copies are never shared.")
            }

            if isEnabled {
                Section {
                    if devices.isEmpty {
                        emptyState
                    }
                    ForEach(devices) { device in
                        let online = onlineIds.contains(device.id)
                        DeviceRow(
                            symbol: device.symbolName,
                            tint: device.tint,
                            name: device.name,
                            status: Self.status(of: device, online: online),
                            isOnline: online
                        ) {
                            Button("Remove…") { pendingRemoval = device }
                        }
                    }
                } header: {
                    Text("Paired Devices")
                }

                if !devices.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add a phone or computer")
                            Text("Shows a code to scan with ClipStack on the other device.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Pair a Device…", action: onPair)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!isListening)
                    }
                    .padding(.vertical, 2)
                }
                }
            } else if !devices.isEmpty {
                Section {
                    Label {
                        Text(devices.count == 1
                             ? "Your paired device reconnects as soon as you turn sharing back on."
                             : "Your \(devices.count) paired devices reconnect as soon as you turn sharing back on.")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "pause.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this device")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { device in
            Button("Remove", role: .destructive) { onRemove(device) }
        } message: { _ in
            Text("It stops sharing clipboards with this Mac. You can pair it again any time.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text("No devices yet")
                .font(.headline)
            Text("Pair your phone to copy on one device and paste on the other.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Pair a Device…", action: onPair)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isListening)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    /// "Connected", "Last seen 5 minutes ago", or "Not connected yet".
    static func status(of device: PairedDevice, online: Bool, now: Date = Date()) -> String {
        if online { return "Connected" }
        guard let seen = device.lastSeenAt else { return "Not connected yet" }
        if now.timeIntervalSince(seen) < 60 { return "Last seen just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last seen \(formatter.localizedString(for: seen, relativeTo: now))"
    }
}

/// A device in the list: tinted platform tile, name, status line, and an
/// optional trailing control.
struct DeviceRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let name: String
    let status: String
    let isOnline: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOnline ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 2)
    }
}

extension PairedDevice {
    /// Tile colour per platform, so a list of devices reads at a glance.
    var tint: Color {
        switch platform {
        case "android": return .green
        case "ios": return .blue
        case "macos": return .gray
        case "windows": return .teal
        case "linux": return .orange
        default: return .secondary
        }
    }
}
