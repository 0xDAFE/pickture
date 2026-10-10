import Foundation
import Observation

/// Target interface for curation, navigation, and view state mutations driven by interactions.
@MainActor
protocol CullingInteractionTarget: AnyObject {
    var selectedItem: MediaItem? { get }
    var selectedItemID: String? { get set }
    var isAutoAdvanceEnabled: Bool { get set }
    var items: [MediaItem] { get }
    func applyCurationAction(_ action: CurationAction, to item: MediaItem, shouldAutoAdvance: Bool)
    func curationMetadata(for item: MediaItem) -> CurationMetadata
    func updateCurationMetadata(_ metadata: CurationMetadata, for item: MediaItem)
    func selectNextItem()
    func selectPreviousItem()
    func selectFirstItem()
    func selectLastItem()
    func toggleViewMode()
    func setViewMode(_ mode: ViewMode)
    func togglePreviewSource()
    func setPreviewSource(_ source: PreviewSource)
    func toggleAutoAdvance()
    func setAutoAdvance(_ enabled: Bool)
    func toggleBorderTapNavigation()
    func toggleSwipeMode()
    func setSwipeMode(_ enabled: Bool)
}

/// Controller responsible for managing shortcut profile mapping, session command dispatch,
/// swipe gesture curation, and swipe history undo stack.
@Observable
@MainActor
final class CullingInteractionController {
    weak var target: CullingInteractionTarget?
    var shortcutProfileKind: ShortcutProfileKind
    var customShortcutMappings: [String: SessionCommand]
    var swipeRightAction: CurationAction
    var swipeLeftAction: CurationAction
    private(set) var swipeHistory: [SwipeRecord] = []

    var canUndoSwipe: Bool {
        !swipeHistory.isEmpty
    }

    var activeShortcutProfile: ShortcutProfile {
        switch shortcutProfileKind {
        case .lightroom:
            return .lightroom
        case .captureOne:
            return .captureOne
        case .custom:
            return .custom(overrides: customShortcutMappings)
        }
    }

    init(
        target: CullingInteractionTarget? = nil,
        shortcutProfileKind: ShortcutProfileKind = .lightroom,
        customShortcutMappings: [String: SessionCommand] = [:],
        swipeRightAction: CurationAction = .setPickFlag(.picked),
        swipeLeftAction: CurationAction = .setPickFlag(.rejected)
    ) {
        self.target = target
        self.shortcutProfileKind = shortcutProfileKind
        self.customShortcutMappings = customShortcutMappings
        self.swipeRightAction = swipeRightAction
        self.swipeLeftAction = swipeLeftAction
    }

    @discardableResult
    func executeCommand(_ command: SessionCommand) -> Bool {
        guard let target else { return false }
        switch command {
        case .curation(let action):
            guard let item = target.selectedItem else { return false }
            target.applyCurationAction(action, to: item, shouldAutoAdvance: true)
            return true

        case .selectPrevious:
            target.selectPreviousItem()
            return true

        case .selectNext:
            target.selectNextItem()
            return true

        case .selectFirst:
            target.selectFirstItem()
            return true

        case .selectLast:
            target.selectLastItem()
            return true

        case .toggleViewMode:
            target.toggleViewMode()
            return true

        case .setViewMode(let mode):
            target.setViewMode(mode)
            return true

        case .togglePreviewSource:
            target.togglePreviewSource()
            return true

        case .setPreviewSource(let source):
            target.setPreviewSource(source)
            return true

        case .toggleAutoAdvance:
            target.toggleAutoAdvance()
            return true

        case .setAutoAdvance(let enabled):
            target.setAutoAdvance(enabled)
            return true

        case .toggleBorderTapNavigation:
            target.toggleBorderTapNavigation()
            return true

        case .toggleSwipeMode:
            target.toggleSwipeMode()
            return true

        case .setSwipeMode(let enabled):
            target.setSwipeMode(enabled)
            return true

        case .undoLastSwipe:
            return undoLastSwipe()
        }
    }

    @discardableResult
    func handleShortcutKey(_ rawKey: String) -> Bool {
        guard let command = activeShortcutProfile.command(for: rawKey) else {
            return false
        }
        return executeCommand(command)
    }

    @discardableResult
    func executeSwipe(_ direction: SwipeDirection) -> Bool {
        guard let target, let item = target.selectedItem else { return false }
        return executeSwipe(direction, for: item)
    }

    @discardableResult
    func executeSwipe(_ direction: SwipeDirection, for item: MediaItem) -> Bool {
        guard let target else { return false }
        let action = (direction == .right) ? swipeRightAction : swipeLeftAction
        let prev = target.curationMetadata(for: item)
        target.applyCurationAction(action, to: item, shouldAutoAdvance: false)
        let record = SwipeRecord(
            itemID: item.id,
            previousMetadata: prev,
            appliedAction: action,
            direction: direction
        )
        swipeHistory.append(record)
        target.selectNextItem()
        return true
    }

    @discardableResult
    func undoLastSwipe() -> Bool {
        guard let target else { return false }
        guard let last = swipeHistory.popLast() else { return false }
        guard let item = target.items.first(where: { $0.id == last.itemID }) else { return false }
        target.updateCurationMetadata(last.previousMetadata, for: item)
        target.selectedItemID = last.itemID
        return true
    }

    func setShortcutProfileKind(_ kind: ShortcutProfileKind) {
        shortcutProfileKind = kind
    }

    func setCustomShortcut(key: String, command: SessionCommand) {
        customShortcutMappings[key.lowercased()] = command
    }

    func setSwipeRightAction(_ action: CurationAction) {
        swipeRightAction = action
    }

    func setSwipeLeftAction(_ action: CurationAction) {
        swipeLeftAction = action
    }

    func clearSwipeHistory() {
        swipeHistory.removeAll()
    }
}
