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
    func discoverSubfolderModeAndDirectoryScopedPairing() throws {
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
        try session.setSubfolderMode(.recursive)
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
        try session.toggleSubfolderMode()
        #expect(session.subfolderMode == .immediate)
        #expect(session.items.count == 1)
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

        let embeddedResult = try #require(PreviewLoader.extractImageThumbnail(from: dngWithEmbeddedThumbURL, maxPixelSize: 360))
        #expect(embeddedResult.strategy == .embeddedPreview)
        #expect(!embeddedResult.jpegData.isEmpty)

        // Verify CullingSession loads and caches the embedded preview for the discovered RAW item
        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try session.openFolder(at: root)
        let rawItem = try #require(session.items.first { $0.baseName == "DSC0999" })
        let cachedThumb = try #require(await session.loadThumbnailData(for: rawItem))
        #expect(!cachedThumb.isEmpty)
        #expect(session.isThumbnailCached(for: rawItem) == true)

        // Verify user quota clamping (250 MB – 20 GB)
        session.setUserConfiguredCacheSizeLimitBytes(10 * 1_024 * 1_024) // below 250 MB
        #expect(session.cacheSizeLimitBytes == MediaCache.minUserQuotaBytes)

        session.setUserConfiguredCacheSizeLimitBytes(50 * 1_024 * 1_024 * 1_024) // above 20 GB
        #expect(session.cacheSizeLimitBytes == MediaCache.maxUserQuotaBytes)
    }
}

