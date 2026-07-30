import Combine
import Foundation
import GRDB

/// Observable list of recent clips, kept in sync with the database via
/// GRDB's ValueObservation. The overlay UI reads from this.
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var clips: [Clip] = []

    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase) {
        let observation = ValueObservation.tracking { db in
            try Clip
                .filter(Column("pinboardId") == nil)
                .order(Column("lastUsedAt").desc)
                .limit(500)
                .fetchAll(db)
        }
        cancellable = observation.start(
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
        )
    }
}
