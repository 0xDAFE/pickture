import CoreGraphics
import Foundation
import ImageIO

public struct RAWPreviewExtraction: Sendable {
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
public enum RAWPreviewExtractor {

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

        guard let headerData = try? handle.read(upToCount: 160), headerData.count >= 92 else {
            return nil
        }

        // Verify RAF magic: "FUJIFILMCCD-RAW"
        guard let magic = String(data: headerData.prefix(15), encoding: .ascii),
              magic.hasPrefix("FUJIFILMCCD-RAW") else {
            return nil
        }

        // JPEG offset (4 bytes big-endian) at 84 (0x54) and length at 88 (0x58)
        let offset = headerData.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 84, as: UInt32.self).bigEndian
        }
        let length = headerData.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 88, as: UInt32.self).bigEndian
        }

        guard offset > 0, length > 1024 else { return nil }

        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let jpegData = try handle.read(upToCount: Int(length)), jpegData.count >= 4 else {
                return nil
            }
            // Check SOI: 0xFF 0xD8
            guard jpegData[0] == 0xFF, jpegData[1] == 0xD8 else { return nil }

            if let cgImage = decodeJPEG(data: jpegData, maxPixelSize: maxPixelSize) {
                return RAWPreviewExtraction(cgImage: cgImage, jpegData: jpegData)
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

        // Read initial container chunk to locate PRVW box (typically in first 128KB - 256KB)
        let searchSize = 262_144
        guard let chunk = try? handle.read(upToCount: searchSize), chunk.count > 16 else {
            return nil
        }

        // Search for 'PRVW' fourcc: [0x50, 0x52, 0x56, 0x57]
        let prvwPattern = Data([0x50, 0x52, 0x56, 0x57])
        if let prvwIndex = chunk.range(of: prvwPattern)?.lowerBound, prvwIndex >= 4 {
            let boxStart = prvwIndex - 4
            let boxSize = chunk.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: boxStart, as: UInt32.self).bigEndian
            }
            if boxSize > 24 {
                let jpegOffset = UInt64(boxStart + 24)
                let jpegLength = Int(boxSize - 24)
                do {
                    try handle.seek(toOffset: jpegOffset)
                    if let jpegData = try handle.read(upToCount: jpegLength),
                       jpegData.count > 4,
                       jpegData[0] == 0xFF, jpegData[1] == 0xD8 {
                        if let cgImage = decodeJPEG(data: jpegData, maxPixelSize: maxPixelSize) {
                            return RAWPreviewExtraction(cgImage: cgImage, jpegData: jpegData)
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

        guard let header = try? handle.read(upToCount: 8), header.count == 8 else {
            return nil
        }

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
            ? header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
            : header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).bigEndian }

        guard ifd0Offset >= 8 else { return nil }

        // Candidates: (offset, length)
        var candidates: [(offset: UInt32, length: UInt32)] = []
        var containerOrientation: CGImagePropertyOrientation? = nil

        var toVisit: [UInt32] = [ifd0Offset]
        var visited = Set<UInt32>()
        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        while !toVisit.isEmpty && visited.count < 30 {
            let offset = toVisit.removeFirst()
            guard offset > 0, offset < fileSize, !visited.contains(offset) else { continue }
            visited.insert(offset)

            do {
                try handle.seek(toOffset: UInt64(offset))
                guard let countData = try handle.read(upToCount: 2), countData.count == 2 else { continue }
                let entryCount = Int(isLittleEndian
                    ? countData.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                    : countData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })

                guard entryCount > 0, entryCount < 1000 else { continue }

                let entriesByteCount = entryCount * 12
                guard let entriesData = try handle.read(upToCount: entriesByteCount),
                      entriesData.count == entriesByteCount else { continue }

                var currentJpegOffset: UInt32? = nil
                var currentJpegLength: UInt32? = nil

                for i in 0..<entryCount {
                    let entryStart = i * 12
                    let tag = isLittleEndian
                        ? entriesData.withUnsafeBytes { $0.load(fromByteOffset: entryStart, as: UInt16.self).littleEndian }
                        : entriesData.withUnsafeBytes { $0.load(fromByteOffset: entryStart, as: UInt16.self).bigEndian }
                    let count = isLittleEndian
                        ? entriesData.withUnsafeBytes { $0.load(fromByteOffset: entryStart + 4, as: UInt32.self).littleEndian }
                        : entriesData.withUnsafeBytes { $0.load(fromByteOffset: entryStart + 4, as: UInt32.self).bigEndian }
                    let val = isLittleEndian
                        ? entriesData.withUnsafeBytes { $0.load(fromByteOffset: entryStart + 8, as: UInt32.self).littleEndian }
                        : entriesData.withUnsafeBytes { $0.load(fromByteOffset: entryStart + 8, as: UInt32.self).bigEndian }

                    switch tag {
                    case 0x0112: // Orientation
                        if containerOrientation == nil, let ori = CGImagePropertyOrientation(rawValue: val) {
                            containerOrientation = ori
                        }
                    case 0x014A: // SubIFDs
                        if count == 1 {
                            toVisit.append(val)
                        } else if count > 1 && count < 20 {
                            let oldPos = try handle.offset()
                            try handle.seek(toOffset: UInt64(val))
                            if let subData = try handle.read(upToCount: Int(count * 4)), subData.count == Int(count * 4) {
                                for s in 0..<Int(count) {
                                    let subOff = isLittleEndian
                                        ? subData.withUnsafeBytes { $0.load(fromByteOffset: s * 4, as: UInt32.self).littleEndian }
                                        : subData.withUnsafeBytes { $0.load(fromByteOffset: s * 4, as: UInt32.self).bigEndian }
                                    toVisit.append(subOff)
                                }
                            }
                            try handle.seek(toOffset: oldPos)
                        }
                    case 0x8769: // ExifIFD
                        toVisit.append(val)
                    case 0x927C: // MakerNote
                        // Check Olympus MakerNote: "OLYMPUS\0"
                        let oldPos = try handle.offset()
                        try handle.seek(toOffset: UInt64(val))
                        if let mnHdr = try handle.read(upToCount: 16),
                           mnHdr.count >= 12,
                           let sig = String(data: mnHdr.prefix(8), encoding: .ascii),
                           sig.hasPrefix("OLYMPUS") {
                            // Olympus MakerNote IFD is at val + 12
                            let mnIFDOffset = val + 12
                            try handle.seek(toOffset: UInt64(mnIFDOffset))
                            if let mnCountData = try handle.read(upToCount: 2), mnCountData.count == 2 {
                                let mnCount = Int(isLittleEndian
                                    ? mnCountData.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                                    : mnCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
                                if let mnEntries = try handle.read(upToCount: mnCount * 12), mnEntries.count == mnCount * 12 {
                                    for m in 0..<mnCount {
                                        let mTag = isLittleEndian
                                            ? mnEntries.withUnsafeBytes { $0.load(fromByteOffset: m * 12, as: UInt16.self).littleEndian }
                                            : mnEntries.withUnsafeBytes { $0.load(fromByteOffset: m * 12, as: UInt16.self).bigEndian }
                                        let mVal = isLittleEndian
                                            ? mnEntries.withUnsafeBytes { $0.load(fromByteOffset: m * 12 + 8, as: UInt32.self).littleEndian }
                                            : mnEntries.withUnsafeBytes { $0.load(fromByteOffset: m * 12 + 8, as: UInt32.self).bigEndian }
                                        if mTag == 0x2020 { // CameraSettingsIFD
                                            // Tag 0x2020 offset is relative to val (MakerNote start)
                                            let csOffset = val + mVal
                                            try handle.seek(toOffset: UInt64(csOffset))
                                            if let csCountData = try handle.read(upToCount: 2), csCountData.count == 2 {
                                                let csCount = Int(isLittleEndian
                                                    ? csCountData.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                                                    : csCountData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
                                                if let csEntries = try handle.read(upToCount: csCount * 12), csEntries.count == csCount * 12 {
                                                    var orfJpgStart: UInt32? = nil
                                                    var orfJpgLen: UInt32? = nil
                                                    for c in 0..<csCount {
                                                        let cTag = isLittleEndian
                                                            ? csEntries.withUnsafeBytes { $0.load(fromByteOffset: c * 12, as: UInt16.self).littleEndian }
                                                            : csEntries.withUnsafeBytes { $0.load(fromByteOffset: c * 12, as: UInt16.self).bigEndian }
                                                        let cVal = isLittleEndian
                                                            ? csEntries.withUnsafeBytes { $0.load(fromByteOffset: c * 12 + 8, as: UInt32.self).littleEndian }
                                                            : csEntries.withUnsafeBytes { $0.load(fromByteOffset: c * 12 + 8, as: UInt32.self).bigEndian }
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
                        try handle.seek(toOffset: oldPos)
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
                if let nextData = try handle.read(upToCount: 4), nextData.count == 4 {
                    let nextIFD = isLittleEndian
                        ? nextData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                        : nextData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    if nextIFD > 0 {
                        toVisit.append(nextIFD)
                    }
                }
            } catch {
                continue
            }
        }

        // Sort candidates by byte length descending (largest high-resolution preview first)
        let sortedCandidates = candidates.sorted { $0.length > $1.length }
        for cand in sortedCandidates {
            guard UInt64(cand.offset + cand.length) <= fileSize else { continue }
            do {
                try handle.seek(toOffset: UInt64(cand.offset))
                guard let data = try handle.read(upToCount: Int(cand.length)), data.count >= 4 else { continue }
                guard data[0] == 0xFF && data[1] == 0xD8 else { continue }

                if let cgImage = decodeJPEG(data: data, maxPixelSize: maxPixelSize, fallbackOrientation: containerOrientation) {
                    return RAWPreviewExtraction(cgImage: cgImage, jpegData: data)
                }
            } catch {
                continue
            }
        }

        return nil
    }

    // MARK: - Helpers

    private static func decodeJPEG(
        data: Data,
        maxPixelSize: Int,
        fallbackOrientation: CGImagePropertyOrientation? = nil
    ) -> CGImage? {
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

        if !hasOwnOrientation, let fallbackOrientation, fallbackOrientation != .up {
            return applyOrientation(cgImage: thumbnail, orientation: fallbackOrientation)
        }
        return thumbnail
    }

    private static func applyOrientation(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        let isRotated = orientation == .left || orientation == .right || orientation == .leftMirrored || orientation == .rightMirrored
        let targetWidth = isRotated ? height : width
        let targetHeight = isRotated ? width : height

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }

        switch orientation {
        case .up:
            break
        case .upMirrored:
            context.translateBy(x: CGFloat(targetWidth), y: 0)
            context.scaleBy(x: -1, y: 1)
        case .down:
            context.translateBy(x: CGFloat(targetWidth), y: CGFloat(targetHeight))
            context.rotate(by: .pi)
        case .downMirrored:
            context.translateBy(x: 0, y: CGFloat(targetHeight))
            context.scaleBy(x: 1, y: -1)
        case .leftMirrored:
            context.rotate(by: .pi / 2)
            context.scaleBy(x: 1, y: -1)
        case .right:
            context.translateBy(x: CGFloat(targetWidth), y: 0)
            context.rotate(by: .pi / 2)
        case .rightMirrored:
            context.translateBy(x: CGFloat(targetWidth), y: CGFloat(targetHeight))
            context.rotate(by: .pi / 2)
            context.scaleBy(x: 1, y: -1)
        case .left:
            context.translateBy(x: 0, y: CGFloat(targetHeight))
            context.rotate(by: -.pi / 2)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? cgImage
    }
}
