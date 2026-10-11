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
    func optimisticStagingAndJournalPersistence() throws {
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

        engine.initializeMetadata(for: [item], isLazy: false)

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
        let record = try #require(engine.syncStore.record(for: item.id))
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

        engine.initializeMetadata(for: [item], isLazy: false)
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

        engine.initializeMetadata(for: [item], isLazy: false)
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

        engine.initializeMetadata(for: [item], isLazy: false)

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

        engine.initializeMetadata(for: allItems, isLazy: false)

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
        engine.initializeMetadata(for: [item], isLazy: false)

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
        let persistedRecord = try #require(engine.syncStore.record(for: item.id))
        #expect(persistedRecord.syncState == .pendingWrite)
        #expect(persistedRecord.metadata == pendingMeta)

        // Resumption: a new engine instance reloads pending writes from the store
        let engine2 = MetadataSyncEngine(storeDirectoryURL: storeRoot)
        engine2.initializeMetadata(for: [item], isLazy: false)
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
}
