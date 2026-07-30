import SwiftUI

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            topBar
            cardRow
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

            Text("↩ paste · ⇧↩ plain · ⌘C copy · esc close")
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
                                ClipCardView(clip: clip, isSelected: index == viewModel.selectedIndex)
                                    .id(clip.id)
                                    .onTapGesture(count: 2) {
                                        viewModel.paste(clip)
                                    }
                                    .onTapGesture {
                                        viewModel.selectedIndex = index
                                    }
                                    .onDrag { dragItem(for: clip) }
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
