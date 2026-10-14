import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@Suite("ImageDecoderActor Tests", .serialized)
struct ImageDecoderActorTests {

    private func makeSampleJPEGData(width: Int = 100, height: Int = 100) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            pixels[idx] = 120
            pixels[idx + 1] = 180
            pixels[idx + 2] = 220
            pixels[idx + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return mutableData as Data
    }

    @Test("ImageDecoderActor decodes valid JPEG data off @MainActor")
    func imageDecoderActorDecodesValidData() async throws {
        let jpegData = try makeSampleJPEGData(width: 150, height: 100)
        let actor = ImageDecoderActor.shared

        let decoded = try #require(await actor.decode(from: jpegData))
        #expect(decoded.width == 150)
        #expect(decoded.height == 100)
    }

    @Test("ImageDecoderActor immediately aborts and returns nil when task is cancelled")
    func imageDecoderActorAbortsOnCancellation() async throws {
        let jpegData = try makeSampleJPEGData(width: 300, height: 300)
        let task = Task {
            await Task.yield()
            return await ImageDecoderActor.shared.decode(from: jpegData)
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }

    @Test("MediaCache storeData aborts and cleans up when task is cancelled")
    func mediaCacheStoreDataAbortsOnCancellation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MediaCacheCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = MediaCache(cacheDirectoryURL: tempDir)
        let dummyData = try makeSampleJPEGData(width: 60, height: 60)
        let key = "cancelled_key"

        let task = Task {
            await Task.yield()
            await cache.storeData(dummyData, forKey: key)
        }
        task.cancel()
        await task.value

        #expect(await cache.contains(key: key) == false)
        let read = await cache.readData(forKey: key)
        #expect(read == nil)
    }

    @Test("MediaCache writeDiskFile writes cooperatively and recordEntry stores metadata")
    func mediaCacheWriteDiskFileAndRecordEntry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MediaCacheCoop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = MediaCache(cacheDirectoryURL: tempDir)
        let dummyData = try makeSampleJPEGData(width: 60, height: 60)
        let key = "cooperative_key"

        // Cooperative nonisolated write off-actor
        let written = try #require(cache.writeDiskFile(dummyData, forKey: key))
        #expect(written.byteSize == Int64(dummyData.count))

        // Record entry on the actor with minimal critical section
        await cache.recordEntry(key: key, fileName: written.fileName, byteSize: written.byteSize, pixelWidth: 60, pixelHeight: 60)

        #expect(await cache.contains(key: key))
        let read = try #require(await cache.readData(forKey: key))
        #expect(read == dummyData)
        #expect(await cache.aspectRatio(forKey: key) == 1.0)
    }
}
