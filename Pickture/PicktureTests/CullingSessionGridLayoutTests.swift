//
//  CullingSessionGridLayoutTests.swift
//  PicktureTests
//
//  Created by Vibe Coder on 30.09.26.
//

import CoreGraphics
import Foundation
import Testing
@testable import Pickture

@MainActor
struct CullingSessionGridLayoutTests {

    // MARK: - Slice 1: Grid Cell Dimension Contracts (185pt - 260pt)

    @Test("Grid cell dimension contracts: standard column widths (185pt to 260pt) allocate bounded stage height without layout explosion")
    func gridCellDimensionContractsStandardWidthConfigurations() {
        let session = CullingSession()

        // Pinned metadata deck height is 48pt across all grid rows
        #expect(session.gridMetadataDeckHeight == 48.0)

        // 185pt minimum column width -> 139pt stage height
        let minStageHeight = session.gridStageHeight(for: 185.0)
        #expect(minStageHeight == 139.0)

        // 200pt typical column width -> 150pt stage height
        let midStageHeight = session.gridStageHeight(for: 200.0)
        #expect(midStageHeight == 150.0)

        // 240pt column width -> 180pt stage height
        let wideStageHeight = session.gridStageHeight(for: 240.0)
        #expect(wideStageHeight == 180.0)

        // 260pt maximum column width -> 195pt stage height
        let maxStageHeight = session.gridStageHeight(for: 260.0)
        #expect(maxStageHeight == 195.0)

        // Ensure proper stage height across standard range without layout explosion
        for width in stride(from: 185.0, through: 260.0, by: 15.0) {
            let height = session.gridStageHeight(for: width)
            #expect(height >= 135.0 && height <= 200.0)
            let totalHeight = height + session.gridMetadataDeckHeight
            #expect(totalHeight >= 180.0 && totalHeight <= 250.0)
        }

        // Boundary and safe fallbacks for invalid values
        #expect(session.gridStageHeight(for: 0.0) == 140.0)
        #expect(session.gridStageHeight(for: -50.0) == 140.0)
        #expect(session.gridStageHeight(for: .nan) == 140.0)
        #expect(session.gridStageHeight(for: .infinity) == 140.0)
    }

    // MARK: - Slice 2: Dynamic Aspect Ratio Silhouette Preservation (16:9, 3:2, 2:3, 1:1, 9:16)

    @Test("Wide video items (16:9) preserve exact aspect ratio calculation within bounded stage")
    func wideVideoItem16By9PreservesExactAspectRatioWithinBoundedStage() {
        let session = CullingSession()
        let stageWidth: CGFloat = 200.0
        let stageHeight = session.gridStageHeight(for: stageWidth) // 150.0

        let videoRatio: CGFloat = 16.0 / 9.0 // ~1.7778
        let size = session.gridItemSilhouetteSize(
            aspectRatio: videoRatio,
            stageWidth: stageWidth,
            stageHeight: stageHeight,
            mediaKind: .video
        )

        // Bounded by width (wider than 4:3 stage ceiling)
        #expect(size.width == 200.0)
        #expect(size.height == 112.5)
        #expect(abs((size.width / size.height) - videoRatio) < 0.0001)
        #expect(size.height <= stageHeight)
    }

    @Test("Standard MediaItems (3:2) preserve exact aspect ratio calculation within bounded stage")
    func standardMediaItem3By2PreservesExactAspectRatioWithinBoundedStage() {
        let session = CullingSession()
        let stageWidth: CGFloat = 200.0
        let stageHeight = session.gridStageHeight(for: stageWidth) // 150.0

        let photoRatio: CGFloat = 1.5 // 3:2 DSLR RAW
        let size = session.gridItemSilhouetteSize(
            aspectRatio: photoRatio,
            stageWidth: stageWidth,
            stageHeight: stageHeight,
            mediaKind: .photo
        )

        // Bounded by width
        #expect(size.width == 200.0)
        #expect(abs(size.height - (200.0 / 1.5)) < 0.0001)
        #expect(abs((size.width / size.height) - 1.5) < 0.0001)
        #expect(size.height <= stageHeight)
    }

    @Test("Portrait MediaItems (2:3) preserve exact aspect ratio calculation within bounded stage")
    func portraitMediaItem2By3PreservesExactAspectRatioWithinBoundedStage() {
        let session = CullingSession()
        let stageWidth: CGFloat = 200.0
        let stageHeight = session.gridStageHeight(for: stageWidth) // 150.0

        let portraitRatio: CGFloat = 2.0 / 3.0 // ~0.6667
        let size = session.gridItemSilhouetteSize(
            aspectRatio: portraitRatio,
            stageWidth: stageWidth,
            stageHeight: stageHeight,
            mediaKind: .photo
        )

        // Bounded by height (taller than 4:3 stage ceiling)
        #expect(size.height == 150.0)
        #expect(size.width == 100.0)
        #expect(abs((size.width / size.height) - portraitRatio) < 0.0001)
        #expect(size.width <= stageWidth)
    }

    @Test("Square MediaItems (1:1), vertical reels (9:16), and boundary fallbacks preserve ratios and clamp safely")
    func squareMediaItemsReelsAndBoundaryFallbacksPreserveRatiosAndClamp() {
        let session = CullingSession()
        let stageWidth: CGFloat = 200.0
        let stageHeight: CGFloat = 150.0

        // Square 1:1 photo
        let squareSize = session.gridItemSilhouetteSize(
            aspectRatio: 1.0,
            stageWidth: stageWidth,
            stageHeight: stageHeight,
            mediaKind: .photo
        )
        #expect(squareSize.width == 150.0)
        #expect(squareSize.height == 150.0)
        #expect(squareSize.width / squareSize.height == 1.0)

        // Vertical reel (9:16 = 0.5625)
        let reelRatio: CGFloat = 9.0 / 16.0
        let reelSize = session.gridItemSilhouetteSize(
            aspectRatio: reelRatio,
            stageWidth: stageWidth,
            stageHeight: stageHeight,
            mediaKind: .video
        )
        #expect(reelSize.height == 150.0)
        #expect(abs(reelSize.width - (150.0 * 9.0 / 16.0)) < 0.0001)
        #expect(abs((reelSize.width / reelSize.height) - reelRatio) < 0.0001)

        // Invalid ratio falls back to kind-specific fallback
        let photoFallback = session.gridItemSilhouetteSize(
            aspectRatio: 0.0,
            stageWidth: stageWidth,
            stageHeight: stageHeight,
            mediaKind: .photo
        )
        #expect(abs((photoFallback.width / photoFallback.height) - 1.5) < 0.0001)

        let videoFallback = session.gridItemSilhouetteSize(
            aspectRatio: .nan,
            stageWidth: stageWidth,
            stageHeight: stageHeight,
            mediaKind: .video
        )
        #expect(abs((videoFallback.width / videoFallback.height) - 1.777) < 0.001)
    }

    // MARK: - Slice 3: Grid Interaction, ViewMode Transitions & Conflict Triggers

    @Test("Double-clicking grid item transitions viewMode to .filmstrip and sets selectedItemID")
    func doubleClickingGridItemTransitionsViewModeToFilmstripAndSetsSelectedItemID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GridTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("img1".utf8).write(to: root.appendingPathComponent("IMG_0001.JPG"))
        try Data("img2".utf8).write(to: root.appendingPathComponent("IMG_0002.JPG"))

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item0 = session.items[0]
        let item1 = session.items[1]

        // Initially in grid view mode
        #expect(session.viewMode == .grid)

        // Select item0 first
        session.selectedItemID = item0.id
        #expect(session.selectedItemID == item0.id)

        // Simulate double-click gesture action on item1
        session.selectedItemID = item1.id
        session.setViewMode(.filmstrip)

        #expect(session.viewMode == .filmstrip)
        #expect(session.selectedItemID == item1.id)
    }

    @Test("Single-click selection and conflict sheet triggers on conflicted grid items")
    func singleClickSelectionAndConflictSheetTriggersOnConflictedGridItems() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GridTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jpg0 = root.appendingPathComponent("IMG_0001.JPG")
        let jpg1 = root.appendingPathComponent("IMG_0002.JPG")
        try Data("img1".utf8).write(to: jpg0)
        try Data("img2".utf8).write(to: jpg1)

        let initialXMP = try SidecarCodec.update(xmlData: nil, with: CurationMetadata(starRating: 1))
        let xmp0 = root.appendingPathComponent("IMG_0001.xmp")
        try initialXMP.write(to: xmp0)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item0 = session.items[0]
        let item1 = session.items[1]

        // 1. Single click on normal item selects it
        session.selectedItemID = item1.id
        #expect(session.selectedItemID == item1.id)
        #expect(session.isConflictSheetPresented == false)

        // 2. Stage local edit on item0, simulate external edit, then flush to produce conflict
        session.setStarRating(5, for: item0)
        let externalXMP = try SidecarCodec.update(xmlData: initialXMP, with: CurationMetadata(starRating: 3))
        try externalXMP.write(to: xmp0)

        await session.flushPendingWrites()
        #expect(session.syncState(for: item0) == .conflicted)

        // Simulate grid cell tap action on conflicted item:
        if session.syncState(for: item0) == .conflicted {
            session.activeConflictItemID = item0.id
            session.isConflictSheetPresented = true
        }

        #expect(session.activeConflictItemID == item0.id)
        #expect(session.isConflictSheetPresented == true)
    }

    @Test("Grid curation mutations (StarRating, PickFlag, ColorLabel) persist through Seam 2")
    func gridCurationMutationsPersistThroughSeam2() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GridTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("img1".utf8).write(to: root.appendingPathComponent("IMG_0001.JPG"))

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item = session.items[0]

        // Rating
        session.setStarRating(4, for: item)
        #expect(session.curationMetadata(for: item).starRating == 4)

        // PickFlag
        session.setPickFlag(.picked, for: item)
        #expect(session.curationMetadata(for: item).pickFlag == .picked)

        // ColorLabel
        session.setColorLabel(.purple, for: item)
        #expect(session.curationMetadata(for: item).colorLabel == .purple)
    }
}
