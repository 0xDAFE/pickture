import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@MainActor
struct MediaPipelineTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func writeSampleRasterImage(to url: URL, red: UInt8 = 100, green: UInt8 = 150, blue: UInt8 = 200, width: Int = 96, height: Int = 96) throws {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            pixels[idx] = red
            pixels[idx + 1] = green
            pixels[idx + 2] = blue
            pixels[idx + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try (mutableData as Data).write(to: url)
    }

    private func makeStandaloneMediaItem(fileURL: URL) -> MediaItem {
        let file = MediaFile(url: fileURL, formatKind: .raster)
        return MediaItem(
            id: file.id,
            baseName: file.baseName,
            directoryURL: fileURL.deletingLastPathComponent(),
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: file,
            mediaPair: nil,
            sidecarURL: nil
        )
    }

    @Test("MediaPipeline initializes with default quota, 0 cached bytes, and custom parameters")
    func pipelineInitializationAndLimits() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pipelineDefault = MediaPipeline(cacheDirectoryURL: tempDir.appendingPathComponent("cache1"))
        #expect(pipelineDefault.totalCachedBytes == 0)
        #expect(pipelineDefault.cacheSizeLimitBytes == MediaCache.defaultQuotaBytes)

        let customLimit: Int64 = 500 * 1024 * 1024
        let pipelineCustom = MediaPipeline(
            cacheDirectoryURL: tempDir.appendingPathComponent("cache2"),
            initialLimitBytes: customLimit,
            maxConcurrentThumbnailWorkers: 2
        )
        #expect(pipelineCustom.totalCachedBytes == 0)
        #expect(pipelineCustom.cacheSizeLimitBytes == customLimit)
    }

    @Test("Thumbnail loading caches data, exposes CGImage, and returns cached data on repeat calls")
    func thumbnailLoadingAndCaching() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imageURL = tempDir.appendingPathComponent("photo1.jpg")
        try writeSampleRasterImage(to: imageURL)
        let item = makeStandaloneMediaItem(fileURL: imageURL)

        let pipeline = MediaPipeline(cacheDirectoryURL: tempDir.appendingPathComponent("cache"))

        // Before loading: item is not cached
        #expect(!pipeline.isThumbnailCached(for: item, previewSource: .preferRaster))
        #expect(pipeline.cachedThumbnailImage(for: item, previewSource: .preferRaster) == nil)

        // Load thumbnail data
        let loadedData = try #require(await pipeline.loadThumbnailData(for: item, previewSource: .preferRaster, maxPixelSize: 360))
        #expect(!loadedData.isEmpty)

        // Now cached
        #expect(pipeline.isThumbnailCached(for: item, previewSource: .preferRaster))
        let cachedImage = try #require(pipeline.cachedThumbnailImage(for: item, previewSource: .preferRaster))
        #expect(cachedImage.width > 0)
        #expect(cachedImage.height > 0)
        #expect(pipeline.totalCachedBytes > 0)

        // Repeat call hits cache
        let cachedData = try #require(await pipeline.loadThumbnailData(for: item, previewSource: .preferRaster, maxPixelSize: 360))
        #expect(cachedData == loadedData)
    }

    @Test("Preview image loading caches distinct preview data and generates valid CGImage")
    func previewLoadingAndCachingWithDistinctKeys() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imageURL = tempDir.appendingPathComponent("photo2.jpg")
        try writeSampleRasterImage(to: imageURL, width: 200, height: 200)
        let item = makeStandaloneMediaItem(fileURL: imageURL)

        let pipeline = MediaPipeline(cacheDirectoryURL: tempDir.appendingPathComponent("cache"))

        let thumbKey = pipeline.thumbnailCacheKey(for: item, previewSource: .preferRaster, maxPixelSize: 360)
        let previewKey = pipeline.previewCacheKey(for: item, previewSource: .preferRaster, maxPixelSize: 2048)
        #expect(thumbKey != previewKey)
        #expect(previewKey.contains("#preview#"))

        // Preview before load
        #expect(pipeline.cachedPreviewImage(for: item, previewSource: .preferRaster) == nil)

        // Load preview
        let previewData = try #require(await pipeline.loadPreviewImageData(for: item, previewSource: .preferRaster, maxPixelSize: 2048))
        #expect(!previewData.isEmpty)

        // Preview after load
        let previewCG = try #require(pipeline.cachedPreviewImage(for: item, previewSource: .preferRaster))
        #expect(previewCG.width > 0)
        #expect(previewCG.height > 0)
    }

    @Test("Thumbnail queue executes requests in LIFO order")
    func thumbnailQueueLIFOPriority() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pipeline = MediaPipeline(
            cacheDirectoryURL: tempDir.appendingPathComponent("cache"),
            maxConcurrentThumbnailWorkers: 1
        )

        let queue = pipeline.thumbnailQueue
        let orderTracker = ExecutionOrderTracker()
        let blockerStarted = AsyncSignal()
        let blockerRelease = AsyncSignal()

        let blockerTask = Task {
            await queue.enqueue(id: "blocker") {
                await blockerStarted.signal()
                await blockerRelease.wait()
                return Data("blocker".utf8)
            }
        }

        await blockerStarted.wait()

        let task1 = Task {
            await queue.enqueue(id: "item1") {
                await orderTracker.record("item1")
                return Data("item1".utf8)
            }
        }
        while await queue.pendingCount < 1 {
            await Task.yield()
        }

        let task2 = Task {
            await queue.enqueue(id: "item2") {
                await orderTracker.record("item2")
                return Data("item2".utf8)
            }
        }
        while await queue.pendingCount < 2 {
            await Task.yield()
        }

        let task3 = Task {
            await queue.enqueue(id: "item3") {
                await orderTracker.record("item3")
                return Data("item3".utf8)
            }
        }
        while await queue.pendingCount < 3 {
            await Task.yield()
        }

        await blockerRelease.signal()
        _ = await blockerTask.value
        _ = await task3.value
        _ = await task2.value
        _ = await task1.value

        let order = await orderTracker.order
        #expect(order == ["item3", "item2", "item1"])
    }

    @Test("Thumbnail cancellation cancels pending worker immediately")
    func thumbnailCancellation() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pipeline = MediaPipeline(
            cacheDirectoryURL: tempDir.appendingPathComponent("cache"),
            maxConcurrentThumbnailWorkers: 1
        )
        let queue = pipeline.thumbnailQueue
        let blockerStarted = AsyncSignal()
        let blockerRelease = AsyncSignal()

        let blockerTask = Task {
            await queue.enqueue(id: "blocker") {
                await blockerStarted.signal()
                await blockerRelease.wait()
                return Data("blocker".utf8)
            }
        }
        await blockerStarted.wait()

        let imageURL = tempDir.appendingPathComponent("photo_cancel.jpg")
        try writeSampleRasterImage(to: imageURL)
        let item = makeStandaloneMediaItem(fileURL: imageURL)

        let loadTask = Task {
            await pipeline.loadThumbnailData(for: item, previewSource: .preferRaster)
        }

        while await queue.pendingCount < 1 {
            await Task.yield()
        }

        // Cancel the pending thumbnail
        await pipeline.cancelThumbnailImmediately(for: item, previewSource: .preferRaster)

        await blockerRelease.signal()
        _ = await blockerTask.value
        let result = await loadTask.value
        #expect(result == nil)
        #expect(!pipeline.isThumbnailCached(for: item, previewSource: .preferRaster))
    }

    @Test("Cache quota clamping and LRU eviction under byte quota")
    func cacheQuotaClampingAndEviction() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pipeline = MediaPipeline(cacheDirectoryURL: tempDir.appendingPathComponent("cache"))

        // Clamping checks
        pipeline.setUserConfiguredCacheSizeLimitBytes(10 * 1024 * 1024)
        #expect(pipeline.cacheSizeLimitBytes == MediaCache.minUserQuotaBytes)

        pipeline.setUserConfiguredCacheSizeLimitBytes(50 * 1024 * 1024 * 1024)
        #expect(pipeline.cacheSizeLimitBytes == MediaCache.maxUserQuotaBytes)

        // Store two items
        let item1URL = tempDir.appendingPathComponent("item1.jpg")
        let item2URL = tempDir.appendingPathComponent("item2.jpg")
        try writeSampleRasterImage(to: item1URL)
        try writeSampleRasterImage(to: item2URL)
        let item1 = makeStandaloneMediaItem(fileURL: item1URL)
        let item2 = makeStandaloneMediaItem(fileURL: item2URL)

        _ = try #require(await pipeline.loadThumbnailData(for: item1, previewSource: .preferRaster))
        _ = try #require(await pipeline.loadThumbnailData(for: item2, previewSource: .preferRaster))

        #expect(pipeline.isThumbnailCached(for: item1, previewSource: .preferRaster))
        #expect(pipeline.isThumbnailCached(for: item2, previewSource: .preferRaster))

        let total = pipeline.totalCachedBytes
        #expect(total > 0)

        // Evict item1 by setting quota lower than total bytes but >= item2's size
        pipeline.setCacheSizeLimitBytes(total / 2)
        #expect(pipeline.totalCachedBytes <= total / 2)
        #expect(!pipeline.isThumbnailCached(for: item1, previewSource: .preferRaster))
        #expect(pipeline.isThumbnailCached(for: item2, previewSource: .preferRaster))
    }

    @Test("clearCache removes all entries and flushIndexImmediately writes index to disk")
    func clearCacheAndFlushIndex() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheDir = tempDir.appendingPathComponent("cache")
        let pipeline = MediaPipeline(cacheDirectoryURL: cacheDir)

        let itemURL = tempDir.appendingPathComponent("item.jpg")
        try writeSampleRasterImage(to: itemURL)
        let item = makeStandaloneMediaItem(fileURL: itemURL)

        _ = try #require(await pipeline.loadThumbnailData(for: item, previewSource: .preferRaster))
        #expect(pipeline.totalCachedBytes > 0)
        #expect(pipeline.isThumbnailCached(for: item, previewSource: .preferRaster))

        pipeline.clearCache()
        #expect(pipeline.totalCachedBytes == 0)
        #expect(!pipeline.isThumbnailCached(for: item, previewSource: .preferRaster))

        pipeline.flushIndexImmediately()
        let indexFile = cacheDir.appendingPathComponent("cache-index.json")
        #expect(FileManager.default.fileExists(atPath: indexFile.path))
    }

    @Test("Preview image loading bounds decode concurrency with HeavyDecodeLimiter")
    func previewLoadingThrottledViaHeavyDecodeLimiter() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pipeline = MediaPipeline(cacheDirectoryURL: tempDir.appendingPathComponent("cache"))

        var items: [MediaItem] = []
        for i in 1...4 {
            let imageURL = tempDir.appendingPathComponent("preview_\(i).jpg")
            try writeSampleRasterImage(to: imageURL, width: 120, height: 120)
            items.append(makeStandaloneMediaItem(fileURL: imageURL))
        }

        await withTaskGroup(of: Data?.self) { group in
            for item in items {
                group.addTask {
                    await pipeline.loadPreviewImageData(for: item, previewSource: .preferRaster)
                }
            }
            for await res in group {
                #expect(res != nil)
            }
        }

        #expect(pipeline.totalCachedBytes > 0)
    }

    @Test("cancelThumbnail method cancels queued requests without detached task")
    func cancelThumbnailAsyncMethod() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pipeline = MediaPipeline(
            cacheDirectoryURL: tempDir.appendingPathComponent("cache"),
            maxConcurrentThumbnailWorkers: 1
        )
        let queue = pipeline.thumbnailQueue
        let blockerStarted = AsyncSignal()
        let blockerRelease = AsyncSignal()

        let blockerTask = Task {
            await queue.enqueue(id: "blocker") {
                await blockerStarted.signal()
                await blockerRelease.wait()
                return Data("blocker".utf8)
            }
        }
        await blockerStarted.wait()

        let imageURL = tempDir.appendingPathComponent("cancel_photo.jpg")
        try writeSampleRasterImage(to: imageURL)
        let item = makeStandaloneMediaItem(fileURL: imageURL)

        let loadTask = Task {
            await pipeline.loadThumbnailData(for: item, previewSource: .preferRaster)
        }

        while await queue.pendingCount < 1 {
            await Task.yield()
        }

        pipeline.cancelThumbnail(for: item, previewSource: .preferRaster)

        try? await Task.sleep(nanoseconds: 50_000_000)

        await blockerRelease.signal()
        _ = await blockerTask.value
        let result = await loadTask.value
        #expect(result == nil)
    }
}
