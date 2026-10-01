import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@MainActor
struct CullingSessionFilterAndSortTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureFilterSortTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeImageFileWithExif(
        at url: URL,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        focalLength: Double? = nil,
        fNumber: Double? = nil,
        exposureTime: Double? = nil,
        iso: Int? = nil,
        dateTimeOriginal: String? = nil
    ) throws {
        let width = 32
        let height = 32
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
        var tiffDict: [CFString: Any] = [:]
        if let cameraModel {
            tiffDict[kCGImagePropertyTIFFModel] = cameraModel
        }
        if !tiffDict.isEmpty {
            properties[kCGImagePropertyTIFFDictionary] = tiffDict
        }

        var exifDict: [CFString: Any] = [:]
        if let lensModel {
            exifDict[kCGImagePropertyExifLensModel] = lensModel
        }
        if let focalLength {
            exifDict[kCGImagePropertyExifFocalLength] = focalLength
        }
        if let fNumber {
            exifDict[kCGImagePropertyExifFNumber] = fNumber
        }
        if let exposureTime {
            exifDict[kCGImagePropertyExifExposureTime] = exposureTime
        }
        if let iso {
            exifDict[kCGImagePropertyExifISOSpeedRatings] = [iso]
        }
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

    // MARK: - Slice 1: ExifMetadata Extraction & Caching

    @Test("ExifMetadata is populated from .xmp Sidecar tags first")
    func exifMetadataPopulatedFromXMPFirst() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0100.JPG")
        try makeImageFileWithExif(at: jpgURL, cameraModel: "HeaderCamera", lensModel: "HeaderLens")

        // Write an XMP sidecar with distinct EXIF tags
        let xmpContent = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:aux="http://ns.adobe.com/exif/1.0/aux/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            tiff:Model="Sony A1"
            aux:Lens="FE 50mm F1.2 GM"
            exif:FocalLength="50/1"
            exif:FNumber="12/10"
            exif:ExposureTime="1/2000"
            exif:ISOSpeedRatings="100"
            exif:DateTimeOriginal="2026-08-15T10:30:00Z"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmpURL = root.appendingPathComponent("DSC0100.xmp")
        try Data(xmpContent.utf8).write(to: xmpURL)

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        #expect(session.items.count == 1)
        let item = try #require(session.items.first)

        let exif = session.exifMetadata(for: item)
        // XMP values must take priority over header
        #expect(exif.cameraModel == "Sony A1")
        #expect(exif.lensModel == "FE 50mm F1.2 GM")
        #expect(exif.focalLength == 50.0)
        #expect(exif.fNumber == 1.2)
        #expect(exif.exposureTime == 0.0005)
        #expect(exif.isoSpeedRatings == [100])
        #expect(exif.dateTimeOriginal != nil)
    }

    @Test("ExifMetadata lazily supplements missing tags via header-only reads, preferring raster in MediaPair")
    func exifMetadataSupplementedViaHeaderPreferringRasterInMediaPair() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create MediaPair: RAW + raster JPG
        let rawURL = root.appendingPathComponent("DSC0200.ARW")
        try Data("fake-raw-bytes".utf8).write(to: rawURL)

        let jpgURL = root.appendingPathComponent("DSC0200.JPG")
        try makeImageFileWithExif(
            at: jpgURL,
            cameraModel: "Sony A7R V",
            lensModel: "FE 24-70mm F2.8 GM II",
            focalLength: 35.0,
            fNumber: 2.8,
            exposureTime: 0.004,
            iso: 400,
            dateTimeOriginal: "2026:09:10 16:45:00"
        )

        // Sidecar provides camera model only, missing lens and exposure tags
        let partialXMP = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            tiff:Model="Sony A7R V (Custom Name)"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(partialXMP.utf8).write(to: root.appendingPathComponent("DSC0200.xmp"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        let item = try #require(session.items.first)
        #expect(item.isMediaPair == true)

        let exif = session.exifMetadata(for: item)
        // Camera model from XMP first
        #expect(exif.cameraModel == "Sony A7R V (Custom Name)")
        // Lens model, focal length, fNumber, etc. supplemented from raster header!
        #expect(exif.lensModel == "FE 24-70mm F2.8 GM II")
        #expect(exif.focalLength == 35.0)
        #expect(exif.fNumber == 2.8)
        #expect(exif.isoSpeedRatings == [400])
        #expect(exif.dateTimeOriginal != nil)
    }

    @Test("ExifMetadata is cached in MetadataSyncStore and survives simulated session restarts")
    func exifMetadataCachedInMetadataSyncStoreAndSurvivesRestarts() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent(".store", isDirectory: true)
        let jpgURL = root.appendingPathComponent("DSC0300.JPG")
        try makeImageFileWithExif(
            at: jpgURL,
            cameraModel: "Canon EOS R5",
            lensModel: "RF 85mm F1.2L USM",
            focalLength: 85.0,
            fNumber: 1.2,
            exposureTime: 0.001,
            iso: 200,
            dateTimeOriginal: "2026:08:20 18:00:00"
        )

        // Session 1: Extract and cache
        let session1 = CullingSession(storageRootURL: storeURL)
        try session1.openFolder(at: root)
        let item1 = try #require(session1.items.first)

        let exif1 = session1.exifMetadata(for: item1)
        #expect(exif1.cameraModel == "Canon EOS R5")
        #expect(exif1.lensModel == "RF 85mm F1.2L USM")

        // Verify stored in MetadataSyncStore
        let record = try #require(session1.metadataSyncStore.record(for: item1.id))
        #expect(record.exif?.cameraModel == "Canon EOS R5")
        #expect(record.exif?.lensModel == "RF 85mm F1.2L USM")

        // Session 2: Simulated restart with fresh instance pointing to same store
        let session2 = CullingSession(storageRootURL: storeURL)
        try session2.openFolder(at: root)
        let item2 = try #require(session2.items.first)

        // Read without extracting again — verified from persistent store
        let cachedRecord = try #require(session2.metadataSyncStore.record(for: item2.id))
        #expect(cachedRecord.exif?.cameraModel == "Canon EOS R5")
        #expect(cachedRecord.exif?.lensModel == "RF 85mm F1.2L USM")
        #expect(session2.exifMetadata(for: item2).cameraModel == "Canon EOS R5")
    }

    // MARK: - Slice 2: Multi-Facet FilterCriteria Evaluation

    @Test("FilterCriteria filters by filename substring case-insensitively")
    func filterCriteriaFilenameSubstring() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("img".utf8).write(to: root.appendingPathComponent("DSC0010.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("IMG_0020.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("DSC0030.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)
        #expect(session.items.count == 3)

        session.filterCriteria.searchQuery = "img"
        #expect(session.visibleItems.count == 1)
        #expect(session.visibleItems.first?.baseName == "IMG_0020")

        session.filterCriteria.searchQuery = "00"
        #expect(session.visibleItems.count == 3)

        session.filterCriteria.searchQuery = "dsc"
        #expect(session.visibleItems.count == 2)
    }

    @Test("FilterCriteria filters by StarRating in exact and minimum (>=) modes")
    func filterCriteriaStarRatingExactAndMinimum() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("img".utf8).write(to: root.appendingPathComponent("A.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("B.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("C.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("D.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        let itemA = try #require(session.items.first { $0.baseName == "A" })
        let itemB = try #require(session.items.first { $0.baseName == "B" })
        let itemC = try #require(session.items.first { $0.baseName == "C" })
        let itemD = try #require(session.items.first { $0.baseName == "D" })

        session.setStarRating(1, for: itemA)
        session.setStarRating(3, for: itemB)
        session.setStarRating(4, for: itemC)
        session.setStarRating(5, for: itemD)

        // Exact mode: [3, 5] (OR within category)
        session.filterCriteria.starRatingFilter = .exact([3, 5])
        #expect(session.visibleItems.count == 2)
        #expect(Set(session.visibleItems.map(\.baseName)) == Set(["B", "D"]))

        // Minimum mode: >= 4
        session.filterCriteria.starRatingFilter = .minimum(4)
        #expect(session.visibleItems.count == 2)
        #expect(Set(session.visibleItems.map(\.baseName)) == Set(["C", "D"]))

        // Minimum mode: >= 1
        session.filterCriteria.starRatingFilter = .minimum(1)
        #expect(session.visibleItems.count == 4)
    }

    @Test("FilterCriteria filters by PickFlag with logical OR within category")
    func filterCriteriaPickFlagORWithin() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("img".utf8).write(to: root.appendingPathComponent("P1.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("P2.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("P3.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        let p1 = try #require(session.items.first { $0.baseName == "P1" })
        let p2 = try #require(session.items.first { $0.baseName == "P2" })
        let p3 = try #require(session.items.first { $0.baseName == "P3" })

        session.setPickFlag(.picked, for: p1)
        session.setPickFlag(.unflagged, for: p2)
        session.setPickFlag(.rejected, for: p3)

        // OR within PickFlag: picked or rejected
        session.filterCriteria.pickFlags = [.picked, .rejected]
        #expect(session.visibleItems.count == 2)
        #expect(Set(session.visibleItems.map(\.baseName)) == Set(["P1", "P3"]))

        // Only picked
        session.filterCriteria.pickFlags = [.picked]
        #expect(session.visibleItems.count == 1)
        #expect(session.visibleItems.first?.baseName == "P1")
    }

    @Test("FilterCriteria filters by ColorLabel with logical OR within category")
    func filterCriteriaColorLabelORWithin() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("img".utf8).write(to: root.appendingPathComponent("C1.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("C2.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("C3.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        let c1 = try #require(session.items.first { $0.baseName == "C1" })
        let c2 = try #require(session.items.first { $0.baseName == "C2" })
        let c3 = try #require(session.items.first { $0.baseName == "C3" })

        session.setColorLabel(.red, for: c1)
        session.setColorLabel(.yellow, for: c2)
        session.setColorLabel(.green, for: c3)

        session.filterCriteria.colorLabels = [.red, .green]
        #expect(session.visibleItems.count == 2)
        #expect(Set(session.visibleItems.map(\.baseName)) == Set(["C1", "C3"]))
    }

    @Test("FilterCriteria filters by Camera Model and Lens Model with logical OR within category")
    func filterCriteriaCameraAndLensModel() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let f1 = root.appendingPathComponent("C1.JPG")
        let f2 = root.appendingPathComponent("C2.JPG")
        let f3 = root.appendingPathComponent("C3.JPG")

        try makeImageFileWithExif(at: f1, cameraModel: "Sony A1", lensModel: "FE 50mm F1.2 GM")
        try makeImageFileWithExif(at: f2, cameraModel: "Canon R5", lensModel: "RF 50mm F1.2L")
        try makeImageFileWithExif(at: f3, cameraModel: "Nikon Z9", lensModel: "NIKKOR 50mm f/1.2")

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        #expect(session.availableCameraModels == ["Canon R5", "Nikon Z9", "Sony A1"])
        #expect(session.availableLensModels == ["FE 50mm F1.2 GM", "NIKKOR 50mm f/1.2", "RF 50mm F1.2L"])

        // Filter by Camera Model
        session.filterCriteria.cameraModels = ["Sony A1", "Canon R5"]
        #expect(session.visibleItems.count == 2)
        #expect(Set(session.visibleItems.map(\.baseName)) == Set(["C1", "C2"]))

        // Filter by Lens Model
        session.filterCriteria.cameraModels = []
        session.filterCriteria.lensModels = ["NIKKOR 50mm f/1.2"]
        #expect(session.visibleItems.count == 1)
        #expect(session.visibleItems.first?.baseName == "C3")
    }

    @Test("FilterCriteria filters by Media Type (Photo, Video, MediaPair) with logical OR within category")
    func filterCriteriaMediaTypeORWithin() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Standalone photo
        try Data("img".utf8).write(to: root.appendingPathComponent("PhotoOnly.JPG"))
        // 2. Video
        try Data("vid".utf8).write(to: root.appendingPathComponent("VideoOnly.MOV"))
        // 3. MediaPair
        try Data("raw".utf8).write(to: root.appendingPathComponent("Paired.ARW"))
        try Data("jpg".utf8).write(to: root.appendingPathComponent("Paired.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)
        #expect(session.items.count == 3)

        // Filter only MediaPairs
        session.filterCriteria.mediaTypes = [.mediaPair]
        #expect(session.visibleItems.count == 1)
        #expect(session.visibleItems.first?.baseName == "Paired")

        // Filter Photos and Videos
        session.filterCriteria.mediaTypes = [.photo, .video]
        #expect(session.visibleItems.count == 2)
        #expect(Set(session.visibleItems.map(\.baseName)) == Set(["PhotoOnly", "VideoOnly"]))
    }

    @Test("FilterCriteria filters by SyncState with logical OR within category")
    func filterCriteriaSyncStateORWithin() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("img".utf8).write(to: root.appendingPathComponent("S1.JPG"))
        try Data("img".utf8).write(to: root.appendingPathComponent("S2.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let s1 = try #require(session.items.first { $0.baseName == "S1" })
        let s2 = try #require(session.items.first { $0.baseName == "S2" })

        // S1 remains synced, S2 gets pending mutation
        session.setStarRating(3, for: s2)
        #expect(session.syncState(for: s1) == .synced)
        #expect(session.syncState(for: s2) == .pendingWrite)

        session.filterCriteria.syncStates = [.pendingWrite]
        #expect(session.visibleItems.count == 1)
        #expect(session.visibleItems.first?.baseName == "S2")

        session.filterCriteria.syncStates = [.synced]
        #expect(session.visibleItems.count == 1)
        #expect(session.visibleItems.first?.baseName == "S1")
    }

    @Test("FilterCriteria combines selections using logical OR within category and logical AND across categories")
    func filterCriteriaORWithinAndANDAcross() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let f1 = root.appendingPathComponent("MATCH.JPG")
        let f2 = root.appendingPathComponent("WRONG_RATING.JPG")
        let f3 = root.appendingPathComponent("WRONG_FLAG.JPG")
        let f4 = root.appendingPathComponent("WRONG_CAMERA.JPG")

        try makeImageFileWithExif(at: f1, cameraModel: "Sony A1")
        try makeImageFileWithExif(at: f2, cameraModel: "Sony A1")
        try makeImageFileWithExif(at: f3, cameraModel: "Sony A1")
        try makeImageFileWithExif(at: f4, cameraModel: "Nikon Z9")

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        let item1 = try #require(session.items.first { $0.baseName == "MATCH" })
        let item2 = try #require(session.items.first { $0.baseName == "WRONG_RATING" })
        let item3 = try #require(session.items.first { $0.baseName == "WRONG_FLAG" })
        let item4 = try #require(session.items.first { $0.baseName == "WRONG_CAMERA" })

        session.setStarRating(5, for: item1)
        session.setPickFlag(.picked, for: item1)

        session.setStarRating(2, for: item2) // wrong rating
        session.setPickFlag(.picked, for: item2)

        session.setStarRating(5, for: item3)
        session.setPickFlag(.rejected, for: item3) // wrong flag

        session.setStarRating(5, for: item4)
        session.setPickFlag(.picked, for: item4) // wrong camera

        // Query: rating >= 4 AND pickFlag == .picked AND cameraModel == "Sony A1"
        session.filterCriteria.starRatingFilter = .minimum(4)
        session.filterCriteria.pickFlags = [.picked]
        session.filterCriteria.cameraModels = ["Sony A1"]

        #expect(session.visibleItems.count == 1)
        #expect(session.visibleItems.first?.baseName == "MATCH")
    }

    @Test("FilterCriteria active filter count badge and one-tap reset")
    func filterCriteriaActiveBadgeAndReset() {
        var criteria = FilterCriteria()
        #expect(criteria.activeFilterCount == 0)
        #expect(!criteria.isActive)

        criteria.searchQuery = "DSC"
        #expect(criteria.activeFilterCount == 1)

        criteria.starRatingFilter = .minimum(3)
        #expect(criteria.activeFilterCount == 2)

        criteria.pickFlags = [.picked]
        #expect(criteria.activeFilterCount == 3)

        criteria.colorLabels = [.red, .blue]
        #expect(criteria.activeFilterCount == 4)

        criteria.cameraModels = ["Sony A1"]
        #expect(criteria.activeFilterCount == 5)

        criteria.lensModels = ["50mm"]
        #expect(criteria.activeFilterCount == 6)

        criteria.mediaTypes = [.photo]
        #expect(criteria.activeFilterCount == 7)

        criteria.syncStates = [.synced]
        #expect(criteria.activeFilterCount == 8)
        #expect(criteria.isActive)

        criteria.reset()
        #expect(criteria.activeFilterCount == 0)
        #expect(!criteria.isActive)
        #expect(criteria.searchQuery.isEmpty)
        #expect(criteria.starRatingFilter == nil)
        #expect(criteria.pickFlags.isEmpty)
        #expect(criteria.colorLabels.isEmpty)
        #expect(criteria.cameraModels.isEmpty)
        #expect(criteria.lensModels.isEmpty)
        #expect(criteria.mediaTypes.isEmpty)
        #expect(criteria.syncStates.isEmpty)
    }

    // MARK: - Slice 3: Configurable Sorting

    @Test("Users can sort visible MediaItems by Filename in ascending and descending order")
    func sortingByFilenameAscendingAndDescending() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("a".utf8).write(to: root.appendingPathComponent("DSC0003.JPG"))
        try Data("b".utf8).write(to: root.appendingPathComponent("DSC0001.JPG"))
        try Data("c".utf8).write(to: root.appendingPathComponent("DSC0002.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        // Default: Filename Ascending
        session.setSortOption(SortOption(field: .fileName, order: .ascending))
        let ascNames = session.visibleItems.map(\.baseName)
        #expect(ascNames == ["DSC0001", "DSC0002", "DSC0003"])

        // Filename Descending
        session.setSortOption(SortOption(field: .fileName, order: .descending))
        let descNames = session.visibleItems.map(\.baseName)
        #expect(descNames == ["DSC0003", "DSC0002", "DSC0001"])
    }

    @Test("Users can sort visible MediaItems by Star Rating in ascending and descending order")
    func sortingByStarRatingAscendingAndDescending() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("a".utf8).write(to: root.appendingPathComponent("ITEM_A.JPG"))
        try Data("b".utf8).write(to: root.appendingPathComponent("ITEM_B.JPG"))
        try Data("c".utf8).write(to: root.appendingPathComponent("ITEM_C.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        let a = try #require(session.items.first { $0.baseName == "ITEM_A" })
        let b = try #require(session.items.first { $0.baseName == "ITEM_B" })
        let c = try #require(session.items.first { $0.baseName == "ITEM_C" })

        session.setStarRating(1, for: a)
        session.setStarRating(5, for: b)
        session.setStarRating(3, for: c)

        // Ascending
        session.setSortOption(SortOption(field: .starRating, order: .ascending))
        #expect(session.visibleItems.map(\.baseName) == ["ITEM_A", "ITEM_C", "ITEM_B"])

        // Descending
        session.setSortOption(SortOption(field: .starRating, order: .descending))
        #expect(session.visibleItems.map(\.baseName) == ["ITEM_B", "ITEM_C", "ITEM_A"])
    }

    @Test("Users can sort visible MediaItems by Capture Date in ascending and descending order")
    func sortingByCaptureDateAscendingAndDescending() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let earlyURL = root.appendingPathComponent("EARLY.JPG")
        let midURL = root.appendingPathComponent("MID.JPG")
        let lateURL = root.appendingPathComponent("LATE.JPG")

        try makeImageFileWithExif(at: earlyURL, dateTimeOriginal: "2026:01:01 10:00:00")
        try makeImageFileWithExif(at: midURL, dateTimeOriginal: "2026:06:01 12:00:00")
        try makeImageFileWithExif(at: lateURL, dateTimeOriginal: "2026:12:01 14:00:00")

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        // Ascending (earliest first)
        session.setSortOption(SortOption(field: .captureDate, order: .ascending))
        #expect(session.visibleItems.map(\.baseName) == ["EARLY", "MID", "LATE"])

        // Descending (latest first)
        session.setSortOption(SortOption(field: .captureDate, order: .descending))
        #expect(session.visibleItems.map(\.baseName) == ["LATE", "MID", "EARLY"])
    }

    @Test("Navigation commands adhere strictly to visibleItems after filtering and sorting")
    func navigationAdheresToVisibleItems() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("1".utf8).write(to: root.appendingPathComponent("IMG_1.JPG"))
        try Data("2".utf8).write(to: root.appendingPathComponent("IMG_2.JPG"))
        try Data("3".utf8).write(to: root.appendingPathComponent("IMG_3.JPG"))
        try Data("4".utf8).write(to: root.appendingPathComponent("IMG_4.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        let i1 = try #require(session.items.first { $0.baseName == "IMG_1" })
        let i2 = try #require(session.items.first { $0.baseName == "IMG_2" })
        let i3 = try #require(session.items.first { $0.baseName == "IMG_3" })
        let i4 = try #require(session.items.first { $0.baseName == "IMG_4" })

        session.setPickFlag(.picked, for: i1)
        session.setPickFlag(.rejected, for: i2)
        session.setPickFlag(.picked, for: i3)
        session.setPickFlag(.rejected, for: i4)

        // Filter to picked items only: [IMG_1, IMG_3]
        session.filterCriteria.pickFlags = [.picked]
        #expect(session.visibleItems.count == 2)

        session.selectFirstItem()
        #expect(session.selectedItemID == i1.id)

        session.selectNextItem()
        #expect(session.selectedItemID == i3.id)

        // Attempting to select past the last visible item stays at the end
        session.selectNextItem()
        #expect(session.selectedItemID == i3.id)

        session.selectPreviousItem()
        #expect(session.selectedItemID == i1.id)

        session.selectLastItem()
        #expect(session.selectedItemID == i3.id)
    }
}
