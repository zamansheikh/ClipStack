import AppKit
import Combine
import Foundation

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case pinned = "Pinned"
    case text = "Text"
    case links = "Links"
    case images = "Images"
    case files = "Files"

    var id: String { rawValue }

    func matches(_ clip: Clip) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return clip.isPinned
        case .text: return clip.kind == .text || clip.kind == .rtf
        case .links: return clip.kind == .url
        case .images: return clip.kind == .image
        case .files: return clip.kind == .file
        }
    }
}

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var filter: ClipFilter = .all
    @Published var selectedIndex = 0
    /// Bumped every time the overlay is shown, to re-focus the search field.
    @Published var focusToken = 0
    /// Non-nil while the large Space preview is open.
    @Published var previewClip: Clip?
    /// True while the preview's text editor is active (keyboard nav suspended).
    @Published var isEditingPreview = false
    /// FTS results for the current search; nil when not searching.
    @Published private(set) var searchResults: [Clip]?

    let clipStore: ClipStore
    private let pasteService: PasteService
    private let database: AppDatabase
    /// Set by the panel controller; called before pasting so the overlay hides
    /// and the target app becomes key again.
    var requestHide: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []

    init(clipStore: ClipStore, pasteService: PasteService, database: AppDatabase) {
        self.clipStore = clipStore
        self.pasteService = pasteService
        self.database = database

        clipStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        $searchText
            .removeDuplicates()
            .sink { [weak self] text in
                self?.selectedIndex = 0
                self?.runSearch(text)
            }
            .store(in: &cancellables)
        $filter
            .sink { [weak self] _ in self?.selectedIndex = 0 }
            .store(in: &cancellables)
    }

    var filteredClips: [Clip] {
        let base: [Clip]
        if let searchResults {
            // FTS results span the whole database, not just the 500-row window.
            base = searchResults
        } else if filter == .pinned {
            // Dedicated (unwindowed) pinned list, so old pins never drop out.
            base = clipStore.pinnedClips
        } else {
            base = clipStore.clips
        }
        return filter == .all ? base : base.filter { filter.matches($0) }
    }

    private func runSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        if let results = (try? database.search(matching: query)) ?? nil {
            searchResults = results
        } else {
            // Query couldn't form an FTS pattern — fall back to substring scan.
            let lowered = query.lowercased()
            searchResults = clipStore.clips.filter { clip in
                (clip.textContent?.lowercased().contains(lowered) ?? false)
                    || (clip.sourceName?.lowercased().contains(lowered) ?? false)
            }
        }
    }

    var selectedClip: Clip? {
        let clips = filteredClips
        guard clips.indices.contains(selectedIndex) else { return nil }
        return clips[selectedIndex]
    }

    func prepareForShow() {
        searchText = ""
        filter = .all
        selectedIndex = 0
        closePreview()
        focusToken += 1
    }

    func closePreview() {
        previewClip = nil
        isEditingPreview = false
    }

    /// Save an edit made in the preview pane (edit-before-paste).
    func saveEditedText(_ text: String) {
        guard let clip = previewClip else { return }
        try? database.updateText(id: clip.id, text: text)
        var updated = clip
        updated.textContent = text
        if updated.kind == .rtf {
            updated.kind = .text
            updated.dataPath = nil
        }
        previewClip = updated
        isEditingPreview = false
    }

    func moveSelection(by delta: Int) {
        let count = filteredClips.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
        // Keep the open preview following the selection.
        if previewClip != nil {
            previewClip = selectedClip
        }
    }

    func togglePreview() {
        if previewClip == nil {
            previewClip = selectedClip
        } else {
            closePreview()
        }
    }

    func pasteSelected(plainText: Bool = false) {
        guard let clip = selectedClip else { return }
        paste(clip, plainText: plainText)
    }

    func paste(_ clip: Clip, plainText: Bool = false) {
        requestHide?()
        pasteService.paste(clip, plainText: plainText)
    }

    /// ⌘1…⌘9 inside the overlay.
    func pasteAt(position: Int, plainText: Bool = false) {
        let clips = filteredClips
        let index = position - 1
        guard clips.indices.contains(index) else { return }
        paste(clips[index], plainText: plainText)
    }

    func copySelected() {
        guard let clip = selectedClip else { return }
        copy(clip)
    }

    func copy(_ clip: Clip) {
        pasteService.copy(clip)
        requestHide?()
    }

    func deleteSelected() {
        guard let clip = selectedClip else { return }
        delete(clip)
    }

    func delete(_ clip: Clip) {
        if previewClip?.id == clip.id { closePreview() }
        if let deleted = try? database.delete(id: clip.id) {
            BlobStore.deleteFiles(for: [deleted])
        }
        moveSelection(by: 0) // clamp selection to the new count
    }

    func togglePinSelected() {
        guard let clip = selectedClip else { return }
        togglePin(clip)
    }

    func togglePin(_ clip: Clip) {
        try? database.togglePin(id: clip.id)
        if previewClip?.id == clip.id {
            var updated = clip
            updated.pinnedAt = clip.isPinned ? nil : Date()
            previewClip = updated
        }
    }
}
