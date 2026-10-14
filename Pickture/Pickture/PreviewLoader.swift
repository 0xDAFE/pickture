import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PreviewExtractionStrategy: String, Sendable {
    case embeddedPreview
    case fullDecodeFallback
    case videoFrameGenerator
}

nonisolated struct PreviewExtractionResult: Sendable {
    let image: CGImage?
    let jpegData: Data
    let strategy: PreviewExtractionStrategy

    init(image: CGImage? = nil, jpegData: Data, strategy: PreviewExtractionStrategy) {
        self.image = image
        self.jpegData = jpegData
        self.strategy = strategy
    }
}

actor HeavyDecodeLimiter {
    static let shared = HeavyDecodeLimiter(maxConcurrent: 2)

    private(set) var maxConcurrent: Int
    private var activeCount: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }

    func setMaxConcurrent(_ newLimit: Int) {
        self.maxConcurrent = max(1, newLimit)
        while activeCount < maxConcurrent && !waiters.isEmpty {
            activeCount += 1
            let next = waiters.removeFirst()
            next.continuation.resume()
        }
    }

    var currentActiveCount: Int {
        activeCount
    }

    var currentPermits: Int {
        maxConcurrent
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    func acquire() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id: id)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume()
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }
}

nonisolated enum PreviewLoader {

    static func extractThumbnail(
        for item: MediaItem,
        previewSource: PreviewSource,
        maxPixelSize: Int = 360
    ) async -> PreviewExtractionResult? {
        guard !Task.isCancelled else { return nil }
        switch item.kind {
        case .photo:
            let file = item.preferredFile(for: previewSource)
            if let result = await extractImageThumbnailAsync(from: file.url, maxPixelSize: maxPixelSize) {
                return result
            }
            // If preferred file fails in a MediaPair, try the alternate paired MediaFile
            if let pair = item.mediaPair {
                let fallbackURL = (file.id == pair.rawFile.id) ? pair.rasterFile.url : pair.rawFile.url
                return await extractImageThumbnailAsync(from: fallbackURL, maxPixelSize: maxPixelSize)
            }
            return nil

        case .video:
            return await extractVideoThumbnail(from: item.primaryFile.url, maxPixelSize: maxPixelSize)
        }
    }

    private static func extractEmbeddedPreview(
        from source: CGImageSource?,
        url: URL,
        isRaw: Bool,
        maxPixelSize: Int
    ) -> PreviewExtractionResult? {
        if isRaw {
            if let headerJPEG = extractEmbeddedJPEGFromHeaderPrefix(containerSource: source, at: url, maxPixelSize: maxPixelSize) {
                let decoded = decodeCGImage(from: headerJPEG)
                return PreviewExtractionResult(image: decoded, jpegData: headerJPEG, strategy: .embeddedPreview)
            }
        }
        guard let source, CGImageSourceGetCount(source) > 0 else { return nil }

        let sizedEmbeddedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let embeddedCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, sizedEmbeddedOptions as CFDictionary) {
            let scaled = downsampleIfNeeded(cgImage: embeddedCGImage, maxPixelSize: maxPixelSize)
            if let jpegData = encodeToJPEG(cgImage: scaled) {
                return PreviewExtractionResult(image: scaled, jpegData: jpegData, strategy: .embeddedPreview)
            }
        }

        let unsizedEmbeddedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let embeddedCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, unsizedEmbeddedOptions as CFDictionary) {
            let scaled = downsampleIfNeeded(cgImage: embeddedCGImage, maxPixelSize: maxPixelSize)
            if let jpegData = encodeToJPEG(cgImage: scaled) {
                return PreviewExtractionResult(image: scaled, jpegData: jpegData, strategy: .embeddedPreview)
            }
        }

        return nil
    }

    static func extractImageThumbnail(from url: URL, maxPixelSize: Int = 360) -> PreviewExtractionResult? {
        let isRaw = MediaFormatKind.classify(fileExtension: url.pathExtension) == .raw
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)

        if let embedded = extractEmbeddedPreview(from: source, url: url, isRaw: isRaw, maxPixelSize: maxPixelSize) {
            return embedded
        }

        if let fallback = extractFullDecodeFallback(from: url, isRaw: isRaw, maxPixelSize: maxPixelSize) {
            return fallback
        }

        return nil
    }

    static func extractImageThumbnailAsync(from url: URL, maxPixelSize: Int = 360) async -> PreviewExtractionResult? {
        guard !Task.isCancelled else { return nil }
        let isRaw = MediaFormatKind.classify(fileExtension: url.pathExtension) == .raw
        if isRaw {
            if let rawExtraction = await RAWPreviewExtractor.extractEmbeddedPreview(from: url, maxPixelSize: maxPixelSize) {
                return PreviewExtractionResult(
                    image: rawExtraction.cgImage,
                    jpegData: rawExtraction.jpegData,
                    strategy: .embeddedPreview
                )
            }
        }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)

        if let embedded = extractEmbeddedPreview(from: source, url: url, isRaw: isRaw, maxPixelSize: maxPixelSize) {
            return embedded
        }

        guard !Task.isCancelled else { return nil }

        return await HeavyDecodeLimiter.shared.withPermit {
            guard !Task.isCancelled else { return nil }
            return extractFullDecodeFallback(from: url, isRaw: isRaw, maxPixelSize: maxPixelSize)
        }
    }

    private static func extractFullDecodeFallback(
        from url: URL,
        isRaw: Bool,
        maxPixelSize: Int
    ) -> PreviewExtractionResult? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            if isRaw, let tiffFallbackJPEG = extractTIFFHintFullDecode(from: url, maxPixelSize: maxPixelSize) {
                let decoded = decodeCGImage(from: tiffFallbackJPEG)
                return PreviewExtractionResult(image: decoded, jpegData: tiffFallbackJPEG, strategy: .fullDecodeFallback)
            }
            return nil
        }

        let fallbackOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let fallbackCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, fallbackOptions as CFDictionary),
           let jpegData = encodeToJPEG(cgImage: fallbackCGImage) {
            return PreviewExtractionResult(image: fallbackCGImage, jpegData: jpegData, strategy: .fullDecodeFallback)
        }

        if let fullCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let containerOrientation = extractContainerOrientation(from: source, url: url)
            if let jpegData = orientAndEncodeJPEG(
                cgImage: fullCGImage,
                hasOwnOrientation: false,
                containerOrientation: containerOrientation,
                maxPixelSize: maxPixelSize
            ) {
                let decoded = decodeCGImage(from: jpegData)
                return PreviewExtractionResult(image: decoded, jpegData: jpegData, strategy: .fullDecodeFallback)
            }
        }

        if isRaw, let tiffFallbackJPEG = extractTIFFHintFullDecode(from: url, maxPixelSize: maxPixelSize) {
            let decoded = decodeCGImage(from: tiffFallbackJPEG)
            return PreviewExtractionResult(image: decoded, jpegData: tiffFallbackJPEG, strategy: .fullDecodeFallback)
        }

        return nil
    }


    private static func extractTIFFHintFullDecode(from url: URL, maxPixelSize: Int) -> Data? {
        let tiffHintOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier
        ]
        guard let tiffSource = CGImageSourceCreateWithURL(url as CFURL, tiffHintOptions as CFDictionary),
              CGImageSourceGetCount(tiffSource) > 0 else {
            return nil
        }
        let fallbackOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(tiffSource, 0, fallbackOptions as CFDictionary),
           let jpegData = encodeToJPEG(cgImage: cgImage) {
            return jpegData
        }
        if let fullCGImage = CGImageSourceCreateImageAtIndex(tiffSource, 0, nil) {
            let containerOrientation = extractContainerOrientation(from: tiffSource, url: url)
            return orientAndEncodeJPEG(
                cgImage: fullCGImage,
                hasOwnOrientation: false,
                containerOrientation: containerOrientation,
                maxPixelSize: maxPixelSize
            )
        }
        return nil
    }

    private static func extractEmbeddedJPEGFromHeaderPrefix(
        containerSource: CGImageSource? = nil,
        at url: URL,
        initialHeaderBytes: Int = 1_048_576,
        maxHeaderBytes: Int = 3_670_016,
        maxPixelSize: Int
    ) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard var prefixData = try? handle.read(upToCount: initialHeaderBytes), prefixData.count > 4 else {
            return nil
        }

        let soi = Data([0xFF, 0xD8, 0xFF])
        let eoi = Data([0xFF, 0xD9])

        // Adaptively scale prefix buffer up to 3.5 MB when an SOI marker indicates a larger embedded preview
        if prefixData.range(of: soi) != nil && prefixData.count < maxHeaderBytes {
            var needsExpansion = false
            var searchStart = prefixData.startIndex
            while let soiRange = prefixData.range(of: soi, in: searchStart..<prefixData.endIndex) {
                if prefixData.range(of: eoi, in: soiRange.upperBound..<prefixData.endIndex) == nil {
                    needsExpansion = true
                    break
                }
                searchStart = soiRange.upperBound
            }

            if needsExpansion {
                let remainingBytes = maxHeaderBytes - prefixData.count
                if let moreData = try? handle.read(upToCount: remainingBytes), !moreData.isEmpty {
                    prefixData.append(moreData)
                }
            }
        }

        // 1. Direct in-memory container probe (e.g. IFD0/SubIFD preview in DNG/TIFF header)
        let containerOrientation = extractContainerOrientation(from: containerSource, prefixData: prefixData, url: url)

        if let directSource = CGImageSourceCreateWithData(prefixData as CFData, nil),
           CGImageSourceGetCount(directSource) > 0 {
            let directHasOwnOrientation: Bool = {
                if let props = CGImageSourceCopyPropertiesAtIndex(directSource, 0, nil) as? [CFString: Any],
                   let num = props[kCGImagePropertyOrientation] as? NSNumber,
                   let ori = CGImagePropertyOrientation(rawValue: num.uint32Value) {
                    return ori != .up
                }
                return false
            }()
            let embeddedOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            if let embeddedCGImage = CGImageSourceCreateThumbnailAtIndex(directSource, 0, embeddedOptions as CFDictionary) {
                if let jpeg = orientAndEncodeJPEG(
                    cgImage: embeddedCGImage,
                    hasOwnOrientation: directHasOwnOrientation,
                    containerOrientation: containerOrientation,
                    maxPixelSize: maxPixelSize
                ) {
                    return jpeg
                }
            }

            let unsizedOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let embeddedCGImage = CGImageSourceCreateThumbnailAtIndex(directSource, 0, unsizedOptions as CFDictionary) {
                if let jpeg = orientAndEncodeJPEG(
                    cgImage: embeddedCGImage,
                    hasOwnOrientation: directHasOwnOrientation,
                    containerOrientation: containerOrientation,
                    maxPixelSize: maxPixelSize
                ) {
                    return jpeg
                }
            }
        }

        // 2. Scan for embedded JPEG SOI streams [0xFF, 0xD8, 0xFF]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        var searchStart = prefixData.startIndex
        var attempts = 0
        var bestImage: CGImage?
        var bestHasOwnOrientation = false

        while attempts < 4, let startRange = prefixData.range(of: soi, in: searchStart..<prefixData.endIndex) {
            attempts += 1
            let slice = prefixData.subdata(in: startRange.lowerBound..<prefixData.endIndex)
            if let source = CGImageSourceCreateWithData(slice as CFData, nil),
               let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let sliceHasOwnOrientation: Bool = {
                    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let num = props[kCGImagePropertyOrientation] as? NSNumber,
                       let ori = CGImagePropertyOrientation(rawValue: num.uint32Value) {
                        return ori != .up
                    }
                    return false
                }()
                if let currentBest = bestImage {
                    if cgImage.width * cgImage.height > currentBest.width * currentBest.height {
                        bestImage = cgImage
                        bestHasOwnOrientation = sliceHasOwnOrientation
                    }
                } else {
                    bestImage = cgImage
                    bestHasOwnOrientation = sliceHasOwnOrientation
                }
            }
            searchStart = startRange.upperBound
        }

        guard let bestImage else {
            return nil
        }
        return orientAndEncodeJPEG(
            cgImage: bestImage,
            hasOwnOrientation: bestHasOwnOrientation,
            containerOrientation: containerOrientation,
            maxPixelSize: maxPixelSize
        )
    }

    private static func orientAndEncodeJPEG(
        cgImage: CGImage,
        hasOwnOrientation: Bool,
        containerOrientation: CGImagePropertyOrientation?,
        maxPixelSize: Int
    ) -> Data? {
        let scaled = downsampleIfNeeded(cgImage: cgImage, maxPixelSize: maxPixelSize)
        var oriented = scaled
        if !hasOwnOrientation, let containerOrientation, containerOrientation != .up {
            oriented = applyOrientation(cgImage: scaled, orientation: containerOrientation)
        }
        return encodeToJPEG(cgImage: oriented)
    }

    private static func downsampleIfNeeded(cgImage: CGImage, maxPixelSize: Int) -> CGImage {
        MetalDownsampler.downsample(cgImage: cgImage, maxPixelSize: maxPixelSize)
    }

    static func extractVideoThumbnail(from url: URL, maxPixelSize: Int = 360) async -> PreviewExtractionResult? {
        guard !Task.isCancelled else { return nil }
        return await HeavyDecodeLimiter.shared.withPermit {
            guard !Task.isCancelled else { return nil }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

            let time = CMTime(seconds: 0.0, preferredTimescale: 600)
            do {
                let (cgImage, _) = try await generator.image(at: time)
                guard let jpegData = encodeToJPEG(cgImage: cgImage) else {
                    return nil
                }
                return PreviewExtractionResult(image: cgImage, jpegData: jpegData, strategy: .videoFrameGenerator)
            } catch {
                return nil
            }
        }
    }

    static func decodeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return thumbnail
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func applyOrientation(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return cgImage }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let isSwapped = (orientation == .leftMirrored || orientation == .right || orientation == .rightMirrored || orientation == .left)
        let targetWidth = Int(isSwapped ? h : w)
        let targetHeight = Int(isSwapped ? w : h)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }

        var transform = CGAffineTransform.identity
        switch orientation {
        case .up:
            break
        case .upMirrored: // Flip horizontal
            transform = transform.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case .down: // 180 deg
            transform = transform.translatedBy(x: w, y: h).scaledBy(x: -1, y: -1)
        case .downMirrored: // Flip vertical
            transform = transform.translatedBy(x: 0, y: h).scaledBy(x: 1, y: -1)
        case .leftMirrored: // Transpose
            transform = transform.translatedBy(x: h, y: w).rotated(by: -.pi / 2).scaledBy(x: 1, y: -1)
        case .right: // Rotate 90 CW
            transform = transform.translatedBy(x: 0, y: w).rotated(by: -.pi / 2)
        case .rightMirrored: // Transverse
            transform = transform.rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
        case .left: // Rotate 270 CW (90 CCW)
            transform = transform.translatedBy(x: h, y: 0).rotated(by: .pi / 2)
        @unknown default:
            break
        }

        ctx.concatenate(transform)
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cgImage
    }

    static func applyOrientation(cgImage: CGImage, orientation: UInt32) -> CGImage {
        guard let propOrientation = CGImagePropertyOrientation(rawValue: orientation) else {
            return cgImage
        }
        return applyOrientation(cgImage: cgImage, orientation: propOrientation)
    }

    static func extractTIFFOrientation(from data: Data) -> CGImagePropertyOrientation? {
        guard data.count >= 8 else { return nil }
        let isLittleEndian: Bool
        if data[0] == 0x49 && data[1] == 0x49 {
            isLittleEndian = true
        } else if data[0] == 0x4D && data[1] == 0x4D {
            isLittleEndian = false
        } else {
            return nil
        }

        func readU16(_ offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1])
            return isLittleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
        }

        func readU32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            return isLittleEndian ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) :
                                    ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
        }

        guard let ifd0Offset = readU32(4) else { return nil }
        let ifdStart = Int(ifd0Offset)
        guard let entryCount = readU16(ifdStart) else { return nil }

        var current = ifdStart + 2
        for _ in 0..<entryCount {
            guard current + 12 <= data.count else { break }
            guard let tag = readU16(current) else { break }
            if tag == 274 { // Tag 274 (0x0112): Orientation
                guard let type = readU16(current + 2) else { break }
                if type == 3 {
                    if let val = readU16(current + 8),
                       let ori = CGImagePropertyOrientation(rawValue: UInt32(val)) {
                        return ori
                    }
                } else if type == 4 {
                    if let val = readU32(current + 8),
                       let ori = CGImagePropertyOrientation(rawValue: val) {
                        return ori
                    }
                }
            }
            current += 12
        }
        return nil
    }

    static func extractContainerOrientation(from source: CGImageSource?, prefixData: Data? = nil, url: URL? = nil) -> CGImagePropertyOrientation? {
        if let prefixData, let val = extractTIFFOrientation(from: prefixData) {
            return val
        }
        if let source, CGImageSourceGetCount(source) > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let num = props[kCGImagePropertyOrientation] as? NSNumber,
               let ori = CGImagePropertyOrientation(rawValue: num.uint32Value) {
                return ori
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
               let num = tiff[kCGImagePropertyTIFFOrientation] as? NSNumber,
               let ori = CGImagePropertyOrientation(rawValue: num.uint32Value) {
                return ori
            }
        }
        if prefixData == nil, let url, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let header = try? handle.read(upToCount: 65536),
               let val = extractTIFFOrientation(from: header) {
                return val
            }
        }
        if let url {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            if let imgSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
               CGImageSourceGetCount(imgSource) > 0,
               let props = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [CFString: Any] {
                if let num = props[kCGImagePropertyOrientation] as? NSNumber,
                   let ori = CGImagePropertyOrientation(rawValue: num.uint32Value) {
                    return ori
                }
                if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                   let num = tiff[kCGImagePropertyTIFFOrientation] as? NSNumber,
                   let ori = CGImagePropertyOrientation(rawValue: num.uint32Value) {
                    return ori
                }
            }
        }
        return nil
    }

    static func encodeToJPEG(cgImage: CGImage, quality: Double = 0.82) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }

    static func extractFullRAW(from url: URL) -> (image: CGImage, data: Data)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        guard let fullCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let containerOrientation = extractContainerOrientation(from: source, url: url)
        let oriented: CGImage
        if let containerOrientation, containerOrientation != .up {
            oriented = applyOrientation(cgImage: fullCGImage, orientation: containerOrientation)
        } else {
            oriented = fullCGImage
        }
        guard let encoded = encodeToHEIC(cgImage: oriented) else {
            return nil
        }
        return (image: oriented, data: encoded.data)
    }

    static func encodeToHEIC(cgImage: CGImage, quality: Double = 0.88) -> (data: Data, format: String)? {
        let cfData = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(cfData, UTType.heic.identifier as CFString, 1, nil) {
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                return (data: cfData as Data, format: "heic")
            }
        }
        // Fallback to JPEG
        cfData.length = 0
        if let destination = CGImageDestinationCreateWithData(cfData, UTType.jpeg.identifier as CFString, 1, nil) {
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                return (data: cfData as Data, format: "jpeg")
            }
        }
        return nil
    }
}


extension CGImage {
    nonisolated var aspectRatio: CGFloat {
        CGFloat(width) / CGFloat(max(1, height))
    }
}

