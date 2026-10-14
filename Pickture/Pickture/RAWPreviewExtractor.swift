import CoreGraphics
import Foundation
import ImageIO

public nonisolated struct RAWPreviewExtraction: Sendable {
    public let cgImage: CGImage
    public let jpegData: Data

    public init(cgImage: CGImage, jpegData: Data) {
        self.cgImage = cgImage
        self.jpegData = jpegData
    }
}

/// Zero-transcode, targeted byte-range preview extractor for RAW container formats
/// (Sony .ARW, Nikon .NEF, Canon .CR3, Fujifilm .RAF, Olympus .ORF, Adobe .DNG).
///
/// Instead of streaming entire 40–85 MB RAW containers over the network to demosaic,
/// this parser reads container headers, locates embedded JPEG preview stream byte ranges,
/// reads only the JPEG slice via `FileHandle.seek`, and decodes directly via ImageIO.
public nonisolated enum RAWPreviewExtractor {
    public static let tiffInitialBufferSize = 131_072 // 128 KB upfront buffer
    public static let cr3InitialBufferSize = 131_072  // 128 KB upfront buffer
    public static let rafInitialBufferSize = 160      // 160 bytes upfront buffer

    public static func extractEmbeddedPreview(from url: URL, maxPixelSize: Int = 4096) async -> RAWPreviewExtraction? {
        guard !Task.isCancelled else { return nil }
        let ext = url.pathExtension.lowercased()

        if ext == "raf" {
            if let result = extractRAF(url: url, maxPixelSize: maxPixelSize) {
                return result
            }
        } else if ext == "cr3" {
            if let result = extractCR3(url: url, maxPixelSize: maxPixelSize) {
                return result
            }
        } else {
            // TIFF-based (ARW, NEF, DNG, CR2, ORF, PEF, RW2, etc.)
            if let result = extractTIFFBased(url: url, maxPixelSize: maxPixelSize) {
                return result
            }
        }

        // Generic fallback probes if extension matching was ambiguous
        if ext != "raf", let result = extractRAF(url: url, maxPixelSize: maxPixelSize) {
            return result
        }
        if ext != "cr3", let result = extractCR3(url: url, maxPixelSize: maxPixelSize) {
            return result
        }
        return extractTIFFBased(url: url, maxPixelSize: maxPixelSize)
    }

    // MARK: - Fujifilm RAF

    private static func extractRAF(url: URL, maxPixelSize: Int) -> RAWPreviewExtraction? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let headerData = try? handle.read(upToCount: rafInitialBufferSize), headerData.count >= 92 else {
            return nil
        }

        // Verify RAF magic: "FUJIFILMCCD-RAW"
        guard let magic = String(data: headerData.prefix(15), encoding: .ascii),
              magic.hasPrefix("FUJIFILMCCD-RAW") else {
            return nil
        }

        // JPEG offset (4 bytes big-endian) at 84 (0x54) and length at 88 (0x58)
        let offset = headerData.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 84, as: UInt32.self).bigEndian
        }
        let length = headerData.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 88, as: UInt32.self).bigEndian
        }

        guard offset > 0, length > 1024 else { return nil }

        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let jpegData = try handle.read(upToCount: Int(length)), jpegData.count >= 4 else {
                return nil
            }
            // Check SOI: 0xFF 0xD8
            guard jpegData[0] == 0xFF, jpegData[1] == 0xD8 else { return nil }

            let containerOrientation = PreviewLoader.extractContainerOrientation(from: nil, prefixData: headerData, url: url)
            if let result = decodeJPEG(data: jpegData, maxPixelSize: maxPixelSize, fallbackOrientation: containerOrientation) {
                return RAWPreviewExtraction(cgImage: result.cgImage, jpegData: result.jpegData)
            }
        } catch {
            return nil
        }

        return nil
    }

    // MARK: - Canon CR3 (ISOBMFF)

    private static func extractCR3(url: URL, maxPixelSize: Int) -> RAWPreviewExtraction? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Read initial container chunk to locate PRVW box (typically in first 96KB - 128KB)
        let searchSize = cr3InitialBufferSize
        guard let chunk = try? handle.read(upToCount: searchSize), chunk.count > 16 else {
            return nil
        }

        // Search for 'PRVW' fourcc: [0x50, 0x52, 0x56, 0x57]
        let prvwPattern = Data([0x50, 0x52, 0x56, 0x57])
        if let prvwIndex = chunk.range(of: prvwPattern)?.lowerBound, prvwIndex >= 4 {
            let boxStart = prvwIndex - 4
            let boxSize = chunk.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: boxStart, as: UInt32.self).bigEndian
            }
            if boxSize > 24 {
                let jpegOffset = UInt64(boxStart + 24)
                let jpegLength = Int(boxSize - 24)
                do {
                    try handle.seek(toOffset: jpegOffset)
                    if let jpegData = try handle.read(upToCount: jpegLength),
                       jpegData.count > 4,
                       jpegData[0] == 0xFF, jpegData[1] == 0xD8 {
                        var containerOrientation: CGImagePropertyOrientation? = nil
                        let cmt1Pattern = Data("CMT1".utf8)
                        if let cmt1Index = chunk.range(of: cmt1Pattern)?.upperBound, cmt1Index + 12 <= chunk.count {
                            let tiffSlice = chunk.subdata(in: cmt1Index..<min(chunk.count, cmt1Index + 4096))
                            containerOrientation = PreviewLoader.extractTIFFOrientation(from: tiffSlice)
                        }
                        if containerOrientation == nil {
                            containerOrientation = PreviewLoader.extractContainerOrientation(from: nil, url: url)
                        }
                        if let result = decodeJPEG(data: jpegData, maxPixelSize: maxPixelSize, fallbackOrientation: containerOrientation) {
                            return RAWPreviewExtraction(cgImage: result.cgImage, jpegData: result.jpegData)
                        }
                    }
                } catch { }
            }
        }

        return nil
    }

    // MARK: - TIFF-Based (ARW, NEF, DNG, ORF, CR2, RW2)

    private static func extractTIFFBased(url: URL, maxPixelSize: Int) -> RAWPreviewExtraction? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let reader = try? TIFFStreamReader(handle: handle, upfrontBufferSize: tiffInitialBufferSize) else {
            return nil
        }
        guard reader.initialBuffer.count >= 8 else { return nil }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
            ?? (try? handle.seekToEnd())
            ?? 0

        guard let parseResult = parseTIFFHeader(reader: reader, fileSize: fileSize) else {
            return nil
        }

        // Sort candidates by byte length descending (largest high-resolution preview first)
        let sortedCandidates = parseResult.candidates.sorted { $0.length > $1.length }
        for cand in sortedCandidates {
            guard UInt64(cand.offset + cand.length) <= fileSize else { continue }
            guard let data = reader.readPayload(at: UInt64(cand.offset), length: Int(cand.length)),
                  data.count >= 4 else { continue }
            guard data[0] == 0xFF && data[1] == 0xD8 else { continue }

            if let result = decodeJPEG(data: data, maxPixelSize: maxPixelSize, fallbackOrientation: parseResult.orientation) {
                return RAWPreviewExtraction(cgImage: result.cgImage, jpegData: result.jpegData)
            }
        }

        return nil
    }

    internal static func parseTIFFHeader(
        reader: TIFFStreamReader,
        fileSize: UInt64
    ) -> TIFFHeaderParseResult? {
        guard reader.initialBuffer.count >= 8 else { return nil }

        let header = reader.initialBuffer.prefix(8)
        let isLittleEndian: Bool
        if header[0] == 0x49 && header[1] == 0x49 {
            isLittleEndian = true
        } else if header[0] == 0x4D && header[1] == 0x4D {
            isLittleEndian = false
        } else {
            return nil
        }

        // First IFD offset
        let ifd0Offset = isLittleEndian
            ? header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
            : header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian }

        guard ifd0Offset >= 8 else { return nil }

        var candidates: [(offset: UInt32, length: UInt32)] = []
        var containerOrientation: CGImagePropertyOrientation? = nil

        var toVisit: [UInt32] = [ifd0Offset]
        var visited = Set<UInt32>()

        while !toVisit.isEmpty && visited.count < 30 {
            toVisit.sort()
            let offset = toVisit.removeFirst()
            guard offset > 0, offset < fileSize, !visited.contains(offset) else { continue }
            visited.insert(offset)

            guard let countData = reader.readBytes(at: UInt64(offset), length: 2), countData.count == 2 else { continue }
            let entryCount = Int(isLittleEndian
                ? countData.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
                : countData.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian })

            guard entryCount > 0, entryCount < 1000 else { continue }

            let entriesByteCount = entryCount * 12
            guard let entriesData = reader.readBytes(at: UInt64(offset + 2), length: entriesByteCount),
                  entriesData.count == entriesByteCount else { continue }

            var currentJpegOffset: UInt32? = nil
            var currentJpegLength: UInt32? = nil

            for i in 0..<entryCount {
                let entryStart = i * 12
                let tag = isLittleEndian
                    ? entriesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entryStart, as: UInt16.self).littleEndian }
                    : entriesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entryStart, as: UInt16.self).bigEndian }
                let count = isLittleEndian
                    ? entriesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entryStart + 4, as: UInt32.self).littleEndian }
                    : entriesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entryStart + 4, as: UInt32.self).bigEndian }
                let val = isLittleEndian
                    ? entriesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entryStart + 8, as: UInt32.self).littleEndian }
                    : entriesData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entryStart + 8, as: UInt32.self).bigEndian }

                switch tag {
                case 0x0112: // Orientation
                    if containerOrientation == nil, let ori = CGImagePropertyOrientation(rawValue: val) {
                        containerOrientation = ori
                    }
                case 0x014A: // SubIFDs
                    if count == 1 {
                        toVisit.append(val)
                    } else if count > 1 && count < 20 {
                        if let subData = reader.readBytes(at: UInt64(val), length: Int(count * 4)),
                           subData.count == Int(count * 4) {
                            for s in 0..<Int(count) {
                                let subOff = isLittleEndian
                                    ? subData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: s * 4, as: UInt32.self).littleEndian }
                                    : subData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: s * 4, as: UInt32.self).bigEndian }
                                if subOff > 0 {
                                    toVisit.append(subOff)
                                }
                            }
                        }
                    }
                case 0x8769: // ExifIFD
                    toVisit.append(val)
                case 0x927C: // MakerNote
                    // Check Olympus MakerNote: "OLYMPUS\0"
                    if let mnHdr = reader.readBytes(at: UInt64(val), length: 16),
                       mnHdr.count >= 12,
                       let sig = String(data: mnHdr.prefix(8), encoding: .ascii),
                       sig.hasPrefix("OLYMPUS") {
                        // Olympus MakerNote IFD is at val + 12
                        let mnIFDOffset = val + 12
                        if let mnCountData = reader.readBytes(at: UInt64(mnIFDOffset), length: 2), mnCountData.count == 2 {
                            let mnCount = Int(isLittleEndian
                                ? mnCountData.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
                                : mnCountData.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian })
                            if mnCount > 0 && mnCount < 1000,
                               let mnEntries = reader.readBytes(at: UInt64(mnIFDOffset + 2), length: mnCount * 12),
                               mnEntries.count == mnCount * 12 {
                                for m in 0..<mnCount {
                                    let mTag = isLittleEndian
                                        ? mnEntries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: m * 12, as: UInt16.self).littleEndian }
                                        : mnEntries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: m * 12, as: UInt16.self).bigEndian }
                                    let mVal = isLittleEndian
                                        ? mnEntries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: m * 12 + 8, as: UInt32.self).littleEndian }
                                        : mnEntries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: m * 12 + 8, as: UInt32.self).bigEndian }
                                    if mTag == 0x2020 { // CameraSettingsIFD
                                        // Tag 0x2020 offset is relative to val (MakerNote start)
                                        let csOffset = val + mVal
                                        if let csCountData = reader.readBytes(at: UInt64(csOffset), length: 2), csCountData.count == 2 {
                                            let csCount = Int(isLittleEndian
                                                ? csCountData.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
                                                : csCountData.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian })
                                            if csCount > 0 && csCount < 1000,
                                               let csEntries = reader.readBytes(at: UInt64(csOffset + 2), length: csCount * 12),
                                               csEntries.count == csCount * 12 {
                                                var orfJpgStart: UInt32? = nil
                                                var orfJpgLen: UInt32? = nil
                                                for c in 0..<csCount {
                                                    let cTag = isLittleEndian
                                                        ? csEntries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: c * 12, as: UInt16.self).littleEndian }
                                                        : csEntries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: c * 12, as: UInt16.self).bigEndian }
                                                    let cVal = isLittleEndian
                                                        ? csEntries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: c * 12 + 8, as: UInt32.self).littleEndian }
                                                        : csEntries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: c * 12 + 8, as: UInt32.self).bigEndian }
                                                    if cTag == 0x0101 { // PreviewImageStart
                                                        orfJpgStart = val + cVal
                                                    } else if cTag == 0x0102 { // PreviewImageLength
                                                        orfJpgLen = cVal
                                                    }
                                                }
                                                if let s = orfJpgStart, let l = orfJpgLen, l > 1024 {
                                                    candidates.append((offset: s, length: l))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                case 0x0201: // JPEGInterchangeFormat
                    currentJpegOffset = val
                case 0x0202: // JPEGInterchangeFormatLength
                    currentJpegLength = val
                default:
                    break
                }
            }

            if let jOff = currentJpegOffset, let jLen = currentJpegLength, jLen > 1024 {
                candidates.append((offset: jOff, length: jLen))
            }

            // Next IFD in main chain
            let nextIFDOffset = UInt64(offset + 2 + UInt32(entriesByteCount))
            if let nextData = reader.readBytes(at: nextIFDOffset, length: 4), nextData.count == 4 {
                let nextIFD = isLittleEndian
                    ? nextData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                    : nextData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                if nextIFD > 0 {
                    toVisit.append(nextIFD)
                }
            }
        }

        return TIFFHeaderParseResult(
            candidates: candidates,
            orientation: containerOrientation,
            headerReadCount: reader.readCount
        )
    }

    // MARK: - TIFF Stream Reader & Types

    nonisolated internal struct TIFFHeaderParseResult: Sendable {
        public let candidates: [(offset: UInt32, length: UInt32)]
        public let orientation: CGImagePropertyOrientation?
        public let headerReadCount: Int

        public init(
            candidates: [(offset: UInt32, length: UInt32)],
            orientation: CGImagePropertyOrientation?,
            headerReadCount: Int
        ) {
            self.candidates = candidates
            self.orientation = orientation
            self.headerReadCount = headerReadCount
        }
    }

    nonisolated internal final class TIFFStreamReader {
        let handle: FileHandle
        let initialBuffer: Data
        private var targetedBuffer: (offset: UInt64, data: Data)? = nil
        private(set) var readCount: Int

        init(handle: FileHandle, upfrontBufferSize: Int = 131_072) throws {
            self.handle = handle
            let buffer = try handle.read(upToCount: upfrontBufferSize) ?? Data()
            self.initialBuffer = buffer
            self.readCount = buffer.isEmpty ? 0 : 1
        }

        init(handle: FileHandle, initialBuffer: Data) {
            self.handle = handle
            self.initialBuffer = initialBuffer
            self.readCount = initialBuffer.isEmpty ? 0 : 1
        }

        /// Reads `length` bytes starting at `offset`.
        /// 1. Slices in-memory `initialBuffer` if `offset + length <= initialBuffer.count` (0 syscalls).
        /// 2. Reuses `targetedBuffer` if fully contained in previous targeted read (0 syscalls).
        /// 3. Otherwise executes a single targeted range-read of bounded size (1 syscall).
        func readBytes(at offset: UInt64, length: Int) -> Data? {
            guard length > 0, offset <= UInt64.max - UInt64(length) else { return Data() }
            let endOffset = offset + UInt64(length)

            // 1. In-RAM upfront buffer
            if endOffset <= UInt64(initialBuffer.count) {
                return initialBuffer.subdata(in: Int(offset)..<Int(endOffset))
            }

            // 2. Cached targeted bounded range-read
            if let targeted = targetedBuffer,
               offset >= targeted.offset,
               endOffset <= targeted.offset + UInt64(targeted.data.count) {
                let start = Int(offset - targeted.offset)
                return targeted.data.subdata(in: start..<start + length)
            }

            // 3. Out-of-bounds targeted bounded range-read
            do {
                try handle.seek(toOffset: offset)
                let fetchSize = max(length, 4096)
                guard let chunk = try handle.read(upToCount: fetchSize), chunk.count >= length else {
                    return nil
                }
                readCount += 1
                targetedBuffer = (offset: offset, data: chunk)
                return chunk.subdata(in: 0..<length)
            } catch {
                return nil
            }
        }

        /// Reads the JPEG preview payload at `offset` for `length` bytes.
        /// If contained within `initialBuffer`, extracts in-RAM with 0 syscalls.
        /// Otherwise performs a single targeted range-read for the exact payload.
        func readPayload(at offset: UInt64, length: Int) -> Data? {
            guard length > 0, offset <= UInt64.max - UInt64(length) else { return nil }
            let endOffset = offset + UInt64(length)
            if endOffset <= UInt64(initialBuffer.count) {
                return initialBuffer.subdata(in: Int(offset)..<Int(endOffset))
            }
            do {
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: length)
            } catch {
                return nil
            }
        }
    }

    // MARK: - Helpers

    private static func decodeJPEG(
        data: Data,
        maxPixelSize: Int,
        fallbackOrientation: CGImagePropertyOrientation? = nil
    ) -> (cgImage: CGImage, jpegData: Data)? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        // Check if data had its own orientation
        var hasOwnOrientation = false
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let num = props[kCGImagePropertyOrientation] as? NSNumber,
           let ori = CGImagePropertyOrientation(rawValue: num.uint32Value),
           ori != .up {
            hasOwnOrientation = true
        }

        let finalImage: CGImage
        if !hasOwnOrientation, let fallbackOrientation, fallbackOrientation != .up {
            finalImage = PreviewLoader.applyOrientation(cgImage: thumbnail, orientation: fallbackOrientation)
        } else {
            finalImage = thumbnail
        }

        let outJPEGData: Data
        if !hasOwnOrientation, let fallbackOrientation, fallbackOrientation != .up {
            outJPEGData = PreviewLoader.encodeToJPEG(cgImage: finalImage) ?? data
        } else if maxPixelSize <= 1024 && data.count > 100_000 {
            outJPEGData = PreviewLoader.encodeToJPEG(cgImage: finalImage) ?? data
        } else {
            outJPEGData = data
        }

        return (cgImage: finalImage, jpegData: outJPEGData)
    }
}
