import Combine
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
    let sync: SyncService

    private var cancellables: Set<AnyCancellable> = []

    /// Test hook: CLIPSTACK_DEBUG_PAIR_FILE runs sync with an always-open
    /// pairing window and writes its link to that file.
    private let debugPairFile: String? = {
        let path = ProcessInfo.processInfo.environment["CLIPSTACK_DEBUG_PAIR_FILE"]
        return path?.isEmpty == false ? path : nil
    }()

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
        sync = SyncService(database: database, settings: settings)
    }

    private var retentionTimer: Timer?

    func start() {
        // Before capture starts, so no new file can be mid-write.
        BlobStore.sweepOrphans(database: database)
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

        startSync()
    }

    private func startSync() {
        // Local copies go to paired devices. capture(from:) runs on the main
        // run loop (watcher timer), so hopping onto the main actor is safe.
        ingest.onCaptured = { [weak self] clip in
            MainActor.assumeIsolated {
                self?.sync.broadcast(clip)
            }
        }

        if let debugPairFile {
            sync.startDebugPairing(writingLinkTo: debugPairFile)
            return
        }
        settings.$syncEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.sync.start() } else { self.sync.stop() }
            }
            .store(in: &cancellables)
    }

    private func sweepRetention() {
        if let evicted = try? database.enforceRetention(seconds: settings.retentionSeconds),
           !evicted.isEmpty
        {
            BlobStore.deleteFiles(for: evicted, database: database)
        }
    }

    func clearHistory() {
        if let deleted = try? database.clearHistory() {
            BlobStore.deleteFiles(for: deleted, database: database)
        }
    }

    func clearHistory(kinds: [ClipKind]) {
        if let deleted = try? database.clearHistory(kinds: kinds) {
            BlobStore.deleteFiles(for: deleted, database: database)
        }
    }
}
