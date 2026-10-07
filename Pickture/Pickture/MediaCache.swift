import CryptoKit
import Foundation

nonisolated struct MediaCacheEntry: Codable, Hashable, Sendable {
    let key: String
    let fileName: String
    let byteSize: Int64
    var lastAccessedAt: Date
    var accessSequence: UInt64
}

nonisolated struct MediaCacheIndexState: Codable, Sendable {
    var cacheSizeLimitBytes: Int64
    var nextSequence: UInt64
    var entries: [String: MediaCacheEntry]
}

@MainActor
final class MediaCache {
    nonisolated static let minUserQuotaBytes: Int64 = 250 * 1_024 * 1_024       // 250 MB
    nonisolated static let maxUserQuotaBytes: Int64 = 20 * 1_024 * 1_024 * 1_024 // 20 GB
    nonisolated static let defaultQuotaBytes: Int64 = 2 * 1_024 * 1_024 * 1_024  // 2 GB

    static let quotaPresetsBytes: [(label: String, bytes: Int64)] = [
        ("250 MB", 250 * 1_024 * 1_024),
        ("500 MB", 500 * 1_024 * 1_024),
        ("1 GB", 1 * 1_024 * 1_024 * 1_024),
        ("2 GB", 2 * 1_024 * 1_024 * 1_024),
        ("5 GB", 5 * 1_024 * 1_024 * 1_024),
        ("10 GB", 10 * 1_024 * 1_024 * 1_024),
        ("20 GB", 20 * 1_024 * 1_024 * 1_024)
    ]

    let cacheDirectoryURL: URL
    private let indexFileURL: URL
    private var state: MediaCacheIndexState

    var cacheSizeLimitBytes: Int64 {
        state.cacheSizeLimitBytes
    }

    var totalCachedBytes: Int64 {
        state.entries.values.reduce(0) { $0 + $1.byteSize }
    }

    var entryCount: Int {
        state.entries.count
    }

    init(cacheDirectoryURL: URL, initialLimitBytes: Int64 = MediaCache.defaultQuotaBytes) {
        let standardized = cacheDirectoryURL.standardizedFileURL
        self.cacheDirectoryURL = standardized
        self.indexFileURL = standardized.appendingPathComponent("cache-index.json")

        try? FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: indexFileURL),
           let decoded = try? JSONDecoder().decode(MediaCacheIndexState.self, from: data) {
            self.state = decoded
        } else {
            self.state = MediaCacheIndexState(
                cacheSizeLimitBytes: initialLimitBytes,
                nextSequence: 1,
                entries: [:]
            )
        }
    }

    func contains(key: String) -> Bool {
        guard let entry = state.entries[key] else {
            return false
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func readData(forKey key: String) -> Data? {
        guard var entry = state.entries[key] else {
            return nil
        }
        let fileURL = cacheDirectoryURL.appendingPathComponent(entry.fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            state.entries.removeValue(forKey: key)
            persistIndex()
            return nil
        }
        entry.lastAccessedAt = Date()
        entry.accessSequence = nextSequenceNumber()
        state.entries[key] = entry
        scheduleDebouncedPersistIndex()
        return data
    }

    func storeData(_ data: Data, forKey key: String) {
        try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)

        let byteSize = Int64(data.count)
        // If single item exceeds quota and quota > 0, evict everything else first
        if let existing = state.entries.removeValue(forKey: key) {
            let oldURL = cacheDirectoryURL.appendingPathComponent(existing.fileName)
            try? FileManager.default.removeItem(at: oldURL)
        }

        let fileName = Self.safeFileName(forKey: key)
        let fileURL = cacheDirectoryURL.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            let entry = MediaCacheEntry(
                key: key,
                fileName: fileName,
                byteSize: byteSize,
                lastAccessedAt: Date(),
                accessSequence: nextSequenceNumber()
            )
            state.entries[key] = entry
            evictIfNeeded()
            persistIndex()
        } catch {
            // Ignore transient disk write failures in cache
        }
    }

    func setCacheSizeLimitBytes(_ newLimitBytes: Int64) {
        state.cacheSizeLimitBytes = max(0, newLimitBytes)
        evictIfNeeded()
        persistIndex()
    }

    func clear() {
        let fm = FileManager.default
        for entry in state.entries.values {
            let fileURL = cacheDirectoryURL.appendingPathComponent(entry.fileName)
            try? fm.removeItem(at: fileURL)
        }
        state.entries.removeAll()
        flushIndexImmediately()
    }

    private func evictIfNeeded() {
        let limit = state.cacheSizeLimitBytes
        guard totalCachedBytes > limit else {
            return
        }

        let fm = FileManager.default
        // Sort entries from oldest accessSequence (least recently used) to newest
        let sortedByLRU = state.entries.values.sorted { lhs, rhs in
            if lhs.accessSequence != rhs.accessSequence {
                return lhs.accessSequence < rhs.accessSequence
            }
            return lhs.lastAccessedAt < rhs.lastAccessedAt
        }

        var currentTotal = totalCachedBytes
        for candidate in sortedByLRU {
            guard currentTotal > limit else { break }
            let fileURL = cacheDirectoryURL.appendingPathComponent(candidate.fileName)
            try? fm.removeItem(at: fileURL)
            state.entries.removeValue(forKey: candidate.key)
            currentTotal -= candidate.byteSize
        }
    }

    private func nextSequenceNumber() -> UInt64 {
        let current = state.nextSequence
        state.nextSequence += 1
        return current
    }

    private var debouncedPersistTask: Task<Void, Never>? = nil
    private var backgroundWriteTask: Task<Void, Never>? = nil
    private let indexWriter = IndexDiskWriter()

    func scheduleDebouncedPersistIndex(delayNanoseconds: UInt64 = 1_000_000_000) {
        debouncedPersistTask?.cancel()
        // Run debounce sleep off-actor at utility priority to keep @MainActor responsive
        debouncedPersistTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.debouncedPersistTask = nil
                self.persistIndex()
            }
        }
    }

    func persistIndex() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let targetURL = indexFileURL
        let seq = state.nextSequence
        let writer = indexWriter
        // Serialized background write: IndexDiskWriter guarantees monotonic sequence ordering
        // so delayed disk operations can never overwrite newer snapshots.
        backgroundWriteTask = Task(priority: .utility) {
            await writer.write(data, sequence: seq, to: targetURL)
        }
    }

    func flushIndexImmediately() {
        debouncedPersistTask?.cancel()
        debouncedPersistTask = nil
        backgroundWriteTask?.cancel()
        backgroundWriteTask = nil
        guard let data = try? JSONEncoder().encode(state) else { return }
        let seq = state.nextSequence
        let writer = indexWriter
        try? data.write(to: indexFileURL, options: .atomic)
        Task(priority: .utility) {
            await writer.markWritten(sequence: seq)
        }
    }

    private static func safeFileName(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).thumb.jpg"
    }
}

private actor IndexDiskWriter {
    private var lastWrittenSequence: UInt64 = 0

    func write(_ data: Data, sequence: UInt64, to url: URL) {
        guard sequence >= lastWrittenSequence else { return }
        lastWrittenSequence = sequence
        try? data.write(to: url, options: .atomic)
    }

    func markWritten(sequence: UInt64) {
        lastWrittenSequence = max(lastWrittenSequence, sequence)
    }
}
