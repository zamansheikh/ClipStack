import Foundation
import GRDB

/// Owns the GRDB database queue and all write operations.
final class AppDatabase {
    let dbQueue: DatabaseQueue

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClipStack", isDirectory: true)
    }()

    init() throws {
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let dbURL = Self.supportDirectory.appendingPathComponent("clipstack.sqlite")
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "pinboard") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull()
            }
            try db.create(table: "clip") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("textContent", .text)
                t.column("dataPath", .text)
                t.column("previewPath", .text)
                t.column("contentHash", .text).notNull()
                t.column("sourceBundle", .text)
                t.column("sourceName", .text)
                t.column("byteSize", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.column("pinboardId", .text).references("pinboard")
            }
            // History dedupe key. Pinboard copies (Phase 2) will get their own rows;
            // NULL pinboardId keeps this unique for plain history only.
            try db.create(
                index: "clip_hash",
                on: "clip",
                columns: ["contentHash"],
                options: .unique,
                condition: Column("pinboardId") == nil
            )
        }

        return migrator
    }

    /// Insert a new clip, or bump an existing one with the same content to the top.
    /// Returns true if a new row was inserted.
    @discardableResult
    func ingest(_ clip: Clip) throws -> Bool {
        try dbQueue.write { db in
            if var existing = try Clip
                .filter(Column("contentHash") == clip.contentHash)
                .filter(Column("pinboardId") == nil)
                .fetchOne(db)
            {
                existing.lastUsedAt = Date()
                existing.sourceBundle = clip.sourceBundle
                existing.sourceName = clip.sourceName
                try existing.update(db)
                return false
            } else {
                try clip.insert(db)
                return true
            }
        }
    }

    func bumpLastUsed(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clip SET lastUsedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    /// Enforce the history item limit (0 = unlimited). Returns clips that were
    /// evicted so the caller can delete their blob files.
    func enforceLimit(_ limit: Int) throws -> [Clip] {
        guard limit > 0 else { return [] }
        return try dbQueue.write { db in
            let evicted = try Clip
                .filter(Column("pinboardId") == nil)
                .order(Column("lastUsedAt").desc)
                .limit(1_000_000, offset: limit)
                .fetchAll(db)
            for clip in evicted {
                try clip.delete(db)
            }
            return evicted
        }
    }

    /// Delete all history. Returns deleted clips so blob files can be cleaned up.
    func clearHistory() throws -> [Clip] {
        try dbQueue.write { db in
            let all = try Clip.filter(Column("pinboardId") == nil).fetchAll(db)
            try Clip.filter(Column("pinboardId") == nil).deleteAll(db)
            return all
        }
    }

    func delete(id: String) throws -> Clip? {
        try dbQueue.write { db in
            guard let clip = try Clip.fetchOne(db, key: id) else { return nil }
            try clip.delete(db)
            return clip
        }
    }
}
