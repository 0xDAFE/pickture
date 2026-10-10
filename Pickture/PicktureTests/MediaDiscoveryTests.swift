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
}
