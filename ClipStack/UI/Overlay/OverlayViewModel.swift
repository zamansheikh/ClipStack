import AppKit
import Combine
import Foundation

/// Kind filter chips (apply within the current tab).
enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case text = "Text"
    case links = "Links"
    case images = "Images"
    case files = "Files"

    var id: String { rawValue }

    func matches(_ clip: Clip) -> Bool {
        switch self {
        case .all: return true
        case .text: return clip.kind == .text || clip.kind == .rtf
        case .links: return clip.kind == .url
        case .images: return clip.kind == .image
        case .files: return clip.kind == .file
        }
    }
}

/// Which collection the overlay is showing.
enum OverlayTab: Equatable {
    case history
    case pinned
    case board(String)
}

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var filter: ClipFilter = .all
    @Published var tab: OverlayTab = .history
    @Published var selectedIndex = 0
    /// Multi-select paste stack, in the order items were added (⌘-click).
    @Published private(set) var stack: [Clip] = []
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
        $tab
            .sink { [weak self] _ in self?.selectedIndex = 0 }
            .store(in: &cancellables)
    }

    var filteredClips: [Clip] {
        let base: [Clip]
        if let searchResults {
            // FTS results span the whole database (all tabs), not just the
            // 500-row history window.
            base = searchResults
        } else {
            switch tab {
            case .history:
                base = clipStore.clips
            case .pinned:
                base = clipStore.pinnedClips
            case .board(let id):
                base = clipStore.boardClips[id] ?? []
            }
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
        tab = .history
        selectedIndex = 0
        stack = []
        closePreview()
        focusToken += 1
    }

    // MARK: - Paste stack (multi-select)

    func toggleStack(_ clip: Clip) {
        if let index = stack.firstIndex(where: { $0.id == clip.id }) {
            stack.remove(at: index)
        } else {
            stack.append(clip)
        }
    }

    /// 1-based position of a clip in the paste stack, nil if not in it.
    func stackIndex(of clip: Clip) -> Int? {
        stack.firstIndex { $0.id == clip.id }.map { $0 + 1 }
    }

    func clearStack() {
        stack = []
    }

    /// Return key: paste the stack if one was built, else the selected card.
    func pasteStackOrSelected(plainText: Bool = false) {
        guard !stack.isEmpty else {
            pasteSelected(plainText: plainText)
            return
        }
        let items = stack
        stack = []
        requestHide?()
        pasteService.pasteSequentially(items, plainText: plainText)
    }

    // MARK: - Pinboards

    var pinboards: [Pinboard] { clipStore.pinboards }

    /// Set by the panel controller: shows a modal text prompt, returns the
    /// entered string or nil on cancel.
    var promptForText: ((_ title: String, _ initial: String) -> String?)?

    func assign(_ clip: Clip, toBoard boardId: String?) {
        try? database.assign(clipId: clip.id, toPinboard: boardId)
    }

    func createPinboard(assigning clip: Clip? = nil) {
        guard let name = promptForText?("New Pinboard", "")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return }
        guard let board = try? database.createPinboard(named: name) else { return }
        if let clip {
            assign(clip, toBoard: board.id)
        }
        tab = .board(board.id)
    }

    func renamePinboard(_ board: Pinboard) {
        guard let name = promptForText?("Rename Pinboard", board.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return }
        try? database.renamePinboard(id: board.id, to: name)
    }

    func deletePinboard(_ board: Pinboard) {
        try? database.deletePinboard(id: board.id)
        if tab == .board(board.id) {
            tab = .pinned
        }
    }

    func movePinboard(_ board: Pinboard, direction: Int) {
        try? database.movePinboard(id: board.id, direction: direction)
    }

    /// Tab key cycles History → Pinned → boards → back.
    func cycleTab(_ delta: Int) {
        let tabs: [OverlayTab] = [.history, .pinned] + pinboards.map { .board($0.id) }
        guard let index = tabs.firstIndex(of: tab) else {
            tab = .history
            return
        }
        tab = tabs[(index + delta + tabs.count) % tabs.count]
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
