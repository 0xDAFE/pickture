import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@Suite("PrefetchCoordinator Tests")
struct PrefetchCoordinatorTests {

    private func makeItem(id: String) -> MediaItem {
        let url = URL(fileURLWithPath: "/tmp/test/\(id).jpg")
        let file = MediaFile(url: url, formatKind: .raster)
        return MediaItem(
            id: id,
            baseName: id,
            directoryURL: url.deletingLastPathComponent(),
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: file,
            mediaPair: nil,
            sidecarURL: nil
        )
    }

    private func makeItems(count: Int) -> [MediaItem] {
        (0..<count).map { makeItem(id: "item_\($0)") }
    }

    @Test("Forward sequential navigation tracks forward direction and plans lookahead items")
    func forwardSequentialNavigationLookahead() async throws {
        let items = makeItems(count: 10)
        let prefetchedIDs = LockedArray<String>()

        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 2,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 3,
            idleDelayNanoseconds: 5_000_000_000, // Do not trigger idle warming during test
            cacheCapacityProvider: { 50 },
            isItemCached: { _, _ in false },
            previewFetcher: { item, _ in
                prefetchedIDs.append(item.id)
            }
        )

        // Select item 0
        await coordinator.navigate(selectedID: items[0].id, visibleItems: items, previewSource: .preferRaster)
        await coordinator.waitForPendingTasks()

        // Select item 1 (forward)
        prefetchedIDs.removeAll()
        await coordinator.navigate(selectedID: items[1].id, visibleItems: items, previewSource: .preferRaster)
        let direction1 = await coordinator.lastDirection
        #expect(direction1 == .forward)

        await coordinator.waitForPendingTasks()
        let fetched = prefetchedIDs.elements
        // Lookahead depth 3 forward from index 1 should fetch items 2, 3, 4
        #expect(fetched.contains("item_2"))
        #expect(fetched.contains("item_3"))
        #expect(fetched.contains("item_4"))
        #expect(!fetched.contains("item_0"))
    }

    @Test("Backward sequential navigation tracks backward direction and plans lookahead items")
    func backwardSequentialNavigationLookahead() async throws {
        let items = makeItems(count: 10)
        let prefetchedIDs = LockedArray<String>()

        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 2,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 3,
            idleDelayNanoseconds: 5_000_000_000,
            cacheCapacityProvider: { 50 },
            isItemCached: { _, _ in false },
            previewFetcher: { item, _ in
                prefetchedIDs.append(item.id)
            }
        )

        // Start at item 8
        await coordinator.navigate(selectedID: items[8].id, visibleItems: items, previewSource: .preferRaster)
        await coordinator.waitForPendingTasks()

        // Step back to item 7
        prefetchedIDs.removeAll()
        await coordinator.navigate(selectedID: items[7].id, visibleItems: items, previewSource: .preferRaster)
        let direction = await coordinator.lastDirection
        #expect(direction == .backward)

        await coordinator.waitForPendingTasks()
        let fetched = prefetchedIDs.elements
        // Lookahead depth 3 backward from index 7 should fetch items 6, 5, 4
        #expect(fetched.contains("item_6"))
        #expect(fetched.contains("item_5"))
        #expect(fetched.contains("item_4"))
        #expect(!fetched.contains("item_8"))
    }

    @Test("Random jump allocates prefetch depth symmetrically forward and backward")
    func randomJumpAllocatesSymmetrically() async throws {
        let items = makeItems(count: 20)
        let prefetchedIDs = LockedArray<String>()

        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 4,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 4,
            idleDelayNanoseconds: 5_000_000_000,
            cacheCapacityProvider: { 50 },
            isItemCached: { _, _ in false },
            previewFetcher: { item, _ in
                prefetchedIDs.append(item.id)
            }
        )

        // Select item 0
        await coordinator.navigate(selectedID: items[0].id, visibleItems: items, previewSource: .preferRaster)
        await coordinator.waitForPendingTasks()

        // Jump to item 10 (delta = 10, not sequential)
        prefetchedIDs.removeAll()
        await coordinator.navigate(selectedID: items[10].id, visibleItems: items, previewSource: .preferRaster)
        let direction = await coordinator.lastDirection
        #expect(direction == .jump)

        await coordinator.waitForPendingTasks()
        let fetched = prefetchedIDs.elements
        // Symmetrical: half forward (11, 12) and half backward (9, 8)
        #expect(fetched.contains("item_11"))
        #expect(fetched.contains("item_9"))
    }

    @Test("ADR-0007: Retains immediate predecessor i-1 during rapid sequential steps while cancelling older skipped items")
    func immediatePredecessorRetentionADR0007() async throws {
        let items = makeItems(count: 10)

        // We use slow fetcher to keep tasks in flight
        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 4,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 3,
            idleDelayNanoseconds: 5_000_000_000,
            cacheCapacityProvider: { 50 },
            isItemCached: { _, _ in false },
            previewFetcher: { _, _ in
                // Keep task running for 500ms
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        )

        // Step 0
        await coordinator.navigate(selectedID: items[0].id, visibleItems: items, previewSource: .preferRaster)
        // Step 1
        await coordinator.navigate(selectedID: items[1].id, visibleItems: items, previewSource: .preferRaster)

        let predecessorAtStep1 = await coordinator.immediatePredecessorID
        #expect(predecessorAtStep1 == items[0].id)

        // Step 2 immediately (rapid scrubbing)
        await coordinator.navigate(selectedID: items[2].id, visibleItems: items, previewSource: .preferRaster)

        let predecessorAtStep2 = await coordinator.immediatePredecessorID
        #expect(predecessorAtStep2 == items[1].id)

        let activeIDs = await coordinator.activeItemIDs
        // Item 0 (i-2) must NOT be active (cancelled per ADR-0007)
        #expect(!activeIDs.contains(items[0].id))
        // Predecessor is items[1].id
        #expect(predecessorAtStep2 == items[1].id)

        await coordinator.cancelAll()
    }

    @Test("Direction reversal cancels pending speculative prefetch tasks from previous direction")
    func directionReversalCancelsPendingTasks() async throws {
        let items = makeItems(count: 10)

        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 4,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 3,
            idleDelayNanoseconds: 5_000_000_000,
            cacheCapacityProvider: { 50 },
            isItemCached: { _, _ in false },
            previewFetcher: { _, _ in
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        )

        // Forward: 0 -> 1 -> 2
        await coordinator.navigate(selectedID: items[0].id, visibleItems: items, previewSource: .preferRaster)
        await coordinator.navigate(selectedID: items[1].id, visibleItems: items, previewSource: .preferRaster)
        await coordinator.navigate(selectedID: items[2].id, visibleItems: items, previewSource: .preferRaster)

        // Active forward items would be 3, 4, 5
        // Now reverse: 2 -> 1
        await coordinator.navigate(selectedID: items[1].id, visibleItems: items, previewSource: .preferRaster)
        let direction = await coordinator.lastDirection
        #expect(direction == .backward)

        let activeIDs = await coordinator.activeItemIDs
        // Forward tasks 3, 4, 5 should be cancelled
        #expect(!activeIDs.contains("item_3"))
        #expect(!activeIDs.contains("item_4"))
        #expect(!activeIDs.contains("item_5"))

        await coordinator.cancelAll()
    }

    @Test("Auto-extend parallelism ramps worker count on consecutive sequential steps and resets on reversal or jump")
    func autoExtendParallelismRampsAndResets() async throws {
        let items = makeItems(count: 20)

        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 2,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 4,
            idleDelayNanoseconds: 5_000_000_000,
            cacheCapacityProvider: { 50 },
            isItemCached: { _, _ in false },
            previewFetcher: { _, _ in }
        )

        // Initial selection: baseline workers
        await coordinator.navigate(selectedID: items[0].id, visibleItems: items, previewSource: .preferRaster)
        #expect(await coordinator.currentWorkerCount == 2)
        #expect(await coordinator.consecutiveSequentialSteps == 0)

        // Step 1: consecutive step 1
        await coordinator.navigate(selectedID: items[1].id, visibleItems: items, previewSource: .preferRaster)
        #expect(await coordinator.consecutiveSequentialSteps == 1)
        #expect(await coordinator.currentWorkerCount == 3)

        // Step 2: consecutive step 2 -> reaches max (4)
        await coordinator.navigate(selectedID: items[2].id, visibleItems: items, previewSource: .preferRaster)
        #expect(await coordinator.consecutiveSequentialSteps == 2)
        #expect(await coordinator.currentWorkerCount == 4)

        // Step 3: stays at max (4)
        await coordinator.navigate(selectedID: items[3].id, visibleItems: items, previewSource: .preferRaster)
        #expect(await coordinator.currentWorkerCount == 4)

        // Reverse direction: 3 -> 2 resets worker count to baseline
        await coordinator.navigate(selectedID: items[2].id, visibleItems: items, previewSource: .preferRaster)
        #expect(await coordinator.currentWorkerCount == 2)
        #expect(await coordinator.consecutiveSequentialSteps == 0)

        // Jump: 2 -> 10 resets worker count to baseline
        await coordinator.navigate(selectedID: items[10].id, visibleItems: items, previewSource: .preferRaster)
        #expect(await coordinator.currentWorkerCount == 2)
        #expect(await coordinator.consecutiveSequentialSteps == 0)
    }

    @Test("Cache-bounded depth invariant clamps prefetch depth to at most 1/2 of active cache capacity")
    func cacheBoundedDepthInvariant() async {
        let coordinator1 = PrefetchCoordinator(
            configuredLookaheadDepth: 10,
            cacheCapacityProvider: { 6 }, // 1/2 capacity = 3
            isItemCached: { _, _ in false },
            previewFetcher: { _, _ in }
        )
        #expect(await coordinator1.effectivePrefetchDepth == 3)

        let coordinator2 = PrefetchCoordinator(
            configuredLookaheadDepth: 10,
            cacheCapacityProvider: { 50 }, // 1/2 capacity = 25
            isItemCached: { _, _ in false },
            previewFetcher: { _, _ in }
        )
        #expect(await coordinator2.effectivePrefetchDepth == 10) // limited by configured 10

        let coordinator3 = PrefetchCoordinator(
            configuredLookaheadDepth: 10,
            cacheCapacityProvider: { 2 }, // 1/2 capacity = 1
            isItemCached: { _, _ in false },
            previewFetcher: { _, _ in }
        )
        #expect(await coordinator3.effectivePrefetchDepth == 1)
    }

    @Test("Idle prefetch warming triggers after configured delay and warms upcoming items")
    func idlePrefetchWarmingTriggersAfterDelay() async throws {
        let items = makeItems(count: 10)
        let prefetchedIDs = LockedArray<String>()

        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 2,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 3,
            idleDelayNanoseconds: 20_000_000, // 20ms for fast test execution
            cacheCapacityProvider: { 50 },
            isItemCached: { _, _ in false },
            previewFetcher: { item, _ in
                prefetchedIDs.append(item.id)
            }
        )

        // Select item 0
        await coordinator.navigate(selectedID: items[0].id, visibleItems: items, previewSource: .preferRaster)
        await coordinator.waitForPendingTasks()
        prefetchedIDs.removeAll()

        // Wait for idle warming to fire (delay is 20ms) and complete
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !prefetchedIDs.elements.isEmpty { break }
        }

        let fetched = prefetchedIDs.elements
        #expect(!fetched.isEmpty)
        #expect(fetched.contains("item_1") || fetched.contains("item_2"))

        await coordinator.cancelAll()
    }

    @Test("Idle prefetch warming suspends under Low Power Mode or metered network")
    func idlePrefetchWarmingSuspendsUnderLowPowerOrMetered() async throws {
        let items = makeItems(count: 10)
        let prefetchedIDs = LockedArray<String>()

        let coordinator = PrefetchCoordinator(
            baselineWorkerCount: 2,
            maxWorkerCount: 4,
            configuredLookaheadDepth: 3,
            idleDelayNanoseconds: 20_000_000,
            cacheCapacityProvider: { 50 },
            lowPowerModeProvider: { true }, // Low Power Mode active!
            meteredNetworkProvider: { false },
            isItemCached: { _, _ in false },
            previewFetcher: { item, _ in
                prefetchedIDs.append(item.id)
            }
        )

        // Select item 0
        await coordinator.navigate(selectedID: items[0].id, visibleItems: items, previewSource: .preferRaster)
        await coordinator.waitForPendingTasks()
        prefetchedIDs.removeAll()

        // Wait 60ms
        try await Task.sleep(nanoseconds: 60_000_000)

        // Idle warming must NOT have run
        #expect(prefetchedIDs.elements.isEmpty)
        #expect(await coordinator.isIdleWarmingActive == false)

        await coordinator.cancelAll()
    }

    @Test("CullingSession navigation integrates PrefetchCoordinator and pre-warms previews in DecodedImageCache")
    @MainActor
    func cullingSessionNavigationIntegratesPrefetchCoordinator() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for i in 1...5 {
            let fileURL = tempDir.appendingPathComponent("IMG_00\(i).JPG")
            try writeSampleRasterImage(to: fileURL)
        }

        let storeURL = tempDir.appendingPathComponent(".session-store")
        let session = CullingSession(storageRootURL: storeURL)
        try session.openFolder(at: tempDir)
        #expect(session.items.count == 5)

        // Select item 0
        session.selectedItemID = session.items[0].id
        // Step forward to item 1
        session.selectNextItem()
        #expect(session.selectedItemID == session.items[1].id)

        // Allow triggerPrefetch task to dispatch and wait for prefetch lookahead to complete
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        await session.prefetchCoordinator.waitForPendingTasks()

        // Upcoming item 2 should be pre-warmed in DecodedImageCache
        let prewarmedItem2 = session.items[2]
        let cached = session.cachedPreviewImage(for: prewarmedItem2, maxPixelSize: 2048)
        #expect(cached != nil)
    }

    private func writeSampleRasterImage(to url: URL, width: Int = 80, height: Int = 80) throws {
        var pixels = [UInt8](repeating: 120, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) {
            pixels[i] = 255
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
        try (mutableData as Data).write(to: url)
    }
}

/// Thread-safe array helper for test assertions.
final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []

    var elements: [T] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: T) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
