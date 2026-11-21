import SwiftUI

struct ClipCardView: View {
    let clip: Clip
    let isSelected: Bool
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private static let cardWidth: CGFloat = 200
    private static let cardHeight: CGFloat = 230

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                    lineWidth: isSelected ? 3 : 1
                )
        )
        .overlay(alignment: .bottomTrailing) {
            if isHovering {
                hoverActions
            }
        }
        // Hit-test, hover, tap and drag exactly the card's visible shape.
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(isSelected ? 0.25 : 0.1), radius: isSelected ? 8 : 4, y: 2)
        .onHover { isHovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(nsImage: AppIconProvider.icon(forBundleIdentifier: clip.sourceBundle))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(clip.sourceName ?? kindLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(clip.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Image(systemName: kindSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            Button(action: onPin) {
                Image(systemName: clip.isPinned ? "pin.slash.fill" : "pin.fill")
                    .font(.caption)
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(clip.isPinned ? "Unpin" : "Pin — pinned clips never expire")

            Button(action: onDelete) {
                Image(systemName: "trash.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Delete this clip")
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        switch clip.kind {
        case .text, .rtf:
            Text(clip.textContent ?? "")
                .font(.callout)
                .lineLimit(9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)

        case .url:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "link")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(clip.textContent ?? "")
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .lineLimit(6)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)

        case .image:
            if let path = clip.previewPath ?? clip.dataPath,
               let image = NSImage(contentsOfFile: path)
            {
                // Color.clear takes exactly the proposed size; overlaying the
                // filled image inside it keeps the oversized image from
                // inflating layout, and .clipped() cuts it to the card.
                // .clipped() only affects drawing, so .contentShape() is what
                // stops the invisible overflow from taking hover and clicks
                // meant for the neighbouring cards.
                Color.clear
                    .overlay(
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipped()
                    .contentShape(Rectangle())
            } else {
                placeholder(symbol: "photo")
            }

        case .file:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(clip.fileURLs.prefix(4), id: \.path) { url in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if clip.fileURLs.count > 4 {
                    Text("+ \(clip.fileURLs.count - 4) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)

        case .color:
            placeholder(symbol: "paintpalette")
        }
    }

    private func placeholder(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var kindLabel: String {
        switch clip.kind {
        case .text: "Text"
        case .rtf: "Rich Text"
        case .url: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }

    private var kindSymbol: String {
        switch clip.kind {
        case .text: "text.alignleft"
        case .rtf: "textformat"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }
}
