import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay", default: .init(.v, modifiers: [.command, .shift]))
}

/// Composition root — owns and wires all long-lived services.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let database: AppDatabase
    let settings: AppSettings
    let clipStore: ClipStore
    let pasteService: PasteService
    let ingest: IngestPipeline
    let watcher: ClipboardWatcher
    let overlayViewModel: OverlayViewModel
    let overlayController: OverlayPanelController

    private init() {
        // A clipboard manager without its database is useless; crash loudly.
        database = try! AppDatabase()
        settings = AppSettings()
        clipStore = ClipStore(database: database)
        pasteService = PasteService(database: database)
        ingest = IngestPipeline(database: database, settings: settings)
        watcher = ClipboardWatcher(ingest: ingest)
        overlayViewModel = OverlayViewModel(
            clipStore: clipStore,
            pasteService: pasteService,
            database: database
        )
        overlayController = OverlayPanelController(viewModel: overlayViewModel)
    }

    private var retentionTimer: Timer?

    func start() {
        watcher.start()
        KeyboardShortcuts.onKeyUp(for: .toggleOverlay) { [weak self] in
            self?.overlayController.toggle()
        }

        // Time-based retention: sweep at launch and every 5 minutes, so old
        // clips expire even when nothing new is copied.
        sweepRetention()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.sweepRetention() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    private func sweepRetention() {
        if let evicted = try? database.enforceRetention(seconds: settings.retentionSeconds),
           !evicted.isEmpty
        {
            BlobStore.deleteFiles(for: evicted)
        }
    }

    func clearHistory() {
        if let deleted = try? database.clearHistory() {
            BlobStore.deleteFiles(for: deleted)
        }
    }
}
