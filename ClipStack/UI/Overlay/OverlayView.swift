import SwiftUI

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            topBar
            if let previewClip = viewModel.previewClip {
                ClipPreviewPane(clip: previewClip)
            } else {
                cardRow
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .onAppear { searchFocused = true }
        .onChange(of: viewModel.focusToken) {
            searchFocused = true
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard history…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Picker("Filter", selection: $viewModel.filter) {
                ForEach(ClipFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

            Spacer()

            Text("↩ paste · ⇧↩ plain · space preview · ⌘P pin · ⌘C copy · esc close")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var cardRow: some View {
        Group {
            if viewModel.filteredClips.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(viewModel.filteredClips.enumerated()), id: \.element.id) { index, clip in
                                ClipCardView(
                                    clip: clip,
                                    isSelected: index == viewModel.selectedIndex,
                                    onPin: { viewModel.togglePin(clip) },
                                    onDelete: { viewModel.delete(clip) }
                                )
                                    .id(clip.id)
                                    .onTapGesture(count: 2) {
                                        viewModel.paste(clip)
                                    }
                                    .onTapGesture {
                                        viewModel.selectedIndex = index
                                    }
                                    .onDrag { dragItem(for: clip) }
                                    .contextMenu {
                                        Button("Paste") { viewModel.paste(clip) }
                                        Button("Paste as Plain Text") { viewModel.paste(clip, plainText: true) }
                                        Button("Copy") { viewModel.copy(clip) }
                                        Divider()
                                        Button(clip.isPinned ? "Unpin" : "Pin") { viewModel.togglePin(clip) }
                                        Divider()
                                        Button("Delete", role: .destructive) { viewModel.delete(clip) }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if index < 9 {
                                            Text("⌘\(index + 1)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .padding(4)
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: viewModel.selectedIndex) {
                        if let clip = viewModel.selectedClip {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(clip.id)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(viewModel.searchText.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(viewModel.searchText.isEmpty
                 ? "Copy something and it will show up here."
                 : "Try a different search or filter.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dragItem(for clip: Clip) -> NSItemProvider {
        switch clip.kind {
        case .image, .file:
            if let url = clip.kind == .image
                ? clip.dataPath.map({ URL(fileURLWithPath: $0) })
                : clip.fileURLs.first
            {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider()
        default:
            return NSItemProvider(object: (clip.textContent ?? "") as NSString)
        }
    }
}

/// Large preview shown when pressing Space on a card (arrows still navigate,
/// Return pastes, Space/Esc closes).
struct ClipPreviewPane: View {
    let clip: Clip

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            metadata
                .frame(width: 180)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch clip.kind {
        case .text, .rtf, .url, .color:
            ScrollView {
                Text(clip.textContent ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        case .image:
            if let path = clip.dataPath ?? clip.previewPath,
               let image = NSImage(contentsOfFile: path)
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(clip.fileURLs, id: \.path) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 32, height: 32)
                            Text(url.path)
                                .font(.callout)
                                .textSelection(.enabled)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(nsImage: AppIconProvider.icon(forBundleIdentifier: clip.sourceBundle))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(clip.sourceName ?? "Unknown app")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            if clip.isPinned {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Copied") {
                Text(clip.createdAt, format: .relative(presentation: .named))
            }
            LabeledContent("Size") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clip.byteSize), countStyle: .file))
            }
            LabeledContent("Type") {
                Text(clip.kind.rawValue.capitalized)
            }
            Spacer()
            Text("space or esc to go back")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.vertical, 4)
    }
}
