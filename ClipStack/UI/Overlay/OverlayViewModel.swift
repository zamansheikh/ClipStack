import AppKit
import Combine
import Foundation

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

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var filter: ClipFilter = .all
    @Published var selectedIndex = 0
    /// Bumped every time the overlay is shown, to re-focus the search field.
    @Published var focusToken = 0

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
            .sink { [weak self] _ in self?.selectedIndex = 0 }
            .store(in: &cancellables)
        $filter
            .sink { [weak self] _ in self?.selectedIndex = 0 }
            .store(in: &cancellables)
    }

    var filteredClips: [Clip] {
        var clips = clipStore.clips.filter { filter.matches($0) }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // Prefix + substring search over content and source app (FTS5 later).
            clips = clips.filter { clip in
                (clip.textContent?.lowercased().contains(query) ?? false)
                    || (clip.sourceName?.lowercased().contains(query) ?? false)
                    || clip.kind.rawValue.contains(query)
            }
        }
        return clips
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
        focusToken += 1
    }

    func moveSelection(by delta: Int) {
        let count = filteredClips.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
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
        pasteService.copy(clip)
        requestHide?()
    }

    func deleteSelected() {
        guard let clip = selectedClip else { return }
        if let deleted = try? database.delete(id: clip.id) {
            BlobStore.deleteFiles(for: [deleted])
        }
        moveSelection(by: 0) // clamp selection to the new count
    }
}
