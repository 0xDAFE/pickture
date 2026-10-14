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

    // MARK: - Lean 128 KB Upfront Buffer & Targeted Range-Read Tests (Ticket 3 / Issue #60)

    private func makeValidJPEGData(width: Int = 200, height: Int = 100) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        for i in 0..<width {
            let r = CGFloat(i) / CGFloat(width)
            context.setFillColor(CGColor(red: r, green: 0.5, blue: 1.0 - r, alpha: 1.0))
            context.fill(CGRect(x: CGFloat(i), y: 0, width: 1, height: CGFloat(height)))
        }
        let cgImage = context.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func writeUInt16LE(_ val: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(val & 0xFF)
        data[offset + 1] = UInt8((val >> 8) & 0xFF)
    }

    private func writeUInt32LE(_ val: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(val & 0xFF)
        data[offset + 1] = UInt8((val >> 8) & 0xFF)
        data[offset + 2] = UInt8((val >> 16) & 0xFF)
        data[offset + 3] = UInt8((val >> 24) & 0xFF)
    }

    private func createSyntheticInRAMTIFF(at fileURL: URL) throws {
        var data = Data(count: 65_536)
        let jpeg = makeValidJPEGData(width: 200, height: 100)

        // Header: "II", 42, IFD0 offset 8
        data[0] = 0x49
        data[1] = 0x49
        writeUInt16LE(42, to: &data, at: 2)
        writeUInt32LE(8, to: &data, at: 4)

        // IFD0 at 8: count = 3
        writeUInt16LE(3, to: &data, at: 8)

        // Entry 0: Orientation (0x0112), SHORT (3), count 1, val 6
        writeUInt16LE(0x0112, to: &data, at: 10)
        writeUInt16LE(3, to: &data, at: 12)
        writeUInt32LE(1, to: &data, at: 14)
        writeUInt32LE(6, to: &data, at: 18)

        // Entry 1: JPEGInterchangeFormat (0x0201), LONG (4), count 1, val 1024
        writeUInt16LE(0x0201, to: &data, at: 22)
        writeUInt16LE(4, to: &data, at: 24)
        writeUInt32LE(1, to: &data, at: 26)
        writeUInt32LE(1024, to: &data, at: 30)

        // Entry 2: JPEGInterchangeFormatLength (0x0202), LONG (4), count 1, val jpeg.count
        writeUInt16LE(0x0202, to: &data, at: 34)
        writeUInt16LE(4, to: &data, at: 36)
        writeUInt32LE(1, to: &data, at: 38)
        writeUInt32LE(UInt32(jpeg.count), to: &data, at: 42)

        // Next IFD: 0
        writeUInt32LE(0, to: &data, at: 46)

        // Insert JPEG payload at 1024
        data.replaceSubrange(1024..<(1024 + jpeg.count), with: jpeg)
        try data.write(to: fileURL)
    }

    private func createSyntheticOutOfBoundsTIFF(at fileURL: URL, subIFDOffset: UInt32 = 150_000) throws {
        var data = Data(count: 256_000)
        let jpeg = makeValidJPEGData(width: 200, height: 100)
        let jpegOffset: UInt32 = 180_000

        // Header: "II", 42, IFD0 offset 8
        data[0] = 0x49
        data[1] = 0x49
        writeUInt16LE(42, to: &data, at: 2)
        writeUInt32LE(8, to: &data, at: 4)

        // IFD0 at 8: count = 1
        writeUInt16LE(1, to: &data, at: 8)

        // Entry 0: SubIFDs (0x014A), LONG (4), count 1, val subIFDOffset (150,000 > 131,072)
        writeUInt16LE(0x014A, to: &data, at: 10)
        writeUInt16LE(4, to: &data, at: 12)
        writeUInt32LE(1, to: &data, at: 14)
        writeUInt32LE(subIFDOffset, to: &data, at: 18)

        // Next IFD: 0
        writeUInt32LE(0, to: &data, at: 22)

        // SubIFD table at subIFDOffset (150,000): count = 3
        let sOff = Int(subIFDOffset)
        writeUInt16LE(3, to: &data, at: sOff)

        // Entry 0: Orientation (0x0112), SHORT (3), count 1, val 8
        writeUInt16LE(0x0112, to: &data, at: sOff + 2)
        writeUInt16LE(3, to: &data, at: sOff + 4)
        writeUInt32LE(1, to: &data, at: sOff + 6)
        writeUInt32LE(8, to: &data, at: sOff + 10)

        // Entry 1: JPEGInterchangeFormat (0x0201), LONG (4), count 1, val jpegOffset (180,000)
        writeUInt16LE(0x0201, to: &data, at: sOff + 14)
        writeUInt16LE(4, to: &data, at: sOff + 16)
        writeUInt32LE(1, to: &data, at: sOff + 18)
        writeUInt32LE(jpegOffset, to: &data, at: sOff + 22)

        // Entry 2: JPEGInterchangeFormatLength (0x0202), LONG (4), count 1, val jpeg.count
        writeUInt16LE(0x0202, to: &data, at: sOff + 26)
        writeUInt16LE(4, to: &data, at: sOff + 28)
        writeUInt32LE(1, to: &data, at: sOff + 30)
        writeUInt32LE(UInt32(jpeg.count), to: &data, at: sOff + 34)

        // Next IFD: 0
        writeUInt32LE(0, to: &data, at: sOff + 38)

        // Insert JPEG payload at jpegOffset (180,000)
        data.replaceSubrange(Int(jpegOffset)..<(Int(jpegOffset) + jpeg.count), with: jpeg)
        try data.write(to: fileURL)
    }

    @Test("In-memory TIFF parsing within 128 KB buffer parses tags with 0 extra reads")
    func inMemoryParsingWithin128KBBufferWithoutExtraReads() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tiffURL = tempDir.appendingPathComponent("in_ram_test.dng")
        try createSyntheticInRAMTIFF(at: tiffURL)

        do {
            let handle = try FileHandle(forReadingFrom: tiffURL)
            defer { try? handle.close() }

            let reader = try RAWPreviewExtractor.TIFFStreamReader(handle: handle, upfrontBufferSize: 131_072)
            let parseResult = try #require(RAWPreviewExtractor.parseTIFFHeader(reader: reader, fileSize: 65_536))

            #expect(parseResult.headerReadCount == 1)
            #expect(parseResult.orientation == .right)
            #expect(parseResult.candidates.count == 1)
            #expect(parseResult.candidates[0].offset == 1024)
        }

        // Verify end-to-end extraction and orientation
        let extraction = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: tiffURL, maxPixelSize: 1024))
        #expect(extraction.cgImage.height > extraction.cgImage.width)
    }

    @Test("Fallback behavior when SubIFD is located beyond 128 KB boundary issues targeted bounded read without streaming gap")
    func fallbackBehaviorWhenIFDTableLocatedBeyond128KBBoundary() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tiffURL = tempDir.appendingPathComponent("out_of_bounds_test.arw")
        try createSyntheticOutOfBoundsTIFF(at: tiffURL, subIFDOffset: 150_000)

        do {
            let handle = try FileHandle(forReadingFrom: tiffURL)
            defer { try? handle.close() }

            let reader = try RAWPreviewExtractor.TIFFStreamReader(handle: handle, upfrontBufferSize: 131_072)
            let parseResult = try #require(RAWPreviewExtractor.parseTIFFHeader(reader: reader, fileSize: 256_000))

            // Exactly 2 reads: 1 upfront 128 KB read + 1 targeted bounded read at 150,000 for the SubIFD table
            #expect(parseResult.headerReadCount == 2)
            #expect(parseResult.orientation == .left)
            #expect(parseResult.candidates.count == 1)
            #expect(parseResult.candidates[0].offset == 180_000)
        }

        // Verify end-to-end extraction succeeds and preserves portrait orientation
        let extraction = try #require(await RAWPreviewExtractor.extractEmbeddedPreview(from: tiffURL, maxPixelSize: 1024))
        #expect(extraction.cgImage.height > extraction.cgImage.width)
    }

    @Test("Real camera RAW TIFF header parsing executes at most 1–2 syscall round-trips")
    func realCameraTIFFHeaderParsingRoundTrips() throws {
        guard let dir = findRepoTestFilesDir() else { return }

        // 1. Sony .ARW: SubIFD is at ~138 KB (> 128 KB), triggering exactly 1 targeted read (2 reads total)
        let arwURL = dir.appendingPathComponent("5947067782.ARW")
        if FileManager.default.fileExists(atPath: arwURL.path) {
            let handle = try FileHandle(forReadingFrom: arwURL)
            defer { try? handle.close() }
            let reader = try RAWPreviewExtractor.TIFFStreamReader(handle: handle, upfrontBufferSize: 131_072)
            let result = try #require(RAWPreviewExtractor.parseTIFFHeader(reader: reader, fileSize: 75_137_024))
            #expect(result.headerReadCount == 2)
            #expect(result.orientation == .left) // Orientation 8
            #expect(result.candidates.contains { $0.offset == 143522 && $0.length == 461907 })
        }

        // 2. Nikon .NEF: SubIFD array at 484 points to ~273 KB, coalesced into a single targeted read (2 reads total)
        let nefURL = dir.appendingPathComponent("4674414196.NEF")
        if FileManager.default.fileExists(atPath: nefURL.path) {
            let handle = try FileHandle(forReadingFrom: nefURL)
            defer { try? handle.close() }
            let reader = try RAWPreviewExtractor.TIFFStreamReader(handle: handle, upfrontBufferSize: 131_072)
            let result = try #require(RAWPreviewExtractor.parseTIFFHeader(reader: reader, fileSize: 28_656_522))
            #expect(result.headerReadCount == 2)
            #expect(result.orientation == .up) // Orientation 1
            #expect(result.candidates.contains { $0.offset == 920064 && $0.length == 1307665 })
        }

        // 3. Olympus .ORF: All IFD0, ExifIFD, MakerNote, and CameraSettingsIFD reside in first 5 KB (1 read total)
        let orfURL = dir.appendingPathComponent("P9227357.ORF")
        if FileManager.default.fileExists(atPath: orfURL.path) {
            let handle = try FileHandle(forReadingFrom: orfURL)
            defer { try? handle.close() }
            let reader = try RAWPreviewExtractor.TIFFStreamReader(handle: handle, upfrontBufferSize: 131_072)
            let result = try #require(RAWPreviewExtractor.parseTIFFHeader(reader: reader, fileSize: 17_260_286))
            #expect(result.headerReadCount == 1) // In-RAM parsing with 0 additional syscalls
            #expect(result.orientation == .left) // Orientation 8
            #expect(result.candidates.contains { $0.offset == 52224 && $0.length == 982593 })
        }
    }
}
