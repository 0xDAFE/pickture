import CoreGraphics
import Foundation

nonisolated private final class CGImageBox: NSObject {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }
}

/// A thread-safe, bounded in-memory cache of decoded uncompressed pixel buffers (`CGImage`).
///
/// Eviction is governed by `NSCache` based on uncompressed byte cost (`bytesPerRow * height`),
/// keeping memory consumption bounded within the device RAM budget while enabling instantaneous
/// back-and-forth filmstrip navigation and grid rendering with zero disk I/O.
///
/// - Note: Concurrency Safety Invariant: Marked `@unchecked Sendable` because the underlying storage
///   is `NSCache<NSString, CGImageBox>`, which is internally synchronized and thread-safe for concurrent
///   read and write operations across arbitrary background and cooperative threads.
public nonisolated final class DecodedImageCache: @unchecked Sendable {
    public static let shared = DecodedImageCache()

    private let cache = NSCache<NSString, CGImageBox>()

    public var totalCostLimitBytes: Int {
        get { cache.totalCostLimit }
        set { cache.totalCostLimit = newValue }
    }

    public var countLimit: Int {
        get { cache.countLimit }
        set { cache.countLimit = newValue }
    }

    public init(totalCostLimitBytes: Int = 512 * 1024 * 1024, countLimit: Int = 50) {
        cache.totalCostLimit = totalCostLimitBytes
        cache.countLimit = countLimit
        cache.name = "com.pickture.DecodedImageCache"
    }

    public func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    public func setImage(_ image: CGImage, forKey key: String) {
        let cost = self.cost(for: image)
        cache.setObject(CGImageBox(image: image), forKey: key as NSString, cost: cost)
    }

    public func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    public func clear() {
        cache.removeAllObjects()
    }

    public func cost(for image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}
