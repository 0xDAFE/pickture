import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Fast, thread-safe SQLite-backed database indexing MediaCache entries and LRU sequences.
/// Replaces monolithic cache-index.json to support 50,000+ entries without memory or I/O spikes.
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
            access_sequence INTEGER NOT NULL
        );
        """)

        execute("""
        CREATE INDEX IF NOT EXISTS idx_access_sequence ON cache_entries (access_sequence);
        """)
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
        let sql = "SELECT file_name, byte_size, last_accessed_at, access_sequence FROM cache_entries WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let fileName = String(cString: sqlite3_column_text(stmt, 0))
            let byteSize = sqlite3_column_int64(stmt, 1)
            let lastAccessedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let accessSequence = UInt64(sqlite3_column_int64(stmt, 3))
            return MediaCacheEntry(
                key: key,
                fileName: fileName,
                byteSize: byteSize,
                lastAccessedAt: lastAccessedAt,
                accessSequence: accessSequence
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
        INSERT INTO cache_entries (key, file_name, byte_size, last_accessed_at, access_sequence)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            file_name = excluded.file_name,
            byte_size = excluded.byte_size,
            last_accessed_at = excluded.last_accessed_at,
            access_sequence = excluded.access_sequence;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, entry.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, entry.fileName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, entry.byteSize)
        sqlite3_bind_double(stmt, 4, entry.lastAccessedAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 5, Int64(entry.accessSequence))
        sqlite3_step(stmt)
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
        let sql = "SELECT key, file_name, byte_size, last_accessed_at, access_sequence FROM cache_entries ORDER BY access_sequence ASC LIMIT ?;"
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
            entries.append(MediaCacheEntry(
                key: key,
                fileName: fileName,
                byteSize: byteSize,
                lastAccessedAt: lastAccessedAt,
                accessSequence: accessSequence
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

    // MARK: - Legacy Migration

    func migrateLegacyJSONIfNeeded(from jsonURL: URL, defaultLimitBytes: Int64) {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return }
        guard let data = try? Data(contentsOf: jsonURL),
              let legacy = try? JSONDecoder().decode(MediaCacheIndexState.self, from: data) else {
            return
        }

        execute("BEGIN TRANSACTION;")
        for entry in legacy.entries.values {
            insertOrReplace(entry: entry)
        }
        setMetadata(key: "cache_size_limit_bytes", value: String(legacy.cacheSizeLimitBytes))
        setMetadata(key: "next_sequence", value: String(legacy.nextSequence))
        execute("COMMIT;")

        try? FileManager.default.removeItem(at: jsonURL)
    }
}
