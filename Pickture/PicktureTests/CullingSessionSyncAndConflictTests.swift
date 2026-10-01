import Foundation
import Testing
@testable import Pickture

@MainActor
struct CullingSessionSyncAndConflictTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureSeam2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Slice 1: Optimistic Curation & BaseSnapshot Persistence

    @Test("Assigning StarRating, PickFlag, or ColorLabel updates UI state immediately and persists PendingWrite with BaseSnapshot in MetadataSyncStore")
    func optimisticCurationUpdatesUIAndPersistsPendingWriteWithBaseSnapshot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0010.JPG")
        try Data("fake-jpg-content".utf8).write(to: jpgURL)

        // Write an initial on-disk sidecar with 1 star, unflagged, none
        let initialMetadata = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let initialXMPData = try SidecarCodec.update(xmlData: nil, with: initialMetadata)
        let xmpURL = root.appendingPathComponent("DSC0010.xmp")
        try initialXMPData.write(to: xmpURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true

        try session.openFolder(at: root)
        #expect(session.items.count == 1)

        let item = try #require(session.items.first)
        #expect(session.syncState(for: item) == .synced)
        #expect(session.curationMetadata(for: item) == initialMetadata)

        let initialBaseSnapshot = try #require(session.baseSnapshot(for: item))
        #expect(initialBaseSnapshot.metadata == initialMetadata)
        #expect(!initialBaseSnapshot.fileDigest.isEmpty)

        // Assign optimistic mutations
        session.setStarRating(5, for: item)
        session.setPickFlag(.picked, for: item)
        session.setColorLabel(.green, for: item)

        let expectedOptimistic = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green)
        #expect(session.curationMetadata(for: item) == expectedOptimistic)
        #expect(session.syncState(for: item) == .pendingWrite)
        #expect(session.pendingWritesCount == 1)

        // Verify MetadataSyncStore holds the pending write alongside the item's BaseSnapshot
        let record = try #require(session.metadataSyncStore.record(for: item.id))
        #expect(record.syncState == .pendingWrite)
        #expect(record.metadata == expectedOptimistic)
        #expect(record.baseSnapshot?.metadata == initialMetadata)
        #expect(record.baseSnapshot?.fileDigest == initialBaseSnapshot.fileDigest)
    }

    // MARK: - Slice 2: Durability Across App Restarts & Cache Purge Isolation

    @Test("MetadataSyncStore survives simulated app restarts and is unaffected by MediaCache quota changes or clearMediaCache")
    func metadataSyncStoreSurvivesRestartsAndCachePurges() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("IMG_5000.JPG")
        try Data("jpg-data".utf8).write(to: jpgURL)

        let initialMetadata = CurationMetadata(starRating: 2, pickFlag: .unflagged, colorLabel: .blue)
        let initialXMP = try SidecarCodec.update(xmlData: nil, with: initialMetadata)
        try initialXMP.write(to: root.appendingPathComponent("IMG_5000.xmp"))

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)

        // Session 1: open and stage optimistic edits
        let session1 = CullingSession(storageRootURL: storeRoot)
        session1.isSyncSuspended = true
        try session1.openFolder(at: root)

        let item1 = try #require(session1.items.first)
        session1.setStarRating(4, for: item1)
        session1.setPickFlag(.picked, for: item1)
        session1.setColorLabel(.purple, for: item1)

        let pendingExpected = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .purple)
        #expect(session1.curationMetadata(for: item1) == pendingExpected)
        #expect(session1.syncState(for: item1) == .pendingWrite)

        // Clear MediaCache and adjust cache limit
        session1.clearMediaCache()
        session1.setUserConfiguredCacheSizeLimitBytes(MediaCache.minUserQuotaBytes)

        #expect(session1.mediaCacheTotalBytes == 0)
        #expect(session1.curationMetadata(for: item1) == pendingExpected)
        #expect(session1.syncState(for: item1) == .pendingWrite)

        // Session 2: simulate cold app restart with a brand new CullingSession
        let session2 = CullingSession(storageRootURL: storeRoot)
        session2.isSyncSuspended = true
        try session2.openFolder(at: root)

        let item2 = try #require(session2.items.first)
        #expect(session2.syncState(for: item2) == .pendingWrite)
        #expect(session2.curationMetadata(for: item2) == pendingExpected)
        #expect(session2.pendingWritesCount == 1)

        let reloadedBase = try #require(session2.baseSnapshot(for: item2))
        #expect(reloadedBase.metadata == initialMetadata)
    }

    // MARK: - Slice 3: Background Synchronization & Asynchronous Sidecar Flushing

    @Test("Background sync flushes PendingWrite entries to .xmp sidecars on disk and updates SyncState and workspace summary badge")
    func backgroundSyncFlushesPendingWritesToDiskAndUpdatesSyncState() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC_9001.JPG")
        try Data("jpg-raw-stream".utf8).write(to: jpgURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item = try #require(session.items.first)
        #expect(session.syncState(for: item) == .synced)
        #expect(session.syncSummaryBadgeText == "Synced")
        #expect(session.syncSummaryState == .synced)

        // Stage mutation while sync suspended
        session.setStarRating(3, for: item)
        session.setPickFlag(.picked, for: item)
        session.setColorLabel(.red, for: item)

        #expect(session.syncState(for: item) == .pendingWrite)
        #expect(session.pendingWritesCount == 1)
        #expect(session.syncSummaryBadgeText == "1 Pending")
        #expect(session.syncSummaryState == .pendingWrite)

        // Sidecar should not yet have been written to disk
        let sidecarURL = root.appendingPathComponent("DSC_9001.xmp")
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))

        // Trigger asynchronous flush
        await session.flushPendingWrites()

        // Verify sidecar now exists on disk and has correct parsed metadata
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        let writtenData = try Data(contentsOf: sidecarURL)
        let (parsedCuration, _) = try SidecarCodec.parse(data: writtenData)
        #expect(parsedCuration.starRating == 3)
        #expect(parsedCuration.pickFlag == .picked)
        #expect(parsedCuration.colorLabel == .red)

        // Verify session state is Synced
        #expect(session.syncState(for: item) == .synced)
        #expect(session.pendingWritesCount == 0)
        #expect(session.syncSummaryBadgeText == "Synced")
        #expect(session.syncSummaryState == .synced)

        // Verify BaseSnapshot updated with new file digest
        let updatedBase = try #require(session.baseSnapshot(for: item))
        #expect(updatedBase.metadata == parsedCuration)
        #expect(updatedBase.fileDigest == SidecarCodec.computeDigest(for: writtenData))
    }

    // MARK: - Slice 4: 3-Way Conflict Detection on External Disk Edit

    @Test("External disk edits during PendingWrite transition item to SyncState.conflicted without overwriting disk")
    func externalDiskEditTransitionsToConflictedWithoutOverwritingDisk() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC_7777.JPG")
        try Data("jpg-data".utf8).write(to: jpgURL)

        // Initial base on disk: 1 star, unflagged, none
        let baseMetadata = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let baseXMPData = try SidecarCodec.update(xmlData: nil, with: baseMetadata)
        let xmpURL = root.appendingPathComponent("DSC_7777.xmp")
        try baseXMPData.write(to: xmpURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item = try #require(session.items.first)
        #expect(session.syncState(for: item) == .synced)

        // Local user stages mutation (Local: 5 stars, picked, green)
        session.setStarRating(5, for: item)
        session.setPickFlag(.picked, for: item)
        session.setColorLabel(.green, for: item)
        #expect(session.syncState(for: item) == .pendingWrite)

        // External tool modifies disk sidecar (Remote: 3 stars, rejected, red)
        let externalMetadata = CurationMetadata(starRating: 3, pickFlag: .rejected, colorLabel: .red)
        let externalXMPData = try SidecarCodec.update(xmlData: baseXMPData, with: externalMetadata)
        try externalXMPData.write(to: xmpURL)

        // Attempt to flush pending writes
        await session.flushPendingWrites()

        // Verify the item transitioned to .conflicted instead of overwriting disk!
        #expect(session.syncState(for: item) == .conflicted)
        #expect(session.conflictedItemsCount == 1)
        #expect(session.syncSummaryState == .conflicted)
        #expect(session.syncSummaryBadgeText == "1 Conflict")

        // Verify disk was NOT overwritten by local edits
        let diskDataAfterFlush = try Data(contentsOf: xmpURL)
        let (diskCuration, _) = try SidecarCodec.parse(data: diskDataAfterFlush)
        #expect(diskCuration == externalMetadata) // Disk still has external edit!

        // Verify structured MetadataConflict
        let conflict = try #require(session.conflict(for: item))
        #expect(conflict.base == baseMetadata)
        #expect(conflict.local == CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green))
        #expect(conflict.remote == externalMetadata)
        #expect(conflict.starRatingDiff.isConflicted == true)
        #expect(conflict.pickFlagDiff.isConflicted == true)
        #expect(conflict.colorLabelDiff.isConflicted == true)
    }

    // MARK: - Slice 5: Single Item & Batch Conflict Resolution

    @Test("Single item conflict resolution via cherry-picking merges chosen fields to disk and transitions to synced")
    func singleItemConflictResolutionCherryPick() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC_8888.JPG")
        try Data("jpg-data".utf8).write(to: jpgURL)

        let baseXMP = try SidecarCodec.update(xmlData: nil, with: CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none))
        let xmpURL = root.appendingPathComponent("DSC_8888.xmp")
        try baseXMP.write(to: xmpURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item = try #require(session.items.first)
        session.setStarRating(5, for: item) // local = 5 stars, unflagged, none

        // Remote edits disk sidecar with crs:Exposure2012="+1.00", 2 stars, rejected, blue
        let thirdPartyXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmp:Rating="2"
            crs:Pick="-1"
            xmp:Label="Blue"
            crs:Exposure2012="+1.00"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try thirdPartyXML.write(to: xmpURL, atomically: true, encoding: .utf8)

        // Flush detects conflict
        await session.flushPendingWrites()
        #expect(session.syncState(for: item) == .conflicted)

        // Cherry-pick: 5 stars (from local), rejected (from remote), blue (from remote)
        let cherryPicked = CurationMetadata(starRating: 5, pickFlag: .rejected, colorLabel: .blue)
        try await session.resolveConflict(for: item, strategy: .cherryPick(cherryPicked))

        #expect(session.syncState(for: item) == .synced)
        #expect(session.conflict(for: item) == nil)
        #expect(session.curationMetadata(for: item) == cherryPicked)
        #expect(session.conflictedItemsCount == 0)

        // Verify disk sidecar merged cherry-picked fields and preserved crs:Exposure2012 intact
        let mergedDiskData = try Data(contentsOf: xmpURL)
        let (parsedCuration, _) = try SidecarCodec.parse(data: mergedDiskData)
        #expect(parsedCuration == cherryPicked)
        let mergedXMLString = String(decoding: mergedDiskData, as: UTF8.self)
        #expect(mergedXMLString.contains("crs:Exposure2012=\"+1.00\""))

        let updatedBase = try #require(session.baseSnapshot(for: item))
        #expect(updatedBase.metadata == cherryPicked)
        #expect(updatedBase.fileDigest == SidecarCodec.computeDigest(for: mergedDiskData))
    }

    @Test("Batch conflict resolution resolves multiple conflicted items with Use Local for All and Use Remote for All")
    func batchConflictResolutionUseLocalAndRemoteForAll() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create Item 1 & Item 2
        let jpg1 = root.appendingPathComponent("BATCH_1.JPG")
        let jpg2 = root.appendingPathComponent("BATCH_2.JPG")
        try Data("jpg1".utf8).write(to: jpg1)
        try Data("jpg2".utf8).write(to: jpg2)

        let baseMetadata = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let baseXMP = try SidecarCodec.update(xmlData: nil, with: baseMetadata)
        let xmp1 = root.appendingPathComponent("BATCH_1.xmp")
        let xmp2 = root.appendingPathComponent("BATCH_2.xmp")
        try baseXMP.write(to: xmp1)
        try baseXMP.write(to: xmp2)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item1 = try #require(session.items.first { $0.baseName == "BATCH_1" })
        let item2 = try #require(session.items.first { $0.baseName == "BATCH_2" })

        // Local edits: item1 -> 5 stars picked, item2 -> 4 stars green
        let local1 = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .none)
        let local2 = CurationMetadata(starRating: 4, pickFlag: .unflagged, colorLabel: .green)
        session.updateCurationMetadata(local1, for: item1)
        session.updateCurationMetadata(local2, for: item2)

        // External edits: item1 -> 2 stars rejected, item2 -> 3 stars red
        let remote1 = CurationMetadata(starRating: 2, pickFlag: .rejected, colorLabel: .none)
        let remote2 = CurationMetadata(starRating: 3, pickFlag: .unflagged, colorLabel: .red)
        try SidecarCodec.update(xmlData: baseXMP, with: remote1).write(to: xmp1)
        try SidecarCodec.update(xmlData: baseXMP, with: remote2).write(to: xmp2)

        // Trigger flush -> both become conflicted
        await session.flushPendingWrites()
        #expect(session.syncState(for: item1) == .conflicted)
        #expect(session.syncState(for: item2) == .conflicted)
        #expect(session.conflictedItemsCount == 2)
        #expect(session.syncSummaryState == .conflicted)
        #expect(session.syncSummaryBadgeText == "2 Conflicts")

        // Batch Action 1: "Use Local for All (2)"
        try await session.resolveAllConflictsWithLocal()

        #expect(session.syncState(for: item1) == .synced)
        #expect(session.syncState(for: item2) == .synced)
        #expect(session.conflictedItemsCount == 0)
        #expect(session.syncSummaryState == .synced)
        #expect(session.syncSummaryBadgeText == "Synced")

        let diskData1 = try Data(contentsOf: xmp1)
        let diskData2 = try Data(contentsOf: xmp2)
        #expect(try SidecarCodec.parse(data: diskData1).curation == local1)
        #expect(try SidecarCodec.parse(data: diskData2).curation == local2)

        // Now test "Use Remote for All" by introducing new conflicts
        session.isSyncSuspended = true
        session.setStarRating(3, for: item1)
        session.setStarRating(2, for: item2)

        let newRemote1 = CurationMetadata(starRating: 1, pickFlag: .rejected, colorLabel: .purple)
        let newRemote2 = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .yellow)
        try SidecarCodec.update(xmlData: diskData1, with: newRemote1).write(to: xmp1)
        try SidecarCodec.update(xmlData: diskData2, with: newRemote2).write(to: xmp2)

        await session.flushPendingWrites()
        #expect(session.conflictedItemsCount == 2)

        // Batch Action 2: "Use Remote for All (2)"
        try await session.resolveAllConflictsWithRemote()

        #expect(session.syncState(for: item1) == .synced)
        #expect(session.syncState(for: item2) == .synced)
        #expect(session.conflictedItemsCount == 0)
        #expect(session.curationMetadata(for: item1) == newRemote1)
        #expect(session.curationMetadata(for: item2) == newRemote2)
    }

    // MARK: - Slice 6: Retry Failed Writes (Spec #21)

    @Test("retryFailedWrites re-queues syncError items to pendingWrite, flushes to disk, and transitions to synced")
    func retryFailedWritesRequeuesAndFlushesToDisk() async throws {
        let root = try makeTemporaryDirectory()
        defer {
            // Restore write permissions on cleanup if needed
            let xmp = root.appendingPathComponent("RETRY01.xmp")
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: xmp.path)
            try? FileManager.default.removeItem(at: root)
        }

        let jpgURL = root.appendingPathComponent("RETRY01.JPG")
        try Data("jpg-bytes".utf8).write(to: jpgURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item = try #require(session.items.first)
        let curation = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green)

        // Create a read-only sidecar file with valid initial XMP to induce a disk write permission error
        let xmpURL = root.appendingPathComponent("RETRY01.xmp")
        let initialXMP = try SidecarCodec.update(xmlData: nil, with: CurationMetadata())
        try initialXMP.write(to: xmpURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: xmpURL.path)

        session.updateCurationMetadata(curation, for: item)
        #expect(session.syncState(for: item) == .pendingWrite)

        // Flush writes while file is read-only -> fails and sets syncError
        await session.flushPendingWrites()

        #expect(session.syncState(for: item) == .syncError)
        #expect(session.syncSummaryState == .syncError)
        #expect(session.syncSummaryBadgeText == "1 Error")
        #expect(session.lastErrorMessage != nil)

        // Make sidecar writable again and retry failed writes
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: xmpURL.path)
        await session.retryFailedWrites()

        #expect(session.syncState(for: item) == .synced)
        #expect(session.syncSummaryState == .synced)
        #expect(session.syncSummaryBadgeText == "Synced")
        #expect(session.lastErrorMessage == nil)

        // Verify sidecar file on disk contains the curation
        let diskData = try Data(contentsOf: xmpURL)
        let parsed = try SidecarCodec.parse(data: diskData)
        #expect(parsed.curation == curation)
    }

    // MARK: - Slice 7: Re-entrant Flush Queuing (Spec #21)

    @Test("Re-entrant mutations during active flush automatically queue and flush to disk without dropping writes")
    func reentrantMutationsDuringActiveFlushAreFlushed() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpg1 = root.appendingPathComponent("REENTRANT_1.JPG")
        let jpg2 = root.appendingPathComponent("REENTRANT_2.JPG")
        try Data("jpg1".utf8).write(to: jpg1)
        try Data("jpg2".utf8).write(to: jpg2)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item1 = try #require(session.items.first { $0.baseName == "REENTRANT_1" })
        let item2 = try #require(session.items.first { $0.baseName == "REENTRANT_2" })

        // Enable slow flush delay
        session.simulatedFlushDelayNanoseconds = 50_000_000 // 50ms per item
        session.isSyncSuspended = false

        // First mutation: triggers background flush of item1
        session.setStarRating(4, for: item1)

        // Wait a short slice so flush has started processing item1
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Second mutation while flush is in-flight: should be queued re-entrantly
        session.setStarRating(2, for: item2)

        // Wait for all flushes to complete (up to 1.5 seconds)
        for _ in 0..<30 {
            if session.pendingWritesCount == 0 && session.syncSummaryState == .synced {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(session.pendingWritesCount == 0)
        #expect(session.syncState(for: item1) == .synced)
        #expect(session.syncState(for: item2) == .synced)
        #expect(session.syncSummaryState == .synced)

        // Verify both sidecars were persisted on disk
        let xmp1 = root.appendingPathComponent("REENTRANT_1.xmp")
        let xmp2 = root.appendingPathComponent("REENTRANT_2.xmp")
        #expect(FileManager.default.fileExists(atPath: xmp1.path))
        #expect(FileManager.default.fileExists(atPath: xmp2.path))

        let parsed1 = try SidecarCodec.parse(data: try Data(contentsOf: xmp1))
        let parsed2 = try SidecarCodec.parse(data: try Data(contentsOf: xmp2))
        #expect(parsed1.curation.starRating == 4)
        #expect(parsed2.curation.starRating == 2)
    }
}
