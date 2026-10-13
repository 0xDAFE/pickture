import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Fast, thread-safe SQLite-backed database indexing MediaCache entries and LRU sequences.
/// Supports 50,000+ entries without memory or I/O spikes.
///
/// - Note: Concurrency Safety Invariant: Marked `@unchecked Sendable` because the underlying SQLite connection
///   is opened with `SQLITE_OPEN_FULLMUTEX` (serialized multi-thread mode) and all retained prepared `sqlite3_stmt`
///   pointers are guarded by an internal `NSLock`. This eliminates statement recompilation churn on every query
///   and guarantees thread-safe statement reuse and resets across concurrent callers.
final class SQLiteMediaCacheIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    let databaseURL: URL
    private let lock = NSLock()

    // Retained prepared statements for high-frequency operations
    private var stmtGetMetadata: OpaquePointer?
    private var stmtSetMetadata: OpaquePointer?
    private var stmtContains: OpaquePointer?
    private var stmtEntry: OpaquePointer?
    private var stmtInsertOrReplace: OpaquePointer?
    private var stmtUpdateAccess: OpaquePointer?
    private var stmtUpdateDimensions: OpaquePointer?
    private var stmtAspectRatio: OpaquePointer?
    private var stmtRemove: OpaquePointer?
    private var stmtFetchOldestEntries: OpaquePointer?
    private var stmtAllFileNames: OpaquePointer?
    private var stmtClearAll: OpaquePointer?
    private var stmtStats: OpaquePointer?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        let path = databaseURL.path

        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let errorMsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            print("Failed to open SQLite cache index at \(path): \(errorMsg)")
        }

        execute("PRAGMA journal_mode = WAL;")
        execute("PRAGMA synchronous = NORMAL;")

        execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        execute("""
        CREATE TABLE IF NOT EXISTS cache_entries (
            key TEXT PRIMARY KEY,
            file_name TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            last_accessed_at REAL NOT NULL,
            access_sequence INTEGER NOT NULL,
            pixel_width INTEGER,
            pixel_height INTEGER
        );
        """)

        ensureColumns()

        execute("""
        CREATE INDEX IF NOT EXISTS idx_access_sequence ON cache_entries (access_sequence);
        """)

        prepareStatements()
    }

    private func ensureColumns() {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(cache_entries);"
        var hasPixelWidth = false
        var hasPixelHeight = false
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let colNamePtr = sqlite3_column_text(stmt, 1) {
                    let colName = String(cString: colNamePtr)
                    if colName == "pixel_width" { hasPixelWidth = true }
                    if colName == "pixel_height" { hasPixelHeight = true }
                }
            }
            sqlite3_finalize(stmt)
        }
        if !hasPixelWidth {
            execute("ALTER TABLE cache_entries ADD COLUMN pixel_width INTEGER;")
        }
        if !hasPixelHeight {
            execute("ALTER TABLE cache_entries ADD COLUMN pixel_height INTEGER;")
        }
    }

    private func prepareStatements() {
        guard let db else { return }
        prepareStatement(
            sql: "SELECT value FROM metadata WHERE key = ? LIMIT 1;",
            dest: &stmtGetMetadata
        )
        prepareStatement(
            sql: "INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            dest: &stmtSetMetadata
        )
        prepareStatement(
            sql: "SELECT 1 FROM cache_entries WHERE key = ? LIMIT 1;",
            dest: &stmtContains
        )
        prepareStatement(
            sql: "SELECT file_name, byte_size, last_accessed_at, access_sequence, pixel_width, pixel_height FROM cache_entries WHERE key = ? LIMIT 1;",
            dest: &stmtEntry
        )
        prepareStatement(
            sql: """
            INSERT INTO cache_entries (key, file_name, byte_size, last_accessed_at, access_sequence, pixel_width, pixel_height)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                file_name = excluded.file_name,
                byte_size = excluded.byte_size,
                last_accessed_at = excluded.last_accessed_at,
                access_sequence = excluded.access_sequence,
                pixel_width = COALESCE(excluded.pixel_width, cache_entries.pixel_width),
                pixel_height = COALESCE(excluded.pixel_height, cache_entries.pixel_height);
            """,
            dest: &stmtInsertOrReplace
        )
        prepareStatement(
            sql: "UPDATE cache_entries SET last_accessed_at = ?, access_sequence = ? WHERE key = ?;",
            dest: &stmtUpdateAccess
        )
        prepareStatement(
            sql: "UPDATE cache_entries SET pixel_width = ?, pixel_height = ? WHERE key = ?;",
            dest: &stmtUpdateDimensions
        )
        prepareStatement(
            sql: "SELECT pixel_width, pixel_height FROM cache_entries WHERE key = ? AND pixel_width IS NOT NULL AND pixel_height IS NOT NULL AND pixel_height > 0 LIMIT 1;",
            dest: &stmtAspectRatio
        )
        prepareStatement(
            sql: "DELETE FROM cache_entries WHERE key = ?;",
            dest: &stmtRemove
        )
        prepareStatement(
            sql: "SELECT key, file_name, byte_size, last_accessed_at, access_sequence, pixel_width, pixel_height FROM cache_entries ORDER BY access_sequence ASC LIMIT ?;",
            dest: &stmtFetchOldestEntries
        )
        prepareStatement(
            sql: "SELECT file_name FROM cache_entries;",
            dest: &stmtAllFileNames
        )
        prepareStatement(
            sql: "DELETE FROM cache_entries;",
            dest: &stmtClearAll
        )
        prepareStatement(
            sql: "SELECT COUNT(*), COALESCE(SUM(byte_size), 0) FROM cache_entries;",
            dest: &stmtStats
        )
    }

    private func prepareStatement(sql: String, dest: inout OpaquePointer?) {
        guard let db else { return }
        if sqlite3_prepare_v2(db, sql, -1, &dest, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            print("SQLite prepare error for [\(sql)]: \(msg)")
        }
    }

    private func finalizePreparedStatements() {
        sqlite3_finalize(stmtGetMetadata)
        sqlite3_finalize(stmtSetMetadata)
        sqlite3_finalize(stmtContains)
        sqlite3_finalize(stmtEntry)
        sqlite3_finalize(stmtInsertOrReplace)
        sqlite3_finalize(stmtUpdateAccess)
        sqlite3_finalize(stmtUpdateDimensions)
        sqlite3_finalize(stmtAspectRatio)
        sqlite3_finalize(stmtRemove)
        sqlite3_finalize(stmtFetchOldestEntries)
        sqlite3_finalize(stmtAllFileNames)
        sqlite3_finalize(stmtClearAll)
        sqlite3_finalize(stmtStats)

        stmtGetMetadata = nil
        stmtSetMetadata = nil
        stmtContains = nil
        stmtEntry = nil
        stmtInsertOrReplace = nil
        stmtUpdateAccess = nil
        stmtUpdateDimensions = nil
        stmtAspectRatio = nil
        stmtRemove = nil
        stmtFetchOldestEntries = nil
        stmtAllFileNames = nil
        stmtClearAll = nil
        stmtStats = nil
    }

    deinit {
        finalizePreparedStatements()
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

    // MARK: - Metadata

    func getMetadata(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtGetMetadata else { return nil }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        if sqlite3_step(stmt) == SQLITE_ROW,
           let text = sqlite3_column_text(stmt, 0) {
            return String(cString: text)
        }
        return nil
    }

    func setMetadata(key: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtSetMetadata else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_step(stmt)
    }

    // MARK: - Entry Operations

    func entry(forKey key: String) -> MediaCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtEntry else { return nil }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let fileName = String(cString: sqlite3_column_text(stmt, 0))
            let byteSize = sqlite3_column_int64(stmt, 1)
            let lastAccessedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let accessSequence = UInt64(sqlite3_column_int64(stmt, 3))
            var pixelWidth: Int? = nil
            var pixelHeight: Int? = nil
            if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                pixelWidth = Int(sqlite3_column_int(stmt, 4))
            }
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                pixelHeight = Int(sqlite3_column_int(stmt, 5))
            }
            return MediaCacheEntry(
                key: key,
                fileName: fileName,
                byteSize: byteSize,
                lastAccessedAt: lastAccessedAt,
                accessSequence: accessSequence,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
        return nil
    }

    func contains(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtContains else { return false }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func insertOrReplace(entry: MediaCacheEntry) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtInsertOrReplace else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, entry.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, entry.fileName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, entry.byteSize)
        sqlite3_bind_double(stmt, 4, entry.lastAccessedAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 5, Int64(entry.accessSequence))
        if let w = entry.pixelWidth {
            sqlite3_bind_int(stmt, 6, Int32(w))
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let h = entry.pixelHeight {
            sqlite3_bind_int(stmt, 7, Int32(h))
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_step(stmt)
    }

    func updateDimensions(key: String, pixelWidth: Int, pixelHeight: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtUpdateDimensions else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int(stmt, 1, Int32(pixelWidth))
        sqlite3_bind_int(stmt, 2, Int32(pixelHeight))
        sqlite3_bind_text(stmt, 3, key, -1, SQLITE_TRANSIENT)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_step(stmt)
    }

    func aspectRatio(forKey key: String) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtAspectRatio else { return nil }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let width = sqlite3_column_int(stmt, 0)
            let height = sqlite3_column_int(stmt, 1)
            if height > 0 {
                return CGFloat(width) / CGFloat(height)
            }
        }
        return nil
    }

    func batchAspectRatios(keys: [String]) -> [String: CGFloat] {
        guard !keys.isEmpty else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtAspectRatio else { return [:] }

        var results: [String: CGFloat] = [:]
        for key in keys {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let width = sqlite3_column_int(stmt, 0)
                let height = sqlite3_column_int(stmt, 1)
                if height > 0 {
                    results[key] = CGFloat(width) / CGFloat(height)
                }
            }
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return results
    }

    func updateAccess(key: String, lastAccessedAt: Date, accessSequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtUpdateAccess else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_double(stmt, 1, lastAccessedAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, Int64(accessSequence))
        sqlite3_bind_text(stmt, 3, key, -1, SQLITE_TRANSIENT)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_step(stmt)
    }

    func remove(key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtRemove else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_step(stmt)
    }

    func fetchOldestEntries(limit: Int) -> [MediaCacheEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtFetchOldestEntries else { return [] }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int(stmt, 1, Int32(limit))
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        var entries: [MediaCacheEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let fileName = String(cString: sqlite3_column_text(stmt, 1))
            let byteSize = sqlite3_column_int64(stmt, 2)
            let lastAccessedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let accessSequence = UInt64(sqlite3_column_int64(stmt, 4))
            var pixelWidth: Int? = nil
            var pixelHeight: Int? = nil
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                pixelWidth = Int(sqlite3_column_int(stmt, 5))
            }
            if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                pixelHeight = Int(sqlite3_column_int(stmt, 6))
            }
            entries.append(MediaCacheEntry(
                key: key,
                fileName: fileName,
                byteSize: byteSize,
                lastAccessedAt: lastAccessedAt,
                accessSequence: accessSequence,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ))
        }
        return entries
    }

    func allFileNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtAllFileNames else { return [] }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        var fileNames: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let fileName = String(cString: sqlite3_column_text(stmt, 0))
            fileNames.append(fileName)
        }
        return fileNames
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtClearAll else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_step(stmt)
    }

    func stats() -> (count: Int, totalBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = stmtStats else { return (0, 0) }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = Int(sqlite3_column_int64(stmt, 0))
            let totalBytes = sqlite3_column_int64(stmt, 1)
            return (count, totalBytes)
        }
        return (0, 0)
    }

    func checkpointWAL() {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    }

    // MARK: - Testing Inspection Support

    #if DEBUG
    var preparedStatementPointers: [String: UnsafeMutableRawPointer?] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "getMetadata": stmtGetMetadata.map { UnsafeMutableRawPointer($0) },
            "setMetadata": stmtSetMetadata.map { UnsafeMutableRawPointer($0) },
            "contains": stmtContains.map { UnsafeMutableRawPointer($0) },
            "entry": stmtEntry.map { UnsafeMutableRawPointer($0) },
            "insertOrReplace": stmtInsertOrReplace.map { UnsafeMutableRawPointer($0) },
            "updateAccess": stmtUpdateAccess.map { UnsafeMutableRawPointer($0) },
            "updateDimensions": stmtUpdateDimensions.map { UnsafeMutableRawPointer($0) },
            "aspectRatio": stmtAspectRatio.map { UnsafeMutableRawPointer($0) },
            "remove": stmtRemove.map { UnsafeMutableRawPointer($0) },
            "fetchOldestEntries": stmtFetchOldestEntries.map { UnsafeMutableRawPointer($0) },
            "allFileNames": stmtAllFileNames.map { UnsafeMutableRawPointer($0) },
            "clearAll": stmtClearAll.map { UnsafeMutableRawPointer($0) },
            "stats": stmtStats.map { UnsafeMutableRawPointer($0) }
        ]
    }
    #endif
}
