import Foundation
import Testing
@testable import Pickture

@Suite("MediaDiscovery Seam Tests")
struct MediaDiscoveryTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("MediaDiscovery pairs case-insensitive RAW and raster files in same directory")
    func discoveryPairsRawAndRasterDirectly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("raw".utf8).write(to: root.appendingPathComponent("DSC_1001.NEF"))
        try Data("jpg".utf8).write(to: root.appendingPathComponent("dsc_1001.jpg"))
        try Data("xmp".utf8).write(to: root.appendingPathComponent("DSC_1001.xmp"))

        let items = try MediaDiscovery.discoverItems(
            inSingleDirectory: root,
            rootURL: root
        )

        #expect(items.count == 1)
        let item = items[0]
        #expect(item.baseName == "DSC_1001")
        #expect(item.isMediaPair == true)
        #expect(item.badgeText == "RAW+JPG")
        #expect(item.sidecarURL != nil)
    }

    @Test("MediaDiscovery isolates video files even when matching photo basename")
    func discoveryIsolatesVideoFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("raw".utf8).write(to: root.appendingPathComponent("IMG_001.CR3"))
        try Data("mov".utf8).write(to: root.appendingPathComponent("IMG_001.MOV"))

        let items = try MediaDiscovery.discoverItems(
            inSingleDirectory: root,
            rootURL: root
        )

        #expect(items.count == 2)
        let photo = try #require(items.first { $0.kind == .photo })
        let video = try #require(items.first { $0.kind == .video })

        #expect(photo.isMediaPair == false)
        #expect(video.isMediaPair == false)
        #expect(video.badgeText == "VIDEO")
    }

    @Test("MediaDiscovery correctly identifies ignored cache directory names")
    func ignoresNonMediaDirectories() {
        #expect(MediaDiscovery.isIgnoredNonMediaDirectory(name: "catalog.lrdata") == true)
        #expect(MediaDiscovery.isIgnoredNonMediaDirectory(name: "Session.lrcat") == true)
        #expect(MediaDiscovery.isIgnoredNonMediaDirectory(name: "CaptureOne") == true)
        #expect(MediaDiscovery.isIgnoredNonMediaDirectory(name: "@eaDir") == true)
        #expect(MediaDiscovery.isIgnoredNonMediaDirectory(name: ".Trashes") == true)
        #expect(MediaDiscovery.isIgnoredNonMediaDirectory(name: ".Spotlight-V100") == true)
        #expect(MediaDiscovery.isIgnoredNonMediaDirectory(name: "Day1_Shoot") == false)
        #expect(MediaDiscovery.isIgnoredNonMediaDirectory(name: "RAW_Files") == false)
    }

    @Test("MediaDiscovery immediate mode only discovers items in root directory")
    func immediateModeTraversalOnlyDiscoversRootItems() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let subfolder = root.appendingPathComponent("Subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        try Data("raw".utf8).write(to: root.appendingPathComponent("IMG_0001.ARW"))
        try Data("jpg".utf8).write(to: root.appendingPathComponent("IMG_0001.JPG"))
        try Data("mov".utf8).write(to: root.appendingPathComponent("IMG_0002.MOV"))

        try Data("raw".utf8).write(to: subfolder.appendingPathComponent("IMG_0003.ARW"))
        try Data("jpg".utf8).write(to: subfolder.appendingPathComponent("IMG_0003.JPG"))

        let storageRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let items = try MediaDiscovery.discoverItems(
            in: root,
            mode: .immediate,
            storageRootURL: storageRoot
        )

        #expect(items.count == 2)
        let itemNames = Set(items.map(\.baseName))
        #expect(itemNames.contains("IMG_0001"))
        #expect(itemNames.contains("IMG_0002"))
        #expect(!itemNames.contains("IMG_0003"))

        let pair = try #require(items.first { $0.baseName == "IMG_0001" })
        #expect(pair.isMediaPair == true)
        #expect(pair.relativeDirectoryPath == "")
    }

    @Test("MediaDiscovery recursive mode skips cache folders during directory enumeration")
    func recursiveModeSkipsCacheDirectoriesDuringEnumeration() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let validSub = root.appendingPathComponent("ShootDay1", isDirectory: true)
        let validNested = validSub.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: validNested, withIntermediateDirectories: true)

        try Data("jpg".utf8).write(to: root.appendingPathComponent("ROOT_01.JPG"))
        try Data("jpg".utf8).write(to: validSub.appendingPathComponent("DAY1_01.JPG"))
        try Data("jpg".utf8).write(to: validNested.appendingPathComponent("NESTED_01.JPG"))

        let lrdata = root.appendingPathComponent("catalog.lrdata", isDirectory: true)
        let c1 = root.appendingPathComponent("CaptureOne", isDirectory: true)
        let eadir = validSub.appendingPathComponent("@eaDir", isDirectory: true)
        let trashes = root.appendingPathComponent(".Trashes", isDirectory: true)
        let spotlight = root.appendingPathComponent(".Spotlight-V100", isDirectory: true)
        let storageRoot = root.appendingPathComponent(".internal-store", isDirectory: true)

        for dir in [lrdata, c1, eadir, trashes, spotlight, storageRoot] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("cache-jpg".utf8).write(to: dir.appendingPathComponent("IGNORED.JPG"))
        }

        let items = try MediaDiscovery.discoverItems(
            in: root,
            mode: .recursive,
            storageRootURL: storageRoot
        )

        let discoveredBaseNames = Set(items.map(\.baseName))
        #expect(discoveredBaseNames.contains("ROOT_01"))
        #expect(discoveredBaseNames.contains("DAY1_01"))
        #expect(discoveredBaseNames.contains("NESTED_01"))
        #expect(!discoveredBaseNames.contains("IGNORED"))
        #expect(items.count == 3)

        let collectedDirs = try MediaDiscovery.collectDirectories(
            from: root,
            mode: .recursive,
            storageRootURL: storageRoot
        )
        let collectedPaths = collectedDirs.map(\.standardizedFileURL.path)
        #expect(collectedPaths.contains(root.standardizedFileURL.path))
        #expect(collectedPaths.contains(validSub.standardizedFileURL.path))
        #expect(collectedPaths.contains(validNested.standardizedFileURL.path))
        for ignored in [lrdata, c1, eadir, trashes, spotlight, storageRoot] {
            #expect(!collectedPaths.contains(ignored.standardizedFileURL.path))
        }
    }

    @Test("MediaDiscovery streamDiscoveredItems streams batches progressively and reports non-decreasing progress")
    func streamDiscoveredItemsStreamsBatchesWithProgress() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir1 = root.appendingPathComponent("FolderA", isDirectory: true)
        let dir2 = root.appendingPathComponent("FolderB", isDirectory: true)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        try Data("jpg".utf8).write(to: root.appendingPathComponent("IMG_ROOT.JPG"))
        try Data("jpg".utf8).write(to: dir1.appendingPathComponent("IMG_A.JPG"))
        try Data("jpg".utf8).write(to: dir2.appendingPathComponent("IMG_B.JPG"))

        let storageRoot = root.appendingPathComponent(".store", isDirectory: true)
        let stream = MediaDiscovery.streamDiscoveredItems(
            from: root,
            mode: .recursive,
            storageRootURL: storageRoot,
            fileManagerFactory: { FileManager() }
        )

        var batches: [MediaDiscovery.DiscoveredBatch] = []
        var lastProgress: Double = 0.0

        for try await batch in stream {
            batches.append(batch)
            #expect(batch.progress >= lastProgress)
            #expect(batch.progress <= 1.0)
            lastProgress = batch.progress
        }

        #expect(!batches.isEmpty)
        #expect(lastProgress == 1.0)

        let allItems = batches.flatMap(\.items)
        let names = Set(allItems.map(\.baseName))
        #expect(names.contains("IMG_ROOT"))
        #expect(names.contains("IMG_A"))
        #expect(names.contains("IMG_B"))
        #expect(allItems.count == 3)
    }

    @Test("MediaDiscovery collectDirectories does not skip sibling directory sharing storage root prefix")
    func collectDirectoriesPreservesSiblingSharingStoragePrefix() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storageRoot = root.appendingPathComponent("store", isDirectory: true)
        let siblingDir = root.appendingPathComponent("store-extra", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)

        try Data("jpg".utf8).write(to: siblingDir.appendingPathComponent("PHOTO.JPG"))

        let dirs = try MediaDiscovery.collectDirectories(
            from: root,
            mode: .recursive,
            storageRootURL: storageRoot
        )
        let paths = dirs.map(\.standardizedFileURL.path)
        #expect(paths.contains(siblingDir.standardizedFileURL.path))
        #expect(!paths.contains(storageRoot.standardizedFileURL.path))
    }

    @Test("MediaDiscovery streamDiscoveredItems finishes throwing when given a non-existent directory")
    func streamDiscoveredItemsThrowsForMissingDirectory() async {
        let nonExistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NonExistent-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Store-\(UUID().uuidString)", isDirectory: true)

        let stream = MediaDiscovery.streamDiscoveredItems(
            from: nonExistent,
            mode: .immediate,
            storageRootURL: storageRoot
        )

        do {
            for try await _ in stream {
                Issue.record("Stream should have failed for non-existent directory")
            }
            Issue.record("Expected error was not thrown")
        } catch {
            #expect((error as? CocoaError)?.code == .fileReadNoSuchFile)
        }
    }

    @Test("MediaDiscovery prefers <basename>.xmp over <filename>.<ext>.xmp per ADR-0001")
    func adr0001SidecarPrecedenceBasenamePreferredOverExtensionSidecar() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Item 1: Has both <basename>.xmp and <filename>.<ext>.xmp
        // <basename>.xmp MUST win regardless of discovery order
        try Data("raw".utf8).write(to: root.appendingPathComponent("DSC0001.ARW"))
        try Data("jpg".utf8).write(to: root.appendingPathComponent("DSC0001.JPG"))
        try Data("basename-xmp".utf8).write(to: root.appendingPathComponent("DSC0001.xmp"))
        try Data("darktable-xmp".utf8).write(to: root.appendingPathComponent("DSC0001.ARW.xmp"))

        // Item 2: Has ONLY <filename>.<ext>.xmp (Darktable convention)
        // Must discover and attach the Darktable sidecar
        try Data("raw".utf8).write(to: root.appendingPathComponent("DSC0002.CR3"))
        try Data("darktable-only-xmp".utf8).write(to: root.appendingPathComponent("DSC0002.CR3.xmp"))

        let items = try MediaDiscovery.discoverItems(
            inSingleDirectory: root,
            rootURL: root
        )

        let item1 = try #require(items.first { $0.baseName == "DSC0001" })
        let sidecar1 = try #require(item1.sidecarURL)
        #expect(sidecar1.lastPathComponent.lowercased() == "dsc0001.xmp")

        let item2 = try #require(items.first { $0.baseName == "DSC0002" })
        let sidecar2 = try #require(item2.sidecarURL)
        #expect(sidecar2.lastPathComponent.lowercased() == "dsc0002.cr3.xmp")
    }

    @Test("MediaDiscovery preserves <basename>.xmp precedence in pairDirectoryMediaFiles")
    func adr0001SidecarPrecedenceInPairDirectoryMediaFiles() {
        let dirURL = URL(fileURLWithPath: "/Photos/Shoot")
        let rootURL = dirURL

        let rawFile = MediaFile(url: dirURL.appendingPathComponent("IMG_500.ARW"), formatKind: .raw)
        let jpgFile = MediaFile(url: dirURL.appendingPathComponent("IMG_500.JPG"), formatKind: .raster)

        let basenameXMP = dirURL.appendingPathComponent("IMG_500.xmp")

        // Passing sidecarsByLowerBase where base resolves to <basename>.xmp
        let sidecars: [String: URL] = [
            "img_500": basenameXMP,
            "img_500.arw": dirURL.appendingPathComponent("IMG_500.ARW.xmp")
        ]

        let items = MediaDiscovery.pairDirectoryMediaFiles(
            [rawFile, jpgFile],
            sidecarsByLowerBase: sidecars,
            directoryURL: dirURL,
            rootURL: rootURL
        )

        #expect(items.count == 1)
        #expect(items[0].sidecarURL?.lastPathComponent == "IMG_500.xmp")
    }
}
