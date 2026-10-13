import Foundation
import Observation
import OSLog

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
    }

    init(syncStore: MetadataSyncStore) {
        self.syncStore = syncStore
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

    private func performPendingWritesFlush() async {
        while !Task.isCancelled {
            let pending = resolvedItems().filter { syncState(for: $0.id) == .pendingWrite }
            guard !pending.isEmpty else { break }

            for item in pending {
                if Task.isCancelled { break }
                if simulatedFlushDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: simulatedFlushDelayNanoseconds)
                }
                if Task.isCancelled { break }
                do {
                    try await flushPendingWrite(for: item)
                } catch {
                    let nsError = error as NSError
                    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                    Self.logger.error("Flush error on \(item.displayFileName, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) underlying=\(underlying?.domain ?? "none", privacy: .public)(\(underlying?.code ?? -1)) desc=\(error.localizedDescription, privacy: .public)")
                }
            }
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
        let readURL = SidecarCodec.resolveSidecarReadURL(for: item)
        var diskCuration: CurationMetadata? = nil
        var diskDigest = ""

        if let readURL, let data = SidecarCodec.readData(from: readURL) {
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

        if let primaryTarget = writtenTargets.first, let writtenData = SidecarCodec.readData(from: primaryTarget) {
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
        } catch {
            syncStateByItemID[item.id] = .syncError
            await syncStore.updateSyncState(.syncError, for: item.id)
            onSyncError?(error, item)
            onStateChange?()
            throw error
        }
    }

    // MARK: - Conflict Resolution

    private func writeAndCreateSnapshot(curation: CurationMetadata, for item: MediaItem) async throws -> BaseSnapshot {
        let writtenTargets = try await SidecarCodec.write(curation: curation, for: item)
        let primaryTarget = writtenTargets.first ?? SidecarCodec.resolveSidecarReadURL(for: item)
        let writtenData = primaryTarget.flatMap { SidecarCodec.readData(from: $0) } ?? Data()
        let digest = SidecarCodec.computeDigest(for: writtenData)
        let modDate = primaryTarget.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        return BaseSnapshot(metadata: curation, fileDigest: digest, modificationDate: modDate)
    }

    func resolveConflict(for item: MediaItem, strategy: ConflictResolutionStrategy) async throws {
        guard let conflict = conflict(for: item.id) else { return }

        let resolvedMetadata: CurationMetadata
        let newBase: BaseSnapshot

        switch strategy {
        case .useRemote:
            resolvedMetadata = conflict.remote
            let readURL = SidecarCodec.resolveSidecarReadURL(for: item)
            let diskData = readURL.flatMap { SidecarCodec.readData(from: $0) } ?? Data()
            let digest = SidecarCodec.computeDigest(for: diskData)
            let modDate = readURL.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            newBase = BaseSnapshot(metadata: resolvedMetadata, fileDigest: digest, modificationDate: modDate)

        case .useLocal:
            resolvedMetadata = conflict.local
            newBase = try await writeAndCreateSnapshot(curation: resolvedMetadata, for: item)

        case .cherryPick(let custom):
            resolvedMetadata = custom
            newBase = try await writeAndCreateSnapshot(curation: resolvedMetadata, for: item)
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

    func initializeMetadata(for items: [MediaItem], isLazy: Bool) {
        currentItems = items
        if isLazy {
            for item in items {
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
                    } else {
                        metadataByItemID[item.id] = persisted.metadata
                        syncStateByItemID[item.id] = .synced
                        baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                    }
                } else {
                    syncStateByItemID[item.id] = .loading
                    metadataByItemID[item.id] = CurationMetadata()
                    baseSnapshotByItemID[item.id] = nil
                }
            }
            onStateChange?()
            startBackgroundSidecarHydration(for: items)
        } else {
            for item in items {
                hydrateItemSynchronously(item)
            }
            onStateChange?()
        }
    }

    func hydrateItemSynchronously(_ item: MediaItem) {
        let persisted = syncStore.cachedRecord(for: item.id)
        let sidecarURL = SidecarCodec.resolveSidecarReadURL(for: item)

        var diskData: Data? = nil
        var diskCuration: CurationMetadata? = nil
        var diskExif: ExifMetadata? = nil
        var diskDigest = ""
        var diskModDate: Date? = nil

        if let sidecarURL, let data = SidecarCodec.readData(from: sidecarURL) {
            diskData = data
            diskDigest = SidecarCodec.computeDigest(for: data)
            diskModDate = (try? sidecarURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let parsed = try? SidecarCodec.parse(data: data) {
                diskCuration = parsed.curation
                diskExif = parsed.exif
            }
        }

        let existingExif = existingExifProvider?(item.id)

        func recordSyncedSnapshot(curation: CurationMetadata?, exif: ExifMetadata?) {
            let snapshot: BaseSnapshot
            let effectiveCuration: CurationMetadata
            if let curation {
                snapshot = BaseSnapshot(metadata: curation, fileDigest: diskDigest, modificationDate: diskModDate)
                effectiveCuration = curation
            } else {
                snapshot = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
                effectiveCuration = CurationMetadata()
            }
            metadataByItemID[item.id] = effectiveCuration
            syncStateByItemID[item.id] = .synced
            baseSnapshotByItemID[item.id] = snapshot
            enqueueStoreOperation { [syncStore] in
                await syncStore.recordBaseSnapshot(snapshot, exif: exif, for: item.id)
            }
        }

        if let persisted {
            if let diskExif, !diskExif.isEmpty {
                let mergedExif: ExifMetadata
                if let persistedExif = persisted.exif {
                    mergedExif = diskExif.supplementing(with: persistedExif)
                } else {
                    mergedExif = diskExif
                }
                onExifDiscovered?(item.id, mergedExif)
            } else if let persistedExif = persisted.exif {
                onExifDiscovered?(item.id, persistedExif)
            }

            if persisted.syncState == .pendingWrite || persisted.syncState == .syncError {
                metadataByItemID[item.id] = persisted.metadata
                syncStateByItemID[item.id] = persisted.syncState
                baseSnapshotByItemID[item.id] = persisted.baseSnapshot

                if let base = persisted.baseSnapshot {
                    let remoteChanged = diskDigest != base.fileDigest
                    let threeWay = XMPConflictEngine.evaluateThreeWay(
                        itemID: item.id,
                        base: base,
                        local: persisted.metadata,
                        remote: diskCuration,
                        remoteDigestChanged: remoteChanged
                    )
                    switch threeWay {
                    case .conflict(let conflict):
                        syncStateByItemID[item.id] = .conflicted
                        conflictsByItemID[item.id] = conflict
                        enqueueStoreOperation { [syncStore] in
                            await syncStore.recordConflict(conflict, for: item.id)
                        }
                    case .cleanMerge(let merged):
                        metadataByItemID[item.id] = merged
                        enqueueStoreOperation { [syncStore] in
                            await syncStore.stagePendingWrite(merged, baseSnapshot: base, for: item.id)
                        }
                    case .noChange:
                        break
                    }
                } else if let diskCuration {
                    let threeWay = XMPConflictEngine.evaluateThreeWay(
                        itemID: item.id,
                        base: nil,
                        local: persisted.metadata,
                        remote: diskCuration,
                        remoteDigestChanged: true
                    )
                    switch threeWay {
                    case .conflict(let conflict):
                        syncStateByItemID[item.id] = .conflicted
                        conflictsByItemID[item.id] = conflict
                        enqueueStoreOperation { [syncStore] in
                            await syncStore.recordConflict(conflict, for: item.id)
                        }
                    case .cleanMerge(let merged):
                        metadataByItemID[item.id] = merged
                        let newBase = BaseSnapshot(metadata: diskCuration, fileDigest: diskDigest, modificationDate: diskModDate)
                        enqueueStoreOperation { [syncStore] in
                            await syncStore.stagePendingWrite(merged, baseSnapshot: newBase, for: item.id)
                        }
                        baseSnapshotByItemID[item.id] = newBase
                    case .noChange:
                        break
                    }
                }
            } else if persisted.syncState == .conflicted, let conflict = persisted.conflict {
                metadataByItemID[item.id] = persisted.metadata
                syncStateByItemID[item.id] = .conflicted
                conflictsByItemID[item.id] = conflict
                baseSnapshotByItemID[item.id] = persisted.baseSnapshot
            } else {
                recordSyncedSnapshot(curation: diskCuration, exif: existingExif ?? diskExif)
            }
        } else {
            if let diskExif {
                onExifDiscovered?(item.id, diskExif)
            }
            recordSyncedSnapshot(curation: diskCuration, exif: diskExif ?? existingExif)
        }
    }

    private enum HydrationOutcome: Sendable {
        case sidecar(curation: CurationMetadata, exif: ExifMetadata?, digest: String, modDate: Date?)
        case none
    }

    nonisolated private static func readSidecarData(for item: MediaItem) -> HydrationOutcome {
        let sidecarURL = item.sidecarURL ?? SidecarCodec.resolveSidecarReadURL(for: item)
        guard let sidecarURL, let data = SidecarCodec.readData(from: sidecarURL) else {
            return .none
        }
        let digest = SidecarCodec.computeDigest(for: data)
        let modDate = (try? sidecarURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let parsed = try? SidecarCodec.parse(data: data) {
            return .sidecar(curation: parsed.curation, exif: parsed.exif, digest: digest, modDate: modDate)
        }
        return .sidecar(curation: CurationMetadata(), exif: nil, digest: digest, modDate: modDate)
    }

    func hydrateMetadata(for item: MediaItem, refreshCounts: Bool = true) async {
        guard syncStateByItemID[item.id] == .loading else { return }

        let outcome = Self.readSidecarData(for: item)

        guard !Task.isCancelled else { return }
        guard syncStateByItemID[item.id] == .loading else { return }

        let existingExif = existingExifProvider?(item.id)

        switch outcome {
        case .sidecar(let curation, let exif, let digest, let modDate):
            let snapshot = BaseSnapshot(metadata: curation, fileDigest: digest, modificationDate: modDate)
            metadataByItemID[item.id] = curation
            syncStateByItemID[item.id] = .synced
            baseSnapshotByItemID[item.id] = snapshot
            if let exif {
                onExifDiscovered?(item.id, exif)
            }
            await syncStore.recordBaseSnapshot(snapshot, exif: existingExif ?? exif, for: item.id)

        case .none:
            let emptySnapshot = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
            metadataByItemID[item.id] = CurationMetadata()
            syncStateByItemID[item.id] = .synced
            baseSnapshotByItemID[item.id] = emptySnapshot
            await syncStore.recordBaseSnapshot(emptySnapshot, exif: existingExif, for: item.id)
        }

        if refreshCounts {
            onStateChange?()
        }
    }

    func startBackgroundSidecarHydration(for items: [MediaItem]? = nil) {
        backgroundHydrationTask?.cancel()
        backgroundHydrationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let pendingItems: [MediaItem] = await MainActor.run {
                let all = self.resolvedItems(items)
                return all.filter { self.syncStateByItemID[$0.id] == .loading }
            }
            guard !pendingItems.isEmpty else { return }

            for item in pendingItems {
                if Task.isCancelled { break }
                await self.hydrateMetadata(for: item, refreshCounts: false)
                await Task.yield()
            }
            await MainActor.run {
                self.onStateChange?()
            }
        }
    }

    // MARK: - Lifecycle & Clean Closure

    func cancelTasks() {
        debouncedFlushTask?.cancel()
        debouncedFlushTask = nil
        backgroundHydrationTask?.cancel()
        backgroundHydrationTask = nil
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
            let outcome = Self.readSidecarData(for: item)
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
            group.addTask { @MainActor in
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
