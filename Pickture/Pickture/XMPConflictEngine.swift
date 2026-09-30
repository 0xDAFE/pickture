import Foundation

nonisolated enum XMPConflictEngine {

    // MARK: - 3-Way Conflict Evaluation

    static func evaluate(
        base: BaseSnapshot?,
        local: CurationMetadata,
        remote: CurationMetadata,
        remoteDigestChanged: Bool,
        itemID: String = ""
    ) -> MetadataConflict? {
        // 1. If remote file has not changed on disk at all, no conflict exists
        guard remoteDigestChanged else {
            return nil
        }

        // 2. If local curation metadata was not modified from base snapshot,
        // no local PendingWrite conflict exists; remote edits should simply be accepted.
        if let base, local == base.metadata {
            return nil
        }

        // 3. If remote curation metadata is identical to the base snapshot,
        // any disk file changes were non-curation (e.g. desktop develop adjustments),
        // so Pickture can safely apply local curation changes without conflict.
        if let base, remote == base.metadata {
            return nil
        }

        // 4. If remote curation equals local curation, both sides arrived at the same state
        if remote == local {
            return nil
        }

        // 5. Remote diverged from base and differs from local -> structured MetadataConflict
        let conflict = MetadataConflict(
            itemID: itemID,
            base: base?.metadata,
            local: local,
            remote: remote
        )
        return conflict.hasConflict ? conflict : nil
    }

    static func evaluate(
        itemID: String,
        base: BaseSnapshot?,
        local: CurationMetadata,
        remote: CurationMetadata,
        remoteDigestChanged: Bool
    ) -> MetadataConflict? {
        evaluate(
            base: base,
            local: local,
            remote: remote,
            remoteDigestChanged: remoteDigestChanged,
            itemID: itemID
        )
    }

    // MARK: - Conflict Resolution & Merging

    static func resolve(
        conflict: MetadataConflict,
        strategy: ConflictResolutionStrategy,
        latestRemoteXMLData: Data
    ) throws -> (mergedMetadata: CurationMetadata, mergedXMLData: Data) {
        let chosenMetadata: CurationMetadata
        switch strategy {
        case .useLocal:
            chosenMetadata = conflict.local
        case .useRemote:
            chosenMetadata = conflict.remote
        case .cherryPick(let custom):
            chosenMetadata = custom
        }

        let mergedXMLData = try SidecarCodec.update(xmlData: latestRemoteXMLData, with: chosenMetadata)
        return (mergedMetadata: chosenMetadata, mergedXMLData: mergedXMLData)
    }
}

