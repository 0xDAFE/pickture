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

    var currentMaxWorkers: Int {
        maxConcurrentWorkers
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
    @ObservationIgnored
    let heavyDecodeLimiter: HeavyDecodeLimiter
    @ObservationIgnored
    private var activePersistenceTasks: [String: Task<Void, Never>] = [:]

    private(set) var totalCachedBytes: Int64 = 0
    private(set) var cacheSizeLimitBytes: Int64 = MediaCache.defaultQuotaBytes

    init(
        cacheDirectoryURL: URL,
        initialLimitBytes: Int64 = MediaCache.defaultQuotaBytes,
        maxConcurrentThumbnailWorkers: Int = 4,
        heavyDecodeLimiter: HeavyDecodeLimiter = HeavyDecodeLimiter.shared
    ) {
        let cache = MediaCache(cacheDirectoryURL: cacheDirectoryURL, initialLimitBytes: initialLimitBytes)
        self.cache = cache
        self.thumbnailQueue = ThumbnailQueueActor(maxConcurrentWorkers: maxConcurrentThumbnailWorkers)
        self.heavyDecodeLimiter = heavyDecodeLimiter
        self.totalCachedBytes = 0
        self.cacheSizeLimitBytes = initialLimitBytes
        Task { [weak self, cache] in
            let metrics = await cache.metrics()
            await MainActor.run { [weak self] in
                self?.totalCachedBytes = metrics.totalBytes
                self?.cacheSizeLimitBytes = metrics.limitBytes
            }
        }
    }

    func syncCacheMetrics() async {
        let metrics = await cache.metrics()
        self.totalCachedBytes = metrics.totalBytes
        self.cacheSizeLimitBytes = metrics.limitBytes
    }

    func setCacheSizeLimitBytes(_ bytes: Int64) async {
        self.cacheSizeLimitBytes = bytes
        await cache.setCacheSizeLimitBytes(bytes)
        await syncCacheMetrics()
    }

    func setUserConfiguredCacheSizeLimitBytes(_ limitBytes: Int64) {
        let clamped = min(
            MediaCache.maxUserQuotaBytes,
            max(MediaCache.minUserQuotaBytes, limitBytes)
        )
        self.cacheSizeLimitBytes = clamped
        Task { [weak self] in
            await self?.setCacheSizeLimitBytes(clamped)
        }
    }

    func applyStorageVolumeProfile(_ profile: StorageVolumeProfile, isHighSpeedLAN: Bool = false) async {
        let thumbWorkers = profile.effectiveThumbnailWorkers(isHighSpeedLAN: isHighSpeedLAN)
        let heavyPermits = profile.effectiveHeavyDecodes(isHighSpeedLAN: isHighSpeedLAN)
        await thumbnailQueue.setMaxConcurrentWorkers(thumbWorkers)
        await heavyDecodeLimiter.setMaxConcurrent(heavyPermits)
    }

    func clearCache() async {
        DecodedImageCache.shared.clear()
        await cache.clear()
        self.totalCachedBytes = 0
    }

    func flushIndexImmediately() async {
        await cache.flushIndexImmediately()
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

    func isThumbnailCached(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async -> Bool {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        return await cache.contains(key: key)
    }

    func inMemoryThumbnailImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) -> CGImage? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        return DecodedImageCache.shared.image(forKey: key)
    }

    func inMemoryPreviewImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) -> CGImage? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        return DecodedImageCache.shared.image(forKey: key)
    }

    func inMemoryFullRAWImage(for item: MediaItem) -> CGImage? {
        let key = fullRAWCacheKey(for: item)
        return DecodedImageCache.shared.image(forKey: key)
    }

    func cachedThumbnailImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async -> CGImage? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        guard let cachedData = await cache.readData(forKey: key) else {
            await syncCacheMetrics()
            return nil
        }
        return await decodeAndCache(data: cachedData, forKey: key)
    }

    func cachedPreviewImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) async -> CGImage? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        guard let cachedData = await cache.readData(forKey: key) else {
            await syncCacheMetrics()
            return nil
        }
        return await decodeAndCache(data: cachedData, forKey: key)
    }

    func cachedFullRAWImage(for item: MediaItem) async -> CGImage? {
        let key = fullRAWCacheKey(for: item)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        guard let cachedData = await cache.readData(forKey: key) else {
            await syncCacheMetrics()
            return nil
        }
        return await decodeAndCache(data: cachedData, forKey: key)
    }

    private func decodeAndCache(data: Data, forKey key: String) async -> CGImage? {
        guard let image = await ImageDecoderActor.shared.decode(from: data) else {
            return nil
        }
        DecodedImageCache.shared.setImage(image, forKey: key)
        return image
    }

    private func resolveAndCacheImage(from extracted: PreviewExtractionResult, forKey key: String) async -> CGImage? {
        if let img = extracted.image {
            DecodedImageCache.shared.setImage(img, forKey: key)
            return img
        }
        return await decodeAndCache(data: extracted.jpegData, forKey: key)
    }

    private func persistExtractedDataAsync(data: Data, forKey key: String, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        let diskCache = self.cache
        activePersistenceTasks[key]?.cancel()
        let task = Task(priority: .userInitiated) { [weak self, diskCache, key, data, pixelWidth, pixelHeight] in
            guard !Task.isCancelled else { return }
            await diskCache.storeData(data, forKey: key, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            guard !Task.isCancelled else { return }
            await self?.syncCacheMetrics()
            await MainActor.run { [weak self] in
                self?.activePersistenceTasks.removeValue(forKey: key)
            }
        }
        activePersistenceTasks[key] = task
    }

    func loadThumbnailImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async -> CGImage? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        if let cachedData = await cache.readData(forKey: key),
           let decoded = await decodeAndCache(data: cachedData, forKey: key) {
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
        let finalImage = await resolveAndCacheImage(from: extracted, forKey: key)
        if let finalImage {
            persistExtractedDataAsync(data: extracted.jpegData, forKey: key, pixelWidth: finalImage.width, pixelHeight: finalImage.height)
        } else {
            persistExtractedDataAsync(data: extracted.jpegData, forKey: key)
        }
        await syncCacheMetrics()
        return finalImage
    }

    func loadThumbnailData(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async -> Data? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let cached = await cache.readData(forKey: key) {
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
        let finalImage = await resolveAndCacheImage(from: extracted, forKey: key)
        await cache.storeData(extracted.jpegData, forKey: key, pixelWidth: finalImage?.width, pixelHeight: finalImage?.height)
        await syncCacheMetrics()
        return extracted.jpegData
    }

    func loadPreviewImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) async -> CGImage? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        if let cachedData = await cache.readData(forKey: key),
           let decoded = await decodeAndCache(data: cachedData, forKey: key) {
            return decoded
        }
        guard !Task.isCancelled else { return nil }
        let extracted = await self.heavyDecodeLimiter.withPermit { () -> PreviewExtractionResult? in
            guard !Task.isCancelled else { return nil }
            return await PreviewLoader.extractThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        }
        guard let extracted, !Task.isCancelled else {
            return nil
        }
        let finalImage = await resolveAndCacheImage(from: extracted, forKey: key)
        persistExtractedDataAsync(data: extracted.jpegData, forKey: key)
        await syncCacheMetrics()
        return finalImage
    }

    func loadPreviewImageData(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) async -> Data? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let cached = await cache.readData(forKey: key) {
            return cached
        }
        guard !Task.isCancelled else { return nil }
        let extracted = await self.heavyDecodeLimiter.withPermit { () -> PreviewExtractionResult? in
            guard !Task.isCancelled else { return nil }
            return await PreviewLoader.extractThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        }
        guard let extracted, !Task.isCancelled else {
            return nil
        }
        _ = await resolveAndCacheImage(from: extracted, forKey: key)
        await cache.storeData(extracted.jpegData, forKey: key)
        await syncCacheMetrics()
        return extracted.jpegData
    }

    func loadFullRAW(for item: MediaItem) async -> CGImage? {
        let key = fullRAWCacheKey(for: item)
        if let inMemory = DecodedImageCache.shared.image(forKey: key) {
            return inMemory
        }
        if let cachedData = await cache.readData(forKey: key),
           let decoded = await decodeAndCache(data: cachedData, forKey: key) {
            return decoded
        }
        guard !Task.isCancelled else { return nil }
        let rawFile = item.mediaPair?.rawFile ?? item.primaryFile
        let result = await self.heavyDecodeLimiter.withPermit { () -> (image: CGImage, data: Data)? in
            guard !Task.isCancelled else { return nil }
            return PreviewLoader.extractFullRAW(from: rawFile.url)
        }
        guard let result, !Task.isCancelled else { return nil }
        DecodedImageCache.shared.setImage(result.image, forKey: key)
        persistExtractedDataAsync(data: result.data, forKey: key)
        await syncCacheMetrics()
        return result.image
    }

    func cancelThumbnail(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        activePersistenceTasks[key]?.cancel()
        activePersistenceTasks.removeValue(forKey: key)
        let queue = thumbnailQueue
        Task {
            await queue.cancel(id: key)
        }
    }

    func cancelThumbnailImmediately(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        activePersistenceTasks[key]?.cancel()
        activePersistenceTasks.removeValue(forKey: key)
        await thumbnailQueue.cancel(id: key)
    }
}
