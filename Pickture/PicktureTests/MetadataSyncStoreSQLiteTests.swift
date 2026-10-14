import Foundation
import Testing
@testable import Pickture

@Suite("MetadataSyncStore SQLite & Reset Tests")
struct MetadataSyncStoreSQLiteTests {

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("SQLite point persistence and legacy sync-journal.json cleanup on initialization")
    func sqlitePointPersistenceAndLegacyCleanup() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent("SyncStore", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        // Pre-create legacy sync-journal.json
        let legacyJournalURL = storeRoot.appendingPathComponent("sync-journal.json")
        try Data("{\"legacy\": true}".utf8).write(to: legacyJournalURL)
        #expect(FileManager.default.fileExists(atPath: legacyJournalURL.path))

        // Initialize store
        let store1 = MetadataSyncStore(storeDirectoryURL: storeRoot)

        // Legacy journal must be cleaned up on SQLite startup
        #expect(!FileManager.default.fileExists(atPath: legacyJournalURL.path))

        // SQLite database file must exist
        let sqliteURL = storeRoot.appendingPathComponent("sync-store.sqlite")
        #expect(FileManager.default.fileExists(atPath: sqliteURL.path))

        // Stage point writes
        let item1 = "DSC_0001"
        let meta1 = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .red)
        let base1 = BaseSnapshot(metadata: CurationMetadata(starRating: 0), fileDigest: "digest-1")
        await store1.stagePendingWrite(meta1, baseSnapshot: base1, for: item1)

        let item2 = "DSC_0002"
        let base2 = BaseSnapshot(metadata: CurationMetadata(starRating: 3), fileDigest: "digest-2")
        let exif2 = ExifMetadata(cameraModel: "Sony A1", lensModel: "FE 50mm F1.2 GM")
        await store1.recordBaseSnapshot(base2, exif: exif2, for: item2)

        // Verify records in store 1
        let rec1 = await store1.record(for: item1)
        let record1 = try #require(rec1)
        #expect(record1.syncState == .pendingWrite)
        #expect(record1.metadata == meta1)
        #expect(record1.baseSnapshot?.fileDigest == "digest-1")

        let rec2 = await store1.record(for: item2)
        let record2 = try #require(rec2)
        #expect(record2.syncState == .synced)
        #expect(record2.metadata.starRating == 3)
        #expect(record2.exif?.cameraModel == "Sony A1")

        // Cold restart simulation: open brand new store instance on same directory
        let store2 = MetadataSyncStore(storeDirectoryURL: storeRoot)

        let rel1 = await store2.record(for: item1)
        let reloaded1 = try #require(rel1)
        #expect(reloaded1.syncState == .pendingWrite)
        #expect(reloaded1.metadata == meta1)
        #expect(reloaded1.baseSnapshot?.fileDigest == "digest-1")

        let rel2 = await store2.record(for: item2)
        let reloaded2 = try #require(rel2)
        #expect(reloaded2.syncState == .synced)
        #expect(reloaded2.metadata.starRating == 3)
        #expect(reloaded2.exif?.cameraModel == "Sony A1")

        let allRecords = await store2.allRecords()
        #expect(allRecords.count == 2)
        #expect(allRecords[item1] != nil)
        #expect(allRecords[item2] != nil)
    }

    @Test("MetadataSyncStore actor executes database transactions off @MainActor")
    @MainActor
    func actorExecutionOffMainActor() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent("SyncStore", isDirectory: true)
        let store = MetadataSyncStore(storeDirectoryURL: storeRoot)

        #expect(Thread.isMainThread)

        // Stage write and check thread within actor
        await store.stagePendingWrite(CurationMetadata(starRating: 4), for: "ITEM_MAIN")
        let record = await store.record(for: "ITEM_MAIN")
        #expect(record?.metadata.starRating == 4)
    }

    @Test("Rapid sequential ratings (150+ mutations) execute with sub-millisecond point write latencies")
    func rapidSequentialRatingsSubMillisecondPointLatencies() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent("SyncStore", isDirectory: true)
        let store = MetadataSyncStore(storeDirectoryURL: storeRoot)

        let mutationCount = 150
        let itemID = "DSC_RAPID"

        let start = ContinuousClock.now
        for rating in 1...mutationCount {
            let meta = CurationMetadata(starRating: StarRating((rating % 5) + 1), pickFlag: .picked)
            await store.stagePendingWrite(meta, for: itemID)
        }
        let elapsed = ContinuousClock.now - start

        let totalSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let averageLatencyMs = (totalSeconds / Double(mutationCount)) * 1_000.0

        // Sub-millisecond requirement: average point write latency must be < 1.0 ms
        #expect(averageLatencyMs < 1.0, "Average point write latency was \(averageLatencyMs) ms, expected < 1.0 ms")

        let recRapid = await store.record(for: itemID)
        let finalRecord = try #require(recRapid)
        #expect(finalRecord.syncState == .pendingWrite)
        let expectedFinalRating = (mutationCount % 5) + 1
        #expect(finalRecord.metadata.starRating.value == expectedFinalRating)
    }

    @Test("Resetting MetadataSyncStore purges SQLite records without touching on-disk .xmp files")
    func resetPurgesSQLiteRecordsWithoutTouchingSidecars() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent("SyncStore", isDirectory: true)
        let store = MetadataSyncStore(storeDirectoryURL: storeRoot)

        // Create media file and sidecar on disk
        let imageURL = root.appendingPathComponent("DSC_RESET.JPG")
        try Data("image-content".utf8).write(to: imageURL)
        let sidecarURL = root.appendingPathComponent("DSC_RESET.xmp")
        let initialMetadata = CurationMetadata(starRating: 3, pickFlag: .picked, colorLabel: .blue)
        let initialXMP = try SidecarCodec.update(xmlData: nil, with: initialMetadata)
        try initialXMP.write(to: sidecarURL)

        // Stage un-flushed pending write in sync store
        let pendingMeta = CurationMetadata(starRating: 5, pickFlag: .rejected, colorLabel: .red)
        await store.stagePendingWrite(pendingMeta, for: "DSC_RESET")

        let beforeRec = await store.record(for: "DSC_RESET")
        let beforeResetRecord = try #require(beforeRec)
        #expect(beforeResetRecord.metadata.starRating == 5)

        // Reset the store
        await store.reset()

        // SQLite records must be purged
        let afterResetRecord = await store.record(for: "DSC_RESET")
        #expect(afterResetRecord == nil)
        let allRecordsAfter = await store.allRecords()
        #expect(allRecordsAfter.isEmpty)

        // On-disk .xmp file must be completely untouched and intact
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        let remainingXMPData = try Data(contentsOf: sidecarURL)
        let (parsedCuration, _) = try SidecarCodec.parse(data: remainingXMPData)
        #expect(parsedCuration.starRating == 3)
        #expect(parsedCuration.pickFlag == .picked)
        #expect(parsedCuration.colorLabel == .blue)
    }

    @Test("CullingSession resetMetadataSyncStore purges store and updates session state cleanly")
    @MainActor
    func cullingSessionResetMetadataSyncStoreIntegration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent(".session-store", isDirectory: true)
        let imageURL = root.appendingPathComponent("PHOTO_01.JPG")
        try Data("jpg-data".utf8).write(to: imageURL)

        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)
        await session.waitForBackgroundHydration()

        let item = try #require(session.items.first)
        #expect(session.syncState(for: item) == .synced)
        #expect(session.pendingWritesCount == 0)

        // Create an un-flushed pending write
        session.setStarRating(4, for: item)
        session.setPickFlag(.picked, for: item)
        await session.waitForPendingStoreWrites()

        #expect(session.curationMetadata(for: item).starRating == 4)
        #expect(session.syncState(for: item) == .pendingWrite)
        #expect(session.pendingWritesCount == 1)

        let stRec = await session.metadataSyncStore.record(for: item.id)
        let storeRecord = try #require(stRec)
        #expect(storeRecord.metadata.starRating == 4)

        // Execute reset
        await session.resetMetadataSyncStore()

        // Pending writes count must reset to 0
        #expect(session.pendingWritesCount == 0)
        #expect(session.syncState(for: item) == .synced)

        // SQLite store must have 0 records
        let records = await session.metadataSyncStore.allRecords()
        #expect(records.isEmpty)

        // No sidecar was written because sync was suspended and reset purged the pending write
        let sidecarURL = root.appendingPathComponent("PHOTO_01.xmp")
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }
}
