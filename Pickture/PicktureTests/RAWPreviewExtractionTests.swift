import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Pickture

@Suite("RAW Preview Extraction Tests")
struct RAWPreviewExtractionTests {

    private func findRepoTestFilesDir() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/tmp/raws", isDirectory: true),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // PicktureTests
                .deletingLastPathComponent() // Pickture
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("testfiles/raws", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("testfiles/raws", isDirectory: true)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }


    @Test("Extracts high-resolution embedded preview from Sony .ARW via byte-range read")
    func extractSonyARWPreview() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let arwURL = dir.appendingPathComponent("5947067782.ARW")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }

        let result = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: arwURL, maxPixelSize: 4096))
        let maxDim = max(result.cgImage.width, result.cgImage.height)
        #expect(maxDim >= 1600)
        #expect(result.jpegData.count > 400_000)
        // 5947067782.ARW is a portrait capture (orientation 8)
        #expect(result.cgImage.height > result.cgImage.width)
        let decodedCached = try #require(PreviewLoader.decodeCGImage(from: result.jpegData))
        #expect(decodedCached.height > decodedCached.width)
    }

    @Test("Extracts embedded preview from Canon .CR3 via ISOBMFF box parsing")
    func extractCanonCR3Preview() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let cr3URL = dir.appendingPathComponent("0L1A9673.CR3")
        guard FileManager.default.fileExists(atPath: cr3URL.path) else { return }

        let result = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: cr3URL, maxPixelSize: 4096))
        let maxDim = max(result.cgImage.width, result.cgImage.height)
        #expect(maxDim >= 1600)
        #expect(result.jpegData.count > 200_000)
        // 0L1A9673.CR3 is a portrait capture (orientation 8)
        #expect(result.cgImage.height > result.cgImage.width)
        let decodedCached = try #require(PreviewLoader.decodeCGImage(from: result.jpegData))
        #expect(decodedCached.height > decodedCached.width)
    }

    @Test("Extracts high-resolution embedded preview from Fujifilm .RAF via header table")
    func extractFujifilmRAFPreview() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let rafURL = dir.appendingPathComponent("6724403687.RAF")
        guard FileManager.default.fileExists(atPath: rafURL.path) else { return }

        let result = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: rafURL, maxPixelSize: 4096))
        let maxDim = max(result.cgImage.width, result.cgImage.height)
        #expect(maxDim >= 4000)
        #expect(result.jpegData.count > 3_500_000)
        // 6724403687.RAF is a portrait capture (orientation 6)
        #expect(result.cgImage.height > result.cgImage.width)
        let decodedCached = try #require(PreviewLoader.decodeCGImage(from: result.jpegData))
        #expect(decodedCached.height > decodedCached.width)
    }

    @Test("Extracts embedded preview from Nikon .NEF via SubIFD parsing")
    func extractNikonNEFPreview() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let nefURL = dir.appendingPathComponent("4674414196.NEF")
        guard FileManager.default.fileExists(atPath: nefURL.path) else { return }

        let result = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: nefURL, maxPixelSize: 4096))
        let maxDim = max(result.cgImage.width, result.cgImage.height)
        #expect(maxDim >= 4000)
        #expect(result.jpegData.count > 1_000_000)
        // 4674414196.NEF is a landscape capture (orientation 1)
        #expect(result.cgImage.width > result.cgImage.height)
        let decodedCached = try #require(PreviewLoader.decodeCGImage(from: result.jpegData))
        #expect(decodedCached.width > decodedCached.height)
    }

    @Test("Extracts embedded preview from Olympus .ORF via MakerNote CameraSettingsIFD")
    func extractOlympusORFPreview() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let orfURL = dir.appendingPathComponent("P9227357.ORF")
        guard FileManager.default.fileExists(atPath: orfURL.path) else { return }

        let result = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: orfURL, maxPixelSize: 4096))
        let maxDim = max(result.cgImage.width, result.cgImage.height)
        #expect(maxDim >= 3000)
        #expect(result.jpegData.count > 500_000)
        // P9227357.ORF is a portrait capture (orientation 8)
        #expect(result.cgImage.height > result.cgImage.width)
        let decodedCached = try #require(PreviewLoader.decodeCGImage(from: result.jpegData))
        #expect(decodedCached.height > decodedCached.width)
    }

    @Test("Thumbnail extraction for vertical RAW generates compact, oriented JPEG data")
    func thumbnailExtractionProducesCompactOrientedData() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let arwURL = dir.appendingPathComponent("5947067782.ARW")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }

        let result = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: arwURL, maxPixelSize: 360))
        let maxDim = max(result.cgImage.width, result.cgImage.height)
        #expect(maxDim <= 360)
        #expect(result.cgImage.height > result.cgImage.width)
        #expect(result.jpegData.count < 100_000) // Compact thumbnail, not full-size raw slice
        let decoded = try #require(PreviewLoader.decodeCGImage(from: result.jpegData))
        #expect(decoded.height > decoded.width)
    }

    private func makeStandaloneRAWMediaItem(fileURL: URL) -> MediaItem {
        let file = MediaFile(url: fileURL, formatKind: .raw)
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

    @Test("Moving forward and backward through vertical RAW photos retains portrait orientation across cache round-trip")
    func movingForwardAndBackwardRetainsPortraitOrientation() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let arwURL = dir.appendingPathComponent("5947067782.ARW")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        DecodedImageCache.shared.clear()
        let pipeline = await MediaPipeline(cacheDirectoryURL: tempDir)

        let item = makeStandaloneRAWMediaItem(fileURL: arwURL)

        // 1. Moving forward: loadPreviewImage for the first time
        let forwardImage = try #require(await pipeline.loadPreviewImage(for: item, previewSource: .preferRAW, maxPixelSize: 2048))
        #expect(forwardImage.height > forwardImage.width)
        #expect(forwardImage.aspectRatio < 1.0)

        // Simulate moving to another item and memory pressure / cache round-trip by evicting DecodedImageCache
        DecodedImageCache.shared.clear()

        // 2. Moving back one item: loadPreviewImage should read from disk cache and NOT revert to horizontal
        let backwardImage = try #require(await pipeline.loadPreviewImage(for: item, previewSource: .preferRAW, maxPixelSize: 2048))
        #expect(backwardImage.height > backwardImage.width)
        #expect(backwardImage.aspectRatio < 1.0)
    }

    @Test("Filmstrip and grid view thumbnail previews for vertical RAW photos show portrait aspect ratio")
    func filmstripAndGridThumbnailsShowPortraitOrientation() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let arwURL = dir.appendingPathComponent("5947067782.ARW")
        guard FileManager.default.fileExists(atPath: arwURL.path) else { return }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        DecodedImageCache.shared.clear()
        let pipeline = await MediaPipeline(cacheDirectoryURL: tempDir)

        let item = makeStandaloneRAWMediaItem(fileURL: arwURL)

        // Grid view path: loadThumbnailImage
        let gridThumb = try #require(await pipeline.loadThumbnailImage(for: item, previewSource: .preferRAW, maxPixelSize: 360))
        #expect(gridThumb.height > gridThumb.width)
        #expect(gridThumb.aspectRatio < 1.0)

        // Filmstrip path: loadThumbnailData
        let thumbData = try #require(await pipeline.loadThumbnailData(for: item, previewSource: .preferRAW, maxPixelSize: 360))
        let filmstripThumb = try #require(PreviewLoader.decodeCGImage(from: thumbData))
        #expect(filmstripThumb.height > filmstripThumb.width)
        #expect(filmstripThumb.aspectRatio < 1.0)
    }
}
