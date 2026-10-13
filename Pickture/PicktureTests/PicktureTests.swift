//
//  PicktureTests.swift
//  PicktureTests
//
//  Created by Vibe Coder on 27.09.26.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@MainActor
struct CullingSessionDiscoveryAndCacheTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("Discover immediate directory pairs case-insensitive RAW and raster files into a single MediaPair MediaItem")
    func discoverImmediateFolderPairsRawAndRaster() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create matching RAW + JPG with different casing in the root directory
        try Data("raw-bytes".utf8).write(to: root.appendingPathComponent("DSC0001.ARW"))
        try Data("jpg-bytes".utf8).write(to: root.appendingPathComponent("dsc0001.jpg"))
        // Create standalone PNG
        try Data("png-bytes".utf8).write(to: root.appendingPathComponent("DSC0002.PNG"))
        // Create sidecar and hidden file that should not become standalone MediaItems
        try Data("<xmp/>".utf8).write(to: root.appendingPathComponent("DSC0001.xmp"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".DS_Store"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try session.openFolder(at: root)

        #expect(session.items.count == 2)

        let first = try #require(session.items.first { $0.baseName.uppercased() == "DSC0001" })
        #expect(first.isMediaPair == true)
        #expect(first.kind == .photo)
        #expect(first.badgeText == "RAW+JPG")
        #expect(first.mediaPair?.rawFile.fileExtension.uppercased() == "ARW")
        #expect(first.mediaPair?.rasterFile.fileExtension.uppercased() == "JPG")

        let second = try #require(session.items.first { $0.baseName.uppercased() == "DSC0002" })
        #expect(second.isMediaPair == false)
        #expect(second.kind == .photo)
    }

    @Test("Toggling SubfolderMode switches between immediate and recursive discovery without pairing across directories")
    func discoverSubfolderModeAndDirectoryScopedPairing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let day1 = root.appendingPathComponent("Day1", isDirectory: true)
        let day2Nested = root.appendingPathComponent("Day2/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: day1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: day2Nested, withIntermediateDirectories: true)

        // DSC0010.ARW in root and DSC0010.JPG in Day1 (different directories -> must NOT pair)
        try Data("raw-root".utf8).write(to: root.appendingPathComponent("DSC0010.ARW"))
        try Data("jpg-day1".utf8).write(to: day1.appendingPathComponent("DSC0010.JPG"))

        // DSC0020.NEF + dsc0020.heic in Day1 (same directory -> MUST pair)
        try Data("nef-day1".utf8).write(to: day1.appendingPathComponent("DSC0020.NEF"))
        try Data("heic-day1".utf8).write(to: day1.appendingPathComponent("dsc0020.heic"))

        // DSC0020.JPG in Day2/Nested (different directory -> must remain standalone)
        try Data("jpg-day2".utf8).write(to: day2Nested.appendingPathComponent("DSC0020.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try session.openFolder(at: root)

        // Default is .immediate: only root's DSC0010.ARW is discovered
        #expect(session.subfolderMode == .immediate)
        #expect(session.items.count == 1)
        #expect(session.items[0].baseName == "DSC0010")
        #expect(session.items[0].isMediaPair == false)

        // Switch to recursive SubfolderMode
        try await session.setSubfolderMode(.recursive)
        #expect(session.subfolderMode == .recursive)
        #expect(session.items.count == 4)

        let dsc0010Items = session.items.filter { $0.baseName.uppercased() == "DSC0010" }
        #expect(dsc0010Items.count == 2)
        #expect(dsc0010Items.allSatisfy { !$0.isMediaPair })

        let day1Pair = try #require(session.items.first {
            $0.baseName.uppercased() == "DSC0020" && $0.relativeDirectoryPath == "Day1"
        })
        #expect(day1Pair.isMediaPair == true)
        #expect(day1Pair.badgeText == "RAW+JPG")

        let day2Standalone = try #require(session.items.first {
            $0.baseName.uppercased() == "DSC0020" && $0.relativeDirectoryPath == "Day2/Nested"
        })
        #expect(day2Standalone.isMediaPair == false)

        // Toggle back to .immediate
        try await session.toggleSubfolderMode()
        #expect(session.subfolderMode == .immediate)
        #expect(session.items.count == 1)
    }

    @Test("Recursive discovery skips non-media cache bundles (*.lrdata, *.lrcat, CaptureOne, @eaDir, .Trashes, .Spotlight-V100)")
    func discoverRecursiveSkipsCacheAndThumbnailDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Valid subfolder with photos
        let shootDay = root.appendingPathComponent("Day1", isDirectory: true)
        try FileManager.default.createDirectory(at: shootDay, withIntermediateDirectories: true)
        try Data("jpg-day1".utf8).write(to: shootDay.appendingPathComponent("VALID_001.JPG"))

        // Known non-media cache directories that MUST be skipped
        let lrDataDir = root.appendingPathComponent("Lightroom Catalog.lrdata", isDirectory: true)
        let lrCatDir = root.appendingPathComponent("Session.lrcat", isDirectory: true)
        let c1Dir = root.appendingPathComponent("CaptureOne/Cache/Proxies", isDirectory: true)
        let eaDir = root.appendingPathComponent("@eaDir/SubFolder", isDirectory: true)
        let trashesDir = root.appendingPathComponent(".Trashes", isDirectory: true)
        let spotlightDir = root.appendingPathComponent(".Spotlight-V100", isDirectory: true)
        let fseventsDir = root.appendingPathComponent(".fseventsd", isDirectory: true)
        let tempItemsDir = root.appendingPathComponent(".TemporaryItems", isDirectory: true)

        let cacheDirs = [lrDataDir, lrCatDir, c1Dir, eaDir, trashesDir, spotlightDir, fseventsDir, tempItemsDir]
        for dir in cacheDirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Put decoy image files inside cache directories
            try Data("decoy-thumb".utf8).write(to: dir.appendingPathComponent("thumb.jpg"))
            try Data("decoy-preview".utf8).write(to: dir.appendingPathComponent("preview.PNG"))
        }

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try session.openFolder(at: root)
        try await session.setSubfolderMode(.recursive)

        // Only the valid photo in Day1 should be discovered; all decoys in cache dirs must be skipped
        #expect(session.items.count == 1)
        #expect(session.items[0].baseName == "VALID_001")
        #expect(session.items[0].relativeDirectoryPath == "Day1")
    }

    @Test("Video files (.mov, .mp4, .m4v) are discovered as standalone MediaItems even when sharing a basename with a still photo")
    func discoverVideoFilesRemainStandaloneEvenWithMatchingPhotoBasename() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("raw".utf8).write(to: root.appendingPathComponent("DSC0050.ARW"))
        try Data("jpg".utf8).write(to: root.appendingPathComponent("DSC0050.JPG"))
        try Data("mov".utf8).write(to: root.appendingPathComponent("DSC0050.MOV"))
        try Data("mp4".utf8).write(to: root.appendingPathComponent("CLIP0001.mp4"))
        try Data("m4v".utf8).write(to: root.appendingPathComponent("CLIP0002.M4V"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try session.openFolder(at: root)

        #expect(session.items.count == 4)

        let dsc0050Items = session.items.filter { $0.baseName.uppercased() == "DSC0050" }
        #expect(dsc0050Items.count == 2)

        let photoPair = try #require(dsc0050Items.first { $0.kind == .photo })
        #expect(photoPair.isMediaPair == true)
        #expect(photoPair.badgeText == "RAW+JPG")
        #expect(photoPair.mediaTypeBadge == "Photo")

        let videoItem = try #require(dsc0050Items.first { $0.kind == .video })
        #expect(videoItem.isMediaPair == false)
        #expect(videoItem.badgeText == "VIDEO")
        #expect(videoItem.mediaTypeBadge == "Video")
        #expect(videoItem.primaryFile.fileExtension.uppercased() == "MOV")

        let mp4Item = try #require(session.items.first { $0.baseName.uppercased() == "CLIP0001" })
        #expect(mp4Item.kind == .video)
        #expect(mp4Item.isMediaPair == false)

        let m4vItem = try #require(session.items.first { $0.baseName.uppercased() == "CLIP0002" })
        #expect(m4vItem.kind == .video)
        #expect(m4vItem.isMediaPair == false)
    }

    @Test("Recently opened folders are persisted with bookmark data and can be reopened across CullingSession launches")
    func recentFoldersPersistViaBookmarkAndReopenAcrossAppLaunches() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let shootFolder = root.appendingPathComponent("WeddingShoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shootFolder, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: shootFolder.appendingPathComponent("IMG_1001.CR3"))
        try Data("jpg".utf8).write(to: shootFolder.appendingPathComponent("IMG_1001.JPG"))

        let storeURL = root.appendingPathComponent(".test-store", isDirectory: true)

        // First launch: open folder and verify recent folder bookmark is recorded
        let session1 = CullingSession(storageRootURL: storeURL)
        try session1.openFolder(at: shootFolder)
        #expect(session1.recentFolders.count == 1)
        #expect(session1.recentFolders[0].name == "WeddingShoot")
        #expect(!session1.recentFolders[0].bookmarkData.isEmpty)

        // Second launch: create a new CullingSession pointing to the same storageRootURL
        let session2 = CullingSession(storageRootURL: storeURL)
        #expect(session2.recentFolders.count == 1)
        let savedFolder = session2.recentFolders[0]
        #expect(savedFolder.name == "WeddingShoot")

        // Reopen with one call (simulating one-tap reopen in UI)
        try session2.reopenRecentFolder(savedFolder)
        #expect(session2.currentFolderURL?.lastPathComponent == "WeddingShoot")
        #expect(session2.items.count == 1)
        #expect(session2.items[0].isMediaPair == true)
    }

    @Test func reopenRecentFolderAsyncStreamsAndOpensFolder() async throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let storeURL = tempRoot.appendingPathComponent(".session-store", isDirectory: true)
        let shootFolder = tempRoot.appendingPathComponent("AsyncShoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shootFolder, withIntermediateDirectories: true)

        let jpgURL = shootFolder.appendingPathComponent("DSC0001.JPG")
        try writeSampleRasterImage(to: jpgURL, red: 10, green: 20, blue: 30)

        let session1 = CullingSession(storageRootURL: storeURL)
        try await session1.openFolderAsync(at: shootFolder)
        #expect(session1.recentFolders.count == 1)
        let saved = session1.recentFolders[0]

        let session2 = CullingSession(storageRootURL: storeURL)
        try await session2.reopenRecentFolderAsync(saved)
        #expect(session2.currentFolderURL?.lastPathComponent == "AsyncShoot")
        #expect(session2.items.count == 1)
    }

    private func writeSampleRasterImage(to url: URL, red: UInt8, green: UInt8, blue: UInt8) throws {
        let width = 96
        let height = 96
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

    @Test("Streaming CGImageSource extracts thumbnails into MediaCache and enforces LRU eviction under byte quota")
    func thumbnailExtractionAndMediaCacheLRUEviction() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSampleRasterImage(to: root.appendingPathComponent("IMG_001.JPG"), red: 220, green: 40, blue: 40)
        try writeSampleRasterImage(to: root.appendingPathComponent("IMG_002.JPG"), red: 40, green: 220, blue: 40)
        try writeSampleRasterImage(to: root.appendingPathComponent("IMG_003.JPG"), red: 40, green: 40, blue: 220)

        let storeURL = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeURL)
        try session.openFolder(at: root)
        #expect(session.items.count == 3)

        let item1 = session.items[0]
        let item2 = session.items[1]
        let item3 = session.items[2]

        let data1 = try #require(await session.loadThumbnailData(for: item1))
        let data2 = try #require(await session.loadThumbnailData(for: item2))
        #expect(!data1.isEmpty)
        #expect(!data2.isEmpty)
        #expect(session.isThumbnailCached(for: item1) == true)
        #expect(session.isThumbnailCached(for: item2) == true)

        let twoItemsByteLimit = Int64(data1.count + data2.count)
        session.setCacheSizeLimitBytes(twoItemsByteLimit)
        #expect(session.mediaCacheTotalBytes == twoItemsByteLimit)

        // Touch item1 so item1 becomes most-recently-used and item2 becomes least-recently-used
        _ = await session.loadThumbnailData(for: item1)

        // Load item3, which exceeds twoItemsByteLimit and must evict item2 (LRU) while keeping item1 and item3
        let data3 = try #require(await session.loadThumbnailData(for: item3))
        #expect(!data3.isEmpty)
        #expect(session.mediaCacheTotalBytes <= twoItemsByteLimit)
        #expect(session.isThumbnailCached(for: item1) == true)
        #expect(session.isThumbnailCached(for: item2) == false)
        #expect(session.isThumbnailCached(for: item3) == true)
    }

    @Test("clearMediaCache purges all cached thumbnails without deleting pending edits in MetadataSyncStore")
    func clearMediaCachePurgesThumbnailsWithoutTouchingMetadataSyncStore() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSampleRasterImage(to: root.appendingPathComponent("DSC0100.JPG"), red: 180, green: 90, blue: 30)

        let storeURL = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeURL)
        try session.openFolder(at: root)
        let item = try #require(session.items.first)

        // Populate MediaCache with thumbnail
        let thumbData = try #require(await session.loadThumbnailData(for: item))
        #expect(!thumbData.isEmpty)
        #expect(session.mediaCacheTotalBytes > 0)
        #expect(session.isThumbnailCached(for: item) == true)

        // Record an unsynchronized pending edit in MetadataSyncStore
        let pendingMetadata = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green)
        session.stagePendingMetadata(pendingMetadata, for: item)
        #expect(session.curationMetadata(for: item) == pendingMetadata)
        #expect(session.syncState(for: item) == .pendingWrite)

        // Clear MediaCache explicitly (Settings -> Clear Cache)
        session.clearMediaCache()

        // Verify MediaCache is completely empty
        #expect(session.mediaCacheTotalBytes == 0)
        #expect(session.isThumbnailCached(for: item) == false)

        // Verify MetadataSyncStore still holds the pending edit, including across a new CullingSession restart
        #expect(session.curationMetadata(for: item) == pendingMetadata)
        #expect(session.syncState(for: item) == .pendingWrite)

        await session.waitForPendingStoreWrites()
        let restartedSession = CullingSession(storageRootURL: storeURL)
        try restartedSession.openFolder(at: root)
        let restartedItem = try #require(restartedSession.items.first)
        #expect(restartedSession.curationMetadata(for: restartedItem) == pendingMetadata)
        #expect(restartedSession.syncState(for: restartedItem) == .pendingWrite)
    }

    @Test("Streaming CGImageSource prefers embedded header preview before full decode fallback and clamps user quota to 250 MB – 20 GB")
    func embeddedPreviewExtractionAndUserQuotaClamping() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Write a 640x480 image with an embedded EXIF thumbnail via CGImageDestination (UTType.jpeg + kCGImageDestinationEmbedThumbnail)
        let width = 640
        let height = 480
        let pixels = [UInt8](repeating: 180, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(
            CGImage(
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
            )
        )

        let dngWithEmbeddedThumbURL = root.appendingPathComponent("DSC0999.DNG")
        let embeddedData = NSMutableData()
        let embeddedDest = try #require(
            CGImageDestinationCreateWithData(
                embeddedData as CFMutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            embeddedDest,
            cgImage,
            [kCGImageDestinationEmbedThumbnail: true] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(embeddedDest) == true)
        try (embeddedData as Data).write(to: dngWithEmbeddedThumbURL)

        // 1. Verify DNG with embedded preview uses .embeddedPreview without full decode
        let embeddedResult = try #require(PreviewLoader.extractImageThumbnail(from: dngWithEmbeddedThumbURL, maxPixelSize: 360))
        #expect(embeddedResult.strategy == .embeddedPreview)
        #expect(!embeddedResult.jpegData.isEmpty)

        // 1b. Verify a spec-compliant 2-IFD DNG (IFD0 reduced-resolution preview + SubIFD0 16-bit Bayer CFA sensor data)
        let twoIFDDNGURL = root.appendingPathComponent("DSC0998_TWO_IFD.DNG")
        try makeTwoIFDDNGData().write(to: twoIFDDNGURL)
        let twoIFDResult = try #require(PreviewLoader.extractImageThumbnail(from: twoIFDDNGURL, maxPixelSize: 360))
        #expect(twoIFDResult.strategy == .embeddedPreview)
        #expect(!twoIFDResult.jpegData.isEmpty)

        // 2. Write a TIFF/DNG container WITHOUT an embedded preview (kCGImageDestinationEmbedThumbnail: false)
        // and verify it falls back cleanly to full image/sensor decode (.fullDecodeFallback)
        let dngWithoutEmbeddedPreviewURL = root.appendingPathComponent("DSC1000_UNEMBEDDED.DNG")
        let unembeddedData = NSMutableData()
        let unembeddedDest = try #require(
            CGImageDestinationCreateWithData(
                unembeddedData as CFMutableData,
                UTType.tiff.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            unembeddedDest,
            cgImage,
            [kCGImageDestinationEmbedThumbnail: false] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(unembeddedDest) == true)
        try (unembeddedData as Data).write(to: dngWithoutEmbeddedPreviewURL)

        let fullDecodeResult = try #require(PreviewLoader.extractImageThumbnail(from: dngWithoutEmbeddedPreviewURL, maxPixelSize: 360))
        #expect(fullDecodeResult.strategy == .fullDecodeFallback)
        #expect(!fullDecodeResult.jpegData.isEmpty)
        let decodedFallbackImage = try #require(PreviewLoader.decodeCGImage(from: fullDecodeResult.jpegData))
        #expect(max(decodedFallbackImage.width, decodedFallbackImage.height) <= 360)

        // 3. Verify CullingSession loads and caches both DNG files (and honours .preferRAW on a MediaPair)
        try writeSampleRasterImage(to: root.appendingPathComponent("DSC0999.JPG"), red: 20, green: 200, blue: 80)
        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        session.previewSource = .preferRAW
        try session.openFolder(at: root)

        let pairedDNGItem = try #require(session.items.first { $0.baseName == "DSC0999" })
        #expect(pairedDNGItem.isMediaPair == true)
        #expect(pairedDNGItem.preferredFile(for: session.previewSource).fileExtension.uppercased() == "DNG")
        let cachedPairedRAWThumb = try #require(await session.loadThumbnailData(for: pairedDNGItem))
        #expect(!cachedPairedRAWThumb.isEmpty)
        #expect(session.isThumbnailCached(for: pairedDNGItem) == true)

        let unembeddedDNGItem = try #require(session.items.first { $0.baseName == "DSC1000_UNEMBEDDED" })
        let cachedFullDecodeThumb = try #require(await session.loadThumbnailData(for: unembeddedDNGItem))
        #expect(!cachedFullDecodeThumb.isEmpty)
        #expect(session.isThumbnailCached(for: unembeddedDNGItem) == true)

        // 4. Verify user quota clamping (250 MB – 20 GB)
        session.setUserConfiguredCacheSizeLimitBytes(10 * 1_024 * 1_024) // below 250 MB
        #expect(session.cacheSizeLimitBytes == MediaCache.minUserQuotaBytes)

        session.setUserConfiguredCacheSizeLimitBytes(50 * 1_024 * 1_024 * 1_024) // above 20 GB
        #expect(session.cacheSizeLimitBytes == MediaCache.maxUserQuotaBytes)
    }

    @Test("HeavyDecodeLimiter bounds concurrent heavy decodes to max 2 concurrent workers")
    func heavyDecodeLimiterBoundsConcurrencyToTwo() async {
        let limiter = HeavyDecodeLimiter(maxConcurrent: 2)
        let peakCounter = PeakCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await limiter.withPermit {
                        await peakCounter.increment()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        await peakCounter.decrement()
                    }
                }
            }
        }

        let maxConcurrentReached = await peakCounter.maxCount
        #expect(maxConcurrentReached <= 2)
        #expect(maxConcurrentReached > 0)
    }

    @Test("ThumbnailQueueActor executes requests in LIFO order and cancels off-screen tasks")
    func thumbnailQueueActorLIFOAndCancellation() async {
        let queue = ThumbnailQueueActor(maxConcurrentWorkers: 1)
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

        // Enqueue item 1, then item 2, then item 3
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

        // Cancel task2 before worker is released
        task2.cancel()
        try? await Task.sleep(nanoseconds: 10_000_000)

        // Release the blocker so queue drains
        await blockerRelease.signal()
        _ = await blockerTask.value

        _ = await task3.value
        _ = await task1.value
        let task2Result = await task2.value

        // Cancelled task2 must return nil
        #expect(task2Result == nil)

        // LIFO order: item3 was enqueued last, so it must execute before item1
        let order = await orderTracker.order
        #expect(order == ["item3", "item1"])
    }

    @Test("500ms sidecar write debouncing coalesces rapid curation mutations and flushes on close")
    func debouncedSidecarWritesCoalesceAndFlushOnClose() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0050.JPG")
        try Data("jpg-content".utf8).write(to: jpgURL)

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        session.flushDebounceNanoseconds = 150_000_000 // 150ms for test execution
        try session.openFolder(at: root)
        let item = try #require(session.items.first)

        let xmpURL = root.appendingPathComponent("DSC0050.xmp")
        #expect(!FileManager.default.fileExists(atPath: xmpURL.path))

        // Rapidly apply 3 mutations within the debounce window
        session.setStarRating(3, for: item)
        #expect(session.syncState(for: item) == .pendingWrite)
        #expect(!FileManager.default.fileExists(atPath: xmpURL.path))

        try? await Task.sleep(nanoseconds: 40_000_000) // 40ms < 150ms
        session.setPickFlag(.picked, for: item)
        #expect(session.syncState(for: item) == .pendingWrite)
        #expect(!FileManager.default.fileExists(atPath: xmpURL.path))

        try? await Task.sleep(nanoseconds: 40_000_000) // 40ms < 150ms
        session.setColorLabel(.blue, for: item)
        #expect(session.syncState(for: item) == .pendingWrite)
        #expect(!FileManager.default.fileExists(atPath: xmpURL.path))

        // Wait for debounce timer to fire (150ms + margin)
        for _ in 0..<15 {
            if FileManager.default.fileExists(atPath: xmpURL.path) && session.syncState(for: item) == .synced {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Sidecar should now be written to disk with coalesced metadata
        #expect(FileManager.default.fileExists(atPath: xmpURL.path))
        #expect(session.syncState(for: item) == .synced)
        let diskData = try #require(SidecarCodec.readData(from: xmpURL))
        let parsed = try SidecarCodec.parse(data: diskData)
        #expect(parsed.curation.starRating == 3)
        #expect(parsed.curation.pickFlag == .picked)
        #expect(parsed.curation.colorLabel == .blue)

        // Now test immediate flush on folder close while a debounce is active
        session.setStarRating(5, for: item)
        #expect(session.syncState(for: item) == .pendingWrite)
        // Immediately close folder before debounce timer fires
        let closeResult = await session.closeFolder()
        #expect(closeResult == .success)

        // Verified written to disk immediately
        let diskData2 = try #require(SidecarCodec.readData(from: xmpURL))
        let parsed2 = try SidecarCodec.parse(data: diskData2)
        #expect(parsed2.curation.starRating == 5)
    }

    @Test("Lazy sidecar hydration exposes loading state and hydrates on demand for visible items")
    func lazySidecarHydrationExposesLoadingStateAndHydratesOnDemand() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0099.JPG")
        try Data("jpg-data".utf8).write(to: jpgURL)

        let initialMetadata = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .purple)
        let initialXMP = try SidecarCodec.update(xmlData: nil, with: initialMetadata)
        try initialXMP.write(to: root.appendingPathComponent("DSC0099.xmp"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        session.isSyncSuspended = true

        // Open folder with lazy sidecar hydration enabled
        try session.openFolder(at: root, lazySidecars: true)
        #expect(session.isLazySidecarHydrationEnabled == true)
        #expect(session.items.count == 1)

        let item = try #require(session.items.first)
        // Should start in loading state without blocking openFolder with synchronous sidecar reads
        #expect(session.syncState(for: item) == .loading)

        // Viewport hydration: when cell scrolls into view
        await session.hydrateMetadata(for: item)

        #expect(session.syncState(for: item) == .synced)
        #expect(session.curationMetadata(for: item) == initialMetadata)
    }

    @Test("openFolderAsync reports isDiscovering and openFolderProgress")
    func openFolderAsyncReportsProgress() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir1 = root.appendingPathComponent("FolderA", isDirectory: true)
        let dir2 = root.appendingPathComponent("FolderB", isDirectory: true)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try Data("imgA".utf8).write(to: dir1.appendingPathComponent("A.JPG"))
        try Data("imgB".utf8).write(to: dir2.appendingPathComponent("B.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try await session.setSubfolderMode(.recursive)

        try await session.openFolderAsync(at: root, lazySidecars: true)
        #expect(session.items.count == 2)
        #expect(session.isDiscovering == false)
    }


    private func makeTwoIFDDNGData() -> Data {
        var data = Data()
        func appendU16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        func appendU32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func entry(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
            appendU16(tag); appendU16(type); appendU32(count); appendU32(valueOrOffset)
        }

        // Little-endian TIFF header ("II", 42, IFD0 at offset 8)
        data.append(contentsOf: [0x49, 0x49])
        appendU16(42)
        appendU32(8)

        let previewW: UInt32 = 32
        let previewH: UInt32 = 32
        let previewPixels = [UInt8](repeating: 140, count: Int(previewW * previewH * 3))
        let rawW: UInt32 = 64
        let rawH: UInt32 = 64
        let rawPixels = [UInt16](repeating: 2048, count: Int(rawW * rawH))

        // Layout:
        // 8: IFD0 (12 entries -> 2 + 12*12 + 4 = 150 bytes -> ends at 158)
        // 158: BitsPerSample [8,8,8] (6 bytes -> ends at 164)
        // 164: SubIFD0 (11 entries -> 2 + 11*12 + 4 = 138 bytes -> ends at 302)
        // 302: Preview RGB data (3072 bytes -> ends at 3374)
        // 3374: CFA 16-bit Bayer sensor data (8192 bytes -> ends at 11566)
        appendU16(12)
        entry(tag: 254, type: 4, count: 1, valueOrOffset: 1)          // NewSubfileType = 1 (Preview)
        entry(tag: 256, type: 4, count: 1, valueOrOffset: previewW)   // ImageWidth
        entry(tag: 257, type: 4, count: 1, valueOrOffset: previewH)   // ImageLength
        entry(tag: 258, type: 3, count: 3, valueOrOffset: 158)        // BitsPerSample -> [8,8,8]
        entry(tag: 259, type: 3, count: 1, valueOrOffset: 1)          // Compression = Uncompressed
        entry(tag: 262, type: 3, count: 1, valueOrOffset: 2)          // PhotometricInterpretation = RGB
        entry(tag: 273, type: 4, count: 1, valueOrOffset: 302)        // StripOffsets
        entry(tag: 277, type: 3, count: 1, valueOrOffset: 3)          // SamplesPerPixel = 3
        entry(tag: 278, type: 4, count: 1, valueOrOffset: previewH)   // RowsPerStrip
        entry(tag: 279, type: 4, count: 1, valueOrOffset: UInt32(previewPixels.count)) // StripByteCounts
        entry(tag: 330, type: 4, count: 1, valueOrOffset: 164)        // SubIFDs -> SubIFD0
        entry(tag: 50706, type: 1, count: 4, valueOrOffset: 0x00000401) // DNGVersion = 1.4.0.0
        appendU32(0)

        appendU16(8); appendU16(8); appendU16(8)

        appendU16(11)
        entry(tag: 254, type: 4, count: 1, valueOrOffset: 0)          // NewSubfileType = 0 (Full-res RAW)
        entry(tag: 256, type: 4, count: 1, valueOrOffset: rawW)
        entry(tag: 257, type: 4, count: 1, valueOrOffset: rawH)
        entry(tag: 258, type: 3, count: 1, valueOrOffset: 16)         // 16-bit sensor
        entry(tag: 259, type: 3, count: 1, valueOrOffset: 1)
        entry(tag: 262, type: 3, count: 1, valueOrOffset: 32803)      // CFA (Color Filter Array)
        entry(tag: 273, type: 4, count: 1, valueOrOffset: 3374)
        entry(tag: 277, type: 3, count: 1, valueOrOffset: 1)
        entry(tag: 278, type: 4, count: 1, valueOrOffset: rawH)
        entry(tag: 279, type: 4, count: 1, valueOrOffset: UInt32(rawPixels.count * 2))
        entry(tag: 33421, type: 3, count: 2, valueOrOffset: 0x00020002) // CFARepeatPatternDim = 2x2
        appendU32(0)

        data.append(contentsOf: previewPixels)
        rawPixels.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    @Test("ExifHeaderExtractor returns empty metadata for video formats (.mov, .mp4, .m4v) without calling CGImageSource")
    func videoExifBypassReturnsEmptyMetadata() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let movURL = root.appendingPathComponent("clip.MOV")
        let mp4URL = root.appendingPathComponent("clip.mp4")
        let m4vURL = root.appendingPathComponent("clip.m4v")

        let videoBytes = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6d, 0x70, 0x34, 0x32])
        try videoBytes.write(to: movURL)
        try videoBytes.write(to: mp4URL)
        try videoBytes.write(to: m4vURL)

        // Directly test extract(from: URL)
        let movExif = ExifHeaderExtractor.extract(from: movURL)
        #expect(movExif.cameraModel == nil)
        #expect(movExif.lensModel == nil)
        #expect(movExif.focalLength == nil)
        #expect(movExif.fNumber == nil)
        #expect(movExif.exposureTime == nil)
        #expect(movExif.isoSpeedRatings.isEmpty)
        #expect(movExif.dateTimeOriginal == nil)

        let mp4Exif = ExifHeaderExtractor.extract(from: mp4URL)
        #expect(mp4Exif.cameraModel == nil)

        let m4vExif = ExifHeaderExtractor.extract(from: m4vURL)
        #expect(m4vExif.cameraModel == nil)

        // Test extractHeaderExif(for: MediaItem)
        let videoFile = MediaFile(url: movURL, formatKind: .video)
        let videoItem = MediaItem(
            id: movURL.path,
            baseName: "clip",
            directoryURL: root,
            relativeDirectoryPath: "",
            kind: .video,
            primaryFile: videoFile,
            mediaPair: nil,
            sidecarURL: nil
        )
        let itemExif = ExifHeaderExtractor.extractHeaderExif(for: videoItem)
        #expect(itemExif.cameraModel == nil)

        // Test extractBatch
        let batch = await ExifHeaderExtractor.extractBatch(for: [videoItem])
        #expect(batch.count == 1)
        #expect(batch[0].0 == videoItem.id)
        #expect(batch[0].1.cameraModel == nil)
    }

    @Test("PreviewLoader adaptively scales prefix probing up to 3.5 MB for embedded previews without full demosaicing fallback")
    func adaptivePrefixProbingExtractsLargeEmbeddedJPEG() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sampleJPEGURL = root.appendingPathComponent("temp_sample.jpg")
        try writeSampleRasterImage(to: sampleJPEGURL, red: 180, green: 90, blue: 45)
        let sampleJPEGData = try Data(contentsOf: sampleJPEGURL)

        // Make an expanded JPEG by injecting COM (comment) segments so the total JPEG is ~1.5 MB (> 1MB initialHeaderBytes)
        let largeEmbeddedJPEG = makeJPEGWithComments(baseJPEG: sampleJPEGData, targetSize: 1_500_000)
        #expect(largeEmbeddedJPEG.count > 1_200_000)

        // Embed the large JPEG in a mock RAW file (.ARW) with a 256-byte header
        var rawData = Data(repeating: 0x00, count: 256)
        rawData[0] = 0x49
        rawData[1] = 0x49
        rawData[2] = 0x2A
        rawData[3] = 0x00
        rawData.append(largeEmbeddedJPEG)

        let mockRawURL = root.appendingPathComponent("LARGE_PREVIEW.ARW")
        try rawData.write(to: mockRawURL)

        let result = await PreviewLoader.extractImageThumbnailAsync(from: mockRawURL, maxPixelSize: 360)
        let unwrapped = try #require(result)
        #expect(unwrapped.strategy == .embeddedPreview)
        #expect(!unwrapped.jpegData.isEmpty)
    }

    @Test("MediaCache readData updates LRU in memory without writing to disk synchronously on every read")
    func mediaCacheReadDataDoesNotWriteToDiskSynchronously() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheDir = root.appendingPathComponent("media-cache", isDirectory: true)
        // Set quota for 2 entries (each entry 100 bytes, quota = 250 bytes)
        let cache = MediaCache(cacheDirectoryURL: cacheDir, initialLimitBytes: 250)

        let key1 = "item_1"
        let key2 = "item_2"
        let key3 = "item_3"
        let data1 = Data(repeating: 0xAA, count: 100)
        let data2 = Data(repeating: 0xBB, count: 100)
        let data3 = Data(repeating: 0xCC, count: 100)

        cache.storeData(data1, forKey: key1)
        cache.storeData(data2, forKey: key2)
        cache.flushIndexImmediately()

        #expect(cache.contains(key: key1) == true)
        #expect(cache.contains(key: key2) == true)

        let indexURL = cache.indexFileURL
        let diskIndexDataBefore = try Data(contentsOf: indexURL)

        // Read key1: moves key1 to most recently used, leaving key2 as least recently used
        let readResult = cache.readData(forKey: key1)
        #expect(readResult == data1)

        // Verify that disk index was NOT written synchronously during readData:
        // disk file contents are still identical to diskIndexDataBefore
        let diskIndexDataImmediately = try Data(contentsOf: indexURL)
        #expect(diskIndexDataImmediately == diskIndexDataBefore)

        // Store third item: exceeding 250-byte quota triggers LRU eviction.
        // Because key1 was read, key2 is the least recently used and MUST be evicted,
        // while key1 and key3 remain!
        cache.storeData(data3, forKey: key3)
        #expect(cache.contains(key: key1) == true)
        #expect(cache.contains(key: key2) == false)
        #expect(cache.contains(key: key3) == true)

        // After flushing immediately, disk reflects updated index
        cache.flushIndexImmediately()
        let diskIndexDataFlushed = try Data(contentsOf: indexURL)
        #expect(diskIndexDataFlushed != diskIndexDataBefore)
    }

    @Test("openFolderAsync and reopenRecentFolderAsync stream discovered items progressively without blocking actor execution")
    func openFolderAsyncAndReopenRecentProgressivelyStreamBatches() async throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let storeURL = tempRoot.appendingPathComponent(".session-store", isDirectory: true)

        let folder1 = tempRoot.appendingPathComponent("Sub1", isDirectory: true)
        let folder2 = tempRoot.appendingPathComponent("Sub2", isDirectory: true)
        let folder3 = tempRoot.appendingPathComponent("Sub3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder3, withIntermediateDirectories: true)

        try Data("img1A".utf8).write(to: folder1.appendingPathComponent("F1_A.JPG"))
        try Data("img1B".utf8).write(to: folder1.appendingPathComponent("F1_B.JPG"))
        try Data("img2A".utf8).write(to: folder2.appendingPathComponent("F2_A.JPG"))
        try Data("img2B".utf8).write(to: folder2.appendingPathComponent("F2_B.JPG"))
        try Data("img3A".utf8).write(to: folder3.appendingPathComponent("F3_A.JPG"))
        try Data("img3B".utf8).write(to: folder3.appendingPathComponent("F3_B.JPG"))

        let session1 = CullingSession(storageRootURL: storeURL)
        try await session1.setSubfolderMode(.recursive)

        try await session1.openFolderAsync(at: tempRoot, lazySidecars: true)
        #expect(session1.items.count == 6)
        #expect(session1.isDiscovering == false)
        #expect(session1.recentFolders.count == 1)

        let recent = session1.recentFolders[0]
        let session2 = CullingSession(storageRootURL: storeURL)
        try await session2.setSubfolderMode(.recursive)
        try await session2.reopenRecentFolderAsync(recent)

        #expect(session2.currentFolderURL == tempRoot)
        #expect(session2.items.count == 6)
        #expect(session2.isDiscovering == false)
    }

    @Test("openFolderAsync completes and sets items before background EXIF preloading completes")
    func openFolderAsyncDecouplesExifPreload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...5 {
            let jpgURL = root.appendingPathComponent("PHOTO_\(i).JPG")
            try writeSampleRasterImage(to: jpgURL, red: UInt8(i * 40), green: 100, blue: 120)
        }

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try await session.openFolderAsync(at: root, lazySidecars: true)

        // openFolderAsync completes promptly and populates items without waiting for EXIF preloading
        #expect(session.items.count == 5)
        #expect(session.isDiscovering == false)

        // Session close cleanly cancels any in-flight background EXIF task
        _ = await session.closeFolder()
        #expect(session.isExifPreloading == false)
    }

    @Test("openFolderAsync handles folders containing mixed RAW, JPG, and video files smoothly without hanging")
    func mixedMediaFolderOpeningHandlesSmoothly() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // RAW + JPG pair
        try Data("raw".utf8).write(to: root.appendingPathComponent("SHOOT_01.CR3"))
        try Data("jpg".utf8).write(to: root.appendingPathComponent("SHOOT_01.JPG"))

        // Standalone RAW
        try Data("raw2".utf8).write(to: root.appendingPathComponent("SHOOT_02.ARW"))

        // Standalone JPG
        try Data("jpg3".utf8).write(to: root.appendingPathComponent("SHOOT_03.JPG"))

        // Video files
        try Data("mov".utf8).write(to: root.appendingPathComponent("CLIP_01.MOV"))
        try Data("mp4".utf8).write(to: root.appendingPathComponent("CLIP_02.mp4"))
        try Data("m4v".utf8).write(to: root.appendingPathComponent("CLIP_03.m4v"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try await session.openFolderAsync(at: root)

        #expect(session.lastErrorMessage == nil)
        #expect(session.items.count == 6)

        let pairItem = try #require(session.items.first { $0.baseName == "SHOOT_01" })
        #expect(pairItem.isMediaPair == true)
        #expect(pairItem.kind == .photo)

        let rawItem = try #require(session.items.first { $0.baseName == "SHOOT_02" })
        #expect(rawItem.isMediaPair == false)
        #expect(rawItem.kind == .photo)

        let jpgItem = try #require(session.items.first { $0.baseName == "SHOOT_03" })
        #expect(jpgItem.isMediaPair == false)
        #expect(jpgItem.kind == .photo)

        let videoItems = session.items.filter { $0.kind == .video }
        #expect(videoItems.count == 3)
        #expect(videoItems.allSatisfy { $0.badgeText == "VIDEO" && $0.mediaTypeBadge == "Video" })

        // Ensure background EXIF preloading completes cleanly without stalling on video files
        var attempts = 0
        while session.isExifPreloading && attempts < 20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        #expect(session.isExifPreloading == false)
    }

    private func makeJPEGWithComments(baseJPEG: Data, targetSize: Int) -> Data {
        guard baseJPEG.count > 4, baseJPEG[0] == 0xFF, baseJPEG[1] == 0xD8 else {
            return baseJPEG
        }
        var insertOffset = 2
        if baseJPEG[2] == 0xFF && (baseJPEG[3] == 0xE0 || baseJPEG[3] == 0xE1) && baseJPEG.count > 6 {
            let segLen = (Int(baseJPEG[4]) << 8) | Int(baseJPEG[5])
            insertOffset = min(baseJPEG.count, 4 + segLen)
        }
        var result = Data()
        result.append(baseJPEG.prefix(insertOffset))
        var currentSize = baseJPEG.count
        while currentSize < targetSize {
            let chunkPayloadSize = min(65533, targetSize - currentSize)
            let totalSegmentLength = UInt16(chunkPayloadSize + 2)
            result.append(contentsOf: [0xFF, 0xFE, UInt8(totalSegmentLength >> 8), UInt8(totalSegmentLength & 0xFF)])
            result.append(Data(repeating: 0x20, count: chunkPayloadSize))
            currentSize += chunkPayloadSize + 4
        }
        result.append(baseJPEG.suffix(from: insertOffset))
        return result
    }

    private func findORFTestFileURL() -> URL? {
        // Sandboxed test execution cannot read repository paths outside the container.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return nil
        }

        let fileManager = FileManager.default
        let relativePath = "testfiles/raws/P9227357.ORF"

        // 1. Check current working directory
        let cwdCandidate = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }

        // 2. Walk upwards from current source file directory
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    @Test("RAW preview extraction respects container orientation 6 and 8 for embedded previews and preserves raster/landscape")
    func rawPreviewOrientationEmbeddedPreviewRespectsContainerOrientation6And8() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let landscapeJPEG = try makeSampleLandscapeJPEGData(width: 120, height: 80)

        // 1a. Orientation 6 (Rotated 90 CW in container): embedded unoriented JPEG must be oriented to portrait
        let rawURL6 = root.appendingPathComponent("SYNTHETIC_ORI_6.ARW")
        let rawData6 = makeSyntheticRAWWithEmbeddedJPEG(orientation: 6, embeddedJPEG: landscapeJPEG)
        try rawData6.write(to: rawURL6)

        // Synchronous extraction
        let result6 = try #require(PreviewLoader.extractImageThumbnail(from: rawURL6, maxPixelSize: 360))
        #expect(result6.strategy == .embeddedPreview)
        let decoded6 = try #require(PreviewLoader.decodeCGImage(from: result6.jpegData))
        #expect(decoded6.height > decoded6.width)
        #expect(decoded6.aspectRatio < 1.0)

        // Asynchronous extraction
        let asyncResult6 = try #require(await PreviewLoader.extractImageThumbnailAsync(from: rawURL6, maxPixelSize: 360))
        #expect(asyncResult6.strategy == .embeddedPreview)
        let asyncDecoded6 = try #require(PreviewLoader.decodeCGImage(from: asyncResult6.jpegData))
        #expect(asyncDecoded6.height > asyncDecoded6.width)
        #expect(asyncDecoded6.aspectRatio < 1.0)

        // 1b. Orientation 8 (Rotated 270 CW in container): embedded unoriented JPEG must be oriented to portrait
        let rawURL8 = root.appendingPathComponent("SYNTHETIC_ORI_8.ARW")
        let rawData8 = makeSyntheticRAWWithEmbeddedJPEG(orientation: 8, embeddedJPEG: landscapeJPEG)
        try rawData8.write(to: rawURL8)

        let result8 = try #require(PreviewLoader.extractImageThumbnail(from: rawURL8, maxPixelSize: 360))
        #expect(result8.strategy == .embeddedPreview)
        let decoded8 = try #require(PreviewLoader.decodeCGImage(from: result8.jpegData))
        #expect(decoded8.height > decoded8.width)
        #expect(decoded8.aspectRatio < 1.0)

        let asyncResult8 = try #require(await PreviewLoader.extractImageThumbnailAsync(from: rawURL8, maxPixelSize: 360))
        #expect(asyncResult8.strategy == .embeddedPreview)
        let asyncDecoded8 = try #require(PreviewLoader.decodeCGImage(from: asyncResult8.jpegData))
        #expect(asyncDecoded8.height > asyncDecoded8.width)
        #expect(asyncDecoded8.aspectRatio < 1.0)

        // 2. Real RAW sample: if testfiles/raws/P9227357.ORF exists on disk and is readable, assert it decodes in portrait
        if let orfURL = findORFTestFileURL(),
           let handle = try? FileHandle(forReadingFrom: orfURL) {
            try? handle.close()
            let orfResult = try #require(PreviewLoader.extractImageThumbnail(from: orfURL, maxPixelSize: 360))
            #expect(orfResult.strategy == .embeddedPreview)
            let decodedORF = try #require(PreviewLoader.decodeCGImage(from: orfResult.jpegData))
            #expect(decodedORF.height > decodedORF.width)
            #expect(decodedORF.aspectRatio < 1.0)

            let asyncORFResult = try #require(await PreviewLoader.extractImageThumbnailAsync(from: orfURL, maxPixelSize: 360))
            #expect(asyncORFResult.strategy == .embeddedPreview)
            let asyncDecodedORF = try #require(PreviewLoader.decodeCGImage(from: asyncORFResult.jpegData))
            #expect(asyncDecodedORF.height > asyncDecodedORF.width)
            #expect(asyncDecodedORF.aspectRatio < 1.0)
        }

        // 3a. Orientation 1 (Normal landscape): landscape RAW remains landscape
        let rawURL1 = root.appendingPathComponent("SYNTHETIC_ORI_1.ARW")
        let rawData1 = makeSyntheticRAWWithEmbeddedJPEG(orientation: 1, embeddedJPEG: landscapeJPEG)
        try rawData1.write(to: rawURL1)

        let result1 = try #require(PreviewLoader.extractImageThumbnail(from: rawURL1, maxPixelSize: 360))
        #expect(result1.strategy == .embeddedPreview)
        let decoded1 = try #require(PreviewLoader.decodeCGImage(from: result1.jpegData))
        #expect(decoded1.width > decoded1.height)
        #expect(decoded1.aspectRatio > 1.0)

        let asyncResult1 = try #require(await PreviewLoader.extractImageThumbnailAsync(from: rawURL1, maxPixelSize: 360))
        #expect(asyncResult1.strategy == .embeddedPreview)
        let asyncDecoded1 = try #require(PreviewLoader.decodeCGImage(from: asyncResult1.jpegData))
        #expect(asyncDecoded1.width > asyncDecoded1.height)
        #expect(asyncDecoded1.aspectRatio > 1.0)

        // 3b. Standard raster JPG with Orientation 6 continues to extract portrait without regression
        let rasterURL6 = root.appendingPathComponent("RASTER_ORI_6.JPG")
        let rasterData6 = try makeSampleRasterJPEGDataWithOrientation(orientation: 6, width: 120, height: 80)
        try rasterData6.write(to: rasterURL6)

        let rasterResult = try #require(PreviewLoader.extractImageThumbnail(from: rasterURL6, maxPixelSize: 360))
        let decodedRaster = try #require(PreviewLoader.decodeCGImage(from: rasterResult.jpegData))
        #expect(decodedRaster.height > decodedRaster.width)
        #expect(decodedRaster.aspectRatio < 1.0)

        // 4. Session integration: MediaItem extraction, caching, aspect ratio, and preview loading
        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try await session.openFolderAsync(at: root)
        #expect(session.items.count >= 4)

        let sessionRawItem6 = try #require(session.items.first { $0.baseName == "SYNTHETIC_ORI_6" })
        let thumbItemResult6 = try #require(await PreviewLoader.extractThumbnail(for: sessionRawItem6, previewSource: .preferRAW, maxPixelSize: 360))
        #expect(thumbItemResult6.strategy == .embeddedPreview)
        let thumbItemDecoded6 = try #require(PreviewLoader.decodeCGImage(from: thumbItemResult6.jpegData))
        #expect(thumbItemDecoded6.height > thumbItemDecoded6.width)
        #expect(thumbItemDecoded6.aspectRatio < 1.0)

        let sessionThumb6 = try #require(await session.loadThumbnailData(for: sessionRawItem6))
        let sessionThumbDecoded6 = try #require(PreviewLoader.decodeCGImage(from: sessionThumb6))
        #expect(sessionThumbDecoded6.height > sessionThumbDecoded6.width)
        #expect(sessionThumbDecoded6.aspectRatio < 1.0)
        #expect(session.thumbnailAspectRatio(for: sessionRawItem6) < 1.0)

        let sessionPreview6 = try #require(await session.loadPreviewImageData(for: sessionRawItem6, maxPixelSize: 1024))
        let sessionPreviewDecoded6 = try #require(PreviewLoader.decodeCGImage(from: sessionPreview6))
        #expect(sessionPreviewDecoded6.height > sessionPreviewDecoded6.width)
        #expect(sessionPreviewDecoded6.aspectRatio < 1.0)

        let sessionRawItem1 = try #require(session.items.first { $0.baseName == "SYNTHETIC_ORI_1" })
        let sessionThumb1 = try #require(await session.loadThumbnailData(for: sessionRawItem1))
        let sessionThumbDecoded1 = try #require(PreviewLoader.decodeCGImage(from: sessionThumb1))
        #expect(sessionThumbDecoded1.width > sessionThumbDecoded1.height)
        #expect(sessionThumbDecoded1.aspectRatio > 1.0)
        #expect(session.thumbnailAspectRatio(for: sessionRawItem1) > 1.0)
    }

    private func makeSampleLandscapeJPEGData(width: Int = 120, height: Int = 80) throws -> Data {
        try makeSampleRasterJPEGDataWithOrientation(orientation: 1, width: width, height: height)
    }

    private func makeSampleRasterJPEGDataWithOrientation(orientation: UInt32, width: Int = 120, height: Int = 80) throws -> Data {
        let pixels = [UInt8](repeating: 160, count: width * height * 4)
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
                  shouldInterpolate: false,
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
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return mutableData as Data
    }

    private func makeSyntheticRAWWithEmbeddedJPEG(orientation: UInt16, embeddedJPEG: Data) -> Data {
        var data = Data()
        func appendU16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        func appendU32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func entry(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
            appendU16(tag); appendU16(type); appendU32(count); appendU32(valueOrOffset)
        }

        // Little-endian TIFF header ("II", 42, IFD0 offset 8)
        data.append(contentsOf: [0x49, 0x49])
        appendU16(42)
        appendU32(8)

        // IFD0: 4 entries
        appendU16(4)
        entry(tag: 256, type: 4, count: 1, valueOrOffset: 6000) // ImageWidth
        entry(tag: 257, type: 4, count: 1, valueOrOffset: 4000) // ImageLength
        entry(tag: 274, type: 3, count: 1, valueOrOffset: UInt32(orientation)) // Orientation
        entry(tag: 50706, type: 1, count: 4, valueOrOffset: 0x00000401) // DNGVersion
        appendU32(0) // Next IFD offset

        while data.count < 256 {
            data.append(0x00)
        }
        data.append(embeddedJPEG)
        return data
    }
}

private actor PeakCounter {
    var current: Int = 0
    var maxCount: Int = 0

    func increment() {
        current += 1
        if current > maxCount {
            maxCount = current
        }
    }

    func decrement() {
        current -= 1
    }
}

actor ExecutionOrderTracker {
    var order: [String] = []
    func record(_ id: String) {
        order.append(id)
    }
}

actor AsyncSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

