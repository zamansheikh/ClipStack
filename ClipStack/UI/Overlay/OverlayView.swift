import SwiftUI

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            topBar
            tabBar
            if let previewClip = viewModel.previewClip {
                ClipPreviewPane(clip: previewClip, viewModel: viewModel)
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

            Text("↩ paste · ⇧↩ plain · space preview · ⌘P pin · ⌘click multi-select · ⇥ tabs")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabChip(.history, label: "History", systemImage: "clock")
            tabChip(.pinned, label: "Pinned", systemImage: "pin")
            ForEach(viewModel.pinboards) { board in
                tabChip(.board(board.id), label: board.name, systemImage: "square.grid.2x2")
                    .contextMenu {
                        Button("Rename…") { viewModel.renamePinboard(board) }
                        Button("Move Left") { viewModel.movePinboard(board, direction: -1) }
                        Button("Move Right") { viewModel.movePinboard(board, direction: 1) }
                        Divider()
                        Button("Delete Pinboard", role: .destructive) {
                            viewModel.deletePinboard(board)
                        }
                    }
            }
            Button {
                viewModel.createPinboard()
            } label: {
                Image(systemName: "plus")
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .help("New pinboard")

            Spacer()

            if !viewModel.stack.isEmpty {
                Text("\(viewModel.stack.count) in paste stack — ↩ pastes all in order")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") { viewModel.clearStack() }
                    .font(.caption)
            }
        }
    }

    private func tabChip(_ tab: OverlayTab, label: String, systemImage: String) -> some View {
        Button {
            viewModel.tab = tab
        } label: {
            Label(label, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    viewModel.tab == tab ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
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
                                        if NSEvent.modifierFlags.contains(.command) {
                                            viewModel.toggleStack(clip)
                                        } else {
                                            viewModel.selectedIndex = index
                                        }
                                    }
                                    .onDrag { dragItem(for: clip) }
                                    .contextMenu {
                                        Button("Paste") { viewModel.paste(clip) }
                                        Button("Paste as Plain Text") { viewModel.paste(clip, plainText: true) }
                                        Button("Copy") { viewModel.copy(clip) }
                                        Divider()
                                        Button(clip.isPinned ? "Unpin" : "Pin") { viewModel.togglePin(clip) }
                                        Menu("Move to Pinboard") {
                                            ForEach(viewModel.pinboards) { board in
                                                Button(board.name) { viewModel.assign(clip, toBoard: board.id) }
                                            }
                                            if !viewModel.pinboards.isEmpty { Divider() }
                                            Button("New Pinboard…") { viewModel.createPinboard(assigning: clip) }
                                        }
                                        if clip.pinboardId != nil {
                                            Button("Remove from Pinboard") { viewModel.assign(clip, toBoard: nil) }
                                        }
                                        Divider()
                                        Button(viewModel.stackIndex(of: clip) == nil
                                               ? "Add to Paste Stack" : "Remove from Paste Stack") {
                                            viewModel.toggleStack(clip)
                                        }
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
                                    .overlay(alignment: .topLeading) {
                                        if let stackNumber = viewModel.stackIndex(of: clip) {
                                            Text("\(stackNumber)")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.white)
                                                .frame(width: 18, height: 18)
                                                .background(Color.accentColor, in: Circle())
                                                .padding(5)
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
            Text(emptyTitle)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(emptyHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !viewModel.searchText.isEmpty { return "No matches" }
        switch viewModel.tab {
        case .history: return "Nothing copied yet"
        case .pinned: return "No pinned clips"
        case .board: return "This pinboard is empty"
        }
    }

    private var emptyHint: String {
        if !viewModel.searchText.isEmpty { return "Try a different search or filter." }
        switch viewModel.tab {
        case .history: return "Copy something and it will show up here."
        case .pinned: return "Pin a clip with ⌘P or its hover pin button."
        case .board: return "Right-click a clip → Move to Pinboard."
        }
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
/// Return pastes, Space/Esc closes). Text clips can be edited in place.
struct ClipPreviewPane: View {
    let clip: Clip
    @ObservedObject var viewModel: OverlayViewModel
    @State private var draft = ""

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

    private var isTextEditable: Bool {
        clip.kind == .text || clip.kind == .rtf
    }

    @ViewBuilder
    private var previewContent: some View {
        switch clip.kind {
        case .text, .rtf, .url, .color:
            if isTextEditable, viewModel.isEditingPreview {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                ScrollView {
                    Text(clip.textContent ?? "")
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
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
                Text(clip.lastUsedAt, format: .relative(presentation: .named))
            }
            LabeledContent("Size") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clip.byteSize), countStyle: .file))
            }
            LabeledContent("Type") {
                Text(clip.kind.rawValue.capitalized)
            }
            Spacer()
            if viewModel.isEditingPreview {
                HStack {
                    Button("Cancel") {
                        viewModel.isEditingPreview = false
                    }
                    Button("Save") {
                        viewModel.saveEditedText(draft)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("edited text pastes with ↩")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                if isTextEditable {
                    Button("Edit Text") {
                        draft = clip.textContent ?? ""
                        viewModel.isEditingPreview = true
                    }
                }
                Text("space or esc to go back")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.vertical, 4)
    }
}
