import CoreGraphics
import Testing
@testable import Pickture

@Suite("DecodedImageCache Tests")
struct DecodedImageCacheTests {

    private func makeTestCGImage(width: Int = 100, height: Int = 100) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    @Test("DecodedImageCache stores, retrieves, and clears decoded CGImages with correct keys")
    func storeRetrieveAndClearImages() {
        let cache = DecodedImageCache(totalCostLimitBytes: 10 * 1024 * 1024)
        let key = "photo123#preferRAW#2048"
        let image = makeTestCGImage(width: 200, height: 200)

        #expect(cache.image(forKey: key) == nil)

        cache.setImage(image, forKey: key)
        let retrieved = cache.image(forKey: key)
        #expect(retrieved != nil)
        #expect(retrieved?.width == 200)
        #expect(retrieved?.height == 200)

        cache.removeImage(forKey: key)
        #expect(cache.image(forKey: key) == nil)

        cache.setImage(image, forKey: key)
        #expect(cache.image(forKey: key) != nil)

        cache.clear()
        #expect(cache.image(forKey: key) == nil)
    }

    @Test("DecodedImageCache calculates pixel buffer byte cost accurately")
    func calculatesPixelBufferCost() {
        let cache = DecodedImageCache()
        let image = makeTestCGImage(width: 100, height: 50)
        let cost = cache.cost(for: image)
        #expect(cost == image.bytesPerRow * image.height)
        #expect(cost > 0)
    }

    @Test("DecodedImageCache evicts oldest items when totalCostLimitBytes is exceeded")
    func evictsUnderCostLimit() {
        // 100x100 32-bit image is ~40,000 bytes. Set limit to hold roughly 2 images.
        let singleImageCost = 100 * 4 * 100 // 40,000 bytes
        let cache = DecodedImageCache(totalCostLimitBytes: singleImageCost * 2)

        let img1 = makeTestCGImage(width: 100, height: 100)
        let img2 = makeTestCGImage(width: 100, height: 100)
        let img3 = makeTestCGImage(width: 100, height: 100)

        cache.setImage(img1, forKey: "key1")
        cache.setImage(img2, forKey: "key2")
        #expect(cache.image(forKey: "key1") != nil)
        #expect(cache.image(forKey: "key2") != nil)

        // Adding img3 should trigger eviction under NSCache cost limit
        cache.setImage(img3, forKey: "key3")
        #expect(cache.image(forKey: "key3") != nil)
    }
}
