import SwiftUI

enum SettingsMetrics {
    /// One width for every tab, so switching tabs only changes the height.
    static let width: CGFloat = 540
}

/// One Settings tab: a grouped form exactly as tall as its content. Tabs
/// keep each page well under a laptop screen's height; a single long form
/// used to grow taller than the display and couldn't be resized.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: SettingsMetrics.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A white SF Symbol on a tinted rounded square — the System Settings idiom
/// for "this row is a thing" (a device, a feature).
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Small status capsule: coloured dot + label on a faint tint.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// "1  Install ClipStack on your phone" — a numbered instruction.
struct StepRow: View {
    let number: Int
    /// Markdown allowed, e.g. bold for the name of a button to tap.
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
                // Centre the circle on the label's first line, not its baseline.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
