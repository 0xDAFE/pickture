import SwiftUI

struct PicktureToolbarContent: ToolbarContent {
    @Environment(\.horizontalSizeClass) private var envHorizontalSizeClass
    @Bindable var session: CullingSession
    @Binding var isFolderImporterPresented: Bool
    @Binding var isSettingsPresented: Bool
    var horizontalSizeClass: UserInterfaceSizeClass?
    var onReopenRecentFolder: (RecentFolder) -> Void

    init(
        session: CullingSession,
        horizontalSizeClass: UserInterfaceSizeClass? = nil,
        isFolderImporterPresented: Binding<Bool> = .constant(false),
        isSettingsPresented: Binding<Bool> = .constant(false),
        onReopenRecentFolder: @escaping (RecentFolder) -> Void = { _ in }
    ) {
        self.session = session
        self.horizontalSizeClass = horizontalSizeClass
        self._isFolderImporterPresented = isFolderImporterPresented
        self._isSettingsPresented = isSettingsPresented
        self.onReopenRecentFolder = onReopenRecentFolder
    }

    private var effectiveHorizontalSizeClass: UserInterfaceSizeClass? {
        horizontalSizeClass ?? envHorizontalSizeClass
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if effectiveHorizontalSizeClass == .compact {
                filterMenu
                viewModePicker
                syncStateBadge
                moreMenu
            } else {
                regularToolbarItems
            }
        }
    }

    // MARK: - Compact Menus

    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Toggle("Subfolder Mode", isOn: $session.isRecursiveSubfolderMode)
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter and subfolder options")
    }

    @ViewBuilder
    private var moreMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            if session.viewMode == .filmstrip {
                Menu {
                    Picker(
                        "Dock Position",
                        selection: Binding(
                            get: { session.filmstripDockPosition },
                            set: { session.setFilmstripDockPosition($0) }
                        )
                    ) {
                        ForEach(FilmstripDockPosition.allCases, id: \.self) { position in
                            Text(position == .bottom ? "Bottom Dock" : "Right Dock").tag(position)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(
                        "Dock: \(session.filmstripDockPosition.displayName)",
                        systemImage: session.filmstripDockPosition == .bottom ? "dock.rectangle" : "sidebar.right"
                    )
                }

                Button {
                    session.toggleBorderTapNavigation()
                } label: {
                    Label(
                        session.isBorderTapNavigationEnabled ? "Border Tap: On" : "Border Tap: Off",
                        systemImage: session.isBorderTapNavigationEnabled ? "hand.tap.fill" : "hand.tap"
                    )
                }

                Button {
                    session.toggleSwipeMode()
                } label: {
                    Label(
                        session.isSwipeModeEnabled ? "SwipeMode: On" : "SwipeMode: Off",
                        systemImage: session.isSwipeModeEnabled ? "hand.draw.fill" : "hand.draw"
                    )
                }
            }

            Button {
                session.togglePreviewSource()
            } label: {
                Label(
                    session.previewSource == .preferRaster ? "Raster" : "RAW",
                    systemImage: "photo.stack"
                )
            }

            Button {
                session.toggleAutoAdvance()
            } label: {
                Label(
                    session.isAutoAdvanceEnabled ? "Auto-Advance: On" : "Auto-Advance: Off",
                    systemImage: session.isAutoAdvanceEnabled ? "forward.fill" : "forward"
                )
            }

            Button {
                isSettingsPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .help("More session options")
    }

    // MARK: - Shared Controls

    @ViewBuilder
    private var viewModePicker: some View {
        Picker("View Mode", selection: $session.viewMode) {
            if effectiveHorizontalSizeClass == .compact {
                Image(systemName: "square.grid.3x3")
                    .accessibilityLabel("Grid")
                    .tag(ViewMode.grid)
                Image(systemName: "rectangle.split.3x1")
                    .accessibilityLabel("Filmstrip")
                    .tag(ViewMode.filmstrip)
            } else {
                Label("Grid (G)", systemImage: "square.grid.3x3").tag(ViewMode.grid)
                Label("Filmstrip (E)", systemImage: "rectangle.split.3x1").tag(ViewMode.filmstrip)
            }
        }
        .pickerStyle(.segmented)
        .help("Toggle between Grid View (G) and Filmstrip View (E or Space)")
    }

    @ViewBuilder
    private var syncStateBadge: some View {
        SyncStateBadgeView(
            session: session,
            isCompact: effectiveHorizontalSizeClass == .compact
        )
    }

    // MARK: - Regular Toolbar Items

    @ViewBuilder
    private var regularToolbarItems: some View {
        viewModePicker

        if session.viewMode == .filmstrip {
            filmstripControls
        }

        Button {
            session.togglePreviewSource()
        } label: {
            Label(
                session.previewSource == .preferRaster ? "Raster" : "RAW",
                systemImage: "photo.stack"
            )
        }
        .help("Toggle PreviewSource (PreferRaster ↔ PreferRAW) (J)")

        Button {
            session.toggleAutoAdvance()
        } label: {
            Label(
                session.isAutoAdvanceEnabled ? "Auto-Advance: On" : "Auto-Advance: Off",
                systemImage: session.isAutoAdvanceEnabled ? "forward.fill" : "forward"
            )
            .foregroundStyle(session.isAutoAdvanceEnabled ? Color.accentColor : Color.primary)
        }
        .help("Toggle Auto-Advance after rating (A)")

        Button {
            isFolderImporterPresented = true
        } label: {
            Label("Open Folder", systemImage: "folder.badge.plus")
        }

        Button {
            Task {
                try? await session.refreshFolder()
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh Folder and re-check sidecars")

        syncStateBadge

        Menu {
            if session.recentFolders.isEmpty {
                Text("No Recent Folders")
            } else {
                ForEach(session.recentFolders) { recent in
                    Button(recent.name) {
                        onReopenRecentFolder(recent)
                    }
                }
            }
        } label: {
            Label("Recent Folders", systemImage: "clock.arrow.circlepath")
        }

        Button {
            try? session.toggleSubfolderMode()
        } label: {
            Label(
                session.subfolderMode == .recursive ? "Subfolders: On" : "Subfolders: Off",
                systemImage: session.subfolderMode == .recursive
                    ? "folder.fill.badge.gearshape"
                    : "folder"
            )
        }
        .help("Toggle recursive Subfolder Mode")

        Button {
            isSettingsPresented = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    @ViewBuilder
    private var filmstripControls: some View {
        Menu {
            Picker(
                "Dock Position",
                selection: Binding(
                    get: { session.filmstripDockPosition },
                    set: { session.setFilmstripDockPosition($0) }
                )
            ) {
                ForEach(FilmstripDockPosition.allCases, id: \.self) { position in
                    Text(position == .bottom ? "Bottom Dock" : "Right Dock").tag(position)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                "Dock: \(session.filmstripDockPosition.displayName)",
                systemImage: session.filmstripDockPosition == .bottom ? "dock.rectangle" : "sidebar.right"
            )
        }
        .help("Filmstrip thumbnail strip dock position")

        Button {
            session.toggleBorderTapNavigation()
        } label: {
            Label(
                session.isBorderTapNavigationEnabled ? "Border Tap: On" : "Border Tap: Off",
                systemImage: session.isBorderTapNavigationEnabled ? "hand.tap.fill" : "hand.tap"
            )
            .foregroundStyle(session.isBorderTapNavigationEnabled ? Color.accentColor : Color.secondary)
        }
        .help("Toggle BorderTapNavigation edge touch zones")

        Button {
            session.toggleSwipeMode()
        } label: {
            Label(
                session.isSwipeModeEnabled ? "SwipeMode: On" : "SwipeMode: Off",
                systemImage: session.isSwipeModeEnabled ? "hand.draw.fill" : "hand.draw"
            )
            .foregroundStyle(session.isSwipeModeEnabled ? Color.accentColor : Color.primary)
        }
        .help("Toggle SwipeMode Culling (Swipe left/right to cull)")

        Button {
            session.undoLastSwipe()
        } label: {
            Label("Undo Swipe", systemImage: "arrow.uturn.backward")
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!session.canUndoSwipe)
        .help("Undo Last Swipe (⌘Z)")
    }
}

struct SyncStateBadgeView: View {
    @Bindable var session: CullingSession
    var isCompact: Bool
    @State private var isErrorPopoverPresented: Bool = false

    var body: some View {
        Button {
            if session.conflictedItemsCount > 0 {
                session.activeConflictItemID = nil
                session.isConflictSheetPresented = true
            } else if session.syncSummaryState == .syncError {
                isErrorPopoverPresented = true
            } else if session.pendingWritesCount > 0 {
                Task { await session.flushPendingWrites() }
            }
        } label: {
            HStack(spacing: 4) {
                switch session.syncSummaryState {
                case .synced:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .pendingWrite:
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                case .loading:
                    ProgressView()
                        .controlSize(.mini)
                case .conflicted:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .syncError:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
                if !isCompact {
                    Text(session.syncSummaryBadgeText)
                        .font(.caption.weight(.medium))
                } else if session.conflictedItemsCount > 0 {
                    Text("\(session.conflictedItemsCount)")
                        .font(.caption2.weight(.bold))
                } else if session.syncSummaryState == .syncError {
                    if session.syncErrorItemsCount > 0 {
                        Text("\(session.syncErrorItemsCount)")
                            .font(.caption2.weight(.bold))
                    }
                } else if session.pendingWritesCount > 0 {
                    Text("\(session.pendingWritesCount)")
                        .font(.caption2.weight(.bold))
                }
            }
            .padding(.horizontal, isCompact ? 6 : 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(
                        session.syncSummaryState == .conflicted
                            ? Color.orange.opacity(0.2)
                            : (session.syncSummaryState == .syncError ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(syncBadgeHelpText)
        .help(syncBadgeHelpText)
        .popover(isPresented: $isErrorPopoverPresented) {
            syncErrorPopover
        }
    }

    private var syncBadgeHelpText: String {
        switch session.syncSummaryState {
        case .conflicted:
            return "Sync Conflicts — Click to resolve conflicts"
        case .syncError:
            return "Sync Error — Click for details and retry"
        case .pendingWrite:
            return "Pending Writes — Click to flush pending writes"
        case .loading:
            return "Syncing..."
        case .synced:
            return "Sync Status — All changes saved"
        }
    }

    @ViewBuilder
    private var syncErrorPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text("Sync Error")
                    .font(.headline)
            }

            if let message = session.lastErrorMessage, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            } else {
                Text("Failed to write metadata changes to storage.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            Text("If using a network share, disconnecting and reconnecting the server in the Files app may help restore write access.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Dismiss") {
                    isErrorPopoverPresented = false
                }
                .buttonStyle(.bordered)

                Button("Retry Now") {
                    isErrorPopoverPresented = false
                    Task {
                        await session.retryFailedWrites()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 280, maxWidth: 360)
    }
}
