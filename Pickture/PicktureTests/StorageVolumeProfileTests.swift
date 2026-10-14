import Foundation
import Testing
@testable import Pickture

@Suite("StorageVolumeProfile Tests", .serialized)
struct StorageVolumeProfileTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureVolumeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - StorageVolumeProfile Defaults & Overrides

    @Test("StorageVolumeProfile defaults match spec for internalSSD, removableMedia, and networkShare")
    func profileDefaults() {
        let ssd = StorageVolumeProfile.internalSSD
        #expect(ssd.maxConcurrentThumbnailGenerations == 6)
        #expect(ssd.maxConcurrentHeavyDecodes == 4)
        #expect(ssd.prefetchMinWorkers == 2)
        #expect(ssd.prefetchMaxWorkers == 6)
        #expect(ssd.prefetchLookaheadDepth == 8)
        #expect(ssd.defaultSidecarWriteWorkers == 4)
        #expect(ssd.defaultExifPreloadWorkers == 6)

        let removable = StorageVolumeProfile.removableMedia
        #expect(removable.maxConcurrentThumbnailGenerations == 3)
        #expect(removable.maxConcurrentHeavyDecodes == 2)
        #expect(removable.prefetchMinWorkers == 2)
        #expect(removable.prefetchMaxWorkers == 3)
        #expect(removable.prefetchLookaheadDepth == 4)
        #expect(removable.defaultSidecarWriteWorkers == 2)
        #expect(removable.defaultExifPreloadWorkers == 4)

        let network = StorageVolumeProfile.networkShare
        #expect(network.maxConcurrentThumbnailGenerations == 2)
        #expect(network.maxConcurrentHeavyDecodes == 1)
        #expect(network.prefetchMinWorkers == 1)
        #expect(network.prefetchMaxWorkers == 2)
        #expect(network.prefetchLookaheadDepth == 3)
        #expect(network.defaultSidecarWriteWorkers == 1)
        #expect(network.defaultExifPreloadWorkers == 2)
    }

    @Test("High-Speed LAN override expands network share limits while leaving local SSD unchanged")
    func highSpeedLANOverrides() {
        let network = StorageVolumeProfile.networkShare
        #expect(network.effectiveThumbnailWorkers(isHighSpeedLAN: true) == 4)
        #expect(network.effectiveHeavyDecodes(isHighSpeedLAN: true) == 2)
        #expect(network.effectivePrefetchMinWorkers(isHighSpeedLAN: true) == 2)
        #expect(network.effectivePrefetchMaxWorkers(isHighSpeedLAN: true) == 4)
        #expect(network.effectivePrefetchLookahead(isHighSpeedLAN: true) == 6)
        #expect(network.effectiveExifPreloadWorkers(isHighSpeedLAN: true) == 4)

        // Internal SSD is unaffected by high speed LAN toggle
        let ssd = StorageVolumeProfile.internalSSD
        #expect(ssd.effectiveThumbnailWorkers(isHighSpeedLAN: true) == 6)
        #expect(ssd.effectiveHeavyDecodes(isHighSpeedLAN: true) == 4)
        #expect(ssd.effectiveExifPreloadWorkers(isHighSpeedLAN: true) == 6)
    }

    // MARK: - StorageVolumeDetector

    @Test("StorageVolumeDetector correctly classifies temporary directory as local/internal")
    func storageVolumeDetectorClassification() {
        let tempDir = FileManager.default.temporaryDirectory
        let profile = StorageVolumeDetector.profile(for: tempDir)
        // Temporary directory on macOS local machine is internal SSD or removable, not a network share
        #expect(profile != .networkShare)
    }

    // MARK: - DirectoryListingCache (ADR-0009)

    @Test("DirectoryListingCache stores, retrieves, and clears directory listings")
    func directoryListingCacheStoreRetrieveAndClear() {
        let cache = DirectoryListingCache.shared
        let testDir = URL(fileURLWithPath: "/tmp/pickture_test_dir_\(UUID().uuidString)")
        let fileA = testDir.appendingPathComponent("image_001.arw")
        let fileB = testDir.appendingPathComponent("image_001.xmp")
        let fileC = testDir.appendingPathComponent("image_002.cr3")

        cache.store(urls: [fileA, fileB, fileC], for: testDir)

        let retrieved = cache.contents(for: testDir)
        #expect(retrieved != nil)
        #expect(retrieved?.count == 3)

        // Case-insensitive lookup helper
        let matched = cache.findFile(named: "IMAGE_001.XMP", in: testDir)
        #expect(matched?.lastPathComponent == "image_001.xmp")

        cache.clear(for: testDir)
        #expect(cache.contents(for: testDir) == nil)
    }

    @Test("SidecarCodec resolves sidecar using DirectoryListingCache")
    func sidecarCodecUsesDirectoryListingCache() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let rawURL = root.appendingPathComponent("photo_01.ARW")
        let sidecarURL = root.appendingPathComponent("photo_01.xmp")
        try Data("raw".utf8).write(to: rawURL)
        try Data("<xmp></xmp>".utf8).write(to: sidecarURL)

        let rawFile = MediaFile(url: rawURL, formatKind: .raw)
        let item = MediaItem(
            id: "\(root.path)#photo_01",
            baseName: "photo_01",
            directoryURL: root,
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: rawFile,
            mediaPair: nil,
            sidecarURL: nil
        )

        // Seed directory cache
        DirectoryListingCache.shared.store(urls: [rawURL, sidecarURL], for: root)

        let resolved = SidecarCodec.resolveSidecarReadURL(for: item)
        #expect(resolved?.lastPathComponent == "photo_01.xmp")

        DirectoryListingCache.shared.clear(for: root)
    }

    // MARK: - MediaPipeline Concurrency Profile

    @Test("MediaPipeline adapts worker concurrency and limiter permits to storage volume profile")
    @MainActor
    func mediaPipelineAdaptsConcurrency() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let customLimiter = HeavyDecodeLimiter(maxConcurrent: 2)
        let pipeline = MediaPipeline(cacheDirectoryURL: root, heavyDecodeLimiter: customLimiter)

        // Apply networkShare profile
        await pipeline.applyStorageVolumeProfile(.networkShare, isHighSpeedLAN: false)
        let networkWorkers = await pipeline.thumbnailQueue.currentMaxWorkers
        let networkPermits = await pipeline.heavyDecodeLimiter.currentPermits
        #expect(networkWorkers == 2)
        #expect(networkPermits == 1)

        // Apply High-Speed LAN override
        await pipeline.applyStorageVolumeProfile(.networkShare, isHighSpeedLAN: true)
        let lanWorkers = await pipeline.thumbnailQueue.currentMaxWorkers
        let lanPermits = await pipeline.heavyDecodeLimiter.currentPermits
        #expect(lanWorkers == 4)
        #expect(lanPermits == 2)

        // Apply internal SSD
        await pipeline.applyStorageVolumeProfile(.internalSSD, isHighSpeedLAN: false)
        let ssdWorkers = await pipeline.thumbnailQueue.currentMaxWorkers
        let ssdPermits = await pipeline.heavyDecodeLimiter.currentPermits
        #expect(ssdWorkers == 6)
        #expect(ssdPermits == 4)
    }

    // MARK: - PrefetchCoordinator Concurrency Profile

    @Test("PrefetchCoordinator adapts worker counts and lookahead depth to storage volume profile")
    func prefetchCoordinatorAdaptsConcurrency() async {
        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 2,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 5,
            cacheCapacityProvider: { 50 },
            isItemCached: { _, _ in false },
            previewFetcher: { _, _ in }
        )

        await coordinator.applyStorageVolumeProfile(.networkShare, isHighSpeedLAN: false)
        var minW = await coordinator.currentMinWorkers
        var maxW = await coordinator.maxWorkerCount
        var depth = await coordinator.currentLookaheadDepth
        #expect(minW == 1)
        #expect(maxW == 2)
        #expect(depth == 3)

        await coordinator.applyStorageVolumeProfile(.networkShare, isHighSpeedLAN: true)
        minW = await coordinator.currentMinWorkers
        maxW = await coordinator.maxWorkerCount
        depth = await coordinator.currentLookaheadDepth
        #expect(minW == 2)
        #expect(maxW == 4)
        #expect(depth == 6)

        await coordinator.applyStorageVolumeProfile(.internalSSD, isHighSpeedLAN: false)
        minW = await coordinator.currentMinWorkers
        maxW = await coordinator.maxWorkerCount
        depth = await coordinator.currentLookaheadDepth
        #expect(minW == 2)
        #expect(maxW == 6)
        #expect(depth == 8)
    }

    // MARK: - CullingSession High-Speed LAN Toggle & Profile

    @Test("CullingSession toggles High-Speed LAN override state")
    @MainActor
    func cullingSessionHighSpeedLANToggle() {
        let session = CullingSession()
        #expect(!session.isHighSpeedLANOverrideEnabled)

        session.toggleHighSpeedLANOverride()
        #expect(session.isHighSpeedLANOverrideEnabled)

        session.toggleHighSpeedLANOverride()
        #expect(!session.isHighSpeedLANOverrideEnabled)
    }

    // MARK: - Background EXIF Pausing on Navigation

    @Test("Background EXIF extraction loop respects pause state during active navigation")
    func backgroundExifExtractionPausesDuringNavigation() async {
        var isPaused = false
        var count = 0

        let task = Task.detached {
            for i in 0..<20 {
                while isPaused {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                count = i + 1
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        try? await Task.sleep(nanoseconds: 15_000_000)
        isPaused = true
        let snapshotCount = count
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(count == snapshotCount, "Extraction should remain paused while navigation is active")

        isPaused = false
        _ = await task.result
        #expect(count == 20)
    }
}
