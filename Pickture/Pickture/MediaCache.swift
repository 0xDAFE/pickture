import CryptoKit
import Foundation

nonisolated struct MediaCacheEntry: Codable, Hashable, Sendable {
    let key: String
    let fileName: String
    let byteSize: Int64
    var lastAccessedAt: Date
    var accessSequence: UInt64
    var pixelWidth: Int?
    var pixelHeight: Int?

    var aspectRatio: CGFloat? {
        guard let w = pixelWidth, let h = pixelHeight, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    init(
        key: String,
        fileName: String,
        byteSize: Int64,
        lastAccessedAt: Date = Date(),
        accessSequence: UInt64 = 0,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.key = key
        self.fileName = fileName
        self.byteSize = byteSize
        self.lastAccessedAt = lastAccessedAt
        self.accessSequence = accessSequence
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Thread-safe background cache actor managing thumbnail/preview disk storage,
/// SHA-256 key hashing, indexed LRU byte-quota eviction, and SQLite index interactions off @MainActor.
actor MediaCache {
    nonisolated static let minUserQuotaBytes: Int64 = 250 * 1_024 * 1_024       // 250 MB
    nonisolated static let maxUserQuotaBytes: Int64 = 20 * 1_024 * 1_024 * 1_024 // 20 GB
    nonisolated static let defaultQuotaBytes: Int64 = 2 * 1_024 * 1_024 * 1_024  // 2 GB

    nonisolated static let quotaPresetsBytes: [(label: String, bytes: Int64)] = [
        ("250 MB", 250 * 1_024 * 1_024),
        ("500 MB", 500 * 1_024 * 1_024),
        ("1 GB", 1 * 1_024 * 1_024 * 1_024),
        ("2 GB", 2 * 1_024 * 1_024 * 1_024),
        ("5 GB", 5 * 1_024 * 1_024 * 1_024),
        ("10 GB", 10 * 1_024 * 1_024 * 1_024),
        ("20 GB", 20 * 1_024 * 1_024 * 1_024)
    ]

    nonisolated let cacheDirectoryURL: URL
    nonisolated let indexFileURL: URL
    private let db: SQLiteMediaCacheIndex

    private(set) var cacheSizeLimitBytes: Int64
    private(set) var totalCachedBytes: Int64
    private(set) var entryCount: Int
    private var nextSequence: UInt64

    private var pendingAccessUpdates: [String: (lastAccessedAt: Date, accessSequence: UInt64)] = [:]
    private var debouncedPersistTask: Task<Void, Never>? = nil

    init(cacheDirectoryURL: URL, initialLimitBytes: Int64 = MediaCache.defaultQuotaBytes) {
        let standardized = cacheDirectoryURL.standardizedFileURL
        self.cacheDirectoryURL = standardized
        let dbURL = standardized.appendingPathComponent("cache-index.sqlite3")
        self.indexFileURL = dbURL

        try? FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)

        let dbIndex = SQLiteMediaCacheIndex(databaseURL: dbURL)
        self.db = dbIndex

        let stats = dbIndex.stats()
        self.entryCount = stats.count
        self.totalCachedBytes = stats.totalBytes

        if let savedLimit = dbIndex.getMetadata(key: "cache_size_limit_bytes"),
           let parsed = Int64(savedLimit) {
            self.cacheSizeLimitBytes = parsed
        } else {
            self.cacheSizeLimitBytes = initialLimitBytes
            dbIndex.setMetadata(key: "cache_size_limit_bytes", value: String(initialLimitBytes))
        }

        if let savedSeq = dbIndex.getMetadata(key: "next_sequence"),
           let parsed = UInt64(savedSeq) {
            self.nextSequence = parsed
        } else {
            self.nextSequence = 1
            dbIndex.setMetadata(key: "next_sequence", value: "1")
        }
    }

    func contains(key: String) -> Bool {
        guard let entry = db.entry(forKey: key) else {
            return false
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func readData(forKey key: String) -> Data? {
        guard let entry = db.entry(forKey: key) else {
            return nil
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(entry.fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            db.remove(key: key)
            totalCachedBytes = max(0, totalCachedBytes - entry.byteSize)
            entryCount = max(0, entryCount - 1)
            return nil
        }

        let seq = nextSequenceNumber()
        pendingAccessUpdates[key] = (Date(), seq)
        scheduleDebouncedPersistIndex()
        return data
    }

    func batchAspectRatios(keys: [String]) -> [String: CGFloat] {
        db.batchAspectRatios(keys: keys)
    }

    func aspectRatio(forKey key: String) -> CGFloat? {
        db.aspectRatio(forKey: key)
    }

    func recordDimensions(key: String, pixelWidth: Int, pixelHeight: Int) {
        db.updateDimensions(key: key, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    nonisolated func writeDiskFile(_ data: Data, forKey key: String) -> (fileName: String, byteSize: Int64)? {
        let fileName = Self.safeFileName(forKey: key)
        let fileURL = cacheDirectoryURL.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return (fileName, Int64(data.count))
        } catch {
            return nil
        }
    }

    func recordEntry(
        key: String,
        fileName: String,
        byteSize: Int64,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        if let existing = db.entry(forKey: key) {
            if existing.fileName != fileName {
                let oldURL = cacheDirectoryURL.appendingPathComponent(existing.fileName)
                try? FileManager.default.removeItem(at: oldURL)
            }
            db.remove(key: key)
            totalCachedBytes = max(0, totalCachedBytes - existing.byteSize)
            entryCount = max(0, entryCount - 1)
        }

        let seq = nextSequenceNumber()
        let entry = MediaCacheEntry(
            key: key,
            fileName: fileName,
            byteSize: byteSize,
            lastAccessedAt: Date(),
            accessSequence: seq,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        db.insertOrReplace(entry: entry)
        totalCachedBytes += byteSize
        entryCount += 1
        pendingAccessUpdates.removeValue(forKey: key)

        evictIfNeeded()
        db.setMetadata(key: "next_sequence", value: String(nextSequence))
        db.setMetadata(key: "cache_size_limit_bytes", value: String(cacheSizeLimitBytes))
    }

    func storeData(_ data: Data, forKey key: String, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        guard let (fileName, byteSize) = writeDiskFile(data, forKey: key) else {
            return
        }
        recordEntry(key: key, fileName: fileName, byteSize: byteSize, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    func setCacheSizeLimitBytes(_ newLimitBytes: Int64) {
        cacheSizeLimitBytes = max(0, newLimitBytes)
        db.setMetadata(key: "cache_size_limit_bytes", value: String(cacheSizeLimitBytes))
        evictIfNeeded()
    }

    func clear() {
        let fm = FileManager.default
        let fileNames = db.allFileNames()
        for fileName in fileNames {
            let fileURL = cacheDirectoryURL.appendingPathComponent(fileName)
            try? fm.removeItem(at: fileURL)
        }
        db.clearAll()
        pendingAccessUpdates.removeAll()
        totalCachedBytes = 0
        entryCount = 0
        flushIndexImmediately()
    }

    func metrics() -> (totalBytes: Int64, limitBytes: Int64, count: Int) {
        (totalCachedBytes, cacheSizeLimitBytes, entryCount)
    }

    private func evictIfNeeded() {
        flushPendingAccessUpdates()
        let limit = cacheSizeLimitBytes
        guard totalCachedBytes > limit else { return }

        let fm = FileManager.default
        while totalCachedBytes > limit {
            let batch = db.fetchOldestEntries(limit: 50)
            if batch.isEmpty { break }
            for candidate in batch {
                guard totalCachedBytes > limit else { break }
                let fileURL = cacheDirectoryURL.appendingPathComponent(candidate.fileName)
                try? fm.removeItem(at: fileURL)
                db.remove(key: candidate.key)
                totalCachedBytes = max(0, totalCachedBytes - candidate.byteSize)
                entryCount = max(0, entryCount - 1)
            }
        }
    }

    private func nextSequenceNumber() -> UInt64 {
        let current = nextSequence
        nextSequence += 1
        return current
    }

    func scheduleDebouncedPersistIndex(delayNanoseconds: UInt64 = 1_000_000_000) {
        debouncedPersistTask?.cancel()
        debouncedPersistTask = Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await self.finishDebouncedPersist()
        }
    }

    private func finishDebouncedPersist() {
        guard !Task.isCancelled else { return }
        self.debouncedPersistTask = nil
        self.persistIndex()
    }

    func persistIndex() {
        flushPendingAccessUpdates()
        db.setMetadata(key: "next_sequence", value: String(nextSequence))
        db.setMetadata(key: "cache_size_limit_bytes", value: String(cacheSizeLimitBytes))
        db.checkpointWAL()
    }

    func flushIndexImmediately() {
        debouncedPersistTask?.cancel()
        debouncedPersistTask = nil
        persistIndex()
    }

    private func flushPendingAccessUpdates() {
        guard !pendingAccessUpdates.isEmpty else { return }
        for (key, update) in pendingAccessUpdates {
            db.updateAccess(key: key, lastAccessedAt: update.lastAccessedAt, accessSequence: update.accessSequence)
        }
        pendingAccessUpdates.removeAll()
    }

    private static func safeFileName(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = key.contains("fullraw") ? "full.heic" : "thumb.jpg"
        return "\(hex).\(ext)"
    }
}
