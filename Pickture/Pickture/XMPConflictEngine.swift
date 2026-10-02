import Foundation

nonisolated enum XMPConflictEngine {

    // MARK: - 3-Way Conflict Evaluation & Auto-Merge

    static func evaluateThreeWay(
        itemID: String = "",
        base: BaseSnapshot?,
        local: CurationMetadata,
        remote: CurationMetadata?,
        remoteDigestChanged: Bool
    ) -> ThreeWayMergeResult {
        // 1. If remote file has not changed on disk at all, no merge or conflict needed
        guard remoteDigestChanged else {
            return .noChange
        }

        // 2. If remote file was deleted on disk (remote == nil)
        guard let remote else {
            if let base, !base.fileDigest.isEmpty {
                if local == base.metadata {
                    // Local was not modified, remote deleted the file -> clean reset to default
                    return .cleanMerge(CurationMetadata())
                } else {
                    // Local was modified while remote deleted the file -> recreate with local mutations
                    return .cleanMerge(local)
                }
            } else {
                return .noChange
            }
        }

        // 3. If local curation metadata was not modified from base snapshot,
        // accept remote mutations cleanly
        if let base, local == base.metadata {
            return .cleanMerge(remote)
        }

        // 4. If remote curation metadata is identical to base snapshot,
        // any disk changes were non-curation (e.g. camera raw settings),
        // so apply local curation mutations cleanly
        if let base, remote == base.metadata {
            return .cleanMerge(local)
        }

        // 5. If remote equals local, both sides arrived at the same state
        if remote == local {
            return .cleanMerge(local)
        }

        // 6. Check per-field diffs
        let conflict = MetadataConflict(
            itemID: itemID,
            base: base?.metadata,
            local: local,
            remote: remote
        )

        if conflict.hasConflict {
            return .conflict(conflict)
        }

        // 7. Non-conflicting divergent fields: perform 3-way auto-merge!
        let baseMeta = base?.metadata
        let mergedStar = (remote.starRating != baseMeta?.starRating) ? remote.starRating : local.starRating
        let mergedPick = (remote.pickFlag != baseMeta?.pickFlag) ? remote.pickFlag : local.pickFlag
        let mergedLabel = (remote.colorLabel != baseMeta?.colorLabel) ? remote.colorLabel : local.colorLabel

        let mergedCuration = CurationMetadata(
            starRating: mergedStar,
            pickFlag: mergedPick,
            colorLabel: mergedLabel
        )
        return .cleanMerge(mergedCuration)
    }

    static func evaluate(
        itemID: String = "",
        base: BaseSnapshot?,
        local: CurationMetadata,
        remote: CurationMetadata,
        remoteDigestChanged: Bool
    ) -> MetadataConflict? {
        let result = evaluateThreeWay(
            itemID: itemID,
            base: base,
            local: local,
            remote: remote,
            remoteDigestChanged: remoteDigestChanged
        )
        if case .conflict(let conflict) = result {
            return conflict
        }
        return nil
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

