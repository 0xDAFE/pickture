import CoreGraphics
import Foundation

actor ThumbnailQueueActor {
    static let shared = ThumbnailQueueActor(maxConcurrentWorkers: 4)

    private let maxConcurrentWorkers: Int
    private var activeWorkers: Int = 0

    private struct PendingRequest {
        let id: String
        let operation: @Sendable () async -> Data?
        let continuation: CheckedContinuation<Data?, Never>
    }

    private var pendingQueue: [PendingRequest] = []
    private var activeTasks: [String: Task<Void, Never>] = [:]

    var pendingCount: Int {
        pendingQueue.count
    }

    init(maxConcurrentWorkers: Int = 4) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
    }

    func enqueue(
        id: String,
        operation: @escaping @Sendable () async -> Data?
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }

        cancel(id: id)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let request = PendingRequest(
                    id: id,
                    operation: operation,
                    continuation: continuation
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
            removed.continuation.resume(returning: nil)
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
                if Task.isCancelled {
                    next.continuation.resume(returning: nil)
                    return
                }
                let result = await next.operation()
                next.continuation.resume(returning: Task.isCancelled ? nil : result)
            }
            activeTasks[itemID] = workerTask
        }
    }
}

/// Coordinates thumbnail and preview image generation, LIFO concurrency scheduling,
/// decode limiting, and evictable caching behind a deep module seam.
@MainActor
final class MediaPipeline {
    let cache: MediaCache
    let thumbnailQueue: ThumbnailQueueActor

    var totalCachedBytes: Int64 {
        cache.totalCachedBytes
    }

    var cacheSizeLimitBytes: Int64 {
        cache.cacheSizeLimitBytes
    }

    init(
        cacheDirectoryURL: URL,
        initialLimitBytes: Int64 = MediaCache.defaultQuotaBytes,
        maxConcurrentThumbnailWorkers: Int = 4
    ) {
        self.cache = MediaCache(cacheDirectoryURL: cacheDirectoryURL, initialLimitBytes: initialLimitBytes)
        self.thumbnailQueue = ThumbnailQueueActor(maxConcurrentWorkers: maxConcurrentThumbnailWorkers)
    }

    func setCacheSizeLimitBytes(_ bytes: Int64) {
        cache.setCacheSizeLimitBytes(bytes)
    }

    func setUserConfiguredCacheSizeLimitBytes(_ limitBytes: Int64) {
        let clamped = min(
            MediaCache.maxUserQuotaBytes,
            max(MediaCache.minUserQuotaBytes, limitBytes)
        )
        setCacheSizeLimitBytes(clamped)
    }

    func clearCache() {
        cache.clear()
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

    func isThumbnailCached(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) -> Bool {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        return cache.contains(key: key)
    }

    func cachedThumbnailImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) -> CGImage? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        guard let cachedData = cache.readData(forKey: key) else {
            return nil
        }
        return PreviewLoader.decodeCGImage(from: cachedData)
    }

    func cachedPreviewImage(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) -> CGImage? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        guard let cachedData = cache.readData(forKey: key) else {
            return nil
        }
        return PreviewLoader.decodeCGImage(from: cachedData)
    }

    func loadThumbnailData(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 360) async -> Data? {
        let key = thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let cached = cache.readData(forKey: key) {
            return cached
        }
        guard !Task.isCancelled else { return nil }
        let queue = thumbnailQueue
        let data = await queue.enqueue(id: key) {
            guard !Task.isCancelled else { return nil }
            let extracted = await PreviewLoader.extractThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
            return extracted?.jpegData
        }
        guard let data, !Task.isCancelled else {
            return nil
        }
        cache.storeData(data, forKey: key)
        return data
    }

    func loadPreviewImageData(for item: MediaItem, previewSource: PreviewSource, maxPixelSize: Int = 2048) async -> Data? {
        let key = previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let cached = cache.readData(forKey: key) {
            return cached
        }
        guard !Task.isCancelled else { return nil }
        let extracted = await PreviewLoader.extractThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        guard let extracted, !Task.isCancelled else {
            return nil
        }
        cache.storeData(extracted.jpegData, forKey: key)
        return extracted.jpegData
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
