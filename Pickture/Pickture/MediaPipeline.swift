import CoreGraphics
import Foundation
import Observation

actor ThumbnailQueueActor {
    static let shared = ThumbnailQueueActor(maxConcurrentWorkers: 4)

    private var maxConcurrentWorkers: Int
    private var activeWorkers: Int = 0

    private struct PendingRequest {
        let id: String
        let execute: @Sendable () async -> Void
        let cancel: @Sendable () -> Void
    }

    private var pendingQueue: [PendingRequest] = []
    private var activeTasks: [String: Task<Void, Never>] = [:]

    var pendingCount: Int {
        pendingQueue.count
    }

    init(maxConcurrentWorkers: Int = 4) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
    }

    func setMaxConcurrentWorkers(_ count: Int) {
        self.maxConcurrentWorkers = max(1, count)
        pump()
    }

    func enqueue<T: Sendable>(
        id: String,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        guard !Task.isCancelled else { return nil }

        cancel(id: id)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                let request = PendingRequest(
                    id: id,
                    execute: {
                        if Task.isCancelled {
                            continuation.resume(returning: nil)
                            return
                        }
                        let result = await operation()
                        continuation.resume(returning: Task.isCancelled ? nil : result)
                    },
                    cancel: {
                        continuation.resume(returning: nil)
                    }
                )
                // LIFO: newest visible cell is placed at the front of the queue
                pendingQueue.insert(request, at: 0)
                pump()
            }
        } onCancel: {
            Task {
                await self.cancel(id: id)
            }
        }
    }

    func cancel(id: String) {
        if let idx = pendingQueue.firstIndex(where: { $0.id == id }) {
            let removed = pendingQueue.remove(at: idx)
            removed.cancel()
        }
        if let task = activeTasks.removeValue(forKey: id) {
            task.cancel()
        }
    }

    private func pump() {
        while activeWorkers < maxConcurrentWorkers && !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            activeWorkers += 1
            let itemID = next.id

            let workerTask = Task {
                defer {
                    self.activeWorkers -= 1
                    self.activeTasks.removeValue(forKey: itemID)
                    self.pump()
                }
                await next.execute()
            }
            activeTasks[itemID] = workerTask
        }
    }
}

/// Coordinates thumbnail and preview image generation, LIFO concurrency scheduling,
/// decode limiting, and evictable caching behind a deep module seam.
@MainActor
@Observable
final class MediaPipeline {
    @ObservationIgnored
    let cache: MediaCache
    @ObservationIgnored
    let thumbnailQueue: ThumbnailQueueActor

    private(set) var totalCachedBytes: Int64 = 0
    private(set) var cacheSizeLimitBytes: Int64 = MediaCache.defaultQuotaBytes

    init(
        cacheDirectoryURL: URL,
        initialLimitBytes: Int64 = MediaCache.defaultQuotaBytes,
        maxConcurrentThumbnailWorkers: Int = 4
    ) {
        let cache = MediaCache(cacheDirectoryURL: cacheDirectoryURL, initialLimitBytes: initialLimitBytes)
        self.cache = cache
        self.thumbnailQueue = ThumbnailQueueActor(maxConcurrentWorkers: maxConcurrentThumbnailWorkers)
        self.totalCachedBytes = cache.totalCachedBytes
        self.cacheSizeLimitBytes = cache.cacheSizeLimitBytes
    }

    func syncCacheMetrics() {
        self.totalCachedBytes = cache.totalCachedBytes
        self.cacheSizeLimitBytes = cache.cacheSizeLimitBytes
    }

    func setCacheSizeLimitBytes(_ bytes: Int64) {
        cache.setCacheSizeLimitBytes(bytes)
        syncCacheMetrics()
    }

    func setUserConfiguredCacheSizeLimitBytes(_ limitBytes: Int64) {
        let clamped = min(
            MediaCache.maxUserQuotaBytes,
            max(MediaCache.minUserQuotaBytes, limitBytes)
        )
        setCacheSizeLimitBytes(clamped)
    }

    func clearCache() {
        DecodedImageCache.shared.clear()
        cache.clear()
        syncCacheMetrics()
    }

    func flushIndexImmediately() {
        cache.flushIndexImmediately()
    }

    nonisolated func thumbnailCacheKey(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) -> String {
        let file = item.preferredFile(for: previewSource)
        return "\(file.id)#\(previewSource.rawValue)#\(maxPixelSize)"
    }

    nonisolated func previewCacheKey(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) -> String {
        let file = item.preferredFile(for: previewSource)
        return "\(file.id)#preview#\(previewSource.rawValue)#\(maxPixelSize)"
    }

    nonisolated func fullRAWCacheKey(for item: MediaItem) -> String {
        let rawFile = item.mediaPair?.rawFile ?? item.primaryFile
        return "\(rawFile.id)#fullraw#preferRAW"
    }

    func isThumbnailCached(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) -> Bool {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        return cache.contains(key: key)
    }

    func cachedThumbnailImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) -> CGImage? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        guard let cachedData = cache.readData(forKey: key) else {
            syncCacheMetrics()
            return nil
        }
        guard let decoded = PreviewLoader.decodeCGImage(from: cachedData) else {
            return nil
        }
        DecodedImageCache.shared.setImage(decoded, forKey: key)
        return decoded
    }

    func cachedPreviewImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) -> CGImage? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        guard let cachedData = cache.readData(forKey: key) else {
            syncCacheMetrics()
            return nil
        }
        guard let decoded = PreviewLoader.decodeCGImage(from: cachedData) else {
            return nil
        }
        DecodedImageCache.shared.setImage(decoded, forKey: key)
        return decoded
    }

    func cachedFullRAWImage(for item: MediaItem) -> CGImage? {
        let key = fullRAWCacheKey(for: item)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        guard let cachedData = cache.readData(forKey: key) else {
            syncCacheMetrics()
            return nil
        }
        guard let decoded = PreviewLoader.decodeCGImage(from: cachedData) else {
            return nil
        }
        DecodedImageCache.shared.setImage(decoded, forKey: key)
        return decoded
    }

    func loadThumbnailImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async -> CGImage? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        if let cachedData = cache.readData(forKey: key),
           let decoded = PreviewLoader.decodeCGImage(from: cachedData) {
            DecodedImageCache.shared.setImage(decoded, forKey: key)
            return decoded
        }
        guard !Task.isCancelled else { return nil }
        let queue = thumbnailQueue
        let extracted = await queue.enqueue(id: key) { () -> PreviewExtractionResult? in
            guard !Task.isCancelled else { return nil }
            return await PreviewLoader.extractThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        }
        guard let extracted, !Task.isCancelled else {
            return nil
        }
        let finalImage = extracted.image ?? PreviewLoader.decodeCGImage(from: extracted.jpegData)
        if let finalImage {
            DecodedImageCache.shared.setImage(finalImage, forKey: key)
        }
        let diskCache = self.cache
        let dataToStore = extracted.jpegData
        Task.detached(priority: .utility) { [diskCache, key, dataToStore] in
            await MainActor.run {
                diskCache.storeData(dataToStore, forKey: key)
            }
        }
        syncCacheMetrics()
        return finalImage
    }

    func loadThumbnailData(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async -> Data? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let cached = cache.readData(forKey: key) {
            return cached
        }
        guard !Task.isCancelled else { return nil }
        let queue = thumbnailQueue
        let extracted = await queue.enqueue(id: key) { () -> PreviewExtractionResult? in
            guard !Task.isCancelled else { return nil }
            return await PreviewLoader.extractThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        }
        guard let extracted, !Task.isCancelled else {
            return nil
        }
        if let finalImage = extracted.image ?? PreviewLoader.decodeCGImage(from: extracted.jpegData) {
            DecodedImageCache.shared.setImage(finalImage, forKey: key)
        }
        cache.storeData(extracted.jpegData, forKey: key)
        syncCacheMetrics()
        return extracted.jpegData
    }

    func loadPreviewImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) async -> CGImage? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        if let cachedData = cache.readData(forKey: key),
           let decoded = PreviewLoader.decodeCGImage(from: cachedData) {
            DecodedImageCache.shared.setImage(decoded, forKey: key)
            return decoded
        }
        guard !Task.isCancelled else { return nil }
        let extracted = await HeavyDecodeLimiter.shared.withPermit { () -> PreviewExtractionResult? in
            guard !Task.isCancelled else { return nil }
            return await PreviewLoader.extractThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        }
        guard let extracted, !Task.isCancelled else {
            return nil
        }
        let finalImage = extracted.image ?? PreviewLoader.decodeCGImage(from: extracted.jpegData)
        if let finalImage {
            DecodedImageCache.shared.setImage(finalImage, forKey: key)
        }
        let diskCache = self.cache
        let dataToStore = extracted.jpegData
        Task.detached(priority: .utility) { [diskCache, key, dataToStore] in
            await MainActor.run {
                diskCache.storeData(dataToStore, forKey: key)
            }
        }
        syncCacheMetrics()
        return finalImage
    }

    func loadPreviewImageData(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) async -> Data? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let cached = cache.readData(forKey: key) {
            return cached
        }
        guard !Task.isCancelled else { return nil }
        let extracted = await HeavyDecodeLimiter.shared.withPermit { () -> PreviewExtractionResult? in
            guard !Task.isCancelled else { return nil }
            return await PreviewLoader.extractThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        }
        guard let extracted, !Task.isCancelled else {
            return nil
        }
        if let finalImage = extracted.image ?? PreviewLoader.decodeCGImage(from: extracted.jpegData) {
            DecodedImageCache.shared.setImage(finalImage, forKey: key)
        }
        cache.storeData(extracted.jpegData, forKey: key)
        syncCacheMetrics()
        return extracted.jpegData
    }

    func loadFullRAW(for item: MediaItem) async -> CGImage? {
        let key = fullRAWCacheKey(for: item)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        if let cachedData = cache.readData(forKey: key),
           let decoded = PreviewLoader.decodeCGImage(from: cachedData) {
            DecodedImageCache.shared.setImage(decoded, forKey: key)
            return decoded
        }
        guard !Task.isCancelled else { return nil }
        let rawFile = item.mediaPair?.rawFile ?? item.primaryFile
        let result = await HeavyDecodeLimiter.shared.withPermit { () -> (image: CGImage, data: Data)? in
            guard !Task.isCancelled else { return nil }
            return PreviewLoader.extractFullRAW(from: rawFile.url)
        }
        guard let result, !Task.isCancelled else { return nil }
        DecodedImageCache.shared.setImage(result.image, forKey: key)
        let diskCache = self.cache
        let dataToStore = result.data
        Task.detached(priority: .utility) { [diskCache, key, dataToStore] in
            await MainActor.run {
                diskCache.storeData(dataToStore, forKey: key)
            }
        }
        syncCacheMetrics()
        return result.image
    }

    func cancelThumbnail(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        let queue = thumbnailQueue
        Task {
            await queue.cancel(id: key)
        }
    }

    func cancelThumbnailImmediately(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        await thumbnailQueue.cancel(id: key)
    }
}

