import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Fast, thread-safe SQLite-backed database indexing MediaCache entries and LRU sequences.
/// Supports 50,000+ entries without memory or I/O spikes.
///
/// - Note: Concurrency Safety Invariant: Marked `@unchecked Sendable` because the underlying SQLite connection
///   is opened with `SQLITE_OPEN_FULLMUTEX` (serialized multi-thread mode). SQLite transparently serializes
///   all statements, queries, pragmas, and WAL checkpoints using its internal connection-level recursive mutexes.
final class SQLiteMediaCacheIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    let databaseURL: URL

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

    // MARK: - Metadata

    func getMetadata(key: String) -> String? {
        guard let db else { return nil }
        let sql = "SELECT value FROM metadata WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW,
           let text = sqlite3_column_text(stmt, 0) {
            return String(cString: text)
        }
        return nil
    }

    func setMetadata(key: String, value: String) {
        guard let db else { return }
        let sql = "INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Entry Operations

    func entry(forKey key: String) -> MediaCacheEntry? {
        guard let db else { return nil }
        let sql = "SELECT file_name, byte_size, last_accessed_at, access_sequence, pixel_width, pixel_height FROM cache_entries WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
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
        guard let db else { return false }
        let sql = "SELECT 1 FROM cache_entries WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func insertOrReplace(entry: MediaCacheEntry) {
        guard let db else { return }
        let sql = """
        INSERT INTO cache_entries (key, file_name, byte_size, last_accessed_at, access_sequence, pixel_width, pixel_height)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            file_name = excluded.file_name,
            byte_size = excluded.byte_size,
            last_accessed_at = excluded.last_accessed_at,
            access_sequence = excluded.access_sequence,
            pixel_width = COALESCE(excluded.pixel_width, cache_entries.pixel_width),
            pixel_height = COALESCE(excluded.pixel_height, cache_entries.pixel_height);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

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
        sqlite3_step(stmt)
    }

    func updateDimensions(key: String, pixelWidth: Int, pixelHeight: Int) {
        guard let db else { return }
        let sql = "UPDATE cache_entries SET pixel_width = ?, pixel_height = ? WHERE key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(pixelWidth))
        sqlite3_bind_int(stmt, 2, Int32(pixelHeight))
        sqlite3_bind_text(stmt, 3, key, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func aspectRatio(forKey key: String) -> CGFloat? {
        guard let db else { return nil }
        let sql = "SELECT pixel_width, pixel_height FROM cache_entries WHERE key = ? AND pixel_width IS NOT NULL AND pixel_height IS NOT NULL AND pixel_height > 0 LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
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
        guard let db, !keys.isEmpty else { return [:] }
        var results: [String: CGFloat] = [:]
        let chunkSize = 500
        for chunk in stride(from: 0, to: keys.count, by: chunkSize) {
            let slice = Array(keys[chunk..<min(chunk + chunkSize, keys.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let sql = "SELECT key, pixel_width, pixel_height FROM cache_entries WHERE key IN (\(placeholders)) AND pixel_width IS NOT NULL AND pixel_height IS NOT NULL AND pixel_height > 0;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            for (idx, key) in slice.enumerated() {
                sqlite3_bind_text(stmt, Int32(idx + 1), key, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let keyPtr = sqlite3_column_text(stmt, 0) {
                    let key = String(cString: keyPtr)
                    let width = sqlite3_column_int(stmt, 1)
                    let height = sqlite3_column_int(stmt, 2)
                    if height > 0 {
                        results[key] = CGFloat(width) / CGFloat(height)
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    func updateAccess(key: String, lastAccessedAt: Date, accessSequence: UInt64) {
        guard let db else { return }
        let sql = "UPDATE cache_entries SET last_accessed_at = ?, access_sequence = ? WHERE key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, lastAccessedAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, Int64(accessSequence))
        sqlite3_bind_text(stmt, 3, key, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func remove(key: String) {
        guard let db else { return }
        let sql = "DELETE FROM cache_entries WHERE key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func fetchOldestEntries(limit: Int) -> [MediaCacheEntry] {
        guard let db else { return [] }
        let sql = "SELECT key, file_name, byte_size, last_accessed_at, access_sequence, pixel_width, pixel_height FROM cache_entries ORDER BY access_sequence ASC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))
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
        guard let db else { return [] }
        let sql = "SELECT file_name FROM cache_entries;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var fileNames: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let fileName = String(cString: sqlite3_column_text(stmt, 0))
            fileNames.append(fileName)
        }
        return fileNames
    }

    func clearAll() {
        execute("DELETE FROM cache_entries;")
    }

    func stats() -> (count: Int, totalBytes: Int64) {
        guard let db else { return (0, 0) }
        let sql = "SELECT COUNT(*), COALESCE(SUM(byte_size), 0) FROM cache_entries;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = Int(sqlite3_column_int64(stmt, 0))
            let totalBytes = sqlite3_column_int64(stmt, 1)
            return (count, totalBytes)
        }
        return (0, 0)
    }

    func checkpointWAL() {
        guard let db else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    }
}
