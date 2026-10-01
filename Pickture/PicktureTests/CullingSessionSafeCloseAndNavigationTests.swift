import Foundation
import Testing
@testable import Pickture

@MainActor
struct CullingSessionSafeCloseAndNavigationTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureSafeCloseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - CullingSession Safe Close & Flush Suite

    @Test("Clean close: closing session with 0 pending writes immediately resets currentFolderURL to nil, empties items, and relinquishes folder access")
    func cleanCloseWithZeroPendingWrites() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("fake-jpg".utf8).write(to: root.appendingPathComponent("DSC0001.JPG"))
        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)

        try session.openFolder(at: root)
        #expect(session.currentFolderURL != nil)
        #expect(session.items.count == 1)
        #expect(session.isAccessingFolder == true)
        #expect(session.pendingWritesCount == 0)

        let result = await session.closeFolder()
        #expect(result == .success)
        #expect(session.currentFolderURL == nil)
        #expect(session.items.isEmpty)
        #expect(session.isAccessingFolder == false)
    }

    @Test("Graceful timeout flush: stages pending writes and calling close flushes writes to disk and completes cleanly")
    func gracefulTimeoutFlush() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0002.JPG")
        try Data("fake-jpg".utf8).write(to: jpgURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true

        try session.openFolder(at: root)
        let item = try #require(session.items.first)

        // Stage pending mutation
        session.setStarRating(4, for: item)
        session.setPickFlag(.picked, for: item)
        session.setColorLabel(.yellow, for: item)
        #expect(session.pendingWritesCount == 1)

        let sidecarURL = root.appendingPathComponent("DSC0002.xmp")
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))

        // Call closeFolder without force: should flush within timeout and cleanly close
        let result = await session.closeFolder(force: false)
        #expect(result == .success)
        #expect(session.currentFolderURL == nil)
        #expect(session.items.isEmpty)
        #expect(session.isAccessingFolder == false)

        // Verify sidecar was written to disk with the staged metadata
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        let sidecarData = try Data(contentsOf: sidecarURL)
        let (parsedCuration, _) = try SidecarCodec.parse(data: sidecarData)
        #expect(parsedCuration.starRating == 4)
        #expect(parsedCuration.pickFlag == .picked)
        #expect(parsedCuration.colorLabel == .yellow)
    }

    @Test("Timeout with pending journal preservation: stalled write queue reports pending writes without dropping access; forced close leaves mutations intact in journal")
    func timeoutWithPendingJournalPreservation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("fake-jpg".utf8).write(to: root.appendingPathComponent("DSC0003.JPG"))
        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true

        try session.openFolder(at: root)
        let item = try #require(session.items.first)

        // Stage pending mutation
        session.setStarRating(5, for: item)
        session.setPickFlag(.picked, for: item)
        #expect(session.pendingWritesCount == 1)

        // Simulate slow write I/O exceeding the timeout
        session.simulatedFlushDelayNanoseconds = 300_000_000

        // Unforced close with short timeout (100ms) to simulate slow/stalled remote NAS
        let unforcedResult = await session.closeFolder(force: false, timeoutNanoseconds: 100_000_000)
        #expect(unforcedResult == .pendingWritesRemaining(1))

        // Folder access must NOT be dropped on timeout
        #expect(session.currentFolderURL != nil)
        #expect(session.items.count == 1)
        #expect(session.isAccessingFolder == true)
        #expect(session.pendingWritesCount == 1)

        // Forced close ("Close Anyway"): preserves journal, resets active session, releases security scope
        let forcedResult = await session.closeFolder(force: true)
        #expect(forcedResult == .closedWithPendingJournaled)
        #expect(session.currentFolderURL == nil)
        #expect(session.items.isEmpty)
        #expect(session.isAccessingFolder == false)

        // Verify mutations remain intact in durable MetadataSyncStore journal on disk
        let persistedRecord = try #require(session.metadataSyncStore.record(for: item.id))
        #expect(persistedRecord.syncState == .pendingWrite)
        #expect(persistedRecord.metadata.starRating == 5)
        #expect(persistedRecord.metadata.pickFlag == .picked)
    }

    @Test("Resumption: reopening folder after forced close successfully reloads pending writes from journal and flushes to disk")
    func resumptionAfterForcedClose() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("fake-jpg".utf8).write(to: root.appendingPathComponent("DSC0004.JPG"))
        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true

        try session.openFolder(at: root)
        let item = try #require(session.items.first)

        // Stage pending mutation
        session.setStarRating(3, for: item)
        session.setColorLabel(.green, for: item)
        #expect(session.pendingWritesCount == 1)

        // Force close to preserve in journal
        let closeResult = await session.closeFolder(force: true)
        #expect(closeResult == .closedWithPendingJournaled)
        #expect(session.currentFolderURL == nil)

        // Reopen the folder in a brand new session simulating app launch
        let reopenedSession = CullingSession(storageRootURL: storeRoot)
        reopenedSession.isSyncSuspended = true // suspend to inspect reloaded state
        try reopenedSession.openFolder(at: root)

        let reloadedItem = try #require(reopenedSession.items.first)
        #expect(reopenedSession.syncState(for: reloadedItem) == .pendingWrite)
        #expect(reopenedSession.curationMetadata(for: reloadedItem).starRating == 3)
        #expect(reopenedSession.curationMetadata(for: reloadedItem).colorLabel == .green)
        #expect(reopenedSession.pendingWritesCount == 1)

        // Flush writes to disk
        await reopenedSession.flushPendingWrites()
        #expect(reopenedSession.syncState(for: reloadedItem) == .synced)
        #expect(reopenedSession.pendingWritesCount == 0)

        // Verify sidecar on disk is now updated
        let sidecarURL = root.appendingPathComponent("DSC0004.xmp")
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        let sidecarData = try Data(contentsOf: sidecarURL)
        let (parsed, _) = try SidecarCodec.parse(data: sidecarData)
        #expect(parsed.starRating == 3)
        #expect(parsed.colorLabel == .green)
    }

    // MARK: - Navigation & Error State Suite

    @Test("Attempting to open an invalid URL records an error in lastErrorMessage without updating currentFolderURL")
    func invalidFolderOpenRecordsErrorWithoutUpdatingCurrentFolder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)

        // Initially no folder loaded
        #expect(session.currentFolderURL == nil)
        #expect(session.lastErrorMessage == nil)

        let invalidURL = root.appendingPathComponent("NonExistentFolder_9999", isDirectory: true)
        #expect(throws: Error.self) {
            try session.openFolder(at: invalidURL)
        }

        #expect(session.currentFolderURL == nil)
        #expect(session.lastErrorMessage != nil)

        // Now open a valid folder
        let validFolder = root.appendingPathComponent("ValidFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: validFolder, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: validFolder.appendingPathComponent("test.jpg"))

        try session.openFolder(at: validFolder)
        #expect(session.currentFolderURL?.lastPathComponent == "ValidFolder")
        #expect(session.lastErrorMessage == nil)

        // Attempting to open an invalid URL while a valid folder is open
        #expect(throws: Error.self) {
            try session.openFolder(at: invalidURL)
        }

        // Must still remain pointing to the previously valid folder, with lastErrorMessage set
        #expect(session.currentFolderURL?.lastPathComponent == "ValidFolder")
        #expect(session.lastErrorMessage != nil)
    }

    @Test("Reopening an invalid recent folder records lastErrorMessage without clearing valid active folder")
    func reopenInvalidRecentFolderRecordsErrorWithoutClearingActiveFolder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)

        // Open a folder, then delete it from disk
        let doomedFolder = root.appendingPathComponent("DoomedFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: doomedFolder, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: doomedFolder.appendingPathComponent("img.jpg"))
        try session.openFolder(at: doomedFolder)

        let doomedRecent = try #require(session.recentFolders.first)
        try FileManager.default.removeItem(at: doomedFolder)

        // Open another valid folder
        let activeFolder = root.appendingPathComponent("ActiveFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: activeFolder, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: activeFolder.appendingPathComponent("active.jpg"))
        try session.openFolder(at: activeFolder)
        #expect(session.currentFolderURL?.lastPathComponent == "ActiveFolder")
        #expect(session.lastErrorMessage == nil)

        // Attempt to reopen the deleted recent folder
        #expect(throws: Error.self) {
            try session.reopenRecentFolder(doomedRecent)
        }

        // Active folder is preserved, error is set
        #expect(session.currentFolderURL?.lastPathComponent == "ActiveFolder")
        #expect(session.lastErrorMessage != nil)
    }

    @Test("Removing a recent folder from the sidebar list does not close or modify the active workspace")
    func removeRecentFolderPreservesActiveWorkspace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder1 = root.appendingPathComponent("FolderOne", isDirectory: true)
        let folder2 = root.appendingPathComponent("FolderTwo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: folder1.appendingPathComponent("f1.jpg"))
        try Data("jpg".utf8).write(to: folder2.appendingPathComponent("f2.jpg"))

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)

        // Open folder 1, then folder 2
        try session.openFolder(at: folder1)
        try session.openFolder(at: folder2)
        #expect(session.recentFolders.count == 2)
        #expect(session.currentFolderURL?.lastPathComponent == "FolderTwo")
        #expect(session.items.count == 1)

        let folder1Recent = try #require(session.recentFolders.first { $0.name == "FolderOne" })
        session.removeRecentFolder(folder1Recent)

        #expect(session.recentFolders.count == 1)
        #expect(session.recentFolders.first?.name == "FolderTwo")
        #expect(session.currentFolderURL?.lastPathComponent == "FolderTwo")
        #expect(session.items.count == 1)
    }
}
