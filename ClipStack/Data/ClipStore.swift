import Combine
import Foundation
import GRDB

/// Observable list of recent clips, kept in sync with the database via
/// GRDB's ValueObservation. The overlay UI reads from this.
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    /// Pinned clips, most recently pinned first. Not subject to the 500-row
    /// history window, so old pins never drop out of the Pinned tab.
    @Published private(set) var pinnedClips: [Clip] = []

    private var cancellables: [AnyDatabaseCancellable] = []

    init(database: AppDatabase) {
        let historyObservation = ValueObservation.tracking { db in
            try Clip
                .filter(Column("pinboardId") == nil)
                .order(Column("lastUsedAt").desc)
                .limit(500)
                .fetchAll(db)
        }
        let pinnedObservation = ValueObservation.tracking { db in
            try Clip
                .filter(Column("pinnedAt") != nil)
                .order(Column("pinnedAt").desc)
                .fetchAll(db)
        }

        cancellables.append(historyObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                NSLog("ClipStore observation error: \(error)")
            },
            onChange: { [weak self] clips in
                // Safe: observation is scheduled on the main queue above.
                MainActor.assumeIsolated {
                    self?.clips = clips
                }
            }
        ))
        cancellables.append(pinnedObservation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { error in
                NSLog("ClipStore pinned observation error: \(error)")
            },
            onChange: { [weak self] clips in
                MainActor.assumeIsolated {
                    self?.pinnedClips = clips
                }
            }
        ))
    }
}
