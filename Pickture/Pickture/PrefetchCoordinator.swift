import CoreGraphics
import Foundation

/// Coordinates directional lookahead speculative prefetching and idle background warming.
///
/// Features:
/// - Direction tracking: speculatively prefetches preview images in the active browsing direction
///   (forward, backward, or symmetrical on jumps).
/// - ADR-0007 compliance: retains the immediate predecessor (i-1) during rapid scrubbing while cancelling
///   older skipped items (i-2, i-3, ...).
/// - Auto-extending parallelism: ramps up concurrent workers from baseline (2) up to maximum limit
///   during sequential navigation, resetting upon pause (>1.5s) or direction reversal.
/// - Idle warming engine: triggers sequential pre-decoding of upcoming visible items after 1.5s idle.
/// - Power & metered network awareness: suspends idle warming under Low Power Mode or metered networks.
/// - Cache-bounded depth: limits prefetch depth to at most 1/2 of active in-memory cache capacity.
actor PrefetchCoordinator {
    enum Direction: String, Sendable, Equatable {
        case forward
        case backward
        case jump
        case stationary
    }

    typealias PreviewFetcher = @Sendable (MediaItem, PreviewSource) async -> Void
    typealias CacheChecker = @Sendable (MediaItem, PreviewSource) -> Bool
    typealias BoolProvider = @Sendable () -> Bool

    private let previewFetcher: PreviewFetcher
    private let isItemCached: CacheChecker
    private let lowPowerModeProvider: BoolProvider
    private let meteredNetworkProvider: BoolProvider

    private(set) var lastSelectedIndex: Int?
    private(set) var lastSelectedID: String?
    private(set) var immediatePredecessorID: String?
    private(set) var lastDirection: Direction = .stationary

    // Parallelism settings
    private(set) var baselineWorkerCount: Int
    private(set) var maxWorkerCount: Int
    private(set) var currentWorkerCount: Int
    private(set) var consecutiveSequentialSteps: Int = 0
    private var lastNavigationInstant: ContinuousClock.Instant?

    // Depth settings
    var configuredLookaheadDepth: Int
    var cacheCapacityProvider: @Sendable () -> Int

    var currentMinWorkers: Int { baselineWorkerCount }
    var currentLookaheadDepth: Int { configuredLookaheadDepth }

    // Active prefetch tasks: [ItemID: Task<Void, Never>]
    private var activePrefetchTasks: [String: Task<Void, Never>] = [:]
    private var pendingTargetItems: [MediaItem] = []
    private var activePreviewSource: PreviewSource = .preferRaster

    // Idle warming
    private var idleTimerTask: Task<Void, Never>?
    var isIdleWarmingEnabled: Bool = true
    let idleDelayNanoseconds: UInt64
    private(set) var isIdleWarmingActive: Bool = false
    private(set) var idleWarmingExecutionCount: Int = 0

    init(
        baselineWorkerCount: Int = 2,
        maxWorkerCount: Int = 4,
        configuredLookaheadDepth: Int = 5,
        idleDelayNanoseconds: UInt64 = 1_500_000_000,
        cacheCapacityProvider: @escaping @Sendable () -> Int = { DecodedImageCache.shared.countLimit },
        lowPowerModeProvider: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        meteredNetworkProvider: @escaping @Sendable () -> Bool = { false },
        isItemCached: @escaping CacheChecker,
        previewFetcher: @escaping PreviewFetcher
    ) {
        self.baselineWorkerCount = baselineWorkerCount
        self.maxWorkerCount = maxWorkerCount
        self.currentWorkerCount = baselineWorkerCount
        self.configuredLookaheadDepth = configuredLookaheadDepth
        self.idleDelayNanoseconds = idleDelayNanoseconds
        self.cacheCapacityProvider = cacheCapacityProvider
        self.lowPowerModeProvider = lowPowerModeProvider
        self.meteredNetworkProvider = meteredNetworkProvider
        self.isItemCached = isItemCached
        self.previewFetcher = previewFetcher
    }

    var effectivePrefetchDepth: Int {
        let capacity = cacheCapacityProvider()
        let maxAllowed = max(1, capacity / 2)
        return min(configuredLookaheadDepth, maxAllowed)
    }

    func applyStorageVolumeProfile(_ profile: StorageVolumeProfile, isHighSpeedLAN: Bool = false) {
        if profile == .networkShare && isHighSpeedLAN {
            self.baselineWorkerCount = 2
            self.maxWorkerCount = 4
            self.configuredLookaheadDepth = 6
        } else {
            let workers = profile.defaultPrefetchWorkers
            self.baselineWorkerCount = workers.baseline
            self.maxWorkerCount = workers.max
            self.configuredLookaheadDepth = profile.defaultLookaheadDepth
        }
        self.currentWorkerCount = min(maxWorkerCount, max(baselineWorkerCount, currentWorkerCount))
    }

    var activeTaskCount: Int {
        activePrefetchTasks.count
    }

    var activeItemIDs: Set<String> {
        Set(activePrefetchTasks.keys)
    }

    func navigate(
        selectedID: String?,
        visibleItems: [MediaItem],
        previewSource: PreviewSource
    ) {
        // 1. Cancel existing idle warming & timer
        cancelIdleWarming()

        guard let selectedID,
              let currentIndex = visibleItems.firstIndex(where: { $0.id == selectedID }) else {
            cancelAll()
            lastSelectedIndex = nil
            lastSelectedID = nil
            immediatePredecessorID = nil
            return
        }

        let previousIndex = lastSelectedIndex
        let previousID = lastSelectedID

        // Same item selected?
        if currentIndex == previousIndex && selectedID == previousID {
            lastDirection = .stationary
            scheduleIdleWarming(visibleItems: visibleItems, currentIndex: currentIndex, previewSource: previewSource)
            return
        }

        // 2. Determine delta and direction
        let direction: Direction
        let isSequential: Bool

        if let prev = previousIndex {
            let delta = currentIndex - prev
            if delta == 1 {
                direction = .forward
                isSequential = true
            } else if delta == -1 {
                direction = .backward
                isSequential = true
            } else if delta > 1 && delta <= 3 {
                // Small leap in forward direction (e.g. rapid key repeat or skipping a reject)
                direction = .forward
                isSequential = false
            } else if delta < -1 && delta >= -3 {
                // Small leap in backward direction
                direction = .backward
                isSequential = false
            } else {
                direction = .jump
                isSequential = false
            }
        } else {
            direction = .jump
            isSequential = false
        }

        // 3. Update parallelism / worker count
        let now = ContinuousClock.now
        let elapsedSinceLastNav: Duration? = lastNavigationInstant.map { now - $0 }
        let isWithinPauseThreshold = (elapsedSinceLastNav ?? .seconds(10)) < .milliseconds(1500)
        let isReversal = (direction == .forward && lastDirection == .backward) ||
                         (direction == .backward && lastDirection == .forward)

        if isSequential && !isReversal && isWithinPauseThreshold {
            consecutiveSequentialSteps += 1
            currentWorkerCount = min(maxWorkerCount, baselineWorkerCount + consecutiveSequentialSteps)
        } else {
            consecutiveSequentialSteps = 0
            currentWorkerCount = baselineWorkerCount
        }
        lastNavigationInstant = now

        // 4. ADR-0007: Immediate Predecessor Retention and Old Skipped Task Cancellation
        let predecessorID: String?
        if isSequential, let prev = previousIndex, prev >= 0, prev < visibleItems.count {
            predecessorID = visibleItems[prev].id
        } else {
            predecessorID = nil
        }
        immediatePredecessorID = predecessorID

        // 5. Plan prefetch target candidate indices
        let targetIndices = candidateIndices(
            currentIndex: currentIndex,
            direction: direction,
            totalCount: visibleItems.count
        )

        // Retain tasks for:
        // - Selected frame
        // - Immediate predecessor (ADR-0007)
        // - Lookahead candidates in the active direction (avoids cancel/requeue churn during scrub)
        var retainedIDs: Set<String> = [selectedID]
        if let predecessorID {
            retainedIDs.insert(predecessorID)
        }
        for idx in targetIndices {
            retainedIDs.insert(visibleItems[idx].id)
        }

        // Cancel tasks that are outside our retained working set
        for (itemID, task) in activePrefetchTasks {
            if !retainedIDs.contains(itemID) {
                task.cancel()
                activePrefetchTasks.removeValue(forKey: itemID)
            }
        }

        lastSelectedIndex = currentIndex
        lastSelectedID = selectedID
        lastDirection = direction

        // 6. Filter target items for those not yet cached and not already running in flight
        let targetItems = targetIndices.compactMap { idx -> MediaItem? in
            let item = visibleItems[idx]
            if isItemCached(item, previewSource) || activePrefetchTasks[item.id] != nil {
                return nil
            }
            return item
        }

        // 7. Schedule prefetch tasks bounded by currentWorkerCount
        schedulePrefetch(
            for: targetItems,
            previewSource: previewSource
        )

        // 8. Schedule idle timer
        scheduleIdleWarming(
            visibleItems: visibleItems,
            currentIndex: currentIndex,
            previewSource: previewSource
        )
    }

    private func candidateIndices(
        currentIndex: Int,
        direction: Direction,
        totalCount: Int
    ) -> [Int] {
        let depth = effectivePrefetchDepth
        guard depth > 0, totalCount > 0 else { return [] }

        var targetIndices: [Int] = []

        switch direction {
        case .forward:
            for offset in 1...depth {
                let idx = currentIndex + offset
                if idx < totalCount {
                    targetIndices.append(idx)
                }
            }
        case .backward:
            for offset in 1...depth {
                let idx = currentIndex - offset
                if idx >= 0 {
                    targetIndices.append(idx)
                }
            }
        case .jump, .stationary:
            let half = max(1, depth / 2)
            for offset in 1...half {
                let forwardIdx = currentIndex + offset
                if forwardIdx < totalCount {
                    targetIndices.append(forwardIdx)
                }
                let backwardIdx = currentIndex - offset
                if backwardIdx >= 0 {
                    targetIndices.append(backwardIdx)
                }
            }
        }

        return targetIndices
    }

    private func schedulePrefetch(
        for items: [MediaItem],
        previewSource: PreviewSource
    ) {
        pendingTargetItems = items
        activePreviewSource = previewSource
        drainPrefetchQueue()
    }

    private func drainPrefetchQueue() {
        while activePrefetchTasks.count < currentWorkerCount, !pendingTargetItems.isEmpty {
            let item = pendingTargetItems.removeFirst()
            let itemID = item.id
            if activePrefetchTasks[itemID] != nil || isItemCached(item, activePreviewSource) {
                continue
            }
            let source = activePreviewSource
            let task = Task(priority: .medium) { [weak self, previewFetcher] in
                guard !Task.isCancelled else { return }
                await previewFetcher(item, source)
                await self?.taskDidComplete(itemID: itemID)
            }
            activePrefetchTasks[itemID] = task
        }
    }

    private func taskDidComplete(itemID: String) {
        activePrefetchTasks.removeValue(forKey: itemID)
        drainPrefetchQueue()
    }

    private func scheduleIdleWarming(
        visibleItems: [MediaItem],
        currentIndex: Int,
        previewSource: PreviewSource
    ) {
        guard isIdleWarmingEnabled else { return }
        idleTimerTask?.cancel()
        idleTimerTask = Task(priority: .userInitiated) { [weak self, idleDelayNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: idleDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runIdleWarming(
                visibleItems: visibleItems,
                currentIndex: currentIndex,
                previewSource: previewSource
            )
        }
    }

    private func runIdleWarming(
        visibleItems: [MediaItem],
        currentIndex: Int,
        previewSource: PreviewSource
    ) async {
        guard !lowPowerModeProvider(), !meteredNetworkProvider() else { return }
        guard !Task.isCancelled else { return }

        isIdleWarmingActive = true
        idleWarmingExecutionCount += 1
        defer { isIdleWarmingActive = false }

        let depth = effectivePrefetchDepth
        guard depth > 0, !visibleItems.isEmpty else { return }

        var warmIndices: [Int] = []
        for offset in 1...depth {
            let idx = currentIndex + offset
            if idx < visibleItems.count {
                warmIndices.append(idx)
            }
        }
        for offset in 1...depth {
            let idx = currentIndex - offset
            if idx >= 0 {
                warmIndices.append(idx)
            }
        }

        for idx in warmIndices {
            guard !Task.isCancelled else { break }
            let item = visibleItems[idx]
            if !isItemCached(item, previewSource) {
                await previewFetcher(item, previewSource)
                await Task.yield()
            }
        }
    }

    private func cancelIdleWarming() {
        idleTimerTask?.cancel()
        idleTimerTask = nil
        isIdleWarmingActive = false
    }

    func cancelAll() {
        cancelIdleWarming()
        pendingTargetItems.removeAll()
        for (_, task) in activePrefetchTasks {
            task.cancel()
        }
        activePrefetchTasks.removeAll()
        consecutiveSequentialSteps = 0
        currentWorkerCount = baselineWorkerCount
    }

    func waitForPendingTasks() async {
        while !activePrefetchTasks.isEmpty || !pendingTargetItems.isEmpty || isIdleWarmingActive {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func waitForIdleWarming() async {
        if let task = idleTimerTask {
            _ = await task.value
        }
    }
}
