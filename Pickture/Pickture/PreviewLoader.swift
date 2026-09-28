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
            // If preferred file fails in a MediaPair, try the companion file
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

        // For RAW files, also check if an embedded JPEG preview stream exists in the initial header bytes
        // so slow network shares only read the header prefix instead of the full sensor payload.
        if isRaw, let headerJPEG = extractEmbeddedJPEGFromHeaderPrefix(at: url, maxPixelSize: maxPixelSize) {
            return PreviewExtractionResult(jpegData: headerJPEG, strategy: .embeddedPreview)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        // Step 1: Streaming embedded preview extraction (avoids full RAW/image decode over network links).
        // Omit kCGImageSourceThumbnailMaxPixelSize on the initial probe so ImageIO never rejects an
        // embedded EXIF/IFD thumbnail whose native pixel dimension is smaller than maxPixelSize.
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

        // Step 2: Fallback to generating thumbnail from image if no embedded preview header exists
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
        guard let startRange = prefixData.range(of: soi),
              let endRange = prefixData.range(of: eoi, options: .backwards, in: startRange.lowerBound..<prefixData.endIndex),
              endRange.upperBound > startRange.lowerBound else {
            return nil
        }
        let candidateJPEG = prefixData.subdata(in: startRange.lowerBound..<endRange.upperBound)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(candidateJPEG as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodeToJPEG(cgImage: cgImage)
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
