import SwiftUI

struct GridContentView: View {
    let session: CullingSession
    var gridColumns: [GridItem]
    var selectedCellStageRect: Binding<CGRect?>?
    var isHeroTransitionActive: Bool

    init(
        session: CullingSession,
        gridColumns: [GridItem] = [GridItem(.adaptive(minimum: 185, maximum: 260), spacing: 12)],
        selectedCellStageRect: Binding<CGRect?>? = nil,
        isHeroTransitionActive: Bool = false
    ) {
        self.session = session
        self.gridColumns = gridColumns
        self.selectedCellStageRect = selectedCellStageRect
        self.isHeroTransitionActive = isHeroTransitionActive
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.conflictedItemsCount > 0 {
                conflictBanner
                Divider()
            }

            statusSummaryBar

            Divider()

            gridLayout
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.conflictedItemsCount) Metadata Conflict\(session.conflictedItemsCount == 1 ? "" : "s") Detected")
                    .font(.subheadline.weight(.semibold))
                Text("External edits on disk diverged from local changes. Review and resolve before syncing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resolve Conflicts…") {
                session.activeConflictItemID = nil
                session.isConflictSheetPresented = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.15))
    }

    private var statusSummaryBar: some View {
        HStack(spacing: 12) {
            if session.filterCriteria.isActive {
                Label("\(session.visibleItems.count) of \(session.items.count) MediaItems", systemImage: "square.grid.3x3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Label("\(session.items.count) MediaItems", systemImage: "square.grid.3x3")
                    .font(.caption.weight(.medium))
            }

            if session.visibleMediaPairCount > 0 {
                Text("• \(session.visibleMediaPairCount) MediaPairs (RAW+JPG)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if session.visibleVideoCount > 0 {
                Text("• \(session.visibleVideoCount) Videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if session.isDiscovering {
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
                if let progress = session.openFolderProgress {
                    Text("Discovering… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Discovering…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var gridLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(session.visibleItems) { item in
                        let isItemSelected = session.selectedItemID == item.id
                        MediaGridCellView(
                            item: item,
                            curation: session.curationMetadata(for: item),
                            syncState: session.syncState(for: item),
                            isSelected: isItemSelected,
                            isRecursiveMode: session.subfolderMode == .recursive,
                            previewSource: session.previewSource,
                            cacheGeneration: session.cacheGeneration,
                            cachedThumbnail: session.inMemoryThumbnailImage(for: item, maxPixelSize: 360),
                            aspectRatio: session.thumbnailAspectRatio(for: item),
                            metadataDeckHeight: CullingLayoutCalculator.defaultGridMetadataDeckHeight,
                            isHeroHidden: isHeroTransitionActive && isItemSelected,
                            onSelect: {
                                session.selectedItemID = item.id
                            },
                            onDoubleClick: {
                                session.selectedItemID = item.id
                                session.setViewMode(.filmstrip)
                            },
                            onResolveConflict: {
                                session.activeConflictItemID = item.id
                                session.isConflictSheetPresented = true
                            },
                            onCurationAction: { action in
                                session.applyCurationAction(action, to: item)
                            },
                            onSelectedStageFrameChange: { rect in
                                if isItemSelected {
                                    selectedCellStageRect?.wrappedValue = rect
                                }
                            },
                            loadThumbnail: { [session, item] in
                                await session.loadThumbnailImage(for: item, maxPixelSize: 360)
                            },
                            onThumbnailLoaded: { [session, item] image in
                                session.recordThumbnailAspectRatio(image.aspectRatio, for: item)
                            },
                            hydrateMetadata: { [session, item] in
                                await session.hydrateMetadata(for: item)
                            }
                        )
                        .equatable()
                        .id(item.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: session.selectedItemID) { _, newID in
                guard let newID else { return }
                if session.viewMode == .grid {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newID)
                    }
                } else {
                    // Keep underlying Grid viewport synchronized while paging/scrubbing in Filmstrip
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }
}
