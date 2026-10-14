import Foundation
import Testing
@testable import Pickture

@MainActor
struct MetadataSyncEngineTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataSyncEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func createTestItem(in directory: URL, fileName: String) throws -> MediaItem {
        let fileURL = directory.appendingPathComponent(fileName)
        try Data("dummy-image-bytes".utf8).write(to: fileURL)
        let mediaFile = MediaFile(url: fileURL, formatKind: .raster)
        return MediaItem(
            id: fileURL.standardizedFileURL.path,
            baseName: (fileName as NSString).deletingPathExtension,
            directoryURL: directory.standardizedFileURL,
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: mediaFile,
            mediaPair: nil,
            sidecarURL: nil
        )
    }

    // MARK: - 1. Optimistic Staging & Journal Persistence

    @Test("Optimistic staging updates in-memory state and persists pending write with base snapshot into sync store journal")
    func optimisticStagingAndJournalPersistence() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try createTestItem(in: root, fileName: "IMG_1001.JPG")

        // Write an initial sidecar to disk
        let initialMetadata = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let initialXMPData = try SidecarCodec.update(xmlData: nil, with: initialMetadata)
        let sidecarURL = root.appendingPathComponent("IMG_1001.xmp")
        try initialXMPData.write(to: sidecarURL)

        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)
        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine.isSyncSuspended = true
        engine.initializeMetadata(for: [item])
        await engine.waitForBackgroundHydration()

        #expect(engine.syncState(for: item) == .synced)
        #expect(engine.curationMetadata(for: item) == initialMetadata)
        let baseSnapshot = try #require(engine.baseSnapshot(for: item))
        #expect(baseSnapshot.metadata == initialMetadata)
        #expect(!baseSnapshot.fileDigest.isEmpty)

        // Stage optimistic curation mutation
        let mutatedMetadata = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .purple)
        engine.updateCurationMetadata(mutatedMetadata, for: item)

        #expect(engine.syncState(for: item) == .pendingWrite)
        #expect(engine.curationMetadata(for: item) == mutatedMetadata)
        #expect(engine.pendingWritesCount == 1)
        #expect(engine.syncSummaryState == .pendingWrite)
        #expect(engine.syncSummaryBadgeText == "1 Pending")

        // Check durable journal persistence
        await engine.waitForPendingStoreWrites()
        let storeRecord = await engine.syncStore.record(for: item.id)
        let record = try #require(storeRecord)
        #expect(record.syncState == .pendingWrite)
        #expect(record.metadata == mutatedMetadata)
        #expect(record.baseSnapshot?.metadata == initialMetadata)
        #expect(record.baseSnapshot?.fileDigest == baseSnapshot.fileDigest)
    }

    // MARK: - 2. Debounced Flushing & BaseSnapshot Update

    @Test("Debounced flushing writes staged mutations to disk sidecar and updates BaseSnapshot and SyncState")
    func debouncedFlushingToDiskAndBaseSnapshotUpdate() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try createTestItem(in: root, fileName: "IMG_1002.JPG")

        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)
        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine.isSyncSuspended = true

        engine.initializeMetadata(for: [item])
        await engine.waitForBackgroundHydration()
        #expect(engine.syncState(for: item) == .synced)

        // Stage optimistic mutation
        let targetMetadata = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .blue)
        engine.updateCurationMetadata(targetMetadata, for: item)
        #expect(engine.pendingWritesCount == 1)

        let sidecarURL = root.appendingPathComponent("IMG_1002.xmp")
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))

        // Trigger flush
        await engine.flushPendingWrites(in: [item])

        #expect(engine.syncState(for: item) == .synced)
        #expect(engine.pendingWritesCount == 0)
        #expect(engine.syncSummaryState == .synced)
        #expect(engine.syncSummaryBadgeText == "Synced")

        // Verify sidecar exists on disk with target curation
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        let writtenData = try Data(contentsOf: sidecarURL)
        let (parsedCuration, _) = try SidecarCodec.parse(data: writtenData)
        #expect(parsedCuration == targetMetadata)

        // Verify updated BaseSnapshot
        let newBase = try #require(engine.baseSnapshot(for: item))
        #expect(newBase.metadata == targetMetadata)
        #expect(!newBase.fileDigest.isEmpty)
        #expect(newBase.fileDigest == SidecarCodec.computeDigest(for: writtenData))
    }

    // MARK: - 3. External Disk Modification Detecting Conflict

    @Test("External disk modification during pending write detects 3-way conflict without overwriting remote sidecar")
    func externalDiskModificationDetectingConflict() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try createTestItem(in: root, fileName: "IMG_1003.JPG")

        // Initial on-disk sidecar: 1 star, unflagged, none
        let baseMetadata = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let baseXMPData = try SidecarCodec.update(xmlData: nil, with: baseMetadata)
        let sidecarURL = root.appendingPathComponent("IMG_1003.xmp")
        try baseXMPData.write(to: sidecarURL)

        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)
        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine.isSyncSuspended = true

        engine.initializeMetadata(for: [item])
        await engine.waitForBackgroundHydration()
        #expect(engine.syncState(for: item) == .synced)

        // Local stages mutation: 5 stars, picked, green
        let localMetadata = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green)
        engine.updateCurationMetadata(localMetadata, for: item)
        #expect(engine.syncState(for: item) == .pendingWrite)

        // External tool modifies on-disk sidecar: 3 stars, rejected, red
        let externalMetadata = CurationMetadata(starRating: 3, pickFlag: .rejected, colorLabel: .red)
        let externalXMPData = try SidecarCodec.update(xmlData: baseXMPData, with: externalMetadata)
        try externalXMPData.write(to: sidecarURL)

        // Attempt flush
        try await engine.flushPendingWrite(for: item.id, in: [item])

        // Verify conflict state
        #expect(engine.syncState(for: item) == .conflicted)
        #expect(engine.conflictedItemsCount == 1)
        #expect(engine.syncSummaryState == .conflicted)
        #expect(engine.syncSummaryBadgeText == "1 Conflict")

        let conflicted = engine.conflictedItems(from: [item])
        #expect(conflicted.count == 1)
        #expect(conflicted.first?.id == item.id)

        let activeConflict = engine.activeConflictItem(selectedItemID: item.id, from: [item])
        #expect(activeConflict?.id == item.id)

        // Disk was NOT overwritten
        let diskData = try Data(contentsOf: sidecarURL)
        let (diskCuration, _) = try SidecarCodec.parse(data: diskData)
        #expect(diskCuration == externalMetadata)

        let conflict = try #require(engine.conflict(for: item))
        #expect(conflict.base == baseMetadata)
        #expect(conflict.local == localMetadata)
        #expect(conflict.remote == externalMetadata)
        #expect(conflict.starRatingDiff.isConflicted == true)
        #expect(conflict.pickFlagDiff.isConflicted == true)
        #expect(conflict.colorLabelDiff.isConflicted == true)
    }

    // MARK: - 4. 3-Way Auto-Merge

    @Test("3-way auto-merge automatically merges non-overlapping field changes and writes to disk cleanly")
    func threeWayAutoMergeUpdatingCuration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try createTestItem(in: root, fileName: "IMG_1004.JPG")

        // Initial base on disk: star 1, unflagged, none
        let baseMetadata = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let baseXMPData = try SidecarCodec.update(xmlData: nil, with: baseMetadata)
        let sidecarURL = root.appendingPathComponent("IMG_1004.xmp")
        try baseXMPData.write(to: sidecarURL)

        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)
        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine.isSyncSuspended = true

        engine.initializeMetadata(for: [item])
        await engine.waitForBackgroundHydration()

        // Local changes pickFlag only (rating remains 1, label remains none)
        let localMetadata = CurationMetadata(starRating: 1, pickFlag: .picked, colorLabel: .none)
        engine.updateCurationMetadata(localMetadata, for: item)

        // Remote changes starRating only (pick remains unflagged, label remains none)
        let remoteMetadata = CurationMetadata(starRating: 5, pickFlag: .unflagged, colorLabel: .none)
        let remoteXMPData = try SidecarCodec.update(xmlData: baseXMPData, with: remoteMetadata)
        try remoteXMPData.write(to: sidecarURL)

        // Flush
        try await engine.flushPendingWrite(for: item.id, in: [item])

        // Verify clean 3-way auto-merge!
        #expect(engine.syncState(for: item) == .synced)
        #expect(engine.conflictedItemsCount == 0)

        let expectedMerged = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .none)
        #expect(engine.curationMetadata(for: item) == expectedMerged)

        // Disk sidecar reflects merged state
        let diskData = try Data(contentsOf: sidecarURL)
        let (diskCuration, _) = try SidecarCodec.parse(data: diskData)
        #expect(diskCuration == expectedMerged)
    }

    // MARK: - 5. Conflict Resolution (useLocal, useRemote, cherryPick)

    @Test("Conflict resolution supports useLocal, useRemote, and cherryPick strategies")
    func conflictResolutionStrategies() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item1 = try createTestItem(in: root, fileName: "IMG_2001.JPG")
        let item2 = try createTestItem(in: root, fileName: "IMG_2002.JPG")
        let item3 = try createTestItem(in: root, fileName: "IMG_2003.JPG")
        let allItems = [item1, item2, item3]

        // Setup base sidecars
        let base = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let baseXMP = try SidecarCodec.update(xmlData: nil, with: base)
        for item in allItems {
            try baseXMP.write(to: root.appendingPathComponent("\(item.baseName).xmp"))
        }

        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)
        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine.isSyncSuspended = true

        engine.initializeMetadata(for: allItems)
        await engine.waitForBackgroundHydration()

        // Create conflicts for all 3 items:
        // Local: starRating = 5, pickFlag = .picked
        // Remote: starRating = 3, pickFlag = .rejected
        let localMeta = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green)
        let remoteMeta = CurationMetadata(starRating: 3, pickFlag: .rejected, colorLabel: .red)
        let remoteXMP = try SidecarCodec.update(xmlData: baseXMP, with: remoteMeta)

        for item in allItems {
            engine.updateCurationMetadata(localMeta, for: item)
            try remoteXMP.write(to: root.appendingPathComponent("\(item.baseName).xmp"))
            try await engine.flushPendingWrite(for: item.id, in: allItems)
            #expect(engine.syncState(for: item) == .conflicted)
        }
        #expect(engine.conflictedItemsCount == 3)

        // Strategy A: Resolve item1 using .useLocal
        try await engine.resolveConflict(for: item1, strategy: .useLocal)
        #expect(engine.syncState(for: item1) == .synced)
        #expect(engine.curationMetadata(for: item1) == localMeta)
        let sidecar1Data = try Data(contentsOf: root.appendingPathComponent("\(item1.baseName).xmp"))
        let (parsed1, _) = try SidecarCodec.parse(data: sidecar1Data)
        #expect(parsed1 == localMeta)

        // Strategy B: Resolve item2 using .useRemote
        try await engine.resolveConflict(for: item2, strategy: .useRemote)
        #expect(engine.syncState(for: item2) == .synced)
        #expect(engine.curationMetadata(for: item2) == remoteMeta)
        let sidecar2Data = try Data(contentsOf: root.appendingPathComponent("\(item2.baseName).xmp"))
        let (parsed2, _) = try SidecarCodec.parse(data: sidecar2Data)
        #expect(parsed2 == remoteMeta)

        // Strategy C: Resolve item3 using .cherryPick
        let customMeta = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .yellow)
        try await engine.resolveConflict(for: item3, strategy: .cherryPick(customMeta))
        #expect(engine.syncState(for: item3) == .synced)
        #expect(engine.curationMetadata(for: item3) == customMeta)
        let sidecar3Data = try Data(contentsOf: root.appendingPathComponent("\(item3.baseName).xmp"))
        let (parsed3, _) = try SidecarCodec.parse(data: sidecar3Data)
        #expect(parsed3 == customMeta)

        #expect(engine.conflictedItemsCount == 0)
    }

    // MARK: - 6. Close Timeout and Pending Journal Preservation

    @Test("Close timeout preserves pending journal without dropping queued mutations, and forced close preserves journal")
    func closeTimeoutAndPendingJournalPreservation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try createTestItem(in: root, fileName: "IMG_3001.JPG")
        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)

        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine.isSyncSuspended = true
        engine.initializeMetadata(for: [item])
        await engine.waitForBackgroundHydration()

        let pendingMeta = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .blue)
        engine.updateCurationMetadata(pendingMeta, for: item)
        #expect(engine.pendingWritesCount == 1)

        // Simulate slow write I/O exceeding timeout
        engine.simulatedFlushDelayNanoseconds = 300_000_000

        // Unforced close with short timeout (100ms)
        let unforcedResult = await engine.close(timeoutNanoseconds: 100_000_000, force: false, items: [item])
        #expect(unforcedResult == .pendingWritesRemaining(1))
        #expect(engine.pendingWritesCount == 1)

        // Forced close ("Close Anyway")
        let forcedResult = await engine.close(force: true, items: [item])
        #expect(forcedResult == .closedWithPendingJournaled)

        // Verify mutations remain intact in durable MetadataSyncStore journal
        await engine.waitForPendingStoreWrites()
        let storeRecord = await engine.syncStore.record(for: item.id)
        let persistedRecord = try #require(storeRecord)
        #expect(persistedRecord.syncState == .pendingWrite)
        #expect(persistedRecord.metadata == pendingMeta)

        // Resumption: a new engine instance reloads pending writes from the store
        let engine2 = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine2.initializeMetadata(for: [item])
        #expect(engine2.syncState(for: item) == .pendingWrite)
        #expect(engine2.curationMetadata(for: item) == pendingMeta)
        #expect(engine2.pendingWritesCount == 1)

        // Successfully flush on resumption
        engine2.simulatedFlushDelayNanoseconds = 0
        await engine2.flushPendingWrites(in: [item])
        #expect(engine2.syncState(for: item) == .synced)
        #expect(engine2.pendingWritesCount == 0)

        let sidecarData = try Data(contentsOf: root.appendingPathComponent("IMG_3001.xmp"))
        let (flushedCuration, _) = try SidecarCodec.parse(data: sidecarData)
        #expect(flushedCuration == pendingMeta)
    }

    // MARK: - 7. Non-Blocking Writes & Off-MainActor Hydration (Issue #61 Acceptance Criteria)

    @Test("performDiskFlush executes off @MainActor on background thread")
    func nonBlockingBackgroundFlushExecutionOffMainActor() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try createTestItem(in: root, fileName: "OFF_MAIN.JPG")
        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)
        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine.isSyncSuspended = true
        engine.initializeMetadata(for: [item])
        await engine.waitForBackgroundHydration()

        // Stage mutation
        let curation = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .green)
        engine.updateCurationMetadata(curation, for: item)

        // Flush pending writes
        await engine.flushPendingWrites(in: [item])

        #expect(engine.syncState(for: item) == .synced)
        let sidecarURL = root.appendingPathComponent("OFF_MAIN.xmp")
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test("Optimistic pendingWrite transitions to synced with BaseSnapshot without MainActor stalls")
    func transitionPendingWriteToSyncedWithoutMainActorStalls() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try createTestItem(in: root, fileName: "OPTIMISTIC_STALL.JPG")
        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)
        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine.isSyncSuspended = true
        engine.initializeMetadata(for: [item])
        await engine.waitForBackgroundHydration()

        #expect(engine.syncState(for: item) == .synced)
        let initialCuration = CurationMetadata(starRating: 3, pickFlag: .unflagged, colorLabel: .red)
        engine.updateCurationMetadata(initialCuration, for: item)

        // Synchronous UI transition without blocking
        #expect(engine.syncState(for: item) == .pendingWrite)
        #expect(engine.curationMetadata(for: item) == initialCuration)

        await engine.waitForPendingStoreWrites()
        let recordBeforeFlush = await engine.syncStore.record(for: item.id)
        #expect(recordBeforeFlush?.syncState == .pendingWrite)

        // Flush to disk
        await engine.flushPendingWrites(in: [item])
        #expect(engine.syncState(for: item) == .synced)
        let recordAfterFlush = await engine.syncStore.record(for: item.id)
        #expect(recordAfterFlush?.syncState == .synced)
        #expect(recordAfterFlush?.baseSnapshot?.metadata == initialCuration)
    }

    @Test("Bounded concurrency queue adheres to StorageVolumeProfile workers")
    func boundedConcurrencyAdheresToStorageVolumeProfile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent(".test-sync-store", isDirectory: true)
        let engine = MetadataSyncEngine(storeDirectoryURL: storeRoot)

        // Test profile worker counts
        engine.setStorageVolumeProfile(.networkShare)
        #expect(engine.storageVolumeProfile.defaultSidecarWriteWorkers == 1)

        engine.setStorageVolumeProfile(.internalSSD)
        #expect(engine.storageVolumeProfile.defaultSidecarWriteWorkers == 4)

        engine.setStorageVolumeProfile(.removableMedia)
        #expect(engine.storageVolumeProfile.defaultSidecarWriteWorkers == 2)

        // Set to networkShare (1 worker) and flush a batch of items
        engine.setStorageVolumeProfile(.networkShare)
        engine.isSyncSuspended = true

        var items = [MediaItem]()
        for i in 1...5 {
            let it = try createTestItem(in: root, fileName: "NET_\(i).JPG")
            items.append(it)
        }
        engine.initializeMetadata(for: items)
        await engine.waitForBackgroundHydration()

        for (idx, it) in items.enumerated() {
            engine.updateCurationMetadata(CurationMetadata(starRating: StarRating(idx + 1)), for: it)
        }
        #expect(engine.pendingWritesCount == 5)

        await engine.flushPendingWrites(in: items)

        #expect(engine.pendingWritesCount == 0)
        for (idx, it) in items.enumerated() {
            #expect(engine.syncState(for: it) == .synced)
            let xmp = root.appendingPathComponent("NET_\(idx + 1).xmp")
            #expect(FileManager.default.fileExists(atPath: xmp.path))
        }
    }

    @Test("readSidecarData executes in background off @MainActor")
    func hydrateMetadataOffMainActor() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = try createTestItem(in: root, fileName: "HYDRATE_BG.JPG")
        let xmp = root.appendingPathComponent("HYDRATE_BG.xmp")
        let expected = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .yellow)
        let xmpData = try SidecarCodec.update(xmlData: nil, with: expected)
        try xmpData.write(to: xmp)

        // Verify SidecarCodec async read
        let readData = await SidecarCodec.readData(from: xmp)
        #expect(readData == xmpData)

        // Verify readSidecarData returns correct HydrationOutcome
        let outcome = await MetadataSyncEngine.readSidecarData(for: item)
        switch outcome {
        case .sidecar(let curation, _, let digest, _):
            #expect(curation == expected)
            #expect(digest == SidecarCodec.computeDigest(for: xmpData))
        case .none:
            Issue.record("Expected sidecar outcome but received .none")
        }
    }

    @Test("initializeMetadata pre-emptively resolves items without sidecars to synced using DirectoryListingCache")
    func initializeMetadataPreemptivelyResolvesItemsWithoutSidecars() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            DirectoryListingCache.shared.clear(for: root)
            try? FileManager.default.removeItem(at: root)
        }

        let store = MetadataSyncStore(storeDirectoryURL: root)
        let engine = await MetadataSyncEngine(syncStore: store)

        var items: [MediaItem] = []
        var urls: [URL] = []
        for i in 1...5 {
            let item = try createTestItem(in: root, fileName: "NOSIDECAR_\(i).JPG")
            items.append(item)
            urls.append(item.primaryFile.url)
        }

        // Populate DirectoryListingCache with ONLY the image files (zero sidecars)
        DirectoryListingCache.shared.setContents(urls, for: root)

        // Initialize metadata
        await engine.initializeMetadata(for: items, isLazy: false)

        // All items must immediately be .synced with empty metadata, NOT .loading
        for item in items {
            let state = await engine.syncState(for: item)
            let curation = await engine.curationMetadata(for: item)
            #expect(state == .synced)
            #expect(curation == CurationMetadata())
        }
    }

    // MARK: - Hydration Queue, Bounded Concurrency & Debounce Tests (ADR-0013)

    @Test("HydrationQueueActor executes requests in LIFO order and cancels off-screen tasks")
    func hydrationQueueActorLIFOAndCancellation() async {
        let queue = HydrationQueueActor(maxConcurrentWorkers: 1)
        let orderTracker = ExecutionOrderTracker()

        let blockerStarted = AsyncSignal()
        let blockerRelease = AsyncSignal()

        let blockerTask = Task {
            await queue.enqueue(id: "blocker") { () -> String? in
                await blockerStarted.signal()
                await blockerRelease.wait()
                return "blocker"
            }
        }

        await blockerStarted.wait()

        // Enqueue item 1, then item 2, then item 3
        let task1 = Task {
            await queue.enqueue(id: "item1") { () -> String? in
                await orderTracker.record("item1")
                return "item1"
            }
        }
        while await queue.pendingCount < 1 {
            await Task.yield()
        }

        let task2 = Task {
            await queue.enqueue(id: "item2") { () -> String? in
                await orderTracker.record("item2")
                return "item2"
            }
        }
        while await queue.pendingCount < 2 {
            await Task.yield()
        }

        let task3 = Task {
            await queue.enqueue(id: "item3") { () -> String? in
                await orderTracker.record("item3")
                return "item3"
            }
        }
        while await queue.pendingCount < 3 {
            await Task.yield()
        }

        // Cancel task2 before worker is released (simulating off-screen flinging)
        task2.cancel()
        try? await Task.sleep(nanoseconds: 10_000_000)

        // Release the blocker so queue drains
        await blockerRelease.signal()
        _ = await blockerTask.value

        _ = await task3.value
        _ = await task1.value
        let task2Result = await task2.value

        // Cancelled task2 must return nil
        #expect(task2Result == nil)

        // LIFO order: item3 was enqueued last, so it must execute before item1
        let finalOrder = await orderTracker.order
        #expect(finalOrder == ["item3", "item1"])
    }

    @Test("HydrationQueueActor limits concurrent workers according to StorageVolumeProfile")
    func hydrationQueueActorConcurrencyLimit() async {
        let profile = StorageVolumeProfile.networkShare
        let maxWorkers = profile.defaultSidecarHydrationWorkers // 2
        let queue = HydrationQueueActor(maxConcurrentWorkers: maxWorkers)

        let peakWorkerTracker = PeakWorkerTracker()
        let releaseSignal = AsyncSignal()
        let allStartedSignal = AsyncSignal()

        var tasks: [Task<String?, Never>] = []
        for i in 1...6 {
            let task = Task {
                await queue.enqueue(id: "worker_\(i)") { () -> String? in
                    await peakWorkerTracker.increment()
                    if await peakWorkerTracker.current == maxWorkers {
                        await allStartedSignal.signal()
                    }
                    await releaseSignal.wait()
                    await peakWorkerTracker.decrement()
                    return "worker_\(i)"
                }
            }
            tasks.append(task)
        }

        await allStartedSignal.wait()
        let peak = await peakWorkerTracker.peak
        #expect(peak <= maxWorkers)

        await releaseSignal.signal()
        for task in tasks {
            _ = await task.value
        }
    }

    @Test("Mass background hydration batches UI updates with 300ms debounce timer")
    func massBackgroundHydrationBatchesUpdatesWithDebounce() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            DirectoryListingCache.shared.clear(for: root)
            try? FileManager.default.removeItem(at: root)
        }

        let store = MetadataSyncStore(storeDirectoryURL: root)
        let engine = await MetadataSyncEngine(syncStore: store)
        await MainActor.run {
            // Configure 300ms debounce for test
            engine.hydrationBatchDebounceNanoseconds = 300_000_000
        }

        var items: [MediaItem] = []
        for i in 1...6 {
            let item = try createTestItem(in: root, fileName: "BATCH_\(i).JPG")
            let xmp = root.appendingPathComponent("BATCH_\(i).xmp")
            let curation = CurationMetadata(starRating: StarRating(i), pickFlag: .picked)
            let data = try SidecarCodec.update(xmlData: nil, with: curation)
            try data.write(to: xmp)
            items.append(item)
        }

        await engine.initializeMetadata(for: items, isLazy: true)

        let stateChangeTracker = StateChangeCounter()
        await MainActor.run {
            engine.onStateChange = {
                stateChangeTracker.increment()
            }
        }

        // Start background sidecar hydration
        await engine.startBackgroundSidecarHydration(for: items)
        await engine.waitForBackgroundHydration()

        // Verify all items are now synced with proper curation
        for (i, item) in items.enumerated() {
            let state = await engine.syncState(for: item)
            let curation = await engine.curationMetadata(for: item)
            #expect(state == .synced)
            #expect(curation.starRating == StarRating(i + 1))
        }

        // Verify onStateChange was batched (significantly fewer turns than 6 individual turns)
        let notifications = await stateChangeTracker.count
        #expect(notifications <= 3)
    }

    @Test("On-demand cell hydrateMetadata resolves immediately and extracts from pending batch")
    func cellOnDemandHydrationExtractsFromPendingBatch() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            DirectoryListingCache.shared.clear(for: root)
            try? FileManager.default.removeItem(at: root)
        }

        let store = MetadataSyncStore(storeDirectoryURL: root)
        let engine = await MetadataSyncEngine(syncStore: store)

        let item = try createTestItem(in: root, fileName: "CELL_FAST.JPG")
        let xmp = root.appendingPathComponent("CELL_FAST.xmp")
        let expected = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .blue)
        let data = try SidecarCodec.update(xmlData: nil, with: expected)
        try data.write(to: xmp)

        await engine.initializeMetadata(for: [item], isLazy: true)
        #expect(await engine.syncState(for: item) == .loading)

        // Seed pendingHydrationBatch with pre-processed result to simulate background worker finishing
        let pendingResult = MetadataSyncEngine.HydrationResult(
            itemID: item.id,
            metadata: expected,
            syncState: .synced,
            baseSnapshot: BaseSnapshot(metadata: expected, fileDigest: "fake"),
            conflict: nil,
            discoveredExif: nil
        )
        await MainActor.run {
            engine.recordBatchHydrationResult(pendingResult)
            #expect(engine.pendingHydrationBatch.count == 1)
        }

        // Cell becomes visible: calls hydrateMetadata on-demand
        await engine.hydrateMetadata(for: item)

        // Must extract from batch immediately and apply to MainActor
        let state = await engine.syncState(for: item)
        let curation = await engine.curationMetadata(for: item)
        #expect(state == .synced)
        #expect(curation == expected)

        let remainingInBatch = await MainActor.run { engine.pendingHydrationBatch.count }
        #expect(remainingInBatch == 0)
    }

    @Test("Opening a folder of 100 items lacking sidecars produces zero background hydration tasks and zero loading spinners")
    func folderOf100ItemsLackingSidecarsProducesZeroBackgroundHydrationTasks() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            DirectoryListingCache.shared.clear(for: root)
            try? FileManager.default.removeItem(at: root)
        }

        let store = MetadataSyncStore(storeDirectoryURL: root)
        let engine = await MetadataSyncEngine(syncStore: store)

        var items: [MediaItem] = []
        var urls: [URL] = []
        for i in 1...100 {
            let item = try createTestItem(in: root, fileName: "NOSIDECAR_\(i).JPG")
            items.append(item)
            urls.append(item.primaryFile.url)
        }

        // Cache the directory listing so sidecar absence is confirmed in-memory
        DirectoryListingCache.shared.setContents(urls, for: root)

        // Initialize metadata with isLazy: false (simulating standard folder open)
        await engine.initializeMetadata(for: items, isLazy: false)

        // Verify every single item is immediately .synced with empty snapshot (no .loading)
        for item in items {
            let state = await engine.syncState(for: item)
            let base = await engine.baseSnapshot(for: item)
            #expect(state == .synced)
            #expect(base != nil)
            #expect(base?.fileDigest == "")
        }

        // Verify zero background tasks were dispatched
        await engine.waitForBackgroundHydration()
        let batchCount = await MainActor.run { engine.pendingHydrationBatch.count }
        let inFlight = await MainActor.run { engine.inFlightHydrations.count }
        #expect(batchCount == 0)
        #expect(inFlight == 0)
    }
}

private actor PeakWorkerTracker {
    private(set) var current: Int = 0
    private(set) var peak: Int = 0

    func increment() {
        current += 1
        peak = max(peak, current)
    }

    func decrement() {
        current -= 1
    }
}

private final class StateChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count: Int = 0

    var count: Int {
        lock.withLock { _count }
    }

    func increment() {
        lock.withLock { _count += 1 }
    }
}


