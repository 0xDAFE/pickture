import SwiftUI

struct GridContentView: View {
    let session: CullingSession
    var gridColumns: [GridItem]

    init(
        session: CullingSession,
        gridColumns: [GridItem] = [GridItem(.adaptive(minimum: 185, maximum: 260), spacing: 12)]
    ) {
        self.session = session
        self.gridColumns = gridColumns
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
                        MediaGridCellView(
                            item: item,
                            curation: session.curationMetadata(for: item),
                            syncState: session.syncState(for: item),
                            isSelected: session.selectedItemID == item.id,
                            isRecursiveMode: session.subfolderMode == .recursive,
                            previewSource: session.previewSource,
                            cacheGeneration: session.cacheGeneration,
                            cachedThumbnail: session.cachedThumbnailImage(for: item, maxPixelSize: 360),
                            aspectRatio: session.thumbnailAspectRatio(for: item),
                            metadataDeckHeight: session.gridMetadataDeckHeight,
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
                            loadThumbnail: { [session, item] in
                                guard let data = await session.loadThumbnailData(for: item, maxPixelSize: 360) else { return nil }
                                return await PreviewLoader.decodeCGImageAsync(from: data)
                            },
                            onThumbnailLoaded: { [session, item] image in
                                session.recordThumbnailAspectRatio(image.aspectRatio, for: item.id)
                            }
                        )
                        .equatable()
                        .id(item.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: session.selectedItemID) { _, newID in
                if let newID, session.viewMode == .grid {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newID)
                    }
                }
            }
        }
    }
}
