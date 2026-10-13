import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Pickture

@MainActor
struct DecoupledCellInvalidationTests {

    private func makeDummyMediaItem(id: String, baseName: String, kind: MediaKind = .photo) -> MediaItem {
        let ext = (kind == .video) ? "mov" : "jpg"
        let formatKind: MediaFormatKind = (kind == .video) ? .video : .raster
        let dummyURL = URL(fileURLWithPath: "/dummy/\(baseName).\(ext)")
        let primaryFile = MediaFile(url: dummyURL, formatKind: formatKind)
        return MediaItem(
            id: id,
            baseName: baseName,
            directoryURL: URL(fileURLWithPath: "/dummy"),
            relativeDirectoryPath: "",
            kind: kind,
            primaryFile: primaryFile,
            mediaPair: nil,
            sidecarURL: nil
        )
    }

    // MARK: - Acceptance Criterion 1: No Storage or Reference to CullingSession

    @Test("Neither MediaGridCellView nor FilmstripThumbnailCell stores or references CullingSession")
    func cellsDoNotStoreCullingSession() {
        let item = makeDummyMediaItem(id: "item-1", baseName: "DSC_0001")
        let curation = CurationMetadata(starRating: 2, pickFlag: .picked, colorLabel: .blue)
        let syncState = SyncState.synced

        let gridCell = MediaGridCellView(
            item: item,
            curation: curation,
            syncState: syncState,
            isSelected: false
        )

        let filmstripCell = FilmstripThumbnailCell(
            item: item,
            curation: curation,
            syncState: syncState,
            isSelected: false
        )

        // Inspect stored properties via Mirror
        let gridMirror = Mirror(reflecting: gridCell)
        for child in gridMirror.children {
            let typeName = String(describing: type(of: child.value))
            #expect(!typeName.contains("CullingSession"), "MediaGridCellView stores a property of type \(typeName)")
        }

        let filmstripMirror = Mirror(reflecting: filmstripCell)
        for child in filmstripMirror.children {
            let typeName = String(describing: type(of: child.value))
            #expect(!typeName.contains("CullingSession"), "FilmstripThumbnailCell stores a property of type \(typeName)")
        }
    }

    // MARK: - Acceptance Criterion 2: Narrow @Observable Invalidation (O(1) updates)

    @Test("Mutating metadata (rating, pick flag, color label) for an item only invalidates the cell representing that item")
    func gridCellNarrowInvalidation() {
        let item1 = makeDummyMediaItem(id: "item-1", baseName: "DSC_0001")
        let item2 = makeDummyMediaItem(id: "item-2", baseName: "DSC_0002")

        let curation1 = CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none)
        let curation2 = CurationMetadata(starRating: 3, pickFlag: .picked, colorLabel: .green)

        let baselineCell1 = MediaGridCellView(
            item: item1,
            curation: curation1,
            syncState: .synced,
            isSelected: true
        )

        let baselineCell2 = MediaGridCellView(
            item: item2,
            curation: curation2,
            syncState: .synced,
            isSelected: false
        )

        // 1. Mutate star rating on item 1: cell 1 should invalidate (!=), cell 2 remains equal (==)
        let updatedCuration1Rating = CurationMetadata(starRating: 5, pickFlag: .unflagged, colorLabel: .none)
        let newCell1Rating = MediaGridCellView(
            item: item1,
            curation: updatedCuration1Rating,
            syncState: .synced,
            isSelected: true
        )
        let newCell2AfterRating = MediaGridCellView(
            item: item2,
            curation: curation2,
            syncState: .synced,
            isSelected: false
        )

        #expect(newCell1Rating != baselineCell1, "Cell 1 must invalidate when star rating changes")
        #expect(newCell2AfterRating == baselineCell2, "Cell 2 must NOT invalidate when item 1 changes")

        // 2. Mutate pick flag on item 1: cell 1 should invalidate (!=), cell 2 remains equal (==)
        let updatedCuration1Flag = CurationMetadata(starRating: 0, pickFlag: .rejected, colorLabel: .none)
        let newCell1Flag = MediaGridCellView(
            item: item1,
            curation: updatedCuration1Flag,
            syncState: .synced,
            isSelected: true
        )
        let newCell2AfterFlag = MediaGridCellView(
            item: item2,
            curation: curation2,
            syncState: .synced,
            isSelected: false
        )

        #expect(newCell1Flag != baselineCell1, "Cell 1 must invalidate when pick flag changes")
        #expect(newCell2AfterFlag == baselineCell2, "Cell 2 must NOT invalidate when item 1 changes")

        // 3. Mutate color label on item 1: cell 1 should invalidate (!=), cell 2 remains equal (==)
        let updatedCuration1Color = CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .purple)
        let newCell1Color = MediaGridCellView(
            item: item1,
            curation: updatedCuration1Color,
            syncState: .synced,
            isSelected: true
        )
        let newCell2AfterColor = MediaGridCellView(
            item: item2,
            curation: curation2,
            syncState: .synced,
            isSelected: false
        )

        #expect(newCell1Color != baselineCell1, "Cell 1 must invalidate when color label changes")
        #expect(newCell2AfterColor == baselineCell2, "Cell 2 must NOT invalidate when item 1 changes")

        // 4. Mutate sync state on item 1: cell 1 should invalidate (!=), cell 2 remains equal (==)
        let newCell1Sync = MediaGridCellView(
            item: item1,
            curation: curation1,
            syncState: .pendingWrite,
            isSelected: true
        )
        let newCell2AfterSync = MediaGridCellView(
            item: item2,
            curation: curation2,
            syncState: .synced,
            isSelected: false
        )

        #expect(newCell1Sync != baselineCell1, "Cell 1 must invalidate when sync state changes")
        #expect(newCell2AfterSync == baselineCell2, "Cell 2 must NOT invalidate when item 1 changes")
    }

    @Test("FilmstripThumbnailCell invalidation narrows strictly to the affected item")
    func filmstripThumbnailCellNarrowInvalidation() {
        let item1 = makeDummyMediaItem(id: "item-1", baseName: "DSC_0001")
        let item2 = makeDummyMediaItem(id: "item-2", baseName: "DSC_0002")

        let curation1 = CurationMetadata(starRating: 1, pickFlag: .picked, colorLabel: .red)
        let curation2 = CurationMetadata(starRating: 4, pickFlag: .unflagged, colorLabel: .yellow)

        let baselineCell1 = FilmstripThumbnailCell(
            item: item1,
            curation: curation1,
            syncState: .synced,
            isSelected: true
        )

        let baselineCell2 = FilmstripThumbnailCell(
            item: item2,
            curation: curation2,
            syncState: .synced,
            isSelected: false
        )

        // Mutate curation on item 1
        let updatedCuration1 = CurationMetadata(starRating: 2, pickFlag: .picked, colorLabel: .red)
        let newCell1 = FilmstripThumbnailCell(
            item: item1,
            curation: updatedCuration1,
            syncState: .synced,
            isSelected: true
        )
        let newCell2 = FilmstripThumbnailCell(
            item: item2,
            curation: curation2,
            syncState: .synced,
            isSelected: false
        )

        #expect(newCell1 != baselineCell1, "Filmstrip cell 1 must invalidate when its curation changes")
        #expect(newCell2 == baselineCell2, "Filmstrip cell 2 must NOT invalidate when item 1 changes")

        // Mutate syncState on item 1
        let newCell1Conflict = FilmstripThumbnailCell(
            item: item1,
            curation: curation1,
            syncState: .conflicted,
            isSelected: true
        )
        #expect(newCell1Conflict != baselineCell1)
    }

    // MARK: - Acceptance Criterion 3: Seamless Callbacks and Gestures

    @Test("MediaGridCellView invokes action callbacks for select, double click, conflict, curation, and thumbnail loading")
    func gridCellActionCallbacks() async {
        let item = makeDummyMediaItem(id: "item-action", baseName: "DSC_1000")
        let curation = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)

        var selected = false
        var doubleClicked = false
        var conflictResolved = false
        var capturedAction: CurationAction?

        let cell = MediaGridCellView(
            item: item,
            curation: curation,
            syncState: .conflicted,
            isSelected: false,
            onSelect: { selected = true },
            onDoubleClick: { doubleClicked = true },
            onResolveConflict: { conflictResolved = true },
            onCurationAction: { capturedAction = $0 },
            loadThumbnail: {
                // Mock thumbnail loader
                let context = CGContext(
                    data: nil,
                    width: 10,
                    height: 10,
                    bitsPerComponent: 8,
                    bytesPerRow: 40,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                return context?.makeImage()
            }
        )

        cell.onSelect?()
        #expect(selected == true)

        cell.onDoubleClick?()
        #expect(doubleClicked == true)

        cell.onResolveConflict?()
        #expect(conflictResolved == true)

        cell.onCurationAction?(.starRating(5))
        #expect(capturedAction?.starRatingValue == 5)

        cell.onCurationAction?(.pickFlag(.picked))
        #expect(capturedAction?.pickFlagValue == .picked)

        cell.onCurationAction?(.colorLabel(.purple))
        #expect(capturedAction?.colorLabelValue == .purple)

        let loadedImage = await cell.loadThumbnail?()
        #expect(loadedImage != nil)
    }

    @Test("FilmstripThumbnailCell invokes onSelect, loadThumbnail, and onThumbnailLoaded callbacks")
    func filmstripThumbnailCellCallbacks() async {
        let item = makeDummyMediaItem(id: "item-fs", baseName: "DSC_2000")
        let curation = CurationMetadata(starRating: 2, pickFlag: .picked, colorLabel: .green)

        var selected = false
        var loadedAspect: CGFloat?

        let cell = FilmstripThumbnailCell(
            item: item,
            curation: curation,
            syncState: .synced,
            isSelected: true,
            onSelect: { selected = true },
            loadThumbnail: {
                let context = CGContext(
                    data: nil,
                    width: 20,
                    height: 10,
                    bitsPerComponent: 8,
                    bytesPerRow: 80,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                return context?.makeImage()
            },
            onThumbnailLoaded: { image in
                loadedAspect = image.aspectRatio
            }
        )

        cell.onSelect?()
        #expect(selected == true)

        if let image = await cell.loadThumbnail?() {
            cell.onThumbnailLoaded?(image)
            #expect(loadedAspect == 2.0)
        } else {
            Issue.record("Thumbnail should have loaded")
        }
    }

    // MARK: - Layout Calculator Verification

    @Test("CullingLayoutCalculator calculates correct silhouette sizes, thumbnail sizes, and stage heights")
    func layoutCalculatorTests() {
        // Stage height
        #expect(CullingLayoutCalculator.gridStageHeight(for: 200.0) == 150.0)
        #expect(CullingLayoutCalculator.gridStageHeight(for: 0.0) == 140.0)

        // Resolve aspect ratio
        #expect(CullingLayoutCalculator.resolveAspectRatio(aspectRatio: 1.6, displayedThumbnail: nil, mediaKind: .photo) == 1.6)
        #expect(CullingLayoutCalculator.resolveAspectRatio(aspectRatio: nil, displayedThumbnail: nil, mediaKind: .photo) == 1.5)
        #expect(CullingLayoutCalculator.resolveAspectRatio(aspectRatio: nil, displayedThumbnail: nil, mediaKind: .video) == 1.777)
        #expect(CullingLayoutCalculator.resolveAspectRatio(aspectRatio: -1.0, displayedThumbnail: nil, mediaKind: .photo) == 1.5)

        // Fallback aspect ratio
        #expect(CullingLayoutCalculator.fallbackAspectRatio(for: .photo) == 1.5)
        #expect(CullingLayoutCalculator.fallbackAspectRatio(for: .video) == 1.777)

        // Filmstrip thumbnail size
        let bottomSize = CullingLayoutCalculator.filmstripThumbnailSize(aspectRatio: 1.5, dockPosition: .bottom)
        #expect(bottomSize.height == 72.0)
        #expect(bottomSize.width == 108.0)

        let rightSize = CullingLayoutCalculator.filmstripThumbnailSize(aspectRatio: 1.5, dockPosition: .right)
        #expect(rightSize.width == 112.0)
        #expect(rightSize.height == 75.0)

        // Filmstrip thumbnail size helper (Ticket 4 AC 2) with optional aspectRatio & displayedThumbnail
        let helperBottomDefault = CullingLayoutCalculator.filmstripThumbnailSize(
            aspectRatio: nil,
            displayedThumbnail: nil,
            dockPosition: .bottom,
            mediaKind: .photo
        )
        #expect(helperBottomDefault.height == 72.0)
        #expect(helperBottomDefault.width == 108.0) // 1.5 fallback -> 108

        let helperBottomVideo = CullingLayoutCalculator.filmstripThumbnailSize(
            aspectRatio: nil,
            displayedThumbnail: nil,
            dockPosition: .bottom,
            mediaKind: .video
        )
        #expect(helperBottomVideo.height == 72.0)
        #expect(helperBottomVideo.width == 128.0) // 1.777 * 72 = 127.9 -> 128 clamped

        let context = CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        if let dummyCGImage = context?.makeImage() {
            let helperWithImage = CullingLayoutCalculator.filmstripThumbnailSize(
                aspectRatio: nil,
                displayedThumbnail: dummyCGImage,
                dockPosition: .bottom,
                mediaKind: .photo
            )
            // 200/100 = 2.0 -> 72 * 2.0 = 144 -> clamped to 128
            #expect(helperWithImage.height == 72.0)
            #expect(helperWithImage.width == 128.0)
        }

        // Grid silhouette size
        let silhouette = CullingLayoutCalculator.gridItemSilhouetteSize(
            aspectRatio: 1.5,
            stageWidth: 200.0,
            stageHeight: 150.0
        )
        #expect(silhouette.width == 200.0)
        #expect(abs(silhouette.height - (200.0 / 1.5)) < 0.001)
    }

    @Test("CullingLayoutCalculator calculates border tap zones and direction")
    func borderTapZoneTests() {
        // Border tap zone width
        #expect(CullingLayoutCalculator.borderTapZoneWidth(for: 1000.0) == 64.0)
        #expect(CullingLayoutCalculator.borderTapZoneWidth(for: 400.0) == 48.0)
        #expect(CullingLayoutCalculator.borderTapZoneWidth(for: 0.0) == 0.0)
        #expect(CullingLayoutCalculator.borderTapZoneWidth(for: -50.0) == 0.0)
        #expect(CullingLayoutCalculator.borderTapZoneWidth(for: .nan) == 0.0)
        #expect(CullingLayoutCalculator.borderTapZoneWidth(for: .infinity) == 0.0)

        // Border tap direction detection
        let containerSize = CGSize(width: 1000.0, height: 800.0)
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 30.0, y: 400.0), in: containerSize) == .previous)
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 64.0, y: 400.0), in: containerSize) == .previous)
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 65.0, y: 400.0), in: containerSize) == nil)
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 500.0, y: 400.0), in: containerSize) == nil)
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 935.0, y: 400.0), in: containerSize) == nil)
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 936.0, y: 400.0), in: containerSize) == .next)
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 990.0, y: 400.0), in: containerSize) == .next)

        // Invalid container sizes
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 10.0, y: 10.0), in: .zero) == nil)
        #expect(CullingLayoutCalculator.borderTapDirection(at: CGPoint(x: 10.0, y: 10.0), in: CGSize(width: -100.0, height: 100.0)) == nil)
    }

    @Test("CullingLayoutCalculator computes grid item silhouette size from column width")
    func gridItemSilhouetteSizeFromColumnWidthTests() {
        let columnWidth: CGFloat = 200.0
        let stageHeight = CullingLayoutCalculator.gridStageHeight(for: columnWidth) // 150.0

        let expectedSize = CullingLayoutCalculator.gridItemSilhouetteSize(
            aspectRatio: 1.5,
            stageWidth: columnWidth,
            stageHeight: stageHeight,
            mediaKind: .photo
        )

        let computedSize = CullingLayoutCalculator.gridItemSilhouetteSize(
            aspectRatio: 1.5,
            columnWidth: columnWidth,
            mediaKind: .photo
        )

        #expect(computedSize == expectedSize)
        #expect(computedSize.width == 200.0)
        #expect(abs(computedSize.height - (200.0 / 1.5)) < 0.001)

        // Video kind with fallback aspect ratio
        let videoSize = CullingLayoutCalculator.gridItemSilhouetteSize(
            aspectRatio: .nan,
            columnWidth: columnWidth,
            mediaKind: .video
        )
        let expectedVideoSize = CullingLayoutCalculator.gridItemSilhouetteSize(
            aspectRatio: .nan,
            stageWidth: columnWidth,
            stageHeight: stageHeight,
            mediaKind: .video
        )
        #expect(videoSize == expectedVideoSize)
    }

    // MARK: - Acceptance Criterion: Decoupled Thumbnail Decoding Task Key Contracts

    @Test("MediaGridCellView thumbnailTaskKey remains stable across curation modifications, sync state transitions, and selection toggles")
    func mediaGridCellViewThumbnailTaskKeyStabilityAcrossCurationAndSyncState() {
        let item = makeDummyMediaItem(id: "item-stability-1", baseName: "DSC_9999")
        let baseCell = MediaGridCellView(
            item: item,
            curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
            syncState: .synced,
            isSelected: false,
            previewSource: .preferRaster,
            cacheGeneration: 1
        )
        let expectedBaseKey = "item-stability-1-preferRaster-1"
        #expect(baseCell.thumbnailTaskKey == expectedBaseKey)

        // 1. Modifying curation metadata does NOT change thumbnailTaskKey
        let ratings: [StarRating] = [1, 2, 3, 4, 5]
        for rating in ratings {
            let ratedCell = MediaGridCellView(
                item: item,
                curation: CurationMetadata(starRating: rating, pickFlag: .unflagged, colorLabel: .none),
                syncState: .synced,
                isSelected: false,
                previewSource: .preferRaster,
                cacheGeneration: 1
            )
            #expect(ratedCell.thumbnailTaskKey == expectedBaseKey)
        }

        let flags: [PickFlag] = [.picked, .rejected, .unflagged]
        for flag in flags {
            let flaggedCell = MediaGridCellView(
                item: item,
                curation: CurationMetadata(starRating: 0, pickFlag: flag, colorLabel: .none),
                syncState: .synced,
                isSelected: false,
                previewSource: .preferRaster,
                cacheGeneration: 1
            )
            #expect(flaggedCell.thumbnailTaskKey == expectedBaseKey)
        }

        let colors: [ColorLabel] = [.red, .yellow, .green, .blue, .purple, .none]
        for color in colors {
            let coloredCell = MediaGridCellView(
                item: item,
                curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: color),
                syncState: .synced,
                isSelected: false,
                previewSource: .preferRaster,
                cacheGeneration: 1
            )
            #expect(coloredCell.thumbnailTaskKey == expectedBaseKey)
        }

        // 2. Transitioning syncState does NOT change thumbnailTaskKey
        let syncStates: [SyncState] = [.loading, .synced, .pendingWrite, .conflicted, .syncError]
        for state in syncStates {
            let stateCell = MediaGridCellView(
                item: item,
                curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
                syncState: state,
                isSelected: false,
                previewSource: .preferRaster,
                cacheGeneration: 1
            )
            #expect(stateCell.thumbnailTaskKey == expectedBaseKey)
        }

        // 3. Selection changes do NOT change thumbnailTaskKey
        let selectedCell = MediaGridCellView(
            item: item,
            curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
            syncState: .synced,
            isSelected: true,
            previewSource: .preferRaster,
            cacheGeneration: 1
        )
        #expect(selectedCell.thumbnailTaskKey == expectedBaseKey)

        // 4. Changing previewSource DOES change thumbnailTaskKey
        let rawSourceCell = MediaGridCellView(
            item: item,
            curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
            syncState: .synced,
            isSelected: false,
            previewSource: .preferRAW,
            cacheGeneration: 1
        )
        #expect(rawSourceCell.thumbnailTaskKey == "item-stability-1-preferRAW-1")

        // 5. Incrementing cacheGeneration DOES change thumbnailTaskKey
        let newGenCell = MediaGridCellView(
            item: item,
            curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
            syncState: .synced,
            isSelected: false,
            previewSource: .preferRaster,
            cacheGeneration: 2
        )
        #expect(newGenCell.thumbnailTaskKey == "item-stability-1-preferRaster-2")
    }

    @Test("FilmstripThumbnailCell thumbnailTaskKey remains stable across curation modifications, sync state transitions, and selection toggles")
    func filmstripThumbnailCellThumbnailTaskKeyStabilityAcrossCurationAndSyncState() {
        let item = makeDummyMediaItem(id: "item-filmstrip-stability", baseName: "DSC_8888")
        let baseCell = FilmstripThumbnailCell(
            item: item,
            curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
            syncState: .synced,
            isSelected: false,
            previewSource: .preferRaster,
            cacheGeneration: 1
        )
        let expectedBaseKey = "item-filmstrip-stability-preferRaster-1"
        #expect(baseCell.thumbnailTaskKey == expectedBaseKey)

        // Curation modifications
        let modifiedCurationCell = FilmstripThumbnailCell(
            item: item,
            curation: CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green),
            syncState: .synced,
            isSelected: false,
            previewSource: .preferRaster,
            cacheGeneration: 1
        )
        #expect(modifiedCurationCell.thumbnailTaskKey == expectedBaseKey)

        // Sync state transitions
        for state in [SyncState.loading, .synced, .pendingWrite, .conflicted, .syncError] {
            let stateCell = FilmstripThumbnailCell(
                item: item,
                curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
                syncState: state,
                isSelected: false,
                previewSource: .preferRaster,
                cacheGeneration: 1
            )
            #expect(stateCell.thumbnailTaskKey == expectedBaseKey)
        }

        // Selection change
        let selectedCell = FilmstripThumbnailCell(
            item: item,
            curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
            syncState: .synced,
            isSelected: true,
            previewSource: .preferRaster,
            cacheGeneration: 1
        )
        #expect(selectedCell.thumbnailTaskKey == expectedBaseKey)

        // Preview source toggle
        let rawCell = FilmstripThumbnailCell(
            item: item,
            curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
            syncState: .synced,
            isSelected: false,
            previewSource: .preferRAW,
            cacheGeneration: 1
        )
        #expect(rawCell.thumbnailTaskKey == "item-filmstrip-stability-preferRAW-1")

        // Cache generation increment
        let newGenCell = FilmstripThumbnailCell(
            item: item,
            curation: CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none),
            syncState: .synced,
            isSelected: false,
            previewSource: .preferRaster,
            cacheGeneration: 5
        )
        #expect(newGenCell.thumbnailTaskKey == "item-filmstrip-stability-preferRaster-5")
    }
}

