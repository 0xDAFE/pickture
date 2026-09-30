import AVKit
import CoreGraphics
import SwiftUI

struct FilmstripView: View {
    let session: CullingSession

    var body: some View {
        VStack(spacing: 0) {
            if session.conflictedItemsCount > 0 {
                conflictAlertBanner
                Divider()
            }

            switch session.filmstripDockPosition {
            case .bottom:
                VStack(spacing: 0) {
                    mainCanvasArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    thumbnailStrip(position: .bottom)
                        .frame(height: 138)
                        .background(.bar)
                }
            case .right:
                HStack(spacing: 0) {
                    mainCanvasArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    thumbnailStrip(position: .right)
                        .frame(width: 144)
                        .background(.bar)
                }
            }
        }
    }

    // MARK: - Main Canvas Area

    @ViewBuilder
    private var mainCanvasArea: some View {
        if let currentItem = session.selectedItem {
            GeometryReader { geo in
                let zoneWidth = session.borderTapZoneWidth(for: geo.size.width)

                ZStack {
                    Color.black.opacity(0.92)
                        .ignoresSafeArea()

                    if currentItem.kind == .video {
                        FilmstripVideoCanvasView(url: currentItem.primaryFile.url)
                            .id(currentItem.id)
                    } else {
                        FilmstripImageCanvasView(item: currentItem, session: session)
                            .id("\(currentItem.id)-\(session.previewSource.rawValue)")
                    }

                    // BorderTapNavigation Edge Tap Zones (applies across both image and video)
                    if session.isBorderTapNavigationEnabled {
                        HStack {
                            Button {
                                session.selectPreviousItem()
                            } label: {
                                Color.white.opacity(0.001)
                                    .frame(width: zoneWidth)
                                    .overlay(
                                        Image(systemName: "chevron.left")
                                            .font(.title2.weight(.bold))
                                            .foregroundStyle(.white.opacity(0.25))
                                            .padding(.leading, 8),
                                        alignment: .leading
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Previous MediaItem")

                            Spacer()

                            Button {
                                session.selectNextItem()
                            } label: {
                                Color.white.opacity(0.001)
                                    .frame(width: zoneWidth)
                                    .overlay(
                                        Image(systemName: "chevron.right")
                                            .font(.title2.weight(.bold))
                                            .foregroundStyle(.white.opacity(0.25))
                                            .padding(.trailing, 8),
                                        alignment: .trailing
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Next MediaItem")
                        }
                    }

                    // Top overlay info badge
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(currentItem.displayFileName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                if !currentItem.relativeDirectoryPath.isEmpty {
                                    Text(currentItem.relativeDirectoryPath)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))

                            Spacer()

                            if currentItem.isMediaPair {
                                Button {
                                    session.togglePreviewSource()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "photo.stack")
                                        Text(session.previewSource == .preferRaster ? "Raster (JPG)" : "RAW Preview")
                                            .font(.caption.weight(.bold))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(session.previewSource == .preferRAW ? Color.orange : Color.blue, in: Capsule())
                                    .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .help("Toggle PreviewSource between PreferRaster and PreferRAW (J)")
                            }
                        }
                        .padding(12)

                        Spacer()

                        // Bottom floating curation controls
                        floatingCurationBar(for: currentItem)
                            .padding(.bottom, 12)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No MediaItem Selected",
                systemImage: "photo.on.rectangle",
                description: Text("Select an item in the filmstrip or grid to preview.")
            )
        }
    }

    // MARK: - Floating Curation Bar

    private func floatingCurationBar(for item: MediaItem) -> some View {
        let curation = session.curationMetadata(for: item)

        return HStack(spacing: 12) {
            // Star Ratings 0..5
            HStack(spacing: 4) {
                Button {
                    session.setStarRating(0, for: item)
                } label: {
                    Image(systemName: "star.slash")
                        .font(.caption)
                        .foregroundStyle(curation.starRating == 0 ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Clear Rating (0)")

                ForEach(1...5, id: \.self) { star in
                    Button {
                        session.setStarRating(StarRating(star), for: item)
                    } label: {
                        Image(systemName: star <= curation.starRating.value ? "star.fill" : "star")
                            .font(.subheadline)
                            .foregroundStyle(star <= curation.starRating.value ? .yellow : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Set Rating \(star) (\(star))")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.65), in: Capsule())

            // Pick Flags: Pick (P), Unflag (U), Reject (X)
            HStack(spacing: 6) {
                Button {
                    session.setPickFlag(.picked, for: item)
                } label: {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(curation.pickFlag == .picked ? .white : .white.opacity(0.5))
                        .padding(5)
                        .background(curation.pickFlag == .picked ? Color.green : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Pick (P or +)")

                Button {
                    session.setPickFlag(.unflagged, for: item)
                } label: {
                    Image(systemName: "flag.slash")
                        .foregroundStyle(curation.pickFlag == .unflagged ? .white : .white.opacity(0.5))
                        .padding(5)
                        .background(curation.pickFlag == .unflagged ? Color.secondary : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Unflag (U)")

                Button {
                    session.setPickFlag(.rejected, for: item)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(curation.pickFlag == .rejected ? .white : .white.opacity(0.5))
                        .padding(5)
                        .background(curation.pickFlag == .rejected ? Color.red : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Reject (X or -)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65), in: Capsule())

            // Color Labels
            HStack(spacing: 5) {
                Button {
                    session.setColorLabel(.none, for: item)
                } label: {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("No Color Label")

                ForEach([ColorLabel.red, .yellow, .green, .blue], id: \.self) { color in
                    Button {
                        session.setColorLabel(color, for: item)
                    } label: {
                        Circle()
                            .fill(color.displayColor)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: curation.colorLabel == color ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.65), in: Capsule())
        }
    }

    // MARK: - Unified Thumbnail Strip

    @ViewBuilder
    private func thumbnailStrip(position: FilmstripDockPosition) -> some View {
        ScrollViewReader { proxy in
            if position == .bottom {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 8) {
                        ForEach(session.items) { item in
                            thumbnailItemView(for: item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: session.selectedItemID) { _, newID in
                    if let newID {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(session.items) { item in
                            thumbnailItemView(for: item)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                }
                .onChange(of: session.selectedItemID) { _, newID in
                    if let newID {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func thumbnailItemView(for item: MediaItem) -> some View {
        FilmstripThumbnailCell(
            item: item,
            isSelected: session.selectedItemID == item.id,
            session: session
        )
        .id(item.id)
        .onTapGesture {
            session.selectedItemID = item.id
        }
    }

    // MARK: - Conflict Alert Banner

    private var conflictAlertBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.conflictedItemsCount) Conflict\(session.conflictedItemsCount == 1 ? "" : "s") Detected")
                    .font(.caption.weight(.semibold))
                Text("External changes diverged from local edits.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resolve…") {
                session.activeConflictItemID = session.selectedItemID
                session.isConflictSheetPresented = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }
}

// MARK: - Filmstrip Image Canvas View

struct FilmstripImageCanvasView: View {
    let item: MediaItem
    let session: CullingSession

    @State private var previewImage: CGImage?
    @State private var zoomScale: CGFloat = 1.0
    @State private var pinchScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var isLoading = false

    private var effectiveScale: CGFloat {
        min(4.0, max(1.0, zoomScale * pinchScale))
    }

    private var displayedImage: CGImage? {
        previewImage
            ?? session.cachedPreviewImage(for: item, maxPixelSize: 2048)
            ?? session.cachedThumbnailImage(for: item, maxPixelSize: 360)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear

                if let cgImage = displayedImage {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(effectiveScale)
                        .offset(
                            x: panOffset.width + dragOffset.width,
                            y: panOffset.height + dragOffset.height
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                }
            }
            .contentShape(Rectangle())
            // Double-tap zoom gesture (toggles between 1.0 and 2.0)
            .gesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if zoomScale > 1.0 {
                            zoomScale = 1.0
                            panOffset = .zero
                            dragOffset = .zero
                        } else {
                            zoomScale = 2.0
                        }
                    }
                }
            )
            // Pinch-to-zoom (1.0x - 4.0x)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        pinchScale = value.magnification
                    }
                    .onEnded { value in
                        zoomScale = min(4.0, max(1.0, zoomScale * value.magnification))
                        pinchScale = 1.0
                        if zoomScale <= 1.0 {
                            panOffset = .zero
                            dragOffset = .zero
                        }
                    }
            )
            // Pan gesture with boundary clamping when zoomed
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        if effectiveScale > 1.0 {
                            dragOffset = value.translation
                        }
                    }
                    .onEnded { value in
                        if effectiveScale > 1.0 {
                            let maxPanX = max(0, (geo.size.width * (effectiveScale - 1)) / 2)
                            let maxPanY = max(0, (geo.size.height * (effectiveScale - 1)) / 2)
                            let newX = panOffset.width + value.translation.width
                            let newY = panOffset.height + value.translation.height
                            panOffset.width = min(maxPanX, max(-maxPanX, newX))
                            panOffset.height = min(maxPanY, max(-maxPanY, newY))
                            dragOffset = .zero
                        }
                    }
            )
            .task(id: "\(item.id)-\(session.previewSource.rawValue)") {
                isLoading = true
                if let data = await session.loadPreviewImageData(for: item, maxPixelSize: 2048) {
                    previewImage = PreviewLoader.decodeCGImage(from: data)
                }
                isLoading = false
            }
        }
    }
}

// MARK: - Filmstrip Video Canvas View

struct FilmstripVideoCanvasView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear {
                        player.pause()
                    }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .onAppear {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Filmstrip Thumbnail Cell

struct FilmstripThumbnailCell: View {
    let item: MediaItem
    let isSelected: Bool
    let session: CullingSession

    @State private var thumbnail: CGImage?

    private var curation: CurationMetadata {
        session.curationMetadata(for: item)
    }

    private var syncState: SyncState {
        session.syncState(for: item)
    }

    private var displayedImage: CGImage? {
        thumbnail ?? session.cachedThumbnailImage(for: item, maxPixelSize: 360)
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.85))

                if let cgImage = displayedImage {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: item.kind == .video ? "film" : "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Color label indicator: A sleek vertical accent stripe on the left edge
                if curation.colorLabel != .none {
                    HStack {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(curation.colorLabel.displayColor)
                            .frame(width: 4)
                            .padding(.vertical, 6)
                            .padding(.leading, 3.5)
                        Spacer()
                    }
                }

                // Rating & Flag overlays
                VStack {
                    HStack(spacing: 3) {
                        if item.isMediaPair {
                            Text("RAW+JPG")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.8), in: Capsule())
                                .foregroundStyle(.yellow)
                        } else if item.kind == .video {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8))
                                .padding(3)
                                .background(.black.opacity(0.8), in: Circle())
                                .foregroundStyle(.white)
                        }

                        Spacer()

                        switch syncState {
                        case .synced:
                            EmptyView()
                        case .pendingWrite:
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        case .conflicted:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        case .loading:
                            ProgressView()
                                .controlSize(.mini)
                        case .syncError:
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.red)
                        }
                    }

                    Spacer()

                    HStack(spacing: 2) {
                        if curation.starRating > 0 {
                            HStack(spacing: 1) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.yellow)
                                Text("\(curation.starRating.value)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.8), in: Capsule())
                        }

                        Spacer()

                        switch curation.pickFlag {
                        case .picked:
                            Image(systemName: "flag.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                                .padding(3)
                                .background(.black.opacity(0.8), in: Circle())
                        case .rejected:
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.red)
                                .padding(3)
                                .background(.black.opacity(0.8), in: Circle())
                        case .unflagged:
                            EmptyView()
                        }
                    }
                }
                .padding(curation.colorLabel != .none ? EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 5) : EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5))
            }
            .frame(width: 108, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )

            Text(item.baseName)
                .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: 108)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.baseName), \(curation.starRating.value) stars, \(curation.pickFlag.rawValue), sync: \(syncState.rawValue)")
        .task(id: item.id) {
            if thumbnail == nil {
                if let data = await session.loadThumbnailData(for: item, maxPixelSize: 360) {
                    thumbnail = PreviewLoader.decodeCGImage(from: data)
                }
            }
        }
    }
}
