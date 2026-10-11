import CoreGraphics
import Foundation
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
    }

    @Test("Extracts embedded preview from Olympus .ORF via MakerNote CameraSettingsIFD")
    func extractOlympusORFPreview() async throws {
        guard let dir = findRepoTestFilesDir() else { return }
        let orfURL = dir.appendingPathComponent("P9227357.ORF")
        guard FileManager.default.fileExists(atPath: orfURL.path) else { return }

        let result = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: orfURL, maxPixelSize: 4096))
        let maxDim = max(result.cgImage.width, result.cgImage.height)
        #expect(maxDim >= 3000)
        #expect(result.jpegData.count > 900_000)
    }
}
