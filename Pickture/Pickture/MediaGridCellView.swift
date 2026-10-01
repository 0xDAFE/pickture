import CoreGraphics
import SwiftUI

struct MediaGridCellView: View {
    let item: MediaItem
    let isSelected: Bool
    let isRecursiveMode: Bool
    let previewSource: PreviewSource
    let cacheGeneration: Int
    let session: CullingSession
    let onSelect: () -> Void

    @State private var thumbnailImage: CGImage?
    @State private var isLoadingThumbnail = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var taskKey: String {
        "\(item.id)-\(previewSource.rawValue)-\(cacheGeneration)"
    }

    private var displayedThumbnail: CGImage? {
        thumbnailImage ?? session.cachedThumbnailImage(for: item, maxPixelSize: 360)
    }

    private var currentAspectRatio: CGFloat {
        if let cgImage = displayedThumbnail {
            return cgImage.aspectRatio
        }
        return session.thumbnailAspectRatio(for: item)
    }

    private var curation: CurationMetadata {
        session.curationMetadata(for: item)
    }

    private var syncState: SyncState {
        session.syncState(for: item)
    }

    private var floatingDropShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12)
    }

    private func platformFillColor(opacity: Double) -> Color {
        #if canImport(AppKit)
        Color(nsColor: .quaternarySystemFill).opacity(opacity)
        #else
        Color.secondary.opacity(opacity)
        #endif
    }

    private var hoverPlateFill: Color {
        platformFillColor(opacity: 0.4)
    }

    private var neutralPlaceholderFill: Color {
        platformFillColor(opacity: 0.5)
    }

    var body: some View {
        Button(action: {
            if syncState == .conflicted {
                session.activeConflictItemID = item.id
                session.isConflictSheetPresented = true
            } else {
                onSelect()
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                // Tier 1: Image Stage (upper zone with fixed maximum height & uniform baseline shelf)
                imageStageView

                // Tier 2: Metadata Deck (pinned fixed height with middle-truncated filename & toolbar)
                metadataDeckView
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : (isHovered ? hoverPlateFill : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                session.selectedItemID = item.id
                session.setViewMode(.filmstrip)
            }
        )
        .contextMenu {
            contextMenuContent
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayFileName), \(item.mediaTypeBadge)\(item.isMediaPair ? ", RAW+JPG pair" : ""), \(curation.starRating.value) stars, \(curation.pickFlag.rawValue), sync: \(syncState.rawValue)")
        .task(id: taskKey) {
            isLoadingThumbnail = true
            defer { isLoadingThumbnail = false }
            guard let data = await session.loadThumbnailData(for: item, maxPixelSize: 360) else {
                thumbnailImage = nil
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                PreviewLoader.decodeCGImage(from: data)
            }.value
            if !Task.isCancelled {
                thumbnailImage = decoded
                if let decoded {
                    session.recordThumbnailAspectRatio(decoded.aspectRatio, for: item.id)
                }
            }
        }
    }

    // MARK: - Tier 1: Image Stage

    @ViewBuilder
    private var imageStageView: some View {
        GeometryReader { proxy in
            let stageWidth = proxy.size.width
            let stageHeight = proxy.size.height
            let silhouetteSize = session.gridItemSilhouetteSize(
                aspectRatio: currentAspectRatio,
                stageWidth: stageWidth,
                stageHeight: stageHeight,
                mediaKind: item.kind
            )

            ZStack(alignment: .bottom) {
                Color.clear

                floatingSilhouetteView(size: silhouetteSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }

    @ViewBuilder
    private func floatingSilhouetteView(size: CGSize) -> some View {
        ZStack {
            if let cgImage = displayedThumbnail {
                Image(decorative: cgImage, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholderView
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
        )
        .overlay(alignment: .topLeading) {
            formatBadgeView
                .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            syncStateBadgeView
                .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            if item.kind == .video {
                videoBadgeView
                    .padding(6)
            }
        }
        .shadow(
            color: floatingDropShadowColor,
            radius: 4,
            x: 0,
            y: 2
        )
    }

    @ViewBuilder
    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(neutralPlaceholderFill)
            .overlay(
                VStack(spacing: 6) {
                    if isLoadingThumbnail {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: item.kind == .video ? "film" : "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.primaryFile.fileExtension.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            )
    }

    @ViewBuilder
    private var formatBadgeView: some View {
        if item.isMediaPair {
            Text("RAW+JPG")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.75), in: Capsule())
                .foregroundStyle(.yellow)
        } else {
            Text(item.primaryFile.fileExtension.uppercased())
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var videoBadgeView: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.black.opacity(0.7), in: Capsule())
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var syncStateBadgeView: some View {
        switch syncState {
        case .conflicted:
            Button {
                session.activeConflictItemID = item.id
                session.isConflictSheetPresented = true
            } label: {
                Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Click to resolve 3-way conflict")

        case .pendingWrite:
            Label("Pending", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.75), in: Capsule())
                .foregroundStyle(.orange)

        case .loading:
            ProgressView()
                .controlSize(.mini)
                .padding(4)
                .background(.black.opacity(0.65), in: Circle())

        case .syncError:
            Label("Sync Error", systemImage: "exclamationmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.red, in: Capsule())
                .foregroundStyle(.white)

        case .synced:
            EmptyView()
        }
    }

    // MARK: - Tier 2: Metadata Deck

    @ViewBuilder
    private var metadataDeckView: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: Filename with middle truncation (and optional relative directory path in recursive SubfolderMode)
            HStack(spacing: 4) {
                Text(item.displayFileName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isRecursiveMode && !item.relativeDirectoryPath.isEmpty {
                    Text("• \(item.relativeDirectoryPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            // Row 2: Interactive curation toolbar
            curationToolbarView
        }
        .frame(height: session.gridMetadataDeckHeight, alignment: .top)
        .padding(.horizontal, 2)
    }

    private var curationToolbarView: some View {
        HStack(spacing: 4) {
            // Pick / Unflag / Reject
            Button {
                let next: PickFlag = (curation.pickFlag == .picked) ? .unflagged : .picked
                session.setPickFlag(next, for: item)
            } label: {
                Image(systemName: curation.pickFlag == .picked ? "flag.fill" : "flag")
                    .font(.system(size: 11))
                    .foregroundStyle(curation.pickFlag == .picked ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Flag as Picked")

            Button {
                let next: PickFlag = (curation.pickFlag == .rejected) ? .unflagged : .rejected
                session.setPickFlag(next, for: item)
            } label: {
                Image(systemName: curation.pickFlag == .rejected ? "xmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(curation.pickFlag == .rejected ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help("Mark as Rejected")

            Spacer()

            // 1-5 Star Ratings
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        let newRating: StarRating = (curation.starRating.value == star) ? StarRating(0) : StarRating(star)
                        session.setStarRating(newRating, for: item)
                    } label: {
                        Image(systemName: star <= curation.starRating.value ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundStyle(star <= curation.starRating.value ? .yellow : .secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Color label menu
            Menu {
                ForEach(ColorLabel.allCases, id: \.self) { label in
                    Button {
                        session.setColorLabel(label, for: item)
                    } label: {
                        HStack {
                            Circle()
                                .fill(label.displayColor)
                                .frame(width: 8, height: 8)
                            Text(label.rawValue.capitalized)
                            if curation.colorLabel == label {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Circle()
                    .fill(curation.colorLabel == .none ? Color.secondary.opacity(0.3) : curation.colorLabel.displayColor)
                    .frame(width: 9, height: 9)
            }
            .buttonStyle(.plain)
            .help("Assign ColorLabel")
        }
        .padding(.top, 2)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if syncState == .conflicted {
            Button {
                session.activeConflictItemID = item.id
                session.isConflictSheetPresented = true
            } label: {
                Label("Resolve Conflict…", systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
        }

        Menu("Star Rating") {
            Button("0 Stars (Unrated)") { session.setStarRating(0, for: item) }
            ForEach(1...5, id: \.self) { rating in
                Button("\(rating) Stars") { session.setStarRating(StarRating(rating), for: item) }
            }
        }

        Menu("Pick Flag") {
            Button("Picked (P)") { session.setPickFlag(.picked, for: item) }
            Button("Unflagged (U)") { session.setPickFlag(.unflagged, for: item) }
            Button("Rejected (X)") { session.setPickFlag(.rejected, for: item) }
        }

        Menu("Color Label") {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button(label.rawValue.capitalized) { session.setColorLabel(label, for: item) }
            }
        }
    }
}
