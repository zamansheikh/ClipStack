import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// What the pairing sheet is showing.
enum PairingState: Equatable {
    /// The listener is coming up; no code yet.
    case starting
    case waiting(link: String, expiresAt: Date?)
    case expired
    case paired(name: String)
}

/// "Pair a Device" sheet: opens a pairing window on appear, shows its link
/// as a QR code, and closes the window on disappear.
struct PairingSheet: View {
    @ObservedObject var sync: SyncService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PairingContent(
            state: state,
            onCopyLink: copyLink,
            onRenew: { sync.openPairingWindow() },
            onClose: { dismiss() }
        )
        .onAppear { sync.openPairingWindow() }
        .onDisappear { sync.closePairingWindow() }
    }

    private var state: PairingState {
        if let name = sync.justPairedName { return .paired(name: name) }
        if let link = sync.pairingLink { return .waiting(link: link, expiresAt: sync.pairingExpiresAt) }
        if sync.isPairingOpen { return .starting }
        return .expired
    }

    /// The link holds a secret token: mark the copy so ClipStack doesn't
    /// record it (or send it to other devices), and flag it as concealed for
    /// other clipboard managers.
    private func copyLink(_ link: String) {
        let pasteboard = AppPasteboard.shared
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        pasteboard.setString("1", forType: ClipboardWatcher.selfWriteType)
        pasteboard.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}

/// The sheet's look, driven only by `state` so every state can be rendered
/// by the DEBUG snapshot hook without a live pairing window.
struct PairingContent: View {
    let state: PairingState
    var onCopyLink: (String) -> Void = { _ in }
    var onRenew: () -> Void = {}
    var onClose: () -> Void = {}

    @State private var linkCopied = false

    /// Pairing and success bodies share a height so the sheet doesn't jump
    /// when the phone connects.
    private static let bodyHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if case .paired(let name) = state {
                    success(name: name)
                } else {
                    pairing
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.bodyHeight)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 520)
    }

    // MARK: Pairing

    private var pairing: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text("Pair a Device")
                    .font(.title2.weight(.semibold))
                Text("Scan this code with ClipStack on your phone.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 24) {
                codeCard

                VStack(alignment: .leading, spacing: 14) {
                    StepRow(number: 1, text: "Install ClipStack on your phone")
                    StepRow(number: 2, text: "Open it and tap **Scan pairing code**")
                    StepRow(number: 3, text: "Point the camera at this code")
                    statusLine
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// White card holding the QR code (or what stands in for it).
    private var codeCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                )

            switch state {
            case .waiting(let link, _):
                QRCodeView(text: link, side: 188)
            case .starting:
                ProgressView()
                    .controlSize(.large)
                    .colorScheme(.light)
            case .expired:
                VStack(spacing: 10) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Code expired")
                        .font(.headline)
                    Button("Show New Code", action: onRenew)
                }
                .colorScheme(.light)
            case .paired:
                EmptyView()
            }
        }
        .frame(width: 212, height: 212)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .waiting(_, let expiresAt):
            HStack(alignment: .top, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for your phone…")
                    if let expiresAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Code expires in \(Self.countdown(to: expiresAt, now: context.date))")
                                .monospacedDigit()
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        case .starting:
            Text("Preparing a code…")
                .foregroundStyle(.secondary)
        case .expired:
            Text("Codes work once and expire after 5 minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .paired:
            EmptyView()
        }
    }

    // MARK: Success

    private func success(name: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
            Text("Paired with \(name)")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Copy on either device and paste on the other. They reconnect on their own whenever both are on this Wi-Fi.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if case .waiting(let link, _) = state {
                Button {
                    onCopyLink(link)
                    linkCopied = true
                } label: {
                    Label(
                        linkCopied ? "Pairing link copied" : "Can't scan? Copy pairing link",
                        systemImage: linkCopied ? "checkmark" : "link"
                    )
                }
                .buttonStyle(.link)
                .help("Paste the link into ClipStack on a device without a camera.")
            }
            Spacer()
            if case .paired = state {
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    /// "4:07" for a code that expires in four minutes seven seconds.
    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A QR code drawn with whole device pixels per module, pre-scaled with
/// nearest-neighbour sampling: stretching a tiny bitmap to an arbitrary size
/// makes modules uneven or blurry, which looks cheap and scans worse.
struct QRCodeView: View {
    let text: String
    /// Largest side to fill, in points.
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // At least 2× so the code stays sharp when a 1× context (or a
        // snapshot) upscales it.
        let scale = max(displayScale, 2)
        if let qr = QRCode.image(for: text, side: side, scale: scale) {
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: qr.size.width, height: qr.size.height)
                .accessibilityLabel("Pairing QR code")
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
        }
    }
}

enum QRCode {
    /// QR code (quiet zone included) as large as fits in `side` points with a
    /// whole number of `scale` pixels per module. The image's size is in
    /// points, so it draws 1:1 without resampling.
    static func image(for string: String, side: CGFloat, scale: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let modules = output.extent.width
        let pixelsPerModule = max(1, (side * scale / modules).rounded(.down))
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        let points = modules * pixelsPerModule / scale
        return NSImage(cgImage: cgImage, size: NSSize(width: points, height: points))
    }
}
