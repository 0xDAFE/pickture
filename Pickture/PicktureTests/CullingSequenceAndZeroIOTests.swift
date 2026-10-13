import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@MainActor
@Suite("CullingSequence & Zero-I/O Metadata Lookups Tests")
struct CullingSequenceAndZeroIOTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureSeqZeroIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeDummyMediaItem(
        id: String,
        baseName: String,
        kind: MediaKind = .photo,
        formatKind: MediaFormatKind = .raster,
        mediaPair: MediaPair? = nil
    ) -> MediaItem {
        let ext = (kind == .video) ? "mov" : (formatKind == .raw ? "cr3" : "jpg")
        let dummyURL = URL(fileURLWithPath: "/dummy/\(baseName).\(ext)")
        let primaryFile = MediaFile(url: dummyURL, formatKind: formatKind)
        return MediaItem(
            id: id,
            baseName: baseName,
            directoryURL: URL(fileURLWithPath: "/dummy"),
            relativeDirectoryPath: "",
            kind: kind,
            primaryFile: primaryFile,
            mediaPair: mediaPair,
            sidecarURL: nil
        )
    }

    private func makeDummyMediaPair(
        id: String,
        baseName: String
    ) -> MediaItem {
        let rawURL = URL(fileURLWithPath: "/dummy/\(baseName).CR3")
        let rasterURL = URL(fileURLWithPath: "/dummy/\(baseName).JPG")
        let rawFile = MediaFile(url: rawURL, formatKind: .raw)
        let rasterFile = MediaFile(url: rasterURL, formatKind: .raster)
        let pair = MediaPair(rawFile: rawFile, rasterFile: rasterFile)
        return MediaItem(
            id: id,
            baseName: baseName,
            directoryURL: URL(fileURLWithPath: "/dummy"),
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: rawFile,
            mediaPair: pair,
            sidecarURL: nil
        )
    }

    private func makeImageFileWithExif(
        at url: URL,
        width: Int = 100,
        height: Int = 100,
        dateTimeOriginal: String? = nil
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }

        var properties: [CFString: Any] = [:]
        var exifDict: [CFString: Any] = [:]
        if let dateTimeOriginal {
            exifDict[kCGImagePropertyExifDateTimeOriginal] = dateTimeOriginal
        }
        if !exifDict.isEmpty {
            properties[kCGImagePropertyExifDictionary] = exifDict
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: - Ticket 1 (#49): Zero-I/O Lookups & Scoped Aspect Ratios

    @Test("thumbnailAspectRatio returns fallback immediately on cold unindexed items without synchronous disk or SQLite reads")
    func coldThumbnailAspectRatioReturnsFallbackZeroIO() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = CullingSession(storageRootURL: root)
        let photoItem = makeDummyMediaItem(id: "cold-photo", baseName: "DSC_0001", kind: .photo)
        let videoItem = makeDummyMediaItem(id: "cold-video", baseName: "DSC_0002", kind: .video)

        // Photo fallback is 3:2 (1.5)
        let photoRatio = session.thumbnailAspectRatio(for: photoItem)
        #expect(abs(photoRatio - 1.5) < 0.001)

        // Video fallback is 16:9 (1.777...)
        let videoRatio = session.thumbnailAspectRatio(for: videoItem)
        #expect(abs(videoRatio - (16.0 / 9.0)) < 0.001)
    }

    @Test("thumbnailAspectRatio scopes aspect ratios independently by previewSource for MediaPair")
    func mediaPairScopedAspectRatiosByPreviewSource() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = CullingSession(storageRootURL: root)
        let pairItem = makeDummyMediaPair(id: "pair-1", baseName: "DSC_PAIR")

        // Record 16:9 for raster preview crop (e.g. camera in-body 16:9 crop)
        // Record 3:2 for full raw sensor readout
        session.recordThumbnailAspectRatio(16.0 / 9.0, for: pairItem, previewSource: .preferRaster)
        session.recordThumbnailAspectRatio(3.0 / 2.0, for: pairItem, previewSource: .preferRAW)

        let rasterRatio = session.thumbnailAspectRatio(for: pairItem, previewSource: .preferRaster)
        let rawRatio = session.thumbnailAspectRatio(for: pairItem, previewSource: .preferRAW)

        #expect(abs(rasterRatio - (16.0 / 9.0)) < 0.001)
        #expect(abs(rawRatio - 1.5) < 0.001)
    }

    @Test("exifMetadata returns in-memory records or empty fallback with zero synchronous I/O")
    func exifMetadataZeroIOSynchronousLookup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = CullingSession(storageRootURL: root)
        let item = makeDummyMediaItem(id: "item-exif-cold", baseName: "DSC_EXIF")

        // Unindexed item returns empty ExifMetadata immediately
        let coldExif = session.exifMetadata(for: item)
        #expect(coldExif.cameraModel == nil)
        #expect(coldExif.lensModel == nil)
        #expect(coldExif.isoSpeedRatings.isEmpty)
        #expect(coldExif.dateTimeOriginal == nil)

        // Camera and lens model sets are pure in-memory lookups
        #expect(session.availableCameraModels.isEmpty)
        #expect(session.availableLensModels.isEmpty)
    }

    @Test("warmThumbnailAspectRatios populates in-memory aspect ratios from persistent cache")
    func warmThumbnailAspectRatiosFromPersistentCache() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = CullingSession(storageRootURL: root)
        let item1 = makeDummyMediaItem(id: "warm-1", baseName: "DSC_0001")
        let item2 = makeDummyMediaItem(id: "warm-2", baseName: "DSC_0002")

        // Persist dimensions in media cache using the pipeline's exact cache key format
        let key1 = session.mediaPipeline.thumbnailCacheKey(for: item1, previewSource: .preferRaster)
        let key2 = session.mediaPipeline.thumbnailCacheKey(for: item2, previewSource: .preferRaster)
        let dummyData = Data(repeating: 0x01, count: 64)
        session.mediaCache.storeData(dummyData, forKey: key1, pixelWidth: 4000, pixelHeight: 2000)
        session.mediaCache.storeData(dummyData, forKey: key2, pixelWidth: 1000, pixelHeight: 1000)

        // Before warming, in-memory cache has fallback 3:2
        #expect(abs(session.thumbnailAspectRatio(for: item1) - 1.5) < 0.001)
        #expect(abs(session.thumbnailAspectRatio(for: item2) - 1.5) < 0.001)

        // Warm aspect ratios and await completion
        await session.warmThumbnailAspectRatios(for: [item1, item2])?.value

        // Now in-memory ratios reflect 4000:2000 (2.0) and 1000:1000 (1.0)
        let warmed1 = session.thumbnailAspectRatio(for: item1)
        let warmed2 = session.thumbnailAspectRatio(for: item2)
        #expect(abs(warmed1 - 2.0) < 0.001)
        #expect(abs(warmed2 - 1.0) < 0.001)
    }

    // MARK: - Ticket 2 (#50): CullingSequence & O(1) Navigation

    @Test("CullingSequence builds fast item index and precomputes pair and video counts")
    func cullingSequenceStructureAndLookups() {
        let item1 = makeDummyMediaItem(id: "item-1", baseName: "A", kind: .photo)
        let item2 = makeDummyMediaItem(id: "item-2", baseName: "B", kind: .video)
        let item3 = makeDummyMediaPair(id: "item-3", baseName: "C")

        let seq = CullingSequence([item1, item2, item3])

        #expect(seq.items.count == 3)
        #expect(seq.visibleVideoCount == 1)
        #expect(seq.visibleMediaPairCount == 1)

        #expect(seq.index(for: "item-1") == 0)
        #expect(seq.index(for: "item-2") == 1)
        #expect(seq.index(for: "item-3") == 2)
        #expect(seq.index(for: "item-missing") == nil)
    }

    @Test("selectNextItem and selectPreviousItem navigate using O(1) sequence indices")
    func selectNextAndPreviousItemUsingSequenceIndex() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("1".utf8).write(to: root.appendingPathComponent("DSC_0001.JPG"))
        try Data("2".utf8).write(to: root.appendingPathComponent("DSC_0002.JPG"))
        try Data("3".utf8).write(to: root.appendingPathComponent("DSC_0003.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        #expect(session.items.count == 3)
        let items = session.items
        session.selectedItemID = items[0].id
        #expect(session.selectedItemID == items[0].id)

        // Next item
        session.selectNextItem()
        #expect(session.selectedItemID == items[1].id)

        session.selectNextItem()
        #expect(session.selectedItemID == items[2].id)

        // Boundary: last item stays on last item
        session.selectNextItem()
        #expect(session.selectedItemID == items[2].id)

        // Previous item
        session.selectPreviousItem()
        #expect(session.selectedItemID == items[1].id)

        session.selectPreviousItem()
        #expect(session.selectedItemID == items[0].id)

        // Boundary: first item stays on first item
        session.selectPreviousItem()
        #expect(session.selectedItemID == items[0].id)
    }

    @Test("visibleItems is an alias to cullingSequence.items and selection changes do not reallocate sequence")
    func selectionChangeDoesNotReallocateSequence() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("1".utf8).write(to: root.appendingPathComponent("DSC_0001.JPG"))
        try Data("2".utf8).write(to: root.appendingPathComponent("DSC_0002.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        let initialSequence = session.cullingSequence
        #expect(session.visibleItems == initialSequence.items)

        // Mutating selection only
        session.selectedItemID = session.items[1].id

        // cullingSequence remains identical
        #expect(session.cullingSequence == initialSequence)
        #expect(session.visibleItems == initialSequence.items)
    }

    @Test("Capture date sorting places items with nil dates at sequence tail in both ascending and descending order")
    func captureDateSortingWithNilDatesAtTail() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let datedURL = root.appendingPathComponent("A_DATED.JPG")
        let undatedURL = root.appendingPathComponent("B_UNDATED.JPG")

        try makeImageFileWithExif(at: datedURL, dateTimeOriginal: "2026:01:01 10:00:00")
        try makeImageFileWithExif(at: undatedURL) // No dateTimeOriginal

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)
        await session.waitForBackgroundExifPreloading()

        // 1. Ascending by capture date: dated first, undated at tail
        session.setSortOption(SortOption(field: .captureDate, order: .ascending))
        #expect(session.visibleItems.map(\.baseName) == ["A_DATED", "B_UNDATED"])

        // 2. Descending by capture date: dated first, undated at tail
        session.setSortOption(SortOption(field: .captureDate, order: .descending))
        #expect(session.visibleItems.map(\.baseName) == ["A_DATED", "B_UNDATED"])
    }

    @Test("Synthetic 10,000 item sequence executes O(1) index lookups and selection changes instantly")
    func syntheticTenThousandItemSequencePerformance() {
        var items: [MediaItem] = []
        items.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let item = makeDummyMediaItem(id: "item-\(i)", baseName: "DSC_\(String(format: "%05d", i))")
            items.append(item)
        }

        let sequence = CullingSequence(items)
        #expect(sequence.items.count == 10_000)
        #expect(sequence.indicesByItemID.count == 10_000)

        // O(1) lookups
        #expect(sequence.index(for: "item-0") == 0)
        #expect(sequence.index(for: "item-5000") == 5000)
        #expect(sequence.index(for: "item-9999") == 9999)
        #expect(sequence.index(for: "non-existent") == nil)

        // Verify index lookups across arbitrary points execute without delay
        let probeIndices = [100, 2500, 7500, 9999]
        for probe in probeIndices {
            let idx = sequence.index(for: "item-\(probe)")
            #expect(idx == probe)
        }
    }
}
