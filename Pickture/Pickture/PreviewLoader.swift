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

nonisolated enum PreviewLoader {

    static func extractThumbnail(
        for item: MediaItem,
        previewSource: PreviewSource,
        maxPixelSize: Int = 360
    ) async -> PreviewExtractionResult? {
        switch item.kind {
        case .photo:
            let file = item.preferredFile(for: previewSource)
            if let result = extractImageThumbnail(from: file.url, maxPixelSize: maxPixelSize) {
                return result
            }
            // If preferred file fails in a MediaPair, try the alternate paired MediaFile
            if let pair = item.mediaPair {
                let fallbackURL = (file.id == pair.rawFile.id) ? pair.rasterFile.url : pair.rawFile.url
                return extractImageThumbnail(from: fallbackURL, maxPixelSize: maxPixelSize)
            }
            return nil

        case .video:
            return await extractVideoThumbnail(from: item.primaryFile.url, maxPixelSize: maxPixelSize)
        }
    }

    static func extractImageThumbnail(from url: URL, maxPixelSize: Int = 360) -> PreviewExtractionResult? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        let isRaw = MediaFormatKind.classify(fileExtension: url.pathExtension) == .raw

        if let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) {
            // Step 1: Streaming embedded preview extraction via CGImageSource (avoids full RAW/image decode).
            // Omit kCGImageSourceThumbnailMaxPixelSize on the embedded probe so ImageIO never rejects an
            // embedded EXIF/IFD preview whose pixel dimension is smaller than maxPixelSize.
            let embeddedProbeOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let embeddedCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedProbeOptions as CFDictionary) {
                let scaled = downsampleIfNeeded(cgImage: embeddedCGImage, maxPixelSize: maxPixelSize)
                if let jpegData = encodeToJPEG(cgImage: scaled) {
                    return PreviewExtractionResult(jpegData: jpegData, strategy: .embeddedPreview)
                }
            }

            // For RAW files whose embedded JPEG header was not returned by CGImageSource thumbnail probe,
            // inspect only the initial header prefix before falling back to full image decode.
            if isRaw, let headerJPEG = extractEmbeddedJPEGFromHeaderPrefix(at: url, maxPixelSize: maxPixelSize) {
                return PreviewExtractionResult(jpegData: headerJPEG, strategy: .embeddedPreview)
            }

            // Step 2: Fallback to generating thumbnail from full image decode when no embedded preview exists.
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
        } else if isRaw, let headerJPEG = extractEmbeddedJPEGFromHeaderPrefix(at: url, maxPixelSize: maxPixelSize) {
            return PreviewExtractionResult(jpegData: headerJPEG, strategy: .embeddedPreview)
        }

        return nil
    }

    private static func extractEmbeddedJPEGFromHeaderPrefix(
        at url: URL,
        maxHeaderBytes: Int = 1_048_576,
        maxPixelSize: Int
    ) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let prefixData = try? handle.read(upToCount: maxHeaderBytes), prefixData.count > 4 else {
            return nil
        }
        let soi = Data([0xFF, 0xD8, 0xFF])
        let eoi = Data([0xFF, 0xD9])
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        var searchStart = prefixData.startIndex
        var bestImage: CGImage?

        while let startRange = prefixData.range(of: soi, in: searchStart..<prefixData.endIndex) {
            var eoiSearch = startRange.upperBound
            while let endRange = prefixData.range(of: eoi, in: eoiSearch..<prefixData.endIndex) {
                let candidateJPEG = prefixData.subdata(in: startRange.lowerBound..<endRange.upperBound)
                if let source = CGImageSourceCreateWithData(candidateJPEG as CFData, nil),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    if let currentBest = bestImage {
                        if cgImage.width * cgImage.height > currentBest.width * currentBest.height {
                            bestImage = cgImage
                        }
                    } else {
                        bestImage = cgImage
                    }
                    break
                }
                eoiSearch = endRange.upperBound
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

    static func decodeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
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
