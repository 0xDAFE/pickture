import Foundation

nonisolated struct MetadataSyncRecord: Codable, Hashable, Sendable {
    var itemID: String
    var metadata: CurationMetadata
    var baseSnapshot: BaseSnapshot?
    var exif: ExifMetadata?
    var syncState: SyncState
    var conflict: MetadataConflict?
    var updatedAt: Date

    init(
        itemID: String,
        metadata: CurationMetadata,
        baseSnapshot: BaseSnapshot? = nil,
        exif: ExifMetadata? = nil,
        syncState: SyncState = .synced,
        conflict: MetadataConflict? = nil,
        updatedAt: Date = Date()
    ) {
        self.itemID = itemID
        self.metadata = metadata
        self.baseSnapshot = baseSnapshot
        self.exif = exif
        self.syncState = syncState
        self.conflict = conflict
        self.updatedAt = updatedAt
    }
}

@MainActor
final class MetadataSyncStore {
    let storeDirectoryURL: URL
    private let journalFileURL: URL
    private var recordsByItemID: [String: MetadataSyncRecord] = [:]

    init(storeDirectoryURL: URL) {
        let standardized = storeDirectoryURL.standardizedFileURL
        self.storeDirectoryURL = standardized
        self.journalFileURL = standardized.appendingPathComponent("sync-journal.json")
        try? FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
        loadJournal()
    }

    func record(for itemID: String) -> MetadataSyncRecord? {
        recordsByItemID[itemID]
    }

    func allRecords() -> [String: MetadataSyncRecord] {
        recordsByItemID
    }

    func stagePendingWrite(_ metadata: CurationMetadata, baseSnapshot: BaseSnapshot? = nil, for itemID: String) {
        let existing = recordsByItemID[itemID]
        let resolvedBase = baseSnapshot ?? existing?.baseSnapshot
        recordsByItemID[itemID] = MetadataSyncRecord(
            itemID: itemID,
            metadata: metadata,
            baseSnapshot: resolvedBase,
            exif: existing?.exif,
            syncState: .pendingWrite,
            conflict: nil,
            updatedAt: Date()
        )
        persistJournal()
    }

    func recordBaseSnapshot(_ snapshot: BaseSnapshot, exif: ExifMetadata? = nil, for itemID: String) {
        if var existing = recordsByItemID[itemID] {
            existing.baseSnapshot = snapshot
            if let exif {
                existing.exif = exif
            }
            if existing.syncState != .pendingWrite && existing.syncState != .conflicted {
                existing.metadata = snapshot.metadata
                existing.syncState = .synced
                existing.conflict = nil
            }
            existing.updatedAt = Date()
            recordsByItemID[itemID] = existing
        } else {
            recordsByItemID[itemID] = MetadataSyncRecord(
                itemID: itemID,
                metadata: snapshot.metadata,
                baseSnapshot: snapshot,
                exif: exif,
                syncState: .synced,
                conflict: nil,
                updatedAt: Date()
            )
        }
        persistJournal()
    }

    func updateSyncState(_ syncState: SyncState, for itemID: String, conflict: MetadataConflict? = nil) {
        guard var existing = recordsByItemID[itemID] else { return }
        existing.syncState = syncState
        existing.conflict = conflict
        existing.updatedAt = Date()
        recordsByItemID[itemID] = existing
        persistJournal()
    }

    func markSynced(for itemID: String, baseSnapshot: BaseSnapshot) {
        let existing = recordsByItemID[itemID]
        recordsByItemID[itemID] = MetadataSyncRecord(
            itemID: itemID,
            metadata: baseSnapshot.metadata,
            baseSnapshot: baseSnapshot,
            exif: existing?.exif,
            syncState: .synced,
            conflict: nil,
            updatedAt: Date()
        )
        persistJournal()
    }

    func recordConflict(_ conflict: MetadataConflict, for itemID: String) {
        if var existing = recordsByItemID[itemID] {
            existing.syncState = .conflicted
            existing.conflict = conflict
            existing.updatedAt = Date()
            recordsByItemID[itemID] = existing
        } else {
            recordsByItemID[itemID] = MetadataSyncRecord(
                itemID: itemID,
                metadata: conflict.local,
                baseSnapshot: conflict.base.map { BaseSnapshot(metadata: $0, fileDigest: "") },
                exif: nil,
                syncState: .conflicted,
                conflict: conflict,
                updatedAt: Date()
            )
        }
        persistJournal()
    }

    func resolveConflict(for itemID: String, resolvedMetadata: CurationMetadata, newBaseSnapshot: BaseSnapshot) {
        let existing = recordsByItemID[itemID]
        recordsByItemID[itemID] = MetadataSyncRecord(
            itemID: itemID,
            metadata: resolvedMetadata,
            baseSnapshot: newBaseSnapshot,
            exif: existing?.exif,
            syncState: .synced,
            conflict: nil,
            updatedAt: Date()
        )
        persistJournal()
    }

    func clear() {
        recordsByItemID.removeAll()
        try? FileManager.default.removeItem(at: journalFileURL)
    }

    private func loadJournal() {
        guard let data = try? Data(contentsOf: journalFileURL),
              let decoded = try? JSONDecoder().decode([String: MetadataSyncRecord].self, from: data) else {
            return
        }
        recordsByItemID = decoded
    }

    private func persistJournal() {
        try? FileManager.default.createDirectory(at: storeDirectoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(recordsByItemID) else { return }
        try? data.write(to: journalFileURL, options: .atomic)
    }
}
