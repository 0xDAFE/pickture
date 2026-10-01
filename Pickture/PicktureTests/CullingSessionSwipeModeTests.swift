import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@MainActor
struct CullingSessionSwipeModeTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureSwipeModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func createTestJPEG(at url: URL, width: Int = 320, height: Int = 240, r: UInt8 = 100, g: UInt8 = 150, b: UInt8 = 200) throws {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try (mutableData as Data).write(to: url)
    }

    // MARK: - Slice 1: Configurable Single and Compound Swipe Actions & Auto-Advancement

    @Test("SwipeMode executes configurable single and compound actions with auto-advancement")
    func swipeModeConfigurableSingleAndCompoundActionsAndAutoAdvance() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...4 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        #expect(session.items.count == 4)
        let item0 = session.items[0]
        let item1 = session.items[1]
        let item2 = session.items[2]
        let item3 = session.items[3]

        // 1. Initial defaults
        #expect(session.isSwipeModeEnabled == false)
        #expect(session.swipeRightAction == .setPickFlag(.picked))
        #expect(session.swipeLeftAction == .setPickFlag(.rejected))

        // Toggle SwipeMode ON
        session.toggleSwipeMode()
        #expect(session.isSwipeModeEnabled == true)

        session.selectedItemID = item0.id

        // 2. Execute default Swipe Right on item0 -> applies PickFlag.picked and auto-advances to item1
        let swipedRight0 = session.executeSwipe(.right)
        #expect(swipedRight0 == true)
        #expect(session.curationMetadata(for: item0).pickFlag == .picked)
        #expect(session.selectedItemID == item1.id)

        // 3. Execute default Swipe Left on item1 -> applies PickFlag.rejected and auto-advances to item2
        let swipedLeft1 = session.executeSwipe(.left)
        #expect(swipedLeft1 == true)
        #expect(session.curationMetadata(for: item1).pickFlag == .rejected)
        #expect(session.selectedItemID == item2.id)

        // 4. Configure compound action for Swipe Right: Picked + 5 Stars
        session.setSwipeRightAction(.compound(starRating: 5, pickFlag: .picked))
        #expect(session.swipeRightAction == .compound(starRating: 5, pickFlag: .picked))

        let swipedCompoundRight = session.executeSwipe(.right)
        #expect(swipedCompoundRight == true)
        let meta2 = session.curationMetadata(for: item2)
        #expect(meta2.pickFlag == .picked)
        #expect(meta2.starRating == 5)
        #expect(session.selectedItemID == item3.id)

        // 5. Configure compound action for Swipe Left: Rejected + Red Label
        session.setSwipeLeftAction(.compound(pickFlag: .rejected, colorLabel: .red))
        #expect(session.swipeLeftAction == .compound(pickFlag: .rejected, colorLabel: .red))

        let swipedCompoundLeft = session.executeSwipe(.left)
        #expect(swipedCompoundLeft == true)
        let meta3 = session.curationMetadata(for: item3)
        #expect(meta3.pickFlag == .rejected)
        #expect(meta3.colorLabel == .red)
        // Swiping at the end of the list stays on the last item
        #expect(session.selectedItemID == item3.id)

        // 6. Configure single StarRating and ColorLabel actions
        session.setSwipeRightAction(.setStarRating(4))
        session.setSwipeLeftAction(.setColorLabel(.green))

        session.selectedItemID = item0.id
        session.executeSwipe(.right)
        #expect(session.curationMetadata(for: item0).starRating == 4)

        session.executeSwipe(.left)
        #expect(session.curationMetadata(for: item1).colorLabel == .green)
    }

    // MARK: - Slice 2: Undo Last Swipe State Restoration & Selection

    @Test("Undo Last Swipe reverts curation mutation and restores selection to the swiped MediaItem")
    func undoLastSwipeStateRestorationAndSelection() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...4 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item0 = session.items[0]
        let item1 = session.items[1]
        let item2 = session.items[2]

        // Seed initial metadata on item0: 2 Stars, None Flag, Blue Label
        session.applyCurationAction(
            .compound(starRating: 2, pickFlag: .unflagged, colorLabel: .blue),
            to: item0,
            shouldAutoAdvance: false
        )
        let initialMeta0 = session.curationMetadata(for: item0)
        #expect(initialMeta0.starRating == 2)
        #expect(initialMeta0.pickFlag == .unflagged)
        #expect(initialMeta0.colorLabel == .blue)

        // Initial undo state
        #expect(session.canUndoSwipe == false)
        #expect(session.undoLastSwipe() == false)

        session.toggleSwipeMode()
        session.selectedItemID = item0.id

        // 1. Swipe Right on item0 with Picked + 5 Stars
        session.setSwipeRightAction(.compound(starRating: 5, pickFlag: .picked))
        let swiped = session.executeSwipe(.right)
        #expect(swiped == true)

        // Item 0 is mutated, selection advanced to item1
        let mutatedMeta0 = session.curationMetadata(for: item0)
        #expect(mutatedMeta0.starRating == 5)
        #expect(mutatedMeta0.pickFlag == .picked)
        #expect(session.selectedItemID == item1.id)
        #expect(session.canUndoSwipe == true)

        // 2. Undo Last Swipe
        let undone = session.undoLastSwipe()
        #expect(undone == true)

        // Item 0 restored to its exact previous metadata
        let restoredMeta0 = session.curationMetadata(for: item0)
        #expect(restoredMeta0.starRating == 2)
        #expect(restoredMeta0.pickFlag == .unflagged)
        #expect(restoredMeta0.colorLabel == .blue)

        // Selection restored to swiped item (item0)
        #expect(session.selectedItemID == item0.id)
        #expect(session.canUndoSwipe == false)

        // 3. Multi-item sequential undo test
        session.setSwipeRightAction(.setPickFlag(.picked))
        session.setSwipeLeftAction(.setPickFlag(.rejected))

        session.selectedItemID = item0.id
        session.executeSwipe(.right) // item0 -> item1
        #expect(session.selectedItemID == item1.id)

        session.executeSwipe(.left)  // item1 -> item2
        #expect(session.selectedItemID == item2.id)

        session.executeSwipe(.right) // item2 -> item3
        #expect(session.canUndoSwipe == true)

        // Undo 1: Reverts item2 and selects item2
        #expect(session.undoLastSwipe() == true)
        #expect(session.selectedItemID == item2.id)
        #expect(session.curationMetadata(for: item2).pickFlag == .unflagged)

        // Undo 2: Reverts item1 and selects item1
        #expect(session.undoLastSwipe() == true)
        #expect(session.selectedItemID == item1.id)
        #expect(session.curationMetadata(for: item1).pickFlag == .unflagged)

        // Undo 3: Reverts item0 and selects item0
        #expect(session.undoLastSwipe() == true)
        #expect(session.selectedItemID == item0.id)
        #expect(session.curationMetadata(for: item0).pickFlag == .unflagged)

        // Undo 4: Stack is empty
        #expect(session.canUndoSwipe == false)
        #expect(session.undoLastSwipe() == false)

        // 4. Test SessionCommand.undoLastSwipe execution
        session.executeSwipe(.right)
        #expect(session.canUndoSwipe == true)
        #expect(session.executeCommand(.undoLastSwipe) == true)
        #expect(session.selectedItemID == item0.id)
        #expect(session.canUndoSwipe == false)
    }

    // MARK: - Slice 3: BorderTapNavigation & SwipeMode Coexistence

    @Test("BorderTapNavigation edge taps navigate without triggering swipe rating or affecting swipe history")
    func borderTapNavigationCoexistsWithSwipeMode() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...3 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item0 = session.items[0]
        let item1 = session.items[1]
        let item2 = session.items[2]

        // Enable both SwipeMode and BorderTapNavigation
        session.setSwipeMode(true)
        #expect(session.isSwipeModeEnabled == true)
        #expect(session.isBorderTapNavigationEnabled == true)

        session.selectedItemID = item1.id
        let containerSize = CGSize(width: 1000.0, height: 800.0)

        // 1. Tapping left border zone navigates to item0
        let handledLeft = session.handleBorderTap(at: CGPoint(x: 20.0, y: 400.0), in: containerSize)
        #expect(handledLeft == true)
        #expect(session.selectedItemID == item0.id)

        // Metadata on both item0 and item1 are untouched
        #expect(session.curationMetadata(for: item0).pickFlag == .unflagged)
        #expect(session.curationMetadata(for: item1).pickFlag == .unflagged)

        // Swipe history remains empty
        #expect(session.canUndoSwipe == false)
        #expect(session.swipeHistory.isEmpty == true)

        // 2. Tapping right border zone navigates to item1
        let handledRight = session.handleBorderTap(at: CGPoint(x: 980.0, y: 400.0), in: containerSize)
        #expect(handledRight == true)
        #expect(session.selectedItemID == item1.id)
        #expect(session.curationMetadata(for: item1).pickFlag == .unflagged)
        #expect(session.canUndoSwipe == false)

        // 3. Tapping right border zone again navigates to item2
        let handledRight2 = session.handleBorderTap(at: CGPoint(x: 980.0, y: 400.0), in: containerSize)
        #expect(handledRight2 == true)
        #expect(session.selectedItemID == item2.id)
        #expect(session.curationMetadata(for: item2).pickFlag == .unflagged)
        #expect(session.canUndoSwipe == false)

        // 4. Executing an actual swipe DOES mutate and add to history
        session.executeSwipe(.right) // on item2
        #expect(session.curationMetadata(for: item2).pickFlag == .picked)
        #expect(session.canUndoSwipe == true)
        #expect(session.swipeHistory.count == 1)

        // 5. Subsequent border tap navigates back without overriding or modifying swipe history
        let handledBack = session.handleBorderTap(at: CGPoint(x: 20.0, y: 400.0), in: containerSize)
        #expect(handledBack == true)
        #expect(session.selectedItemID == item1.id)
        #expect(session.canUndoSwipe == true)
        #expect(session.swipeHistory.count == 1)
    }
}
