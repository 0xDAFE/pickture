import CoreGraphics
import Foundation
import Testing
@testable import Pickture

@MainActor
struct ZoomLockTests {

    // MARK: - Unit 1: ZoomLockState & Layout Clamping Calculations

    @Test("ZoomLockState initializes with scale and normalized anchor, clamping scale >= 1.0")
    func zoomLockStateInitialization() {
        let state1 = ZoomLockState(scale: 2.5, normalizedAnchor: CGPoint(x: 0.7, y: 0.3))
        #expect(state1.scale == 2.5)
        #expect(state1.normalizedAnchor.x == 0.7)
        #expect(state1.normalizedAnchor.y == 0.3)

        // Scale below 1.0 clamps to 1.0
        let state2 = ZoomLockState(scale: 0.5, normalizedAnchor: CGPoint(x: 0.5, y: 0.5))
        #expect(state2.scale == 1.0)
    }

    @Test("CullingLayoutCalculator converts normalized anchor to clamped pan offset and back across standard aspect ratios")
    func normalizedAnchorToPanOffsetRoundTrip() {
        let containerSize = CGSize(width: 800, height: 600)
        // 3:2 landscape image -> fits into 800x600 as 800x533.33
        let imageSize = CGSize(width: 6000, height: 4000)
        let scale: CGFloat = 2.0

        // 1. Center anchor (0.5, 0.5) must yield zero pan offset
        let centerOffset = CullingLayoutCalculator.calculatePanOffset(
            forNormalizedAnchor: CGPoint(x: 0.5, y: 0.5),
            containerSize: containerSize,
            imageSize: imageSize,
            scale: scale
        )
        #expect(abs(centerOffset.width) < 0.001)
        #expect(abs(centerOffset.height) < 0.001)

        // 2. Unclamped off-center anchor (0.7, 0.35) within centerable bounds at 2.0x
        let targetAnchor = CGPoint(x: 0.7, y: 0.35)
        let panOffset = CullingLayoutCalculator.calculatePanOffset(
            forNormalizedAnchor: targetAnchor,
            containerSize: containerSize,
            imageSize: imageSize,
            scale: scale
        )

        let maxPanX = (800.0 * scale - containerSize.width) / 2.0
        let maxPanY = (533.3333333333334 * scale - containerSize.height) / 2.0
        #expect(panOffset.width >= -maxPanX - 0.001 && panOffset.width <= maxPanX + 0.001)
        #expect(panOffset.height >= -maxPanY - 0.001 && panOffset.height <= maxPanY + 0.001)

        // Converting pan offset back to normalized anchor reconstructs the target anchor
        let reconstructedAnchor = CullingLayoutCalculator.calculateNormalizedAnchor(
            forPanOffset: panOffset,
            containerSize: containerSize,
            imageSize: imageSize,
            scale: scale
        )
        #expect(abs(reconstructedAnchor.x - targetAnchor.x) < 0.001)
        #expect(abs(reconstructedAnchor.y - targetAnchor.y) < 0.001)

        // 3. Extreme edge anchor (0.95, 0.05) clamps safely to maxPan boundaries
        let edgeOffset = CullingLayoutCalculator.calculatePanOffset(
            forNormalizedAnchor: CGPoint(x: 0.95, y: 0.05),
            containerSize: containerSize,
            imageSize: imageSize,
            scale: scale
        )
        #expect(abs(edgeOffset.width - (-maxPanX)) < 0.001)
        #expect(abs(edgeOffset.height - maxPanY) < 0.001)
    }

    @Test("CullingLayoutCalculator maps tap location inside container to normalized image coordinates")
    func containerTapLocationToNormalizedAnchor() {
        let containerSize = CGSize(width: 800, height: 600)
        // 4:3 image in 800x600 container fills exactly 800x600
        let imageSize = CGSize(width: 4000, height: 3000)

        // Center tap (400, 300) -> (0.5, 0.5)
        let centerAnchor = CullingLayoutCalculator.normalizedAnchor(
            forTapLocation: CGPoint(x: 400, y: 300),
            inContainerSize: containerSize,
            imageSize: imageSize
        )
        #expect(abs(centerAnchor.x - 0.5) < 0.001)
        #expect(abs(centerAnchor.y - 0.5) < 0.001)

        // Top-left quarter tap (200, 150) -> (0.25, 0.25)
        let cornerAnchor = CullingLayoutCalculator.normalizedAnchor(
            forTapLocation: CGPoint(x: 200, y: 150),
            inContainerSize: containerSize,
            imageSize: imageSize
        )
        #expect(abs(cornerAnchor.x - 0.25) < 0.001)
        #expect(abs(cornerAnchor.y - 0.25) < 0.001)
    }

    // MARK: - Unit 2: CullingSession ZoomLock Lifecycle & Navigation Retention

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureZoomLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func createDummyFile(at url: URL, content: String = "dummy") throws {
        try content.data(using: .utf8)?.write(to: url)
    }

    @Test("CullingSession manages ZoomLock lifecycle across sequential navigation, auto-advance, and reset triggers")
    func cullingSessionZoomLockLifecycle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create 2 photos and 1 video
        let photo1 = root.appendingPathComponent("DSC0001.JPG")
        let photo2 = root.appendingPathComponent("DSC0002.JPG")
        let video3 = root.appendingPathComponent("DSC0003.MOV")

        try createDummyFile(at: photo1)
        try createDummyFile(at: photo2)
        try createDummyFile(at: video3)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        #expect(session.items.count == 3)
        let item0 = session.items[0] // photo1
        let item1 = session.items[1] // photo2
        let item2 = session.items[2] // video3
        #expect(item0.kind == .photo)
        #expect(item1.kind == .photo)
        #expect(item2.kind == .video)

        session.setViewMode(.filmstrip)
        session.selectedItemID = item0.id

        // 1. Initially ZoomLock is nil
        #expect(session.zoomLockState == nil)
        #expect(session.isZoomLocked == false)

        // 2. Setting ZoomLock
        session.setZoomLock(scale: 2.0, normalizedAnchor: CGPoint(x: 0.65, y: 0.35))
        #expect(session.isZoomLocked == true)
        #expect(session.zoomLockState?.scale == 2.0)
        #expect(session.zoomLockState?.normalizedAnchor == CGPoint(x: 0.65, y: 0.35))

        // 3. Sequential navigation via selectNextItem() preserves ZoomLock across photos
        session.selectNextItem()
        #expect(session.selectedItemID == item1.id)
        #expect(session.isZoomLocked == true)
        #expect(session.zoomLockState?.scale == 2.0)
        #expect(session.zoomLockState?.normalizedAnchor == CGPoint(x: 0.65, y: 0.35))

        // 4. Sequential navigation via selectPreviousItem() preserves ZoomLock
        session.selectPreviousItem()
        #expect(session.selectedItemID == item0.id)
        #expect(session.isZoomLocked == true)

        // 5. Border tap navigation preserves ZoomLock across photos
        session.isBorderTapNavigationEnabled = true
        let container = CGSize(width: 800, height: 600)
        let nextTapLocation = CGPoint(x: 780, y: 300) // within right border zone (64pt)
        #expect(session.handleBorderTap(at: nextTapLocation, in: container) == true)
        #expect(session.selectedItemID == item1.id)
        #expect(session.isZoomLocked == true)

        // 6. Navigating onto a video item resets ZoomLock to nil
        session.selectNextItem()
        #expect(session.selectedItemID == item2.id)
        #expect(session.selectedItem?.kind == .video)
        #expect(session.zoomLockState == nil)
        #expect(session.isZoomLocked == false)

        // 7. Auto-advance curation mutation preserves ZoomLock between photos
        session.selectedItemID = item0.id
        session.setZoomLock(scale: 3.0, normalizedAnchor: CGPoint(x: 0.4, y: 0.8))
        #expect(session.isZoomLocked == true)

        session.isAutoAdvanceEnabled = true
        session.setStarRating(5, for: item0)
        #expect(session.selectedItemID == item1.id)
        #expect(session.isZoomLocked == true)
        #expect(session.zoomLockState?.scale == 3.0)

        // 8. Toggling viewMode to .grid clears ZoomLock
        session.setViewMode(.grid)
        #expect(session.zoomLockState == nil)
        #expect(session.isZoomLocked == false)

        // 9. Direct selection via selectItemDirectly clears ZoomLock
        session.selectedItemID = item0.id
        session.setZoomLock(scale: 2.0, normalizedAnchor: CGPoint(x: 0.5, y: 0.5))
        session.selectItemDirectly(id: item1.id)
        #expect(session.selectedItemID == item1.id)
        #expect(session.zoomLockState == nil)

        // 10. Non-sequential jump navigation (selectFirstItem, selectLastItem) clears ZoomLock
        session.selectedItemID = item0.id
        session.setZoomLock(scale: 2.0, normalizedAnchor: CGPoint(x: 0.5, y: 0.5))
        session.selectLastItem()
        #expect(session.selectedItemID == item2.id)
        #expect(session.zoomLockState == nil)

        session.setZoomLock(scale: 2.0, normalizedAnchor: CGPoint(x: 0.5, y: 0.5))
        session.selectFirstItem()
        #expect(session.selectedItemID == item0.id)
        #expect(session.zoomLockState == nil)
    }

    // MARK: - Unit 3: Canvas View Model & Gesture Projection

    @Test("FilmstripImageCanvasView initializes with locked scale when session.isZoomLocked is true")
    func filmstripCanvasViewInitializationWithZoomLock() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let photo1 = root.appendingPathComponent("IMG001.JPG")
        try createDummyFile(at: photo1)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item0 = session.items[0]
        session.selectedItemID = item0.id
        session.setZoomLock(scale: 2.5, normalizedAnchor: CGPoint(x: 0.7, y: 0.3))

        let canvas = FilmstripImageCanvasView(item: item0, session: session)
        #expect(canvas.currentZoomScale == 2.5)
    }

    @Test("Double tap calculation centers exactly on double-tapped point")
    func doubleTapPointTargetingCalculation() {
        let container = CGSize(width: 800, height: 600)
        let imageSize = CGSize(width: 4000, height: 3000) // 4:3 fills 800x600

        // Tap at (600, 150) -> normalized anchor (0.75, 0.25)
        let anchor = CullingLayoutCalculator.normalizedAnchor(
            forTapLocation: CGPoint(x: 600, y: 150),
            inContainerSize: container,
            imageSize: imageSize
        )
        #expect(abs(anchor.x - 0.75) < 0.001)
        #expect(abs(anchor.y - 0.25) < 0.001)

        let offset = CullingLayoutCalculator.calculatePanOffset(
            forNormalizedAnchor: anchor,
            containerSize: container,
            imageSize: imageSize,
            scale: 2.0
        )
        // Scaled is 1600x1200, maxPanX = 400, maxPanY = 300
        // targetX = -(0.75 - 0.5) * 1600 = -400
        // targetY = -(0.25 - 0.5) * 1200 = 300
        #expect(abs(offset.width - (-400)) < 0.001)
        #expect(abs(offset.height - 300) < 0.001)
    }

    @Test("CullingLayoutCalculator clamps pan offset within visible bounds")
    func clampPanOffsetCalculations() {
        let container = CGSize(width: 800, height: 600)
        let imageSize = CGSize(width: 4000, height: 3000) // fits 800x600, at 2.0x is 1600x1200
        // maxPanX = 400, maxPanY = 300
        let clamped = CullingLayoutCalculator.clampPanOffset(
            CGSize(width: 600, height: -500),
            containerSize: container,
            imageSize: imageSize,
            scale: 2.0
        )
        #expect(clamped.width == 400)
        #expect(clamped.height == -300)
    }
}
