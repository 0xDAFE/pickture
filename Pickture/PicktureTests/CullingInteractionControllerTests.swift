import CoreGraphics
import Foundation
import Testing
@testable import Pickture

@MainActor
final class MockCullingInteractionTarget: CullingInteractionTarget {
    var items: [MediaItem]
    var selectedItemID: String?
    var isAutoAdvanceEnabled: Bool = false
    var isBorderTapNavigationEnabled: Bool = true
    var isSwipeModeEnabled: Bool = false
    var viewMode: ViewMode = .grid
    var previewSource: PreviewSource = .preferRaster
    var metadataByItemID: [String: CurationMetadata] = [:]
    var shouldFailRestoreSwipe: Bool = false

    init(items: [MediaItem] = []) {
        self.items = items
        self.selectedItemID = items.first?.id
    }

    func restoreSwipeState(for itemID: String, metadata: CurationMetadata) -> Bool {
        if shouldFailRestoreSwipe { return false }
        guard let item = items.first(where: { $0.id == itemID }) else { return false }
        updateCurationMetadata(metadata, for: item)
        selectedItemID = itemID
        return true
    }

    var selectedItem: MediaItem? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID }) ?? items.first
    }

    func applyCurationAction(_ action: CurationAction, to item: MediaItem, shouldAutoAdvance: Bool) {
        var current = curationMetadata(for: item)
        switch action {
        case .starRating(let rating):
            current.starRating = rating
        case .pickFlag(let flag):
            current.pickFlag = flag
        case .colorLabel(let label):
            current.colorLabel = label
        case .compound(let star, let flag, let label):
            if let star { current.starRating = star }
            if let flag { current.pickFlag = flag }
            if let label { current.colorLabel = label }
        }
        updateCurationMetadata(current, for: item)
        if shouldAutoAdvance && isAutoAdvanceEnabled && (selectedItemID == nil || selectedItemID == item.id) {
            selectNextItem()
        }
    }

    func curationMetadata(for item: MediaItem) -> CurationMetadata {
        metadataByItemID[item.id] ?? CurationMetadata()
    }

    func updateCurationMetadata(_ metadata: CurationMetadata, for item: MediaItem) {
        metadataByItemID[item.id] = metadata
    }

    func selectNextItem() {
        guard !items.isEmpty else { return }
        guard let currentID = selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            selectedItemID = items.first?.id
            return
        }
        if currentIndex + 1 < items.count {
            selectedItemID = items[currentIndex + 1].id
        }
    }

    func selectPreviousItem() {
        guard !items.isEmpty else { return }
        guard let currentID = selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            selectedItemID = items.first?.id
            return
        }
        if currentIndex > 0 {
            selectedItemID = items[currentIndex - 1].id
        }
    }

    func selectFirstItem() {
        selectedItemID = items.first?.id
    }

    func selectLastItem() {
        selectedItemID = items.last?.id
    }

    func toggleViewMode() {
        viewMode = (viewMode == .grid) ? .filmstrip : .grid
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
    }

    func togglePreviewSource() {
        previewSource = (previewSource == .preferRaster) ? .preferRAW : .preferRaster
    }

    func setPreviewSource(_ source: PreviewSource) {
        previewSource = source
    }

    func toggleAutoAdvance() {
        isAutoAdvanceEnabled.toggle()
    }

    func setAutoAdvance(_ enabled: Bool) {
        isAutoAdvanceEnabled = enabled
    }

    func toggleBorderTapNavigation() {
        isBorderTapNavigationEnabled.toggle()
    }

    func toggleSwipeMode() {
        isSwipeModeEnabled.toggle()
    }

    func setSwipeMode(_ enabled: Bool) {
        isSwipeModeEnabled = enabled
    }
}

@MainActor
struct CullingInteractionControllerTests {

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

    private func makeTestItems() -> [MediaItem] {
        return [
            makeDummyMediaItem(id: "item1", baseName: "IMG001"),
            makeDummyMediaItem(id: "item2", baseName: "IMG002"),
            makeDummyMediaItem(id: "item3", baseName: "IMG003")
        ]
    }

    // MARK: - Command Execution Tests

    @Test("Command execution dispatches curation, navigation, view modes, and settings to target")
    func commandExecutionDispatchesToTarget() {
        let items = makeTestItems()
        let target = MockCullingInteractionTarget(items: items)
        let controller = CullingInteractionController(target: target)

        #expect(target.selectedItemID == "item1")

        // Curation command
        let handledCuration = controller.executeCommand(.curation(.setPickFlag(.picked)))
        #expect(handledCuration == true)
        #expect(target.curationMetadata(for: items[0]).pickFlag == .picked)

        // Navigation commands
        #expect(controller.executeCommand(.selectNext) == true)
        #expect(target.selectedItemID == "item2")

        #expect(controller.executeCommand(.selectLast) == true)
        #expect(target.selectedItemID == "item3")

        #expect(controller.executeCommand(.selectPrevious) == true)
        #expect(target.selectedItemID == "item2")

        #expect(controller.executeCommand(.selectFirst) == true)
        #expect(target.selectedItemID == "item1")

        // View mode commands
        #expect(target.viewMode == .grid)
        #expect(controller.executeCommand(.toggleViewMode) == true)
        #expect(target.viewMode == .filmstrip)
        #expect(controller.executeCommand(.setViewMode(.grid)) == true)
        #expect(target.viewMode == .grid)

        // Preview source commands
        #expect(target.previewSource == .preferRaster)
        #expect(controller.executeCommand(.togglePreviewSource) == true)
        #expect(target.previewSource == .preferRAW)
        #expect(controller.executeCommand(.setPreviewSource(.preferRaster)) == true)
        #expect(target.previewSource == .preferRaster)

        // Auto-advance commands
        #expect(target.isAutoAdvanceEnabled == false)
        #expect(controller.executeCommand(.toggleAutoAdvance) == true)
        #expect(target.isAutoAdvanceEnabled == true)
        #expect(controller.executeCommand(.setAutoAdvance(false)) == true)
        #expect(target.isAutoAdvanceEnabled == false)

        // Border tap commands
        #expect(target.isBorderTapNavigationEnabled == true)
        #expect(controller.executeCommand(.toggleBorderTapNavigation) == true)
        #expect(target.isBorderTapNavigationEnabled == false)

        // Swipe mode commands
        #expect(target.isSwipeModeEnabled == false)
        #expect(controller.executeCommand(.toggleSwipeMode) == true)
        #expect(target.isSwipeModeEnabled == true)
        #expect(controller.executeCommand(.setSwipeMode(false)) == true)
        #expect(target.isSwipeModeEnabled == false)
    }

    // MARK: - Shortcut Key Parsing

    @Test("Shortcut keys dispatch correctly for Lightroom, Capture One, and Custom profiles")
    func shortcutKeyDispatchAcrossProfiles() {
        let items = makeTestItems()
        let target = MockCullingInteractionTarget(items: items)
        let controller = CullingInteractionController(target: target)

        // Lightroom profile (default)
        #expect(controller.shortcutProfileKind == .lightroom)
        #expect(controller.activeShortcutProfile.kind == .lightroom)

        #expect(controller.handleShortcutKey("5") == true)
        #expect(target.curationMetadata(for: items[0]).starRating == 5)

        #expect(controller.handleShortcutKey("p") == true)
        #expect(target.curationMetadata(for: items[0]).pickFlag == .picked)

        #expect(controller.handleShortcutKey("6") == true)
        #expect(target.curationMetadata(for: items[0]).colorLabel == .red)

        // Capture One profile
        controller.setShortcutProfileKind(.captureOne)
        #expect(controller.shortcutProfileKind == .captureOne)
        #expect(controller.activeShortcutProfile.kind == .captureOne)

        #expect(controller.handleShortcutKey("+") == true)
        #expect(target.curationMetadata(for: items[0]).pickFlag == .picked)

        #expect(controller.handleShortcutKey("*") == true)
        #expect(target.curationMetadata(for: items[0]).colorLabel == .green)

        // Custom profile
        controller.setShortcutProfileKind(.custom)
        #expect(controller.shortcutProfileKind == .custom)
        controller.setCustomShortcut(key: "z", command: .curation(.setPickFlag(.rejected)))
        #expect(controller.handleShortcutKey("z") == true)
        #expect(target.curationMetadata(for: items[0]).pickFlag == .rejected)

        // Unmapped key
        #expect(controller.handleShortcutKey("F24") == false)
    }

    // MARK: - Swipe Execution & History

    @Test("Swipe execution applies actions, records history, and auto-advances")
    func swipeExecutionAndHistory() {
        let items = makeTestItems()
        let target = MockCullingInteractionTarget(items: items)
        let controller = CullingInteractionController(target: target)

        #expect(controller.canUndoSwipe == false)
        #expect(controller.swipeHistory.isEmpty == true)

        // Default: Right = Picked, Left = Rejected
        #expect(controller.swipeRightAction == .setPickFlag(.picked))
        #expect(controller.swipeLeftAction == .setPickFlag(.rejected))

        // Swipe right on item1
        let swipedRight = controller.executeSwipe(.right)
        #expect(swipedRight == true)
        #expect(target.curationMetadata(for: items[0]).pickFlag == .picked)
        #expect(target.selectedItemID == "item2")
        #expect(controller.swipeHistory.count == 1)
        #expect(controller.canUndoSwipe == true)

        let record1 = controller.swipeHistory.first
        #expect(record1?.itemID == "item1")
        #expect(record1?.direction == .right)
        #expect(record1?.appliedAction == .setPickFlag(.picked))

        // Configure custom swipe left action
        controller.setSwipeLeftAction(.compound(starRating: 1, pickFlag: .rejected, colorLabel: .red))
        let swipedLeft = controller.executeSwipe(.left)
        #expect(swipedLeft == true)
        let meta2 = target.curationMetadata(for: items[1])
        #expect(meta2.starRating == 1)
        #expect(meta2.pickFlag == .rejected)
        #expect(meta2.colorLabel == .red)
        #expect(target.selectedItemID == "item3")
        #expect(controller.swipeHistory.count == 2)

        // Item-specific swipe overload
        controller.setSwipeRightAction(.setStarRating(5))
        let swipedItem1 = controller.executeSwipe(.right, for: items[0])
        #expect(swipedItem1 == true)
        #expect(target.curationMetadata(for: items[0]).starRating == 5)
        #expect(controller.swipeHistory.count == 3)
    }

    @Test("Item-specific swipe does not advance selection when swiping an unselected item")
    func itemSpecificSwipeDoesNotAdvanceSelectionForUnselectedItem() {
        let items = makeTestItems()
        let target = MockCullingInteractionTarget(items: items)
        let controller = CullingInteractionController(target: target)

        #expect(target.selectedItemID == "item1")

        // 1. Swipe on item2 (which is NOT selected): curation updates, selection remains on item1
        let swipedUnselected = controller.executeSwipe(.right, for: items[1])
        #expect(swipedUnselected == true)
        #expect(target.curationMetadata(for: items[1]).pickFlag == .picked)
        #expect(target.selectedItemID == "item1")

        // 2. Swipe on item1 (which IS selected): curation updates and selection advances to item2
        let swipedSelected = controller.executeSwipe(.left, for: items[0])
        #expect(swipedSelected == true)
        #expect(target.curationMetadata(for: items[0]).pickFlag == .rejected)
        #expect(target.selectedItemID == "item2")

        // 3. Swipe when selectedItemID is nil: curation updates and selectNextItem selects first item
        target.selectedItemID = nil
        let swipedWhenNil = controller.executeSwipe(.right, for: items[0])
        #expect(swipedWhenNil == true)
        #expect(target.selectedItemID == "item1")
    }

    // MARK: - Undo Last Swipe

    @Test("Undo last swipe restores previous metadata and item selection")
    func undoLastSwipeRestoresState() {
        let items = makeTestItems()
        let target = MockCullingInteractionTarget(items: items)
        let controller = CullingInteractionController(target: target)

        // Seed initial metadata on item1
        target.updateCurationMetadata(
            CurationMetadata(starRating: 3, pickFlag: .unflagged, colorLabel: .blue),
            for: items[0]
        )

        controller.setSwipeRightAction(.setPickFlag(.picked))
        #expect(controller.executeSwipe(.right) == true)
        #expect(target.curationMetadata(for: items[0]).pickFlag == .picked)
        #expect(target.selectedItemID == "item2")

        // Undo
        #expect(controller.undoLastSwipe() == true)
        let restored = target.curationMetadata(for: items[0])
        #expect(restored.starRating == 3)
        #expect(restored.pickFlag == .unflagged)
        #expect(restored.colorLabel == .blue)
        #expect(target.selectedItemID == "item1")
        #expect(controller.canUndoSwipe == false)

        // Execute command undoLastSwipe
        #expect(controller.executeSwipe(.right) == true)
        #expect(controller.canUndoSwipe == true)
        #expect(controller.executeCommand(.undoLastSwipe) == true)
        #expect(target.selectedItemID == "item1")
        #expect(controller.canUndoSwipe == false)
    }

    @Test("Non-destructive undo retains swipe history and canUndoSwipe when target cannot restore item")
    func nonDestructiveUndoRetainsHistoryOnFailure() {
        let items = makeTestItems()
        let target = MockCullingInteractionTarget(items: items)
        let controller = CullingInteractionController(target: target)

        #expect(controller.executeSwipe(.right) == true)
        #expect(controller.canUndoSwipe == true)
        #expect(controller.swipeHistory.count == 1)

        // 1. When target fails to restore state (e.g. item deleted from session or invalid item ID)
        target.shouldFailRestoreSwipe = true
        let undoResult = controller.undoLastSwipe()
        #expect(undoResult == false)
        #expect(controller.canUndoSwipe == true)
        #expect(controller.swipeHistory.count == 1)

        // 2. When target is subsequently able to restore state
        target.shouldFailRestoreSwipe = false
        #expect(controller.undoLastSwipe() == true)
        #expect(controller.canUndoSwipe == false)
        #expect(controller.swipeHistory.isEmpty == true)
    }

    // MARK: - Edge Cases

    @Test("Edge cases: nil target, empty items, empty history, and clearSwipeHistory")
    func edgeCasesHandling() {
        let controller = CullingInteractionController()
        #expect(controller.target == nil)

        // No target
        #expect(controller.executeCommand(.selectNext) == false)
        #expect(controller.handleShortcutKey("5") == false)
        #expect(controller.executeSwipe(.right) == false)
        #expect(controller.undoLastSwipe() == false)

        // Target with empty items
        let emptyTarget = MockCullingInteractionTarget(items: [])
        controller.target = emptyTarget

        #expect(controller.executeCommand(.curation(.setPickFlag(.picked))) == false)
        #expect(controller.executeSwipe(.right) == false)
        #expect(controller.undoLastSwipe() == false)

        // Clear swipe history
        let items = makeTestItems()
        let target = MockCullingInteractionTarget(items: items)
        controller.target = target

        #expect(controller.executeSwipe(.right) == true)
        #expect(controller.canUndoSwipe == true)
        controller.clearSwipeHistory()
        #expect(controller.canUndoSwipe == false)
        #expect(controller.undoLastSwipe() == false)
    }
}
