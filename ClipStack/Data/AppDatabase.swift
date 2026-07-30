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

        migrator.registerMigration("v2") { db in
            try db.alter(table: "clip") { t in
                t.add(column: "pinnedAt", .datetime)
            }
        }

        migrator.registerMigration("v3") { db in
            // External-content FTS5 index over clip text + source app name,
            // kept in sync with triggers and populated from existing rows.
            try db.create(virtualTable: "clip_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clip")
                t.tokenizer = .unicode61()
                t.column("textContent")
                t.column("sourceName")
            }
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

    /// Enforce the history item limit (0 = unlimited). Pinned clips never
    /// count against nor fall to the limit. Returns evicted clips so the
    /// caller can delete their blob files.
    func enforceLimit(_ limit: Int) throws -> [Clip] {
        guard limit > 0 else { return [] }
        return try dbQueue.write { db in
            let evicted = try Clip
                .filter(Column("pinboardId") == nil)
                .filter(Column("pinnedAt") == nil)
                .order(Column("lastUsedAt").desc)
                .limit(1_000_000, offset: limit)
                .fetchAll(db)
            for clip in evicted {
                try clip.delete(db)
            }
            return evicted
        }
    }

    /// Delete unpinned clips older than the retention window (0 = keep forever).
    /// Returns evicted clips so blob files can be cleaned up.
    func enforceRetention(seconds: Int) throws -> [Clip] {
        guard seconds > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(seconds))
        return try dbQueue.write { db in
            let evicted = try Clip
                .filter(Column("pinboardId") == nil)
                .filter(Column("pinnedAt") == nil)
                .filter(Column("lastUsedAt") < cutoff)
                .fetchAll(db)
            for clip in evicted {
                try clip.delete(db)
            }
            return evicted
        }
    }

    /// Delete all unpinned history — pinned clips survive. Returns deleted
    /// clips so blob files can be cleaned up.
    func clearHistory() throws -> [Clip] {
        try dbQueue.write { db in
            let request = Clip
                .filter(Column("pinboardId") == nil)
                .filter(Column("pinnedAt") == nil)
            let all = try request.fetchAll(db)
            try request.deleteAll(db)
            return all
        }
    }

    /// Delete unpinned history of specific kinds only (e.g. all images).
    /// Returns deleted clips so blob files can be cleaned up.
    func clearHistory(kinds: [ClipKind]) throws -> [Clip] {
        try dbQueue.write { db in
            let request = Clip
                .filter(Column("pinboardId") == nil)
                .filter(Column("pinnedAt") == nil)
                .filter(kinds.map(\.rawValue).contains(Column("kind")))
            let all = try request.fetchAll(db)
            try request.deleteAll(db)
            return all
        }
    }

    /// Full-text search over content and source app (FTS5, prefix matching).
    /// Returns nil when the query can't form a valid FTS pattern.
    func search(matching query: String) throws -> [Clip]? {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return nil }
        return try dbQueue.read { db in
            try Clip.fetchAll(
                db,
                sql: """
                SELECT clip.*
                FROM clip
                JOIN clip_fts ON clip_fts.rowid = clip.rowid
                WHERE clip_fts MATCH ?
                ORDER BY clip.lastUsedAt DESC
                LIMIT 300
                """,
                arguments: [pattern]
            )
        }
    }

    /// Save an edited text body (edit-before-paste). Editing an RTF clip
    /// demotes it to plain text since the rich data no longer matches.
    func updateText(id: String, text: String) throws {
        try dbQueue.write { db in
            guard var clip = try Clip.fetchOne(db, key: id) else { return }
            clip.textContent = text
            clip.byteSize = text.utf8.count
            if clip.kind == .rtf {
                if let path = clip.dataPath { try? FileManager.default.removeItem(atPath: path) }
                clip.dataPath = nil
                clip.kind = .text
            }
            clip.contentHash = BlobStore.sha256("text:" + text)
            do {
                try clip.update(db)
            } catch {
                // Edited content now duplicates another clip's hash — keep a
                // synthetic unique hash rather than failing the save.
                clip.contentHash = "edited:" + clip.id
                try clip.update(db)
            }
        }
    }

    func togglePin(id: String) throws {
        try dbQueue.write { db in
            guard var clip = try Clip.fetchOne(db, key: id) else { return }
            clip.pinnedAt = clip.pinnedAt == nil ? Date() : nil
            try clip.update(db)
        }
    }

    // MARK: - Pinboards

    func createPinboard(named name: String) throws -> Pinboard {
        try dbQueue.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM pinboard") ?? 0
            let board = Pinboard(id: UUID().uuidString, name: name, sortOrder: maxOrder + 1)
            try board.insert(db)
            return board
        }
    }

    func renamePinboard(id: String, to name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pinboard SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// Delete a pinboard; its clips return to loose pins (nothing is lost).
    func deletePinboard(id: String) throws {
        try dbQueue.write { db in
            let clips = try Clip.filter(Column("pinboardId") == id).fetchAll(db)
            for clip in clips {
                try Self.unassign(clip, in: db)
            }
            try db.execute(sql: "DELETE FROM pinboard WHERE id = ?", arguments: [id])
        }
    }

    func movePinboard(id: String, direction: Int) throws {
        try dbQueue.write { db in
            let boards = try Pinboard.order(Column("sortOrder")).fetchAll(db)
            guard let index = boards.firstIndex(where: { $0.id == id }) else { return }
            let target = index + direction
            guard boards.indices.contains(target) else { return }
            var a = boards[index]
            var b = boards[target]
            swap(&a.sortOrder, &b.sortOrder)
            try a.update(db)
            try b.update(db)
        }
    }

    /// Move a clip into a pinboard (auto-pins it) or back out (nil).
    func assign(clipId: String, toPinboard boardId: String?) throws {
        try dbQueue.write { db in
            guard var clip = try Clip.fetchOne(db, key: clipId) else { return }
            if let boardId {
                clip.pinboardId = boardId
                if clip.pinnedAt == nil { clip.pinnedAt = Date() }
                try clip.update(db)
            } else {
                try Self.unassign(clip, in: db)
            }
        }
    }

    /// Returning a clip to history can collide with the history dedupe index
    /// if the same content was copied again meanwhile — fall back to a
    /// synthetic hash so the clip is never lost.
    private static func unassign(_ clip: Clip, in db: Database) throws {
        var clip = clip
        clip.pinboardId = nil
        do {
            try clip.update(db)
        } catch {
            clip.contentHash = "unassigned:" + clip.id
            try clip.update(db)
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
