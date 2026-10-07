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
    let jpegData: Data
    let strategy: PreviewExtractionStrategy
}

actor HeavyDecodeLimiter {
    static let shared = HeavyDecodeLimiter(maxConcurrent: 2)

    private let maxConcurrent: Int
    private var activeCount: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }

    var currentActiveCount: Int {
        activeCount
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
            if let headerJPEG = extractEmbeddedJPEGFromHeaderPrefix(at: url, maxPixelSize: maxPixelSize) {
                return PreviewExtractionResult(jpegData: headerJPEG, strategy: .embeddedPreview)
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
                return PreviewExtractionResult(jpegData: jpegData, strategy: .embeddedPreview)
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
                return PreviewExtractionResult(jpegData: jpegData, strategy: .embeddedPreview)
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

        if let source, CGImageSourceGetCount(source) > 0 {
            if let fallback = extractFullDecodeFallback(from: source, url: url, isRaw: isRaw, maxPixelSize: maxPixelSize) {
                return fallback
            }
        } else if isRaw {
            if let tiffFallbackJPEG = extractTIFFHintFullDecode(from: url, maxPixelSize: maxPixelSize) {
                return PreviewExtractionResult(jpegData: tiffFallbackJPEG, strategy: .fullDecodeFallback)
            }
        }

        return nil
    }

    static func extractImageThumbnailAsync(from url: URL, maxPixelSize: Int = 360) async -> PreviewExtractionResult? {
        guard !Task.isCancelled else { return nil }
        let isRaw = MediaFormatKind.classify(fileExtension: url.pathExtension) == .raw
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)

        if let embedded = extractEmbeddedPreview(from: source, url: url, isRaw: isRaw, maxPixelSize: maxPixelSize) {
            return embedded
        }

        guard !Task.isCancelled else { return nil }

        if let source, CGImageSourceGetCount(source) > 0 {
            return await HeavyDecodeLimiter.shared.withPermit {
                guard !Task.isCancelled else { return nil }
                return extractFullDecodeFallback(from: source, url: url, isRaw: isRaw, maxPixelSize: maxPixelSize)
            }
        } else if isRaw {
            return await HeavyDecodeLimiter.shared.withPermit {
                guard !Task.isCancelled else { return nil }
                if let tiffFallbackJPEG = extractTIFFHintFullDecode(from: url, maxPixelSize: maxPixelSize) {
                    return PreviewExtractionResult(jpegData: tiffFallbackJPEG, strategy: .fullDecodeFallback)
                }
                return nil
            }
        }

        return nil
    }

    private static func extractFullDecodeFallback(
        from source: CGImageSource,
        url: URL,
        isRaw: Bool,
        maxPixelSize: Int
    ) -> PreviewExtractionResult? {
        let fallbackOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let fallbackCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, fallbackOptions as CFDictionary),
           let jpegData = encodeToJPEG(cgImage: fallbackCGImage) {
            return PreviewExtractionResult(jpegData: jpegData, strategy: .fullDecodeFallback)
        }

        if let fullCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let scaled = downsampleIfNeeded(cgImage: fullCGImage, maxPixelSize: maxPixelSize)
            if let jpegData = encodeToJPEG(cgImage: scaled) {
                return PreviewExtractionResult(jpegData: jpegData, strategy: .fullDecodeFallback)
            }
        }

        if isRaw, let tiffFallbackJPEG = extractTIFFHintFullDecode(from: url, maxPixelSize: maxPixelSize) {
            return PreviewExtractionResult(jpegData: tiffFallbackJPEG, strategy: .fullDecodeFallback)
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
            let scaled = downsampleIfNeeded(cgImage: fullCGImage, maxPixelSize: maxPixelSize)
            return encodeToJPEG(cgImage: scaled)
        }
        return nil
    }

    private static func extractEmbeddedJPEGFromHeaderPrefix(
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
        if let directSource = CGImageSourceCreateWithData(prefixData as CFData, nil),
           CGImageSourceGetCount(directSource) > 0 {
            let embeddedOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            if let embeddedCGImage = CGImageSourceCreateThumbnailAtIndex(directSource, 0, embeddedOptions as CFDictionary) {
                let scaled = downsampleIfNeeded(cgImage: embeddedCGImage, maxPixelSize: maxPixelSize)
                if let jpeg = encodeToJPEG(cgImage: scaled) {
                    return jpeg
                }
            }

            let unsizedOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let embeddedCGImage = CGImageSourceCreateThumbnailAtIndex(directSource, 0, unsizedOptions as CFDictionary) {
                let scaled = downsampleIfNeeded(cgImage: embeddedCGImage, maxPixelSize: maxPixelSize)
                if let jpeg = encodeToJPEG(cgImage: scaled) {
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

        while attempts < 4, let startRange = prefixData.range(of: soi, in: searchStart..<prefixData.endIndex) {
            attempts += 1
            let slice = prefixData.subdata(in: startRange.lowerBound..<prefixData.endIndex)
            if let source = CGImageSourceCreateWithData(slice as CFData, nil),
               let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                if let currentBest = bestImage {
                    if cgImage.width * cgImage.height > currentBest.width * currentBest.height {
                        bestImage = cgImage
                    }
                } else {
                    bestImage = cgImage
                }
            }
            searchStart = startRange.upperBound
        }

        guard let bestImage else {
            return nil
        }
        return encodeToJPEG(cgImage: bestImage)
    }

    private static func downsampleIfNeeded(cgImage: CGImage, maxPixelSize: Int) -> CGImage {
        let maxDim = max(cgImage.width, cgImage.height)
        guard maxDim > maxPixelSize, maxPixelSize > 0 else {
            return cgImage
        }
        let scale = Double(maxPixelSize) / Double(maxDim)
        let targetWidth = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(cgImage.height) * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? cgImage
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
                return PreviewExtractionResult(jpegData: jpegData, strategy: .videoFrameGenerator)
            } catch {
                return nil
            }
        }
    }

    static func decodeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated static func decodeCGImageAsync(from data: Data) async -> CGImage? {
        decodeCGImage(from: data)
    }

    private static func encodeToJPEG(cgImage: CGImage, quality: Double = 0.82) -> Data? {
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
}

extension CGImage {
    var aspectRatio: CGFloat {
        CGFloat(width) / CGFloat(max(1, height))
    }
}

