import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated struct MetadataSyncRecord: Codable, Hashable, Sendable {
    var itemID: String
    var metadata: CurationMetadata
    var baseSnapshot: BaseSnapshot?
    var exif: ExifMetadata?
    var syncState: SyncState
    var conflict: MetadataConflict?
    var updatedAt: Date

    init(
        itemID: String,
        metadata: CurationMetadata,
        baseSnapshot: BaseSnapshot? = nil,
        exif: ExifMetadata? = nil,
        syncState: SyncState = .synced,
        conflict: MetadataConflict? = nil,
        updatedAt: Date = Date()
    ) {
        self.itemID = itemID
        self.metadata = metadata
        self.baseSnapshot = baseSnapshot
        self.exif = exif
        self.syncState = syncState
        self.conflict = conflict
        self.updatedAt = updatedAt
    }
}

/// In-memory cache for synchronous, zero-I/O metadata record lookups across actor boundaries.
///
/// **Concurrency Safety Invariant**:
/// - `RecordCache` is marked `@unchecked Sendable` because it protects its internal mutable
///   state (`records: [String: MetadataSyncRecord]`) via an internal `NSLock` synchronization primitive.
/// - All read and write accesses (`get`, `getAll`, `set`, `setAll`, `updateIfExists`, `removeAll`)
///   are strictly guarded by `lock.withLock { ... }`, preventing data races across concurrent callers.
/// - The contained `MetadataSyncRecord` value instances are immutable snapshot copies at the point
///   of reading and writing, ensuring no aliased mutable memory escapes lock protection.
///
/// **Follow-Up Removal Plan**:
/// - Once the Swift standard library / Foundation stabilizes non-blocking synchronous reader actors
///   or synchronized types (e.g. `OSAllocatedUnfairLock` or `Synchronization.Mutex` when minimum deployment
///   targets permit), migrate `RecordCache` to `Mutex<[String: MetadataSyncRecord]>` to replace
///   `@unchecked Sendable` with standard library compile-time concurrency checking.
private final class RecordCache: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: MetadataSyncRecord] = [:]

    func get(_ id: String) -> MetadataSyncRecord? {
        lock.withLock { records[id] }
    }

    func getAll() -> [String: MetadataSyncRecord] {
        lock.withLock { records }
    }

    func set(_ id: String, record: MetadataSyncRecord) {
        lock.withLock { records[id] = record }
    }

    func setAll(_ newRecords: [String: MetadataSyncRecord]) {
        lock.withLock { records = newRecords }
    }

    func updateIfExists(_ id: String, mutate: (inout MetadataSyncRecord) -> Void) {
        lock.withLock {
            if var existing = records[id] {
                mutate(&existing)
                records[id] = existing
            }
        }
    }

    func removeAll() {
        lock.withLock { records.removeAll() }
    }
}

actor MetadataSyncStore {
    let storeDirectoryURL: URL
    let databaseURL: URL
    private var db: OpaquePointer?

    nonisolated private let cache = RecordCache()

    init(storeDirectoryURL: URL) {
        let standardized = storeDirectoryURL.standardizedFileURL
        self.storeDirectoryURL = standardized
        self.databaseURL = standardized.appendingPathComponent("sync-store.sqlite")

        // Requirement 4: Any legacy sync-journal.json must be cleaned up on initial startup
        let legacyJournalURL = standardized.appendingPathComponent("sync-journal.json")
        if FileManager.default.fileExists(atPath: legacyJournalURL.path) {
            try? FileManager.default.removeItem(at: legacyJournalURL)
        }

        try? FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)

        if sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let errorMsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            print("Failed to open SQLite sync store at \(databaseURL.path): \(errorMsg)")
        }

        // Requirement 1: WAL mode, PRAGMA synchronous = NORMAL, single-row ACID transactions
        execute("PRAGMA journal_mode = WAL;")
        execute("PRAGMA synchronous = NORMAL;")

        execute("""
        CREATE TABLE IF NOT EXISTS sync_records (
            item_id TEXT PRIMARY KEY,
            metadata TEXT NOT NULL,
            base_snapshot TEXT,
            exif TEXT,
            sync_state TEXT NOT NULL,
            conflict TEXT,
            updated_at REAL NOT NULL
        );
        """)

        loadInitialRecords()
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            if let errorMessage {
                print("SQLite exec error (\(sql)): \(String(cString: errorMessage))")
                sqlite3_free(errorMessage)
            }
        }
    }

    private enum SQLParam {
        case text(String)
        case real(Double)
        case null
    }

    private func executeStatement(_ sql: String, params: [SQLParam]) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            print("SQLite prepare error: \(errorMsg) for sql: \(sql)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        for (index, param) in params.enumerated() {
            let col = Int32(index + 1)
            switch param {
            case .text(let str):
                sqlite3_bind_text(stmt, col, (str as NSString).utf8String, -1, SQLITE_TRANSIENT)
            case .real(let val):
                sqlite3_bind_double(stmt, col, val)
            case .null:
                sqlite3_bind_null(stmt, col)
            }
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            print("SQLite step error: \(errorMsg) for sql: \(sql)")
        }
    }

    private static func parseRecord(from stmt: OpaquePointer) -> MetadataSyncRecord? {
        guard let itemIDPtr = sqlite3_column_text(stmt, 0),
              let metadataPtr = sqlite3_column_text(stmt, 1),
              let syncStatePtr = sqlite3_column_text(stmt, 4) else {
            return nil
        }

        let itemID = String(cString: itemIDPtr)
        let metadataString = String(cString: metadataPtr)
        let syncStateString = String(cString: syncStatePtr)
        let updatedAtTime = sqlite3_column_double(stmt, 6)

        guard let metadataData = metadataString.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(CurationMetadata.self, from: metadataData) else {
            return nil
        }

        let baseSnapshot: BaseSnapshot? = {
            guard let ptr = sqlite3_column_text(stmt, 2) else { return nil }
            let str = String(cString: ptr)
            guard let data = str.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(BaseSnapshot.self, from: data)
        }()

        let exif: ExifMetadata? = {
            guard let ptr = sqlite3_column_text(stmt, 3) else { return nil }
            let str = String(cString: ptr)
            guard let data = str.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ExifMetadata.self, from: data)
        }()

        let conflict: MetadataConflict? = {
            guard let ptr = sqlite3_column_text(stmt, 5) else { return nil }
            let str = String(cString: ptr)
            guard let data = str.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(MetadataConflict.self, from: data)
        }()

        let syncState = SyncState(rawValue: syncStateString) ?? .synced
        let updatedAt = Date(timeIntervalSince1970: updatedAtTime)

        return MetadataSyncRecord(
            itemID: itemID,
            metadata: metadata,
            baseSnapshot: baseSnapshot,
            exif: exif,
            syncState: syncState,
            conflict: conflict,
            updatedAt: updatedAt
        )
    }

    private func loadInitialRecords() {
        guard let db else { return }
        let sql = "SELECT item_id, metadata, base_snapshot, exif, sync_state, conflict, updated_at FROM sync_records;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var loaded: [String: MetadataSyncRecord] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = Self.parseRecord(from: stmt!) {
                loaded[record.itemID] = record
            }
        }
        cache.setAll(loaded)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Synchronous In-Memory Zero-I/O Mirrors

    nonisolated func cachedRecord(for itemID: String) -> MetadataSyncRecord? {
        cache.get(itemID)
    }

    nonisolated func allCachedRecords() -> [String: MetadataSyncRecord] {
        cache.getAll()
    }

    // MARK: - Actor-Isolated SQLite Queries

    func record(for itemID: String) -> MetadataSyncRecord? {
        guard let db else {
            return cache.get(itemID)
        }
        let sql = "SELECT item_id, metadata, base_snapshot, exif, sync_state, conflict, updated_at FROM sync_records WHERE item_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return cache.get(itemID)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (itemID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.parseRecord(from: stmt!)
    }

    func allRecords() -> [String: MetadataSyncRecord] {
        guard let db else {
            return cache.getAll()
        }
        let sql = "SELECT item_id, metadata, base_snapshot, exif, sync_state, conflict, updated_at FROM sync_records;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return cache.getAll()
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: MetadataSyncRecord] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = Self.parseRecord(from: stmt!) {
                result[record.itemID] = record
            }
        }
        return result
    }

    // MARK: - Sub-Millisecond Point Writes (Requirement 2)

    func stagePendingWrite(_ metadata: CurationMetadata, baseSnapshot: BaseSnapshot? = nil, for itemID: String) {
        let now = Date()
        let existing = cache.get(itemID)
        let resolvedBase = baseSnapshot ?? existing?.baseSnapshot

        let metaJSON = Self.encodeJSON(metadata) ?? "{}"
        let baseJSON = resolvedBase.flatMap { Self.encodeJSON($0) }

        let sql = """
        INSERT INTO sync_records (item_id, metadata, base_snapshot, exif, sync_state, conflict, updated_at)
        VALUES (?1, ?2, ?3, NULL, 'pendingWrite', NULL, ?4)
        ON CONFLICT(item_id) DO UPDATE SET
            metadata = excluded.metadata,
            base_snapshot = COALESCE(excluded.base_snapshot, sync_records.base_snapshot),
            sync_state = 'pendingWrite',
            conflict = NULL,
            updated_at = excluded.updated_at;
        """

        executeStatement(sql, params: [
            .text(itemID),
            .text(metaJSON),
            baseJSON.map { .text($0) } ?? .null,
            .real(now.timeIntervalSince1970)
        ])

        let updated = MetadataSyncRecord(
            itemID: itemID,
            metadata: metadata,
            baseSnapshot: resolvedBase,
            exif: existing?.exif,
            syncState: .pendingWrite,
            conflict: nil,
            updatedAt: now
        )
        cache.set(itemID, record: updated)
    }

    func recordBaseSnapshot(_ snapshot: BaseSnapshot, exif: ExifMetadata? = nil, for itemID: String) {
        let now = Date()
        let existing = cache.get(itemID)
        let mergedExif = exif ?? existing?.exif

        let metaJSON = Self.encodeJSON(snapshot.metadata) ?? "{}"
        let baseJSON = Self.encodeJSON(snapshot) ?? "{}"
        let exifJSON = mergedExif.flatMap { Self.encodeJSON($0) }

        let sql = """
        INSERT INTO sync_records (item_id, metadata, base_snapshot, exif, sync_state, conflict, updated_at)
        VALUES (?1, ?2, ?3, ?4, 'synced', NULL, ?5)
        ON CONFLICT(item_id) DO UPDATE SET
            base_snapshot = excluded.base_snapshot,
            exif = COALESCE(excluded.exif, sync_records.exif),
            metadata = CASE WHEN sync_records.sync_state NOT IN ('pendingWrite', 'conflicted') THEN excluded.metadata ELSE sync_records.metadata END,
            sync_state = CASE WHEN sync_records.sync_state NOT IN ('pendingWrite', 'conflicted') THEN 'synced' ELSE sync_records.sync_state END,
            conflict = CASE WHEN sync_records.sync_state NOT IN ('pendingWrite', 'conflicted') THEN NULL ELSE sync_records.conflict END,
            updated_at = excluded.updated_at;
        """

        executeStatement(sql, params: [
            .text(itemID),
            .text(metaJSON),
            .text(baseJSON),
            exifJSON.map { .text($0) } ?? .null,
            .real(now.timeIntervalSince1970)
        ])

        let updated: MetadataSyncRecord
        if var rec = existing {
            rec.baseSnapshot = snapshot
            if let exif {
                rec.exif = exif
            }
            if rec.syncState != .pendingWrite && rec.syncState != .conflicted {
                rec.metadata = snapshot.metadata
                rec.syncState = .synced
                rec.conflict = nil
            }
            rec.updatedAt = now
            updated = rec
        } else {
            updated = MetadataSyncRecord(
                itemID: itemID,
                metadata: snapshot.metadata,
                baseSnapshot: snapshot,
                exif: exif,
                syncState: .synced,
                conflict: nil,
                updatedAt: now
            )
        }
        cache.set(itemID, record: updated)
    }

    func recordExif(_ exif: ExifMetadata, for itemID: String) {
        let now = Date()
        let existing = cache.get(itemID)
        let mergedExif = existing?.exif?.supplementing(with: exif) ?? exif

        let exifJSON = Self.encodeJSON(mergedExif) ?? "{}"
        let defaultMetaJSON = Self.encodeJSON(CurationMetadata()) ?? "{}"

        let sql = """
        INSERT INTO sync_records (item_id, metadata, base_snapshot, exif, sync_state, conflict, updated_at)
        VALUES (?1, ?2, NULL, ?3, 'synced', NULL, ?4)
        ON CONFLICT(item_id) DO UPDATE SET
            exif = excluded.exif,
            updated_at = excluded.updated_at;
        """

        executeStatement(sql, params: [
            .text(itemID),
            .text(defaultMetaJSON),
            .text(exifJSON),
            .real(now.timeIntervalSince1970)
        ])

        let updated: MetadataSyncRecord
        if var rec = existing {
            rec.exif = mergedExif
            rec.updatedAt = now
            updated = rec
        } else {
            updated = MetadataSyncRecord(
                itemID: itemID,
                metadata: CurationMetadata(),
                exif: exif,
                syncState: .synced,
                updatedAt: now
            )
        }
        cache.set(itemID, record: updated)
    }

    func updateSyncState(_ syncState: SyncState, for itemID: String, conflict: MetadataConflict? = nil) {
        let now = Date()
        let conflictJSON = conflict.flatMap { Self.encodeJSON($0) }

        let sql = "UPDATE sync_records SET sync_state = ?1, conflict = ?2, updated_at = ?3 WHERE item_id = ?4;"

        executeStatement(sql, params: [
            .text(syncState.rawValue),
            conflictJSON.map { .text($0) } ?? .null,
            .real(now.timeIntervalSince1970),
            .text(itemID)
        ])

        cache.updateIfExists(itemID) { rec in
            rec.syncState = syncState
            rec.conflict = conflict
            rec.updatedAt = now
        }
    }

    private func upsertSyncedRecord(
        itemID: String,
        metadata: CurationMetadata,
        baseSnapshot: BaseSnapshot,
        now: Date = Date()
    ) {
        let existing = cache.get(itemID)

        let metaJSON = Self.encodeJSON(metadata) ?? "{}"
        let baseJSON = Self.encodeJSON(baseSnapshot) ?? "{}"

        let sql = """
        INSERT INTO sync_records (item_id, metadata, base_snapshot, exif, sync_state, conflict, updated_at)
        VALUES (?1, ?2, ?3, NULL, 'synced', NULL, ?4)
        ON CONFLICT(item_id) DO UPDATE SET
            metadata = excluded.metadata,
            base_snapshot = excluded.base_snapshot,
            sync_state = 'synced',
            conflict = NULL,
            updated_at = excluded.updated_at;
        """

        executeStatement(sql, params: [
            .text(itemID),
            .text(metaJSON),
            .text(baseJSON),
            .real(now.timeIntervalSince1970)
        ])

        let updated = MetadataSyncRecord(
            itemID: itemID,
            metadata: metadata,
            baseSnapshot: baseSnapshot,
            exif: existing?.exif,
            syncState: .synced,
            conflict: nil,
            updatedAt: now
        )
        cache.set(itemID, record: updated)
    }

    func markSynced(for itemID: String, baseSnapshot: BaseSnapshot) {
        upsertSyncedRecord(itemID: itemID, metadata: baseSnapshot.metadata, baseSnapshot: baseSnapshot)
    }

    func recordConflict(_ conflict: MetadataConflict, for itemID: String) {
        let now = Date()
        let existing = cache.get(itemID)

        let metaJSON = Self.encodeJSON(conflict.local) ?? "{}"
        let conflictJSON = Self.encodeJSON(conflict) ?? "{}"
        let baseSnapshot = conflict.base.map { BaseSnapshot(metadata: $0, fileDigest: "") }
        let baseJSON = baseSnapshot.flatMap { Self.encodeJSON($0) }

        let sql = """
        INSERT INTO sync_records (item_id, metadata, base_snapshot, exif, sync_state, conflict, updated_at)
        VALUES (?1, ?2, ?3, NULL, 'conflicted', ?4, ?5)
        ON CONFLICT(item_id) DO UPDATE SET
            sync_state = 'conflicted',
            conflict = excluded.conflict,
            updated_at = excluded.updated_at;
        """

        executeStatement(sql, params: [
            .text(itemID),
            .text(metaJSON),
            baseJSON.map { .text($0) } ?? .null,
            .text(conflictJSON),
            .real(now.timeIntervalSince1970)
        ])

        let updated: MetadataSyncRecord
        if var rec = existing {
            rec.syncState = .conflicted
            rec.conflict = conflict
            rec.updatedAt = now
            updated = rec
        } else {
            updated = MetadataSyncRecord(
                itemID: itemID,
                metadata: conflict.local,
                baseSnapshot: baseSnapshot,
                exif: nil,
                syncState: .conflicted,
                conflict: conflict,
                updatedAt: now
            )
        }
        cache.set(itemID, record: updated)
    }

    func resolveConflict(for itemID: String, resolvedMetadata: CurationMetadata, newBaseSnapshot: BaseSnapshot) {
        upsertSyncedRecord(itemID: itemID, metadata: resolvedMetadata, baseSnapshot: newBaseSnapshot)
    }

    func reset() {
        execute("DELETE FROM sync_records;")
        execute("PRAGMA wal_checkpoint(TRUNCATE);")
        cache.removeAll()
    }

    func clear() {
        reset()
    }
}
