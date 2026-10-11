import CoreGraphics
import Foundation
import Testing
@testable import Pickture

@Suite("MediaCache SQLite & Metal Downsampler Tests", .serialized)
struct MediaCacheSQLiteAndMetalTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureCacheSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func createTestCGImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - SQLiteMediaCacheIndex Unit Tests

    @Test("SQLiteMediaCacheIndex stores, updates, queries entries, and orders by access sequence")
    func sqliteIndexEntryOperations() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("cache-index.sqlite3")
        let index = SQLiteMediaCacheIndex(databaseURL: dbURL)

        let entry1 = MediaCacheEntry(
            key: "key_1",
            fileName: "file_1.jpg",
            byteSize: 500,
            lastAccessedAt: Date(timeIntervalSince1970: 1000),
            accessSequence: 10
        )
        let entry2 = MediaCacheEntry(
            key: "key_2",
            fileName: "file_2.jpg",
            byteSize: 1000,
            lastAccessedAt: Date(timeIntervalSince1970: 2000),
            accessSequence: 20
        )
        let entry3 = MediaCacheEntry(
            key: "key_3",
            fileName: "file_3.jpg",
            byteSize: 1500,
            lastAccessedAt: Date(timeIntervalSince1970: 3000),
            accessSequence: 30
        )

        index.insertOrReplace(entry: entry1)
        index.insertOrReplace(entry: entry2)
        index.insertOrReplace(entry: entry3)

        #expect(index.contains(key: "key_1"))
        #expect(index.contains(key: "key_2"))
        #expect(index.contains(key: "key_3"))
        #expect(!index.contains(key: "key_missing"))

        let fetched2 = try #require(index.entry(forKey: "key_2"))
        #expect(fetched2.fileName == "file_2.jpg")
        #expect(fetched2.byteSize == 1000)
        #expect(fetched2.accessSequence == 20)

        // Check stats
        let stats = index.stats()
        #expect(stats.count == 3)
        #expect(stats.totalBytes == 3000)

        // Oldest entries ordered by access_sequence ASC
        let oldest = index.fetchOldestEntries(limit: 2)
        #expect(oldest.count == 2)
        #expect(oldest[0].key == "key_1")
        #expect(oldest[1].key == "key_2")

        // Update entry1 access sequence to 40 -> now entry2 is oldest
        index.updateAccess(key: "key_1", lastAccessedAt: Date(timeIntervalSince1970: 4000), accessSequence: 40)
        let oldestAfterUpdate = index.fetchOldestEntries(limit: 1)
        #expect(oldestAfterUpdate.count == 1)
        #expect(oldestAfterUpdate[0].key == "key_2")

        // Remove entry
        index.remove(key: "key_2")
        #expect(!index.contains(key: "key_2"))
        #expect(index.stats().count == 2)
    }

    @Test("SQLiteMediaCacheIndex migrates legacy cache-index.json cleanly")
    func legacyJSONMigration() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jsonURL = root.appendingPathComponent("cache-index.json")
        let legacyEntry = MediaCacheEntry(
            key: "legacy_key",
            fileName: "legacy.jpg",
            byteSize: 2048,
            lastAccessedAt: Date(),
            accessSequence: 42
        )
        let legacyState = MediaCacheIndexState(
            cacheSizeLimitBytes: 500_000_000,
            nextSequence: 43,
            entries: ["legacy_key": legacyEntry]
        )
        let data = try JSONEncoder().encode(legacyState)
        try data.write(to: jsonURL)

        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        let dbURL = root.appendingPathComponent("cache-index.sqlite3")
        let index = SQLiteMediaCacheIndex(databaseURL: dbURL)
        index.migrateLegacyJSONIfNeeded(from: jsonURL, defaultLimitBytes: 100_000_000)

        // Legacy JSON file should be removed after migration
        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))

        // Migrated entry should exist in SQLite database
        let migrated = try #require(index.entry(forKey: "legacy_key"))
        #expect(migrated.fileName == "legacy.jpg")
        #expect(migrated.byteSize == 2048)
        #expect(migrated.accessSequence == 42)

        let limit = index.getMetadata(key: "cache_size_limit_bytes")
        #expect(limit == "500000000")
        let seq = index.getMetadata(key: "next_sequence")
        #expect(seq == "43")
    }

    // MARK: - MediaCache Scaling & Quota Eviction

    @Test("MediaCache enforces byte quota with indexed LRU eviction across multiple stores")
    @MainActor
    func mediaCacheQuotaAndEviction() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDir = root.appendingPathComponent("cache")
        // Limit of 300 bytes -> each entry is 100 bytes
        let cache = MediaCache(cacheDirectoryURL: cacheDir, initialLimitBytes: 300)

        for i in 1...5 {
            let data = Data(repeating: UInt8(i), count: 100)
            cache.storeData(data, forKey: "item_\(i)")
        }

        // Quota is 300 bytes, total cached should be <= 300 bytes
        #expect(cache.totalCachedBytes <= 300)
        #expect(cache.entryCount <= 3)

        // Items 1 and 2 should have been evicted; items 3, 4, 5 should remain
        #expect(!cache.contains(key: "item_1"))
        #expect(!cache.contains(key: "item_2"))
        #expect(cache.contains(key: "item_3"))
        #expect(cache.contains(key: "item_4"))
        #expect(cache.contains(key: "item_5"))
    }

    // MARK: - MetalDownsampler Tests

    @Test("MetalDownsampler downsamples large images to bounded maxPixelSize preserving aspect ratio")
    func metalDownsamplerDownsamples() {
        let original = createTestCGImage(width: 4000, height: 3000)
        let downsampled = MetalDownsampler.downsample(cgImage: original, maxPixelSize: 1000)

        #expect(max(downsampled.width, downsampled.height) == 1000)
        #expect(downsampled.width == 1000)
        #expect(downsampled.height == 750)
    }

    @Test("MetalDownsampler preserves images already smaller than maxPixelSize")
    func metalDownsamplerPassesThroughSmallImages() {
        let original = createTestCGImage(width: 400, height: 300)
        let result = MetalDownsampler.downsample(cgImage: original, maxPixelSize: 1000)

        #expect(result.width == 400)
        #expect(result.height == 300)
    }
}
