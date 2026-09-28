import Foundation

nonisolated struct MetadataSyncRecord: Codable, Hashable, Sendable {
    var metadata: CurationMetadata
    var syncState: SyncState
    var updatedAt: Date
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

    func stagePendingWrite(_ metadata: CurationMetadata, for itemID: String) {
        recordsByItemID[itemID] = MetadataSyncRecord(
            metadata: metadata,
            syncState: .pendingWrite,
            updatedAt: Date()
        )
        persistJournal()
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
