import Foundation
import Testing
@testable import Pickture

struct XMPConflictEngineTests {

    // MARK: - Three-Way Conflict Evaluation Matrix

    @Test("XMPConflictEngine reports no conflict when remoteDigestChanged is false")
    func conflictEngineNoConflictWhenRemoteDigestUnchanged() {
        let baseMeta = CurationMetadata(starRating: 3, pickFlag: .unflagged, colorLabel: .none)
        let baseSnapshot = BaseSnapshot(metadata: baseMeta, fileDigest: "digest-1")
        let localMeta = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .red)
        let remoteMeta = CurationMetadata(starRating: 3, pickFlag: .unflagged, colorLabel: .none)

        let conflict = XMPConflictEngine.evaluate(
            itemID: "item-1",
            base: baseSnapshot,
            local: localMeta,
            remote: remoteMeta,
            remoteDigestChanged: false
        )
        #expect(conflict == nil)
    }

    @Test("XMPConflictEngine reports no conflict when remote curation equals base metadata even if remote digest changed externally")
    func conflictEngineNoConflictWhenRemoteCurationMatchesBase() {
        let baseMeta = CurationMetadata(starRating: 2, pickFlag: .unflagged, colorLabel: .blue)
        let baseSnapshot = BaseSnapshot(metadata: baseMeta, fileDigest: "digest-1")
        let localMeta = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .blue)
        // Remote file had external develop edits (digest changed), but curation metadata is unchanged from base
        let remoteMeta = CurationMetadata(starRating: 2, pickFlag: .unflagged, colorLabel: .blue)

        let conflict = XMPConflictEngine.evaluate(
            itemID: "item-2",
            base: baseSnapshot,
            local: localMeta,
            remote: remoteMeta,
            remoteDigestChanged: true
        )
        #expect(conflict == nil)
    }

    @Test("XMPConflictEngine reports no conflict when remote curation equals local curation")
    func conflictEngineNoConflictWhenRemoteMatchesLocal() {
        let baseMeta = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let baseSnapshot = BaseSnapshot(metadata: baseMeta, fileDigest: "digest-1")
        let localMeta = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .green)
        let remoteMeta = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .green)

        let conflict = XMPConflictEngine.evaluate(
            itemID: "item-3",
            base: baseSnapshot,
            local: localMeta,
            remote: remoteMeta,
            remoteDigestChanged: true
        )
        #expect(conflict == nil)
    }

    @Test("XMPConflictEngine reports no conflict when local has no uncommitted changes (local == base)")
    func conflictEngineNoConflictWhenLocalEqualsBase() {
        let baseMeta = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let baseSnapshot = BaseSnapshot(metadata: baseMeta, fileDigest: "digest-1")
        // Local has not changed from base
        let localMeta = baseMeta
        // Remote was modified externally to 5 stars
        let remoteMeta = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .red)

        let conflict = XMPConflictEngine.evaluate(
            base: baseSnapshot,
            local: localMeta,
            remote: remoteMeta,
            remoteDigestChanged: true
        )
        #expect(conflict == nil)
    }

    @Test("XMPConflictEngine raises structured MetadataConflict with per-field diffs when remote diverged from base and local")
    func conflictEngineDetectsFieldLevelConflict() {
        let baseMeta = CurationMetadata(starRating: 2, pickFlag: .unflagged, colorLabel: .none)
        let baseSnapshot = BaseSnapshot(metadata: baseMeta, fileDigest: "digest-1")
        // Local: user picked item, gave 5 stars, labeled blue
        let localMeta = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .blue)
        // Remote: desktop user rejected item, gave 1 star, and labeled red
        let remoteMeta = CurationMetadata(starRating: 1, pickFlag: .rejected, colorLabel: .red)

        let conflict = XMPConflictEngine.evaluate(
            itemID: "item-4",
            base: baseSnapshot,
            local: localMeta,
            remote: remoteMeta,
            remoteDigestChanged: true
        )

        let unwrapped = try! #require(conflict)
        #expect(unwrapped.itemID == "item-4")
        #expect(unwrapped.hasConflict == true)

        // StarRating diff
        #expect(unwrapped.starRatingDiff.base == 2)
        #expect(unwrapped.starRatingDiff.local == 5)
        #expect(unwrapped.starRatingDiff.remote == 1)
        #expect(unwrapped.starRatingDiff.isConflicted == true)

        // PickFlag diff
        #expect(unwrapped.pickFlagDiff.base == .unflagged)
        #expect(unwrapped.pickFlagDiff.local == .picked)
        #expect(unwrapped.pickFlagDiff.remote == .rejected)
        #expect(unwrapped.pickFlagDiff.isConflicted == true)

        // ColorLabel diff
        #expect(unwrapped.colorLabelDiff.base == ColorLabel.none)
        #expect(unwrapped.colorLabelDiff.local == ColorLabel.blue)
        #expect(unwrapped.colorLabelDiff.remote == ColorLabel.red)
        #expect(unwrapped.colorLabelDiff.isConflicted == true)
    }

    // MARK: - Conflict Resolution & Merging

    @Test("Resolve conflict with useLocal merges local curation into latest remote XML preserving desktop adjustments")
    func resolveConflictUseLocal() throws {
        let remoteXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            crs:Exposure2012="+1.20"
            crs:Temperature="4800"
            crs:Pick="-1"
            xmp:Rating="1"
            xmp:Label="Red"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let remoteData = Data(remoteXML.utf8)
        let localMeta = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green)
        let remoteMeta = CurationMetadata(starRating: 1, pickFlag: .rejected, colorLabel: .red)
        let baseMeta = CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none)

        let conflict = MetadataConflict(
            itemID: "item-res-1",
            base: baseMeta,
            local: localMeta,
            remote: remoteMeta
        )

        let (mergedMeta, mergedData) = try XMPConflictEngine.resolve(
            conflict: conflict,
            strategy: .useLocal,
            latestRemoteXMLData: remoteData
        )

        #expect(mergedMeta == localMeta)

        let xmlString = String(decoding: mergedData, as: UTF8.self)
        // Desktop develop tags preserved
        #expect(xmlString.contains("crs:Exposure2012=\"+1.20\""))
        #expect(xmlString.contains("crs:Temperature=\"4800\""))
        // Local curation applied
        #expect(xmlString.contains("xmp:Rating=\"5\""))
        #expect(xmlString.contains("crs:Pick=\"1\""))
        #expect(xmlString.contains("xmp:Label=\"Green\""))
    }

    @Test("Resolve conflict with cherryPick merges selected fields into latest remote XML")
    func resolveConflictCherryPick() throws {
        let remoteXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            crs:Highlights2012="-50"
            crs:Pick="1"
            xmp:Rating="2"
            xmp:Label="Blue"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let remoteData = Data(remoteXML.utf8)
        let localMeta = CurationMetadata(starRating: 4, pickFlag: .unflagged, colorLabel: .purple)
        let remoteMeta = CurationMetadata(starRating: 2, pickFlag: .picked, colorLabel: .blue)
        let baseMeta = CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none)

        let conflict = MetadataConflict(
            itemID: "item-res-2",
            base: baseMeta,
            local: localMeta,
            remote: remoteMeta
        )

        // User cherry-picks: keep local rating (4), keep remote pick flag (.picked), select none for color label
        let cherryPickedMeta = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .none)

        let (mergedMeta, mergedData) = try XMPConflictEngine.resolve(
            conflict: conflict,
            strategy: .cherryPick(cherryPickedMeta),
            latestRemoteXMLData: remoteData
        )

        #expect(mergedMeta == cherryPickedMeta)

        let xmlString = String(decoding: mergedData, as: UTF8.self)
        #expect(xmlString.contains("crs:Highlights2012=\"-50\""))
        #expect(xmlString.contains("xmp:Rating=\"4\""))
        #expect(xmlString.contains("crs:Pick=\"1\""))
        #expect(!xmlString.contains("xmp:Label=\"Blue\""))
        #expect(!xmlString.contains("xmp:Label=\"Purple\""))
    }

    @Test("Resolve conflict with useRemote retains remote curation and updates remote XML")
    func resolveConflictUseRemote() throws {
        let remoteXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            crs:Exposure2012="+0.50"
            crs:Pick="-1"
            xmp:Rating="1"
            xmp:Label="Red"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let remoteData = Data(remoteXML.utf8)
        let localMeta = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green)
        let remoteMeta = CurationMetadata(starRating: 1, pickFlag: .rejected, colorLabel: .red)
        let baseMeta = CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none)

        let conflict = MetadataConflict(
            itemID: "item-res-3",
            base: baseMeta,
            local: localMeta,
            remote: remoteMeta
        )

        let (mergedMeta, mergedData) = try XMPConflictEngine.resolve(
            conflict: conflict,
            strategy: .useRemote,
            latestRemoteXMLData: remoteData
        )

        #expect(mergedMeta == remoteMeta)

        let xmlString = String(decoding: mergedData, as: UTF8.self)
        #expect(xmlString.contains("crs:Exposure2012=\"+0.50\""))
        #expect(xmlString.contains("xmp:Rating=\"1\""))
        #expect(xmlString.contains("crs:Pick=\"-1\""))
        #expect(xmlString.contains("xmp:Label=\"Red\""))
    }
}
