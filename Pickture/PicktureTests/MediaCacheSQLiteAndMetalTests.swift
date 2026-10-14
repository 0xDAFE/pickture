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

    @Test("SQLiteMediaCacheIndex records dimensions, calculates aspect ratios, and batch queries across large slices")
    func sqliteIndexDimensionsAndBatchAspectRatios() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("cache-index.sqlite3")
        let index = SQLiteMediaCacheIndex(databaseURL: dbURL)

        // 1. Insert entries with pixel dimensions
        let entry1 = MediaCacheEntry(
            key: "photo_3_2",
            fileName: "photo1.jpg",
            byteSize: 200,
            pixelWidth: 3000,
            pixelHeight: 2000
        )
        let entry2 = MediaCacheEntry(
            key: "video_16_9",
            fileName: "video1.mov",
            byteSize: 500,
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        let entryNoDim = MediaCacheEntry(
            key: "unknown_dim",
            fileName: "raw1.cr3",
            byteSize: 100
        )

        index.insertOrReplace(entry: entry1)
        index.insertOrReplace(entry: entry2)
        index.insertOrReplace(entry: entryNoDim)

        let fetched1 = try #require(index.entry(forKey: "photo_3_2"))
        #expect(fetched1.pixelWidth == 3000)
        #expect(fetched1.pixelHeight == 2000)
        #expect(abs((fetched1.aspectRatio ?? 0) - 1.5) < 0.001)

        let fetched2 = try #require(index.entry(forKey: "video_16_9"))
        #expect(fetched2.pixelWidth == 1920)
        #expect(fetched2.pixelHeight == 1080)
        #expect(abs((fetched2.aspectRatio ?? 0) - (16.0 / 9.0)) < 0.001)

        let fetchedNoDim = try #require(index.entry(forKey: "unknown_dim"))
        #expect(fetchedNoDim.pixelWidth == nil)
        #expect(fetchedNoDim.pixelHeight == nil)
        #expect(fetchedNoDim.aspectRatio == nil)

        // 2. updateDimensions
        index.updateDimensions(key: "unknown_dim", pixelWidth: 4000, pixelHeight: 3000)
        #expect(abs((index.aspectRatio(forKey: "unknown_dim") ?? 0) - (4.0 / 3.0)) < 0.001)

        // 3. batchAspectRatios across > 500 items to exercise slicing logic
        var keysToQuery: [String] = ["photo_3_2", "video_16_9", "unknown_dim", "non_existent"]
        for i in 1...600 {
            let key = "synthetic_\(i)"
            let width = 1000 + i
            let height = 1000
            index.insertOrReplace(entry: MediaCacheEntry(
                key: key,
                fileName: "\(key).jpg",
                byteSize: 50,
                pixelWidth: width,
                pixelHeight: height
            ))
            keysToQuery.append(key)
        }

        let batchResults = index.batchAspectRatios(keys: keysToQuery)
        #expect(batchResults.count == 603) // 3 existing + 600 synthetic, non_existent omitted
        #expect(abs((batchResults["photo_3_2"] ?? 0) - 1.5) < 0.001)
        #expect(abs((batchResults["video_16_9"] ?? 0) - (16.0 / 9.0)) < 0.001)
        #expect(abs((batchResults["unknown_dim"] ?? 0) - (4.0 / 3.0)) < 0.001)
        #expect(batchResults["non_existent"] == nil)
        #expect(abs((batchResults["synthetic_600"] ?? 0) - 1.6) < 0.001)
    }

    @Test("SQLiteMediaCacheIndex retains and reuses prepared statements across repeated operations without recompilation")
    func sqliteIndexStatementReuse() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("cache-index.sqlite3")
        let index = SQLiteMediaCacheIndex(databaseURL: dbURL)

        let initialPointers = index.preparedStatementPointers
        #expect(initialPointers["contains"] != nil)
        #expect(initialPointers["entry"] != nil)
        #expect(initialPointers["insertOrReplace"] != nil)
        #expect(initialPointers["updateAccess"] != nil)
        #expect(initialPointers["updateDimensions"] != nil)
        #expect(initialPointers["aspectRatio"] != nil)
        #expect(initialPointers["getMetadata"] != nil)
        #expect(initialPointers["setMetadata"] != nil)

        // Perform multiple insertions, metadata writes, and lookups
        for i in 1...20 {
            index.setMetadata(key: "meta_\(i)", value: "val_\(i)")
            #expect(index.getMetadata(key: "meta_\(i)") == "val_\(i)")

            let entry = MediaCacheEntry(
                key: "key_\(i)",
                fileName: "file_\(i).jpg",
                byteSize: 100,
                pixelWidth: 1000 + i,
                pixelHeight: 1000
            )
            index.insertOrReplace(entry: entry)
            #expect(index.contains(key: "key_\(i)"))
            #expect(index.entry(forKey: "key_\(i)")?.byteSize == 100)
            index.updateAccess(key: "key_\(i)", lastAccessedAt: Date(), accessSequence: UInt64(i))
            index.updateDimensions(key: "key_\(i)", pixelWidth: 2000 + i, pixelHeight: 1000)
            #expect(index.aspectRatio(forKey: "key_\(i)") != nil)
        }

        // Test batchAspectRatios statement reuse across multiple iterations
        let batchKeys = (1...20).map { "key_\($0)" }
        for _ in 1...5 {
            let ratios = index.batchAspectRatios(keys: batchKeys)
            #expect(ratios.count == 20)
        }

        // Verify statement pointers remained unchanged (retained, never recompiled or leaked)
        let finalPointers = index.preparedStatementPointers
        for (key, ptr) in initialPointers {
            #expect(finalPointers[key] == ptr, "Statement pointer for \(key) must remain identical across operations")
        }
    }

    @Test("MediaCache records dimensions and provides batch aspect ratio lookups")
    func mediaCacheDimensionsAndBatchAspectRatios() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDir = root.appendingPathComponent("cache")
        let cache = MediaCache(cacheDirectoryURL: cacheDir, initialLimitBytes: 10_000)

        let dummyData = Data(repeating: 0xAA, count: 64)
        await cache.storeData(dummyData, forKey: "item_portrait", pixelWidth: 2000, pixelHeight: 3000)
        await cache.storeData(dummyData, forKey: "item_landscape", pixelWidth: 6000, pixelHeight: 4000)

        #expect(abs((await cache.aspectRatio(forKey: "item_portrait") ?? 0) - (2.0 / 3.0)) < 0.001)
        #expect(abs((await cache.aspectRatio(forKey: "item_landscape") ?? 0) - 1.5) < 0.001)
        #expect(await cache.aspectRatio(forKey: "item_missing") == nil)

        let batch = await cache.batchAspectRatios(keys: ["item_portrait", "item_landscape", "item_missing"])
        #expect(batch.count == 2)
        #expect(abs((batch["item_portrait"] ?? 0) - (2.0 / 3.0)) < 0.001)
        #expect(abs((batch["item_landscape"] ?? 0) - 1.5) < 0.001)
    }

    // MARK: - MediaCache Scaling & Quota Eviction

    @Test("MediaCache enforces byte quota with indexed LRU eviction across multiple stores")
    func mediaCacheQuotaAndEviction() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDir = root.appendingPathComponent("cache")
        // Limit of 300 bytes -> each entry is 100 bytes
        let cache = MediaCache(cacheDirectoryURL: cacheDir, initialLimitBytes: 300)

        for i in 1...5 {
            let data = Data(repeating: UInt8(i), count: 100)
            await cache.storeData(data, forKey: "item_\(i)")
        }

        // Quota is 300 bytes, total cached should be <= 300 bytes
        #expect(await cache.totalCachedBytes <= 300)
        #expect(await cache.entryCount <= 3)

        // Items 1 and 2 should have been evicted; items 3, 4, 5 should remain
        #expect(await !cache.contains(key: "item_1"))
        #expect(await !cache.contains(key: "item_2"))
        #expect(await cache.contains(key: "item_3"))
        #expect(await cache.contains(key: "item_4"))
        #expect(await cache.contains(key: "item_5"))
    }

    @Test("MediaCache executes background actor operations safely off @MainActor under concurrent read/write access")
    func mediaCacheActorBackgroundThreadSafety() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDir = root.appendingPathComponent("cache")
        let cache = MediaCache(cacheDirectoryURL: cacheDir, initialLimitBytes: 100_000)

        // Concurrently write and read from 30 detached tasks (off @MainActor)
        await withTaskGroup(of: Void.self) { group in
            for i in 1...30 {
                group.addTask {
                    let dummyData = Data(repeating: UInt8(i % 255), count: 200)
                    let key = "concurrent_item_\(i)"
                    await cache.storeData(dummyData, forKey: key, pixelWidth: 1600, pixelHeight: 1200)
                    let readBack = await cache.readData(forKey: key)
                    #expect(readBack == dummyData)
                    let exists = await cache.contains(key: key)
                    #expect(exists == true)
                    let ratio = await cache.aspectRatio(forKey: key)
                    #expect(ratio != nil)
                }
            }
        }

        let metrics = await cache.metrics()
        #expect(metrics.count == 30)
        #expect(metrics.totalBytes == 30 * 200)
    }

    @Test("MediaCache provides consistent batch aspect ratio lookups under concurrent worker load")
    func mediaCacheBatchAspectRatiosUnderConcurrentLoad() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDir = root.appendingPathComponent("cache")
        let cache = MediaCache(cacheDirectoryURL: cacheDir, initialLimitBytes: 500_000)

        // Seed 100 entries
        var keys: [String] = []
        for i in 1...100 {
            let key = "aspect_item_\(i)"
            keys.append(key)
            let data = Data(repeating: 0x55, count: 50)
            await cache.storeData(data, forKey: key, pixelWidth: 3000, pixelHeight: 2000)
        }

        // Concurrently query batchAspectRatios from 15 detached tasks
        await withTaskGroup(of: Bool.self) { group in
            for _ in 1...15 {
                let slice = Array(keys.shuffled().prefix(40))
                group.addTask {
                    let results = await cache.batchAspectRatios(keys: slice)
                    guard results.count == slice.count else { return false }
                    for key in slice {
                        guard let ratio = results[key], abs(ratio - 1.5) < 0.001 else {
                            return false
                        }
                    }
                    return true
                }
            }

            for await taskSuccess in group {
                #expect(taskSuccess == true)
            }
        }
    }

    @Test("MediaCache strictly enforces LRU byte quota eviction under tight capacity")
    func mediaCacheLRUEvictionStrictLimit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDir = root.appendingPathComponent("cache")
        // Limit: 500 bytes. Store 10 items of 100 bytes each -> only 5 can remain
        let cache = MediaCache(cacheDirectoryURL: cacheDir, initialLimitBytes: 500)

        for i in 1...10 {
            let data = Data(repeating: UInt8(i), count: 100)
            await cache.storeData(data, forKey: "lru_\(i)")
        }

        let metrics = await cache.metrics()
        #expect(metrics.totalBytes <= 500)
        #expect(metrics.count <= 5)

        // Items 1 through 5 should have been evicted; items 6 through 10 remain
        for i in 1...5 {
            #expect(await !cache.contains(key: "lru_\(i)"))
        }
        for i in 6...10 {
            #expect(await cache.contains(key: "lru_\(i)"))
        }

        // Dynamically lower limit to 200 bytes -> evicts down to 2 items
        await cache.setCacheSizeLimitBytes(200)
        let loweredMetrics = await cache.metrics()
        #expect(loweredMetrics.totalBytes <= 200)
        #expect(loweredMetrics.count <= 2)
        #expect(await cache.contains(key: "lru_9"))
        #expect(await cache.contains(key: "lru_10"))
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

    @Test("MetalDownsampler downsamples using bicubic Catmull-Rom spline filter")
    func metalDownsamplerBicubic() {
        let original = createTestCGImage(width: 4000, height: 3000)
        let downsampled = MetalDownsampler.downsample(cgImage: original, maxPixelSize: 1000, algorithm: .bicubic())

        #expect(max(downsampled.width, downsampled.height) == 1000)
        #expect(downsampled.width == 1000)
        #expect(downsampled.height == 750)
    }
}
