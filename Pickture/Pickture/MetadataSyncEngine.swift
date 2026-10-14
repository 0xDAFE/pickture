import Foundation
import Observation
import OSLog

/// Bounded LIFO queue for cell on-demand metadata hydration requests with cooperative task cancellation.
actor HydrationQueueActor {
    private var maxConcurrentWorkers: Int
    private var activeWorkers: Int = 0

    private struct PendingRequest {
        let id: String
        let execute: @Sendable () async -> Void
        let cancel: @Sendable () -> Void
    }

    private var pendingQueue: [PendingRequest] = []
    private var activeTasks: [String: Task<Void, Never>] = [:]

    init(maxConcurrentWorkers: Int = 4) {
        self.maxConcurrentWorkers = max(1, maxConcurrentWorkers)
    }

    func setMaxConcurrentWorkers(_ count: Int) {
        self.maxConcurrentWorkers = max(1, count)
        pump()
    }

    var currentMaxWorkers: Int {
        maxConcurrentWorkers
    }

    var pendingCount: Int {
        pendingQueue.count
    }

    var activeCount: Int {
        activeWorkers
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

    func cancelAll() {
        for request in pendingQueue {
            request.cancel()
        }
        pendingQueue.removeAll()
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
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

@MainActor
@Observable
final class MetadataSyncEngine {
    @ObservationIgnored
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pickture", category: "sync")

    let syncStore: MetadataSyncStore

    // MARK: - In-Memory Caches & Sync State

    private(set) var metadataByItemID: [String: CurationMetadata] = [:]
    private(set) var syncStateByItemID: [String: SyncState] = [:]
    private(set) var baseSnapshotByItemID: [String: BaseSnapshot] = [:]
    private(set) var conflictsByItemID: [String: MetadataConflict] = [:]
    private(set) var currentItems: [MediaItem] = []

    // MARK: - Flush Queue & Debounce Configuration

    var flushDebounceNanoseconds: UInt64 = 500_000_000
    var simulatedFlushDelayNanoseconds: UInt64 = 0
    private(set) var storageVolumeProfile: StorageVolumeProfile = .internalSSD
    private(set) var isHighSpeedLAN: Bool = false

    @ObservationIgnored
    let hydrationQueue: HydrationQueueActor

    @ObservationIgnored
    private(set) var inFlightHydrations: [String: Task<Void, Never>] = [:]

    var hydrationBatchDebounceNanoseconds: UInt64 = 300_000_000

    @ObservationIgnored
    private(set) var pendingHydrationBatch: [HydrationResult] = []

    @ObservationIgnored
    private var debouncedHydrationFlushTask: Task<Void, Never>? = nil

    func setStorageVolumeProfile(_ profile: StorageVolumeProfile, isHighSpeedLAN: Bool = false) {
        self.storageVolumeProfile = profile
        self.isHighSpeedLAN = isHighSpeedLAN
        let workers = profile.effectiveSidecarHydrationWorkers(isHighSpeedLAN: isHighSpeedLAN)
        Task { [hydrationQueue] in
            await hydrationQueue.setMaxConcurrentWorkers(workers)
        }
    }

    var isSyncSuspended: Bool = false {
        didSet {
            if !isSyncSuspended {
                scheduleFlushPendingWrites()
            }
        }
    }

    private(set) var isFlushingPendingWrites: Bool = false

    @ObservationIgnored
    private var debouncedFlushTask: Task<Void, Never>? = nil

    @ObservationIgnored
    private var activeFlushTask: Task<Void, Never>? = nil

    @ObservationIgnored
    private var backgroundHydrationTask: Task<Void, Never>? = nil

    @ObservationIgnored
    private var pendingStoreTask: Task<Void, Never>? = nil

    func enqueueStoreOperation(_ operation: @escaping @Sendable () async -> Void) {
        let previous = pendingStoreTask
        pendingStoreTask = Task {
            _ = await previous?.value
            await operation()
        }
    }

    func waitForPendingStoreWrites() async {
        await pendingStoreTask?.value
    }

    // MARK: - Integrations & Observation Callbacks

    @ObservationIgnored
    var itemsProvider: (() -> [MediaItem])?

    @ObservationIgnored
    var onStateChange: (() -> Void)?

    @ObservationIgnored
    var onSyncError: ((Error, MediaItem) -> Void)?

    @ObservationIgnored
    var onExifDiscovered: ((String, ExifMetadata) -> Void)?

    @ObservationIgnored
    var existingExifProvider: ((String) -> ExifMetadata?)?

    // MARK: - Initialization

    init(storeDirectoryURL: URL) {
        self.syncStore = MetadataSyncStore(storeDirectoryURL: storeDirectoryURL)
        self.hydrationQueue = HydrationQueueActor(maxConcurrentWorkers: StorageVolumeProfile.internalSSD.defaultSidecarHydrationWorkers)
    }

    init(syncStore: MetadataSyncStore) {
        self.syncStore = syncStore
        self.hydrationQueue = HydrationQueueActor(maxConcurrentWorkers: StorageVolumeProfile.internalSSD.defaultSidecarHydrationWorkers)
    }

    func resolvedItems(_ items: [MediaItem]? = nil) -> [MediaItem] {
        if let items { return items }
        if let fromProvider = itemsProvider?() { return fromProvider }
        return currentItems
    }

    // MARK: - Summary States

    var pendingWritesCount: Int {
        syncStateByItemID.values.filter { $0 == .pendingWrite }.count
    }

    var conflictedItemsCount: Int {
        syncStateByItemID.values.filter { $0 == .conflicted }.count
    }

    var syncErrorItemsCount: Int {
        syncStateByItemID.values.filter { $0 == .syncError }.count
    }

    var syncSummaryState: SyncState {
        if conflictedItemsCount > 0 {
            return .conflicted
        }
        if syncErrorItemsCount > 0 {
            return .syncError
        }
        if syncStateByItemID.values.contains(.loading) {
            return .loading
        }
        if pendingWritesCount > 0 {
            return .pendingWrite
        }
        return .synced
    }

    var syncSummaryBadgeText: String {
        let conflicts = conflictedItemsCount
        if conflicts > 0 {
            return "\(conflicts) Conflict\(conflicts == 1 ? "" : "s")"
        }
        let errors = syncErrorItemsCount
        if errors > 0 {
            return "\(errors) Error\(errors == 1 ? "" : "s")"
        }
        let pending = pendingWritesCount
        if pending > 0 {
            return "\(pending) Pending"
        }
        return "Synced"
    }

    func conflictedItems(from items: [MediaItem]) -> [MediaItem] {
        items.filter { syncState(for: $0.id) == .conflicted }
    }

    var conflictedItems: [MediaItem] {
        conflictedItems(from: resolvedItems())
    }

    func activeConflictItem(selectedItemID: String?, from items: [MediaItem]) -> MediaItem? {
        let conflicted = conflictedItems(from: items)
        guard let selectedItemID else { return conflicted.first }
        return items.first { $0.id == selectedItemID } ?? conflicted.first
    }

    func activeConflictItem(selectedItemID: String?) -> MediaItem? {
        activeConflictItem(selectedItemID: selectedItemID, from: resolvedItems())
    }

    // MARK: - Curation Metadata, Sync State & Conflict Queries

    func curationMetadata(for itemID: String) -> CurationMetadata {
        if let local = metadataByItemID[itemID] {
            return local
        }
        if let persisted = syncStore.cachedRecord(for: itemID) {
            return persisted.metadata
        }
        return CurationMetadata()
    }

    func curationMetadata(for item: MediaItem) -> CurationMetadata {
        curationMetadata(for: item.id)
    }

    func syncState(for itemID: String) -> SyncState {
        if let state = syncStateByItemID[itemID] {
            return state
        }
        if let persisted = syncStore.cachedRecord(for: itemID) {
            return persisted.syncState
        }
        return .synced
    }

    func syncState(for item: MediaItem) -> SyncState {
        syncState(for: item.id)
    }

    func baseSnapshot(for itemID: String) -> BaseSnapshot? {
        if let local = baseSnapshotByItemID[itemID] {
            return local
        }
        return syncStore.cachedRecord(for: itemID)?.baseSnapshot
    }

    func baseSnapshot(for item: MediaItem) -> BaseSnapshot? {
        baseSnapshot(for: item.id)
    }

    func conflict(for itemID: String) -> MetadataConflict? {
        if let local = conflictsByItemID[itemID] {
            return local
        }
        return syncStore.cachedRecord(for: itemID)?.conflict
    }

    func conflict(for item: MediaItem) -> MetadataConflict? {
        conflict(for: item.id)
    }

    // MARK: - Optimistic Curation Staging

    func stagePendingMetadata(_ metadata: CurationMetadata, for item: MediaItem) {
        updateCurationMetadata(metadata, for: item)
    }

    func updateCurationMetadata(_ metadata: CurationMetadata, for item: MediaItem) {
        updateCurationMetadata(metadata, for: item.id)
    }

    func updateCurationMetadata(_ metadata: CurationMetadata, for itemID: String) {
        let base = baseSnapshot(for: itemID)
        metadataByItemID[itemID] = metadata
        syncStateByItemID[itemID] = .pendingWrite
        conflictsByItemID.removeValue(forKey: itemID)
        enqueueStoreOperation { [syncStore] in
            await syncStore.stagePendingWrite(metadata, baseSnapshot: base, for: itemID)
        }
        onStateChange?()

        if !isSyncSuspended {
            scheduleFlushPendingWrites()
        }
    }

    // MARK: - Flush Queue & Sidecar Writes

    func scheduleFlushPendingWrites() {
        guard !isSyncSuspended else { return }
        debouncedFlushTask?.cancel()
        debouncedFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.flushDebounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: self.flushDebounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self.debouncedFlushTask = nil
            await self.flushPendingWrites()
        }
    }

    func flushPendingWrites() async {
        debouncedFlushTask?.cancel()
        debouncedFlushTask = nil
        while !Task.isCancelled {
            if let existing = activeFlushTask {
                await existing.value
            } else {
                let allItems = resolvedItems()
                let pendingCount = allItems.filter { syncState(for: $0.id) == .pendingWrite }.count
                guard pendingCount > 0 else { break }

                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isFlushingPendingWrites = true
                    defer {
                        self.isFlushingPendingWrites = false
                        self.activeFlushTask = nil
                    }
                    await self.performPendingWritesFlush()
                }
                activeFlushTask = task
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            let remainingPending = resolvedItems().contains { syncState(for: $0.id) == .pendingWrite }
            if !remainingPending {
                break
            }
        }
    }

    func flushPendingWrites(in items: [MediaItem]) async {
        currentItems = items
        await flushPendingWrites()
    }

    private struct FlushTaskResult: Sendable {
        let item: MediaItem
        let pendingCuration: CurationMetadata
        let outcome: Result<FlushOutcome, Error>
    }

    private func performPendingWritesFlush() async {
        while !Task.isCancelled {
            let pending = resolvedItems().filter { syncState(for: $0.id) == .pendingWrite }
            guard !pending.isEmpty else { break }

            let maxWorkers = max(1, storageVolumeProfile.defaultSidecarWriteWorkers)

            if simulatedFlushDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: simulatedFlushDelayNanoseconds)
            }
            if Task.isCancelled { break }

            await withTaskGroup(of: FlushTaskResult.self) { group in
                var inFlight = 0
                for item in pending {
                    if Task.isCancelled { break }
                    guard syncState(for: item.id) == .pendingWrite else { continue }

                    let pendingCuration = curationMetadata(for: item.id)
                    let base = baseSnapshot(for: item.id)

                    // Mark as loading on MainActor
                    syncStateByItemID[item.id] = .loading
                    onStateChange?()

                    if inFlight >= maxWorkers {
                        if let result = await group.next() {
                            inFlight -= 1
                            await self.applyFlushResult(result)
                        }
                    }

                    inFlight += 1
                    group.addTask {
                        do {
                            let outcome = try await Self.performDiskFlush(
                                item: item,
                                pendingCuration: pendingCuration,
                                base: base
                            )
                            return FlushTaskResult(item: item, pendingCuration: pendingCuration, outcome: .success(outcome))
                        } catch {
                            return FlushTaskResult(item: item, pendingCuration: pendingCuration, outcome: .failure(error))
                        }
                    }
                }

                while let result = await group.next() {
                    await self.applyFlushResult(result)
                }
            }
        }
    }

    private func applyFlushResult(_ result: FlushTaskResult) async {
        let item = result.item
        guard syncStateByItemID[item.id] == .loading else { return }

        switch result.outcome {
        case .success(let outcome):
            switch outcome {
            case .conflict(let conflict):
                syncStateByItemID[item.id] = .conflicted
                conflictsByItemID[item.id] = conflict
                await syncStore.recordConflict(conflict, for: item.id)

            case .success(let newBase):
                metadataByItemID[item.id] = newBase.metadata
                baseSnapshotByItemID[item.id] = newBase
                syncStateByItemID[item.id] = .synced
                conflictsByItemID.removeValue(forKey: item.id)
                await syncStore.markSynced(for: item.id, baseSnapshot: newBase)
            }
            onStateChange?()

        case .failure(let error):
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            Self.logger.error("Flush error on \(item.displayFileName, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) underlying=\(underlying?.domain ?? "none", privacy: .public)(\(underlying?.code ?? -1)) desc=\(error.localizedDescription, privacy: .public)")

            syncStateByItemID[item.id] = .syncError
            await syncStore.updateSyncState(.syncError, for: item.id)
            onSyncError?(error, item)
            onStateChange?()
        }
    }

    func flushPendingWrite(for itemID: String, in items: [MediaItem]) async throws {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        try await flushPendingWrite(for: item)
    }

    func flushPendingWrite(for itemID: String) async throws {
        guard let item = resolvedItems().first(where: { $0.id == itemID }) else { return }
        try await flushPendingWrite(for: item)
    }

    enum FlushOutcome: Sendable {
        case conflict(MetadataConflict)
        case success(BaseSnapshot)
    }

    nonisolated static func performDiskFlush(
        item: MediaItem,
        pendingCuration: CurationMetadata,
        base: BaseSnapshot?
    ) async throws -> FlushOutcome {
        let readURL = await SidecarCodec.resolveSidecarReadURL(for: item)
        var diskCuration: CurationMetadata? = nil
        var diskDigest = ""

        if let readURL, let data = try? Data(contentsOf: readURL) {
            diskDigest = SidecarCodec.computeDigest(for: data)
            if let parsed = try? SidecarCodec.parse(data: data) {
                diskCuration = parsed.curation
            }
        }

        let remoteDigestChanged = (base?.fileDigest != diskDigest)

        let mergeEvaluation = XMPConflictEngine.evaluateThreeWay(
            itemID: item.id,
            base: base,
            local: pendingCuration,
            remote: diskCuration,
            remoteDigestChanged: remoteDigestChanged
        )

        let curationToWrite: CurationMetadata

        switch mergeEvaluation {
        case .conflict(let conflict):
            return .conflict(conflict)

        case .cleanMerge(let mergedCuration):
            if diskCuration == nil && pendingCuration == base?.metadata {
                return .success(BaseSnapshot(metadata: CurationMetadata(), fileDigest: ""))
            }
            curationToWrite = mergedCuration

        case .noChange:
            curationToWrite = pendingCuration
        }

        let writtenTargets = try await SidecarCodec.write(curation: curationToWrite, for: item)

        if let primaryTarget = writtenTargets.first, let writtenData = try? Data(contentsOf: primaryTarget) {
            let newDigest = SidecarCodec.computeDigest(for: writtenData)
            let modDate = (try? primaryTarget.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let newBase = BaseSnapshot(metadata: curationToWrite, fileDigest: newDigest, modificationDate: modDate)
            return .success(newBase)
        } else {
            let fallbackBase = BaseSnapshot(metadata: curationToWrite, fileDigest: "")
            return .success(fallbackBase)
        }
    }

    func flushPendingWrite(for item: MediaItem) async throws {
        let pendingCuration = curationMetadata(for: item.id)
        let base = baseSnapshot(for: item.id)

        syncStateByItemID[item.id] = .loading
        onStateChange?()

        do {
            let outcome = try await Self.performDiskFlush(
                item: item,
                pendingCuration: pendingCuration,
                base: base
            )
            await applyFlushResult(FlushTaskResult(item: item, pendingCuration: pendingCuration, outcome: .success(outcome)))
        } catch {
            await applyFlushResult(FlushTaskResult(item: item, pendingCuration: pendingCuration, outcome: .failure(error)))
            throw error
        }
    }

    // MARK: - Conflict Resolution

    nonisolated static func writeAndCreateSnapshot(curation: CurationMetadata, for item: MediaItem) async throws -> BaseSnapshot {
        let writtenTargets = try await SidecarCodec.write(curation: curation, for: item)
        let fallbackURL = await SidecarCodec.resolveSidecarReadURL(for: item)
        let primaryTarget = writtenTargets.first ?? fallbackURL
        let writtenData = primaryTarget.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let digest = SidecarCodec.computeDigest(for: writtenData)
        let modDate = primaryTarget.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        return BaseSnapshot(metadata: curation, fileDigest: digest, modificationDate: modDate)
    }

    nonisolated static func readRemoteSnapshot(for item: MediaItem, resolvedMetadata: CurationMetadata) async -> BaseSnapshot {
        let readURL = await SidecarCodec.resolveSidecarReadURL(for: item)
        let diskData = readURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let digest = SidecarCodec.computeDigest(for: diskData)
        let modDate = readURL.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        return BaseSnapshot(metadata: resolvedMetadata, fileDigest: digest, modificationDate: modDate)
    }

    func resolveConflict(for item: MediaItem, strategy: ConflictResolutionStrategy) async throws {
        guard let conflict = conflict(for: item.id) else { return }

        let resolvedMetadata: CurationMetadata
        let newBase: BaseSnapshot

        switch strategy {
        case .useRemote:
            resolvedMetadata = conflict.remote
            newBase = await Self.readRemoteSnapshot(for: item, resolvedMetadata: resolvedMetadata)

        case .useLocal:
            resolvedMetadata = conflict.local
            newBase = try await Self.writeAndCreateSnapshot(curation: resolvedMetadata, for: item)

        case .cherryPick(let custom):
            resolvedMetadata = custom
            newBase = try await Self.writeAndCreateSnapshot(curation: resolvedMetadata, for: item)
        }

        metadataByItemID[item.id] = resolvedMetadata
        syncStateByItemID[item.id] = .synced
        baseSnapshotByItemID[item.id] = newBase
        conflictsByItemID.removeValue(forKey: item.id)
        await syncStore.resolveConflict(for: item.id, resolvedMetadata: resolvedMetadata, newBaseSnapshot: newBase)
        onStateChange?()
    }

    func resolveConflict(for itemID: String, in items: [MediaItem], strategy: ConflictResolutionStrategy) async throws {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        try await resolveConflict(for: item, strategy: strategy)
    }

    func resolveAllConflicts(in items: [MediaItem], strategy: ConflictResolutionStrategy) async throws {
        let conflicted = conflictedItems(from: items)
        for item in conflicted {
            try await resolveConflict(for: item, strategy: strategy)
        }
    }

    func resolveAllConflicts(strategy: ConflictResolutionStrategy) async throws {
        try await resolveAllConflicts(in: resolvedItems(), strategy: strategy)
    }

    func resolveAllConflictsWithLocal(in items: [MediaItem]? = nil) async throws {
        try await resolveAllConflicts(in: resolvedItems(items), strategy: .useLocal)
    }

    func resolveAllConflictsWithRemote(in items: [MediaItem]? = nil) async throws {
        try await resolveAllConflicts(in: resolvedItems(items), strategy: .useRemote)
    }

    // MARK: - Retry Failed Writes

    func retryFailedWrites(in items: [MediaItem]? = nil) async {
        let allItems = resolvedItems(items)
        let failedItems = allItems.filter { syncState(for: $0.id) == .syncError }
        guard !failedItems.isEmpty else { return }

        for item in failedItems {
            syncStateByItemID[item.id] = .pendingWrite
            await syncStore.updateSyncState(.pendingWrite, for: item.id)
        }
        onStateChange?()
        await flushPendingWrites()
    }

    // MARK: - Sidecar Hydration

    // MARK: - Sidecar Hydration

    func initializeMetadata(for items: [MediaItem], isLazy: Bool = false) {
        currentItems = items
        for item in items {
            let dir = item.directoryURL.standardizedFileURL
            let hasListing = DirectoryListingCache.shared.contents(for: dir) != nil
            let resolvedSidecar = item.sidecarURL ?? (hasListing ? SidecarCodec.resolveSidecarReadURLCached(for: item) : nil)
            let confirmedNoSidecar = hasListing && resolvedSidecar == nil

            let persisted = syncStore.cachedRecord(for: item.id)

            if let persisted {
                if let persistedExif = persisted.exif {
                    onExifDiscovered?(item.id, persistedExif)
                }

                if persisted.syncState == .pendingWrite || persisted.syncState == .syncError {
                    metadataByItemID[item.id] = persisted.metadata
                    syncStateByItemID[item.id] = persisted.syncState
                    baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                } else if persisted.syncState == .conflicted, let conflict = persisted.conflict {
                    metadataByItemID[item.id] = persisted.metadata
                    syncStateByItemID[item.id] = .conflicted
                    conflictsByItemID[item.id] = conflict
                    baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                } else if confirmedNoSidecar && (persisted.baseSnapshot?.fileDigest.isEmpty == false) {
                    // Previously had an on-disk sidecar that has been deleted externally (Bug 1)
                    let emptySnapshot = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
                    metadataByItemID[item.id] = CurationMetadata()
                    syncStateByItemID[item.id] = .synced
                    baseSnapshotByItemID[item.id] = emptySnapshot
                    let itemID = item.id
                    enqueueStoreOperation { [syncStore] in
                        await syncStore.recordBaseSnapshot(emptySnapshot, exif: nil, for: itemID)
                    }
                } else {
                    metadataByItemID[item.id] = persisted.metadata
                    syncStateByItemID[item.id] = .synced
                    baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                }
            } else {
                if confirmedNoSidecar {
                    // Pre-emptive in-memory resolution for items confirmed without sidecars (ADR-0013)
                    let emptySnapshot = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
                    metadataByItemID[item.id] = CurationMetadata()
                    syncStateByItemID[item.id] = .synced
                    baseSnapshotByItemID[item.id] = emptySnapshot
                    let itemID = item.id
                    enqueueStoreOperation { [syncStore] in
                        await syncStore.recordBaseSnapshot(emptySnapshot, exif: nil, for: itemID)
                    }
                } else {
                    syncStateByItemID[item.id] = .loading
                    metadataByItemID[item.id] = CurationMetadata()
                    baseSnapshotByItemID[item.id] = nil
                }
            }
        }
        onStateChange?()
        if !isLazy {
            startBackgroundSidecarHydration(for: items)
        }
    }

    enum HydrationOutcome: Sendable {
        case sidecar(curation: CurationMetadata, exif: ExifMetadata?, digest: String, modDate: Date?)
        case none
    }

    nonisolated static func readSidecarData(for item: MediaItem) async -> HydrationOutcome {
        let sidecarURL: URL?
        if let direct = item.sidecarURL {
            sidecarURL = direct
        } else {
            sidecarURL = await SidecarCodec.resolveSidecarReadURL(for: item)
        }
        guard let sidecarURL else {
            return .none
        }
        let data: Data?
        if let asyncData = await SidecarCodec.readData(from: sidecarURL) {
            data = asyncData
        } else {
            data = try? Data(contentsOf: sidecarURL)
        }
        guard let data else {
            return .none
        }

        let digest = SidecarCodec.computeDigest(for: data)
        let modDate = (try? sidecarURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let parsed = try? SidecarCodec.parse(data: data) {
            return .sidecar(curation: parsed.curation, exif: parsed.exif, digest: digest, modDate: modDate)
        }
        return .sidecar(curation: CurationMetadata(), exif: nil, digest: digest, modDate: modDate)
    }



    struct LocalItemSyncState: Sendable {
        var syncState: SyncState?
        var metadata: CurationMetadata?
        var baseSnapshot: BaseSnapshot?
        var conflict: MetadataConflict?
    }

    struct HydrationResult: Sendable {
        let itemID: String
        let metadata: CurationMetadata
        let syncState: SyncState
        let baseSnapshot: BaseSnapshot?
        let conflict: MetadataConflict?
        let discoveredExif: ExifMetadata?
    }

    nonisolated static func processHydration(
        for item: MediaItem,
        syncStore: MetadataSyncStore,
        existingExif: ExifMetadata?,
        localState: LocalItemSyncState?
    ) async -> HydrationResult? {
        guard !Task.isCancelled else { return nil }
        let outcome = await readSidecarData(for: item)
        guard !Task.isCancelled else { return nil }

        let persisted = syncStore.cachedRecord(for: item.id)

        switch outcome {
        case .sidecar(let diskCuration, let diskExif, let diskDigest, let diskModDate):
            let baseExif = existingExif ?? persisted?.exif
            let discoveredExif: ExifMetadata?
            if let diskExif, !diskExif.isEmpty {
                if let baseExif {
                    discoveredExif = diskExif.supplementing(with: baseExif)
                } else {
                    discoveredExif = diskExif
                }
            } else if let baseExif {
                discoveredExif = baseExif
            } else {
                discoveredExif = nil
            }

            let isPendingOrError = localState?.syncState == .pendingWrite ||
                localState?.syncState == .syncError ||
                persisted?.syncState == .pendingWrite ||
                persisted?.syncState == .syncError

            if isPendingOrError {
                let local = localState?.metadata ?? persisted?.metadata ?? CurationMetadata()
                let syncState = localState?.syncState ?? persisted?.syncState ?? .pendingWrite
                let base = localState?.baseSnapshot ?? persisted?.baseSnapshot

                if let base {
                    let remoteChanged = diskDigest != base.fileDigest
                    let threeWay = XMPConflictEngine.evaluateThreeWay(
                        itemID: item.id,
                        base: base,
                        local: local,
                        remote: diskCuration,
                        remoteDigestChanged: remoteChanged
                    )
                    switch threeWay {
                    case .conflict(let conflict):
                        await syncStore.recordConflict(conflict, for: item.id)
                        return HydrationResult(
                            itemID: item.id,
                            metadata: local,
                            syncState: .conflicted,
                            baseSnapshot: base,
                            conflict: conflict,
                            discoveredExif: discoveredExif
                        )
                    case .cleanMerge(let merged):
                        await syncStore.stagePendingWrite(merged, baseSnapshot: base, for: item.id)
                        return HydrationResult(
                            itemID: item.id,
                            metadata: merged,
                            syncState: syncState,
                            baseSnapshot: base,
                            conflict: nil,
                            discoveredExif: discoveredExif
                        )
                    case .noChange:
                        return HydrationResult(
                            itemID: item.id,
                            metadata: local,
                            syncState: syncState,
                            baseSnapshot: base,
                            conflict: nil,
                            discoveredExif: discoveredExif
                        )
                    }
                } else {
                    let threeWay = XMPConflictEngine.evaluateThreeWay(
                        itemID: item.id,
                        base: nil,
                        local: local,
                        remote: diskCuration,
                        remoteDigestChanged: true
                    )
                    switch threeWay {
                    case .conflict(let conflict):
                        await syncStore.recordConflict(conflict, for: item.id)
                        return HydrationResult(
                            itemID: item.id,
                            metadata: local,
                            syncState: .conflicted,
                            baseSnapshot: nil,
                            conflict: conflict,
                            discoveredExif: discoveredExif
                        )
                    case .cleanMerge(let merged):
                        let newBase = BaseSnapshot(metadata: diskCuration, fileDigest: diskDigest, modificationDate: diskModDate)
                        await syncStore.stagePendingWrite(merged, baseSnapshot: newBase, for: item.id)
                        return HydrationResult(
                            itemID: item.id,
                            metadata: merged,
                            syncState: syncState,
                            baseSnapshot: newBase,
                            conflict: nil,
                            discoveredExif: discoveredExif
                        )
                    case .noChange:
                        return HydrationResult(
                            itemID: item.id,
                            metadata: local,
                            syncState: syncState,
                            baseSnapshot: nil,
                            conflict: nil,
                            discoveredExif: discoveredExif
                        )
                    }
                }
            } else if let persisted, persisted.syncState == .conflicted, let conflict = persisted.conflict {
                return HydrationResult(
                    itemID: item.id,
                    metadata: persisted.metadata,
                    syncState: .conflicted,
                    baseSnapshot: persisted.baseSnapshot,
                    conflict: conflict,
                    discoveredExif: discoveredExif
                )
            } else {
                let snapshot = BaseSnapshot(metadata: diskCuration, fileDigest: diskDigest, modificationDate: diskModDate)
                await syncStore.recordBaseSnapshot(snapshot, exif: existingExif ?? diskExif, for: item.id)
                return HydrationResult(
                    itemID: item.id,
                    metadata: diskCuration,
                    syncState: .synced,
                    baseSnapshot: snapshot,
                    conflict: nil,
                    discoveredExif: discoveredExif
                )
            }

        case .none:
            let isPendingOrError = localState?.syncState == .pendingWrite ||
                localState?.syncState == .syncError ||
                persisted?.syncState == .pendingWrite ||
                persisted?.syncState == .syncError

            if isPendingOrError {
                let local = localState?.metadata ?? persisted?.metadata ?? CurationMetadata()
                let syncState = localState?.syncState ?? persisted?.syncState ?? .pendingWrite
                let base = localState?.baseSnapshot ?? persisted?.baseSnapshot
                return HydrationResult(
                    itemID: item.id,
                    metadata: local,
                    syncState: syncState,
                    baseSnapshot: base,
                    conflict: nil,
                    discoveredExif: nil
                )
            } else if let persisted, persisted.syncState == .conflicted, let conflict = persisted.conflict {
                return HydrationResult(
                    itemID: item.id,
                    metadata: persisted.metadata,
                    syncState: .conflicted,
                    baseSnapshot: persisted.baseSnapshot,
                    conflict: conflict,
                    discoveredExif: nil
                )
            } else {
                let emptySnapshot = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
                await syncStore.recordBaseSnapshot(emptySnapshot, exif: existingExif, for: item.id)
                return HydrationResult(
                    itemID: item.id,
                    metadata: CurationMetadata(),
                    syncState: .synced,
                    baseSnapshot: emptySnapshot,
                    conflict: nil,
                    discoveredExif: nil
                )
            }
        }
    }

    private func localItemState(for itemID: String) -> (existingExif: ExifMetadata?, localState: LocalItemSyncState?) {
        let exif = existingExifProvider?(itemID)
        let state = LocalItemSyncState(
            syncState: syncStateByItemID[itemID],
            metadata: metadataByItemID[itemID],
            baseSnapshot: baseSnapshotByItemID[itemID],
            conflict: conflictsByItemID[itemID]
        )
        return (exif, state)
    }

    func recordBatchHydrationResult(_ result: HydrationResult) {
        pendingHydrationBatch.append(result)
        if debouncedHydrationFlushTask == nil {
            let delay = self.hydrationBatchDebounceNanoseconds
            debouncedHydrationFlushTask = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.debouncedHydrationFlushTask = nil
                    self.flushHydrationBatch()
                }
            }
        }
    }

    func flushHydrationBatch() {
        debouncedHydrationFlushTask?.cancel()
        debouncedHydrationFlushTask = nil
        guard !pendingHydrationBatch.isEmpty else { return }
        let batch = pendingHydrationBatch
        pendingHydrationBatch.removeAll()

        for result in batch {
            applyHydrationResult(result, refreshCounts: false)
        }
        onStateChange?()
    }

    func applyHydrationResult(_ result: HydrationResult, refreshCounts: Bool = true) {
        if syncStateByItemID[result.itemID] == .pendingWrite && result.syncState == .synced {
            if let base = result.baseSnapshot {
                baseSnapshotByItemID[result.itemID] = base
            }
        } else {
            metadataByItemID[result.itemID] = result.metadata
            syncStateByItemID[result.itemID] = result.syncState
            if let base = result.baseSnapshot {
                baseSnapshotByItemID[result.itemID] = base
            }
            if let conflict = result.conflict {
                conflictsByItemID[result.itemID] = conflict
            } else {
                conflictsByItemID.removeValue(forKey: result.itemID)
            }
        }

        if let exif = result.discoveredExif {
            onExifDiscovered?(result.itemID, exif)
        }

        if refreshCounts {
            onStateChange?()
        }
    }

    func hydrateMetadata(for item: MediaItem, refreshCounts: Bool = true) async {
        guard !Task.isCancelled else { return }

        // Fast path 1: If already in pendingHydrationBatch, extract and apply immediately
        if let idx = pendingHydrationBatch.firstIndex(where: { $0.itemID == item.id }) {
            let result = pendingHydrationBatch.remove(at: idx)
            applyHydrationResult(result, refreshCounts: refreshCounts)
            return
        }

        if let existing = inFlightHydrations[item.id] {
            await existing.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlightHydrations.removeValue(forKey: item.id) }

            let (existingExif, localState) = self.localItemState(for: item.id)
            let store = self.syncStore

            let result = await self.hydrationQueue.enqueue(id: item.id) { () -> HydrationResult? in
                guard !Task.isCancelled else { return nil }
                return await Self.processHydration(
                    for: item,
                    syncStore: store,
                    existingExif: existingExif,
                    localState: localState
                )
            }

            guard !Task.isCancelled, let result else { return }

            if let idx = self.pendingHydrationBatch.firstIndex(where: { $0.itemID == item.id }) {
                self.pendingHydrationBatch.remove(at: idx)
            }

            self.applyHydrationResult(result, refreshCounts: refreshCounts)
        }

        inFlightHydrations[item.id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func startBackgroundSidecarHydration(for items: [MediaItem]? = nil) {
        let previousTask = backgroundHydrationTask
        backgroundHydrationTask = Task(priority: .utility) { [weak self] in
            _ = await previousTask?.value
            guard let self else { return }

            let (itemsToHydrate, store, maxWorkers) = await MainActor.run {
                let all = self.resolvedItems(items)
                let toHydrate = all.filter { item in
                    let dir = item.directoryURL.standardizedFileURL
                    let hasListing = DirectoryListingCache.shared.contents(for: dir) != nil
                    let resolvedSidecar = item.sidecarURL ?? (hasListing ? SidecarCodec.resolveSidecarReadURLCached(for: item) : nil)
                    let confirmedNoSidecar = hasListing && resolvedSidecar == nil
                    return !confirmedNoSidecar
                }
                let limit = max(1, self.storageVolumeProfile.effectiveSidecarHydrationWorkers(isHighSpeedLAN: self.isHighSpeedLAN))
                return (toHydrate, self.syncStore, limit)
            }
            guard !itemsToHydrate.isEmpty else { return }

            await withTaskGroup(of: HydrationResult?.self) { group in
                var index = 0
                let total = itemsToHydrate.count

                while index < total && index < maxWorkers {
                    let item = itemsToHydrate[index]
                    index += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let (existingExif, localState) = await MainActor.run { () -> (ExifMetadata?, LocalItemSyncState?) in
                            self.localItemState(for: item.id)
                        }

                        return await Self.processHydration(
                            for: item,
                            syncStore: store,
                            existingExif: existingExif,
                            localState: localState
                        )
                    }
                }

                for await maybeResult in group {
                    if let result = maybeResult {
                        await MainActor.run {
                            self.recordBatchHydrationResult(result)
                        }
                    }
                    if index < total && !Task.isCancelled {
                        let item = itemsToHydrate[index]
                        index += 1
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            let (existingExif, localState) = await MainActor.run { () -> (ExifMetadata?, LocalItemSyncState?) in
                                self.localItemState(for: item.id)
                            }

                            return await Self.processHydration(
                                for: item,
                                syncStore: store,
                                existingExif: existingExif,
                                localState: localState
                            )
                        }
                    }
                }
            }

            await MainActor.run {
                self.flushHydrationBatch()
                self.onStateChange?()
            }
        }
    }


    func waitForBackgroundHydration() async {
        await backgroundHydrationTask?.value
    }

    // MARK: - Lifecycle & Clean Closure

    func cancelTasks() {
        debouncedFlushTask?.cancel()
        debouncedFlushTask = nil
        backgroundHydrationTask?.cancel()
        backgroundHydrationTask = nil
        debouncedHydrationFlushTask?.cancel()
        debouncedHydrationFlushTask = nil
        pendingHydrationBatch.removeAll()
        for (_, task) in inFlightHydrations {
            task.cancel()
        }
        inFlightHydrations.removeAll()
        Task { [hydrationQueue] in
            await hydrationQueue.cancelAll()
        }
    }

    func reset() {
        cancelTasks()
        currentItems.removeAll()
        metadataByItemID.removeAll()
        syncStateByItemID.removeAll()
        baseSnapshotByItemID.removeAll()
        conflictsByItemID.removeAll()
        onStateChange?()
    }

    func resetMetadataSyncStore() async {
        await waitForPendingStoreWrites()
        cancelTasks()
        await syncStore.reset()
        metadataByItemID.removeAll()
        syncStateByItemID.removeAll()
        baseSnapshotByItemID.removeAll()
        conflictsByItemID.removeAll()
        for item in currentItems {
            let outcome = await Self.readSidecarData(for: item)
            switch outcome {
            case .sidecar(let curation, _, let digest, let modDate):
                metadataByItemID[item.id] = curation
                syncStateByItemID[item.id] = .synced
                baseSnapshotByItemID[item.id] = BaseSnapshot(metadata: curation, fileDigest: digest, modificationDate: modDate)
            case .none:
                metadataByItemID[item.id] = CurationMetadata()
                syncStateByItemID[item.id] = .synced
                baseSnapshotByItemID[item.id] = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
            }
        }
        onStateChange?()
    }

    @discardableResult
    func close(
        timeoutNanoseconds: UInt64 = 2_500_000_000,
        force: Bool = false,
        items: [MediaItem]? = nil
    ) async -> CloseFolderResult {
        debouncedFlushTask?.cancel()
        debouncedFlushTask = nil

        let allItems = resolvedItems(items)
        let pending = allItems.filter { syncState(for: $0.id) == .pendingWrite }

        if pending.isEmpty {
            await waitForPendingStoreWrites()
            reset()
            return .success
        }

        if force {
            await waitForPendingStoreWrites()
            reset()
            return .closedWithPendingJournaled
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.flushPendingWrites()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }
            _ = await group.next()
            group.cancelAll()
        }

        await waitForPendingStoreWrites()

        let remainingPending = resolvedItems(items).filter { syncState(for: $0.id) == .pendingWrite }.count
        if remainingPending == 0 {
            reset()
            return .success
        } else {
            return .pendingWritesRemaining(remainingPending)
        }
    }
}
