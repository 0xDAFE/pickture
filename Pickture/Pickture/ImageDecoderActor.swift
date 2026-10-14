import CoreGraphics
import Foundation
import ImageIO

/// A background actor running on the cooperative thread pool that executes
/// ImageIO and CoreGraphics JPEG, HEIC, and thumbnail decompression off `@MainActor`.
///
/// Decompressing large raster images (2048px previews or full 24MP+ RAW previews)
/// takes tens to hundreds of milliseconds of CPU time. Moving decompression to
/// `ImageDecoderActor` ensures that the main runloop is never blocked by pixel rasterization.
///
/// Cooperative cancellation is respected at suspension points and intermediate decode checks:
/// if the calling `Task` is cancelled (e.g. a SwiftUI view scrolls out of viewport or navigates away),
/// decoding immediately aborts and returns `nil`.
actor ImageDecoderActor {
    static let shared = ImageDecoderActor()

    /// Decompresses an image from raw data off `@MainActor`, respecting cooperative cancellation.
    ///
    /// - Parameters:
    ///   - data: Encoded image data (JPEG, HEIC, PNG, etc.).
    ///   - key: Optional cache key. When provided, the decoded `CGImage` is immediately inserted
    ///     into `DecodedImageCache.shared` from the background decode path before returning.
    /// - Returns: The decompressed `CGImage`, or `nil` if decoding failed or the task was cancelled.
    func decode(from data: Data, cachingWithKey key: String? = nil) -> CGImage? {
        guard !Task.isCancelled else { return nil }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        guard !Task.isCancelled else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        let image: CGImage?
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            image = thumbnail
        } else if !Task.isCancelled {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            image = nil
        }

        guard !Task.isCancelled, let decodedImage = image else {
            return nil
        }

        if let key {
            DecodedImageCache.shared.setImage(decodedImage, forKey: key)
        }

        return decodedImage
    }

    /// Convenience overload matching the exact spec signature: `func decode(from data: Data) -> CGImage?`
    func decode(from data: Data) -> CGImage? {
        decode(from: data, cachingWithKey: nil)
    }
}
