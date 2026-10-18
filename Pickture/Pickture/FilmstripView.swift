import AVKit
import CoreGraphics
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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
                let zoneWidth = CullingLayoutCalculator.borderTapZoneWidth(for: geo.size.width)

                ZStack {
                    Color.black.opacity(0.92)
                        .ignoresSafeArea()

                    if currentItem.kind == .video {
                        FilmstripVideoCanvasView(url: currentItem.primaryFile.url, item: currentItem, session: session)
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

                            if currentItem.isMediaPair || currentItem.hasRAWFile {
                                FilmstripRepresentationControls(item: currentItem, session: session)
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
            let isHorizontal = position == .bottom
            let axis: Axis.Set = isHorizontal ? .horizontal : .vertical
            ScrollView(axis, showsIndicators: true) {
                if isHorizontal {
                    LazyHStack(spacing: 8) {
                        ForEach(session.visibleItems) { item in
                            thumbnailItemView(for: item, position: .bottom)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(session.visibleItems) { item in
                            thumbnailItemView(for: item, position: .right)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                }
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

    private func thumbnailItemView(for item: MediaItem, position: FilmstripDockPosition) -> some View {
        FilmstripThumbnailCell(
            item: item,
            curation: session.curationMetadata(for: item),
            syncState: session.syncState(for: item),
            isSelected: session.selectedItemID == item.id,
            dockPosition: position,
            previewSource: session.previewSource,
            cacheGeneration: session.cacheGeneration,
            cachedThumbnail: session.inMemoryThumbnailImage(for: item, maxPixelSize: 360),
            aspectRatio: session.thumbnailAspectRatio(for: item),
            onSelect: {
                session.selectItemDirectly(id: item.id)
            },
            loadThumbnail: { [session, item] in
                await session.loadThumbnailImage(for: item, maxPixelSize: 360)
            },
            onThumbnailLoaded: { [session, item] image in
                session.recordThumbnailAspectRatio(image.aspectRatio, for: item.id)
            },
            hydrateMetadata: { [session, item] in
                await session.hydrateMetadata(for: item)
            }
        )
        .equatable()
        .id(item.id)
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

// MARK: - Filmstrip Representation Controls

struct FilmstripRepresentationControls: View {
    let item: MediaItem
    let session: CullingSession

    var state: PreviewRepresentation {
        session.previewRepresentation(for: item)
    }

    var body: some View {
        HStack(spacing: 8) {
            representationPill

            if item.hasRAWFile && (session.previewSource == .preferRAW || !item.isMediaPair) {
                FullRAWActionButton(item: item, session: session)
                    .id(item.id)
            }
        }
        .animation(.snappy, value: state)
    }

    @ViewBuilder
    private var representationPill: some View {
        let labelContent = pillContent

        if item.isMediaPair {
            Button {
                session.togglePreviewSource()
            } label: {
                labelContent
            }
            .buttonStyle(.plain)
            .help(state.helpText(isMediaPair: true))
        } else {
            labelContent
                .help(state.helpText(isMediaPair: false))
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        HStack(spacing: 4) {
            Image(systemName: state.iconName)
                .accessibilityHidden(true)
            Text(state.titleText)
                .font(.caption.weight(.bold))
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(state.backgroundColor, in: Capsule())
        .foregroundStyle(.white)
    }
}

// MARK: - PreviewRepresentation Presentation

extension PreviewRepresentation {
    var iconName: String {
        switch self {
        case .raster, .rawPreview:
            return "photo.stack"
        case .fullRAW:
            return "camera.aperture"
        }
    }

    var titleText: String {
        switch self {
        case .raster:
            return "Raster (JPG)"
        case .rawPreview:
            return "RAW Preview"
        case .fullRAW:
            return "Full RAW"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .raster:
            return .blue
        case .rawPreview:
            return .orange
        case .fullRAW:
            return .purple
        }
    }

    func helpText(isMediaPair: Bool) -> String {
        switch self {
        case .raster:
            return "Showing paired raster file. Toggle between Raster and RAW (J)"
        case .rawPreview:
            return isMediaPair
                ? "Showing embedded RAW preview. Toggle between Raster and RAW (J)"
                : "Showing embedded RAW preview"
        case .fullRAW:
            return isMediaPair
                ? "Showing 100% demosaiced sensor RAW. Toggle between Raster and RAW (J)"
                : "Showing 100% demosaiced sensor RAW"
        }
    }
}

// MARK: - Full RAW Action Button

struct FullRAWActionButton: View {
    let item: MediaItem
    let session: CullingSession

    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        if !session.isFullRAWLoaded(for: item) {
            let isLoading = session.isLoadingFullRAW(for: item)

            Button {
                guard !isLoading else { return }
                loadTask?.cancel()
                loadTask = Task {
                    _ = await session.loadFullRAW(for: item)
                }
            } label: {
                HStack(spacing: 5) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Demosaicing RAW…")
                            .font(.caption.weight(.medium))
                    } else {
                        Image(systemName: "camera.aperture")
                        Text("Load Full RAW")
                            .font(.caption.weight(.medium))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help(isLoading ? "Demosaicing RAW…" : "Demosaic full RAW for critical focus inspection (ADR-0005)")
            .onDisappear {
                loadTask?.cancel()
                loadTask = nil
            }
        }
    }
}

// MARK: - Swipe Action Badge View

struct SwipeActionBadgeView: View {
    let action: CurationAction
    let direction: SwipeDirection

    private var badgeColor: Color {
        switch direction {
        case .right:
            return .green
        case .left:
            return .red
        }
    }

    private var iconName: String {
        if let flag = action.pickFlagValue {
            switch flag {
            case .picked: return "flag.fill"
            case .rejected: return "xmark"
            case .unflagged: return "flag.slash"
            }
        }
        if let star = action.starRatingValue, star.value > 0 {
            return "star.fill"
        }
        if let label = action.colorLabelValue, label != .none {
            return "tag.fill"
        }
        return direction == .right ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title2.weight(.bold))
                .foregroundStyle(badgeColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(direction == .right ? "SWIPE RIGHT" : "SWIPE LEFT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .tracking(1)

                Text(action.displayName)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(badgeColor, lineWidth: 2.5)
                )
                .shadow(color: badgeColor.opacity(0.5), radius: 14, x: 0, y: 4)
        )
    }
}

// MARK: - Filmstrip Image Canvas View

struct FilmstripImageCanvasView: View {
    let item: MediaItem
    let session: CullingSession

    @State private var previewImage: CGImage?
    @State private var zoomScale: CGFloat
    @State private var pinchScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var swipeTranslation: CGFloat = 0.0
    @State private var isLoading = false

    var currentZoomScale: CGFloat { zoomScale }

    init(item: MediaItem, session: CullingSession) {
        self.item = item
        self.session = session
        if let lock = session.zoomLockState, lock.scale > 1.0 {
            _zoomScale = State(initialValue: lock.scale)
        } else {
            _zoomScale = State(initialValue: 1.0)
        }
    }

    private var effectiveScale: CGFloat {
        if zoomScale <= 1.0 {
            return min(4.0, max(0.75, zoomScale * pinchScale))
        }
        return min(4.0, max(1.0, zoomScale * pinchScale))
    }

    private var displayedImage: CGImage? {
        if (session.previewSource == .preferRAW || !item.isMediaPair),
           session.isFullRAWLoaded(for: item),
           let fullRaw = session.inMemoryFullRAWImage(for: item) {
            return fullRaw
        }
        return previewImage
            ?? session.inMemoryPreviewImage(for: item, maxPixelSize: 2048)
            ?? session.inMemoryThumbnailImage(for: item, maxPixelSize: 360)
    }

    private func currentImageSize(in containerSize: CGSize) -> CGSize {
        if let cgImage = displayedImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        let ratio = session.thumbnailAspectRatio(for: item)
        return CGSize(width: max(1.0, ratio * 1000), height: 1000)
    }

    private func activePanOffset(in containerSize: CGSize) -> CGSize {
        if panOffset != .zero || dragOffset != .zero {
            return CGSize(width: panOffset.width + dragOffset.width, height: panOffset.height + dragOffset.height)
        }
        if let lock = session.zoomLockState, lock.scale > 1.0 {
            return CullingLayoutCalculator.calculatePanOffset(
                forNormalizedAnchor: lock.normalizedAnchor,
                containerSize: containerSize,
                imageSize: currentImageSize(in: containerSize),
                scale: lock.scale
            )
        }
        return .zero
    }

    private func handleDoubleTap(at location: CGPoint, in containerSize: CGSize) {
        if zoomScale > 1.0 {
            withAnimation(.easeInOut(duration: 0.25)) {
                zoomScale = 1.0
                panOffset = .zero
                dragOffset = .zero
            }
            session.clearZoomLock()
        } else {
            let imgSize = currentImageSize(in: containerSize)
            let anchor = CullingLayoutCalculator.normalizedAnchor(
                forTapLocation: location,
                inContainerSize: containerSize,
                imageSize: imgSize
            )
            let newScale: CGFloat = 2.0
            let newOffset = CullingLayoutCalculator.calculatePanOffset(
                forNormalizedAnchor: anchor,
                containerSize: containerSize,
                imageSize: imgSize,
                scale: newScale
            )
            withAnimation(.easeInOut(duration: 0.25)) {
                zoomScale = newScale
                panOffset = newOffset
                dragOffset = .zero
            }
            session.setZoomLock(scale: newScale, normalizedAnchor: anchor)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let threshold = CullingLayoutCalculator.swipeNavigationThreshold(for: geo.size.width)
            let isSwipeCullingActive = session.isSwipeModeEnabled && effectiveScale <= 1.0
            let isSwipeNavActive = !session.isSwipeModeEnabled && effectiveScale <= 1.0
            let isAtLeading = !session.canSelectPreviousItem
            let isAtTrailing = !session.canSelectNextItem
            let currentPan = activePanOffset(in: geo.size)

            ZStack {
                Color.clear

                if let cgImage = displayedImage {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(effectiveScale)
                        .offset(
                            x: currentPan.width + (isSwipeCullingActive || isSwipeNavActive ? swipeTranslation : 0),
                            y: currentPan.height
                        )
                        .rotationEffect(
                            Angle.degrees(
                                isSwipeCullingActive
                                    ? Double(min(12.0, max(-12.0, swipeTranslation / 25.0)))
                                    : 0
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                }

                // Overlay action badge when swiping horizontally at 1.0x zoom in dedicated SwipeMode
                if isSwipeCullingActive {
                    if swipeTranslation > 20 {
                        let progress = min(1.0, (swipeTranslation - 20) / max(1.0, threshold - 20))
                        SwipeActionBadgeView(action: session.swipeRightAction, direction: .right)
                            .opacity(Double(progress))
                            .scaleEffect(0.85 + 0.15 * progress)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else if swipeTranslation < -20 {
                        let progress = min(1.0, (-swipeTranslation - 20) / max(1.0, threshold - 20))
                        SwipeActionBadgeView(action: session.swipeLeftAction, direction: .left)
                            .opacity(Double(progress))
                            .scaleEffect(0.85 + 0.15 * progress)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }

            .contentShape(Rectangle())
            // Double-tap zoom gesture (centers on tapped point)
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { event in
                        handleDoubleTap(at: event.location, in: geo.size)
                    }
            )
            // Pinch-to-zoom (1.0x - 4.0x) & PinchToGrid
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        pinchScale = value.magnification
                        if swipeTranslation != 0 {
                            swipeTranslation = 0
                        }
                    }
                    .onEnded { value in
                        if CullingLayoutCalculator.shouldCommitPinchToGrid(currentZoom: zoomScale, magnification: value.magnification) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                session.setViewMode(.grid)
                            }
                            pinchScale = 1.0
                        } else {
                            let targetScale = min(4.0, max(1.0, zoomScale * value.magnification))
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                zoomScale = targetScale
                                pinchScale = 1.0
                            }
                            if targetScale <= 1.0 {
                                panOffset = .zero
                                dragOffset = .zero
                                session.clearZoomLock()
                            } else {
                                let imgSize = currentImageSize(in: geo.size)
                                panOffset = CullingLayoutCalculator.clampPanOffset(
                                    currentPan,
                                    containerSize: geo.size,
                                    imageSize: imgSize,
                                    scale: targetScale
                                )
                                let anchor = CullingLayoutCalculator.calculateNormalizedAnchor(
                                    forPanOffset: panOffset,
                                    containerSize: geo.size,
                                    imageSize: imgSize,
                                    scale: targetScale
                                )
                                session.setZoomLock(scale: targetScale, normalizedAnchor: anchor)
                            }
                        }
                    }
            )
            // Pan gesture when zoomed (> 1.0x) OR Swipe curation / navigation when at 1.0x
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        if effectiveScale > 1.0 {
                            // Zoomed: inspect focus sharpness by panning
                            dragOffset = value.translation
                        } else if session.isSwipeModeEnabled && pinchScale == 1.0 {
                            // 1.0x zoom: swipe curation
                            swipeTranslation = value.translation.width
                        } else if !session.isSwipeModeEnabled && pinchScale == 1.0 {
                            // 1.0x zoom: swipe navigation with boundary damping
                            swipeTranslation = CullingLayoutCalculator.swipeNavigationTranslation(
                                offset: value.translation.width,
                                isAtLeadingBoundary: isAtLeading,
                                isAtTrailingBoundary: isAtTrailing
                            )
                        }
                    }
                    .onEnded { value in
                        if effectiveScale > 1.0 {
                            let imgSize = currentImageSize(in: geo.size)
                            let initialPan = (panOffset != .zero) ? panOffset : activePanOffset(in: geo.size)
                            let newOffset = CGSize(
                                width: initialPan.width + value.translation.width,
                                height: initialPan.height + value.translation.height
                            )
                            panOffset = CullingLayoutCalculator.clampPanOffset(
                                newOffset,
                                containerSize: geo.size,
                                imageSize: imgSize,
                                scale: effectiveScale
                            )
                            dragOffset = .zero

                            let anchor = CullingLayoutCalculator.calculateNormalizedAnchor(
                                forPanOffset: panOffset,
                                containerSize: geo.size,
                                imageSize: imgSize,
                                scale: effectiveScale
                            )
                            session.setZoomLock(scale: effectiveScale, normalizedAnchor: anchor)
                        } else if session.isSwipeModeEnabled && pinchScale == 1.0 {
                            if value.translation.width >= threshold {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeTranslation = geo.size.width + 100
                                } completion: {
                                    swipeTranslation = 0
                                }
                                session.executeSwipe(.right, for: item)
                            } else if value.translation.width <= -threshold {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeTranslation = -geo.size.width - 100
                                } completion: {
                                    swipeTranslation = 0
                                }
                                session.executeSwipe(.left, for: item)
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    swipeTranslation = 0
                                }
                            }
                        } else if !session.isSwipeModeEnabled && pinchScale == 1.0 {
                            // SwipeNavigation: Dragging left (width <= -threshold) -> Next, Dragging right (width >= threshold) -> Previous
                            if value.translation.width <= -threshold && session.canSelectNextItem {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeTranslation = -geo.size.width
                                } completion: {
                                    swipeTranslation = 0
                                    session.selectNextItem()
                                }
                            } else if value.translation.width >= threshold && session.canSelectPreviousItem {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeTranslation = geo.size.width
                                } completion: {
                                    swipeTranslation = 0
                                    session.selectPreviousItem()
                                }
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    swipeTranslation = 0
                                }
                            }
                        }
                    }
            )
            .onAppear {
                if let lock = session.zoomLockState, lock.scale > 1.0, panOffset == .zero {
                    let computed = CullingLayoutCalculator.calculatePanOffset(
                        forNormalizedAnchor: lock.normalizedAnchor,
                        containerSize: geo.size,
                        imageSize: currentImageSize(in: geo.size),
                        scale: lock.scale
                    )
                    panOffset = computed
                }
            }
            .task(id: "\(item.id)-\(session.previewSource.rawValue)-\(session.cacheGeneration)") {
                if let inMemory = session.inMemoryPreviewImage(for: item, maxPixelSize: 2048) {
                    previewImage = inMemory
                    if let lock = session.zoomLockState, lock.scale > 1.0 {
                        let imgSize = CGSize(width: inMemory.width, height: inMemory.height)
                        panOffset = CullingLayoutCalculator.calculatePanOffset(
                            forNormalizedAnchor: lock.normalizedAnchor,
                            containerSize: geo.size,
                            imageSize: imgSize,
                            scale: lock.scale
                        )
                    }
                    return
                }
                isLoading = true
                defer { isLoading = false }
                let decoded = await session.loadPreviewImage(for: item, maxPixelSize: 2048)
                if !Task.isCancelled {
                    previewImage = decoded
                    if let decoded = decoded, let lock = session.zoomLockState, lock.scale > 1.0 {
                        let imgSize = CGSize(width: decoded.width, height: decoded.height)
                        panOffset = CullingLayoutCalculator.calculatePanOffset(
                            forNormalizedAnchor: lock.normalizedAnchor,
                            containerSize: geo.size,
                            imageSize: imgSize,
                            scale: lock.scale
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Filmstrip Video Canvas View

struct FilmstripVideoCanvasView: View {
    let url: URL
    let item: MediaItem
    let session: CullingSession

    @State private var player: AVPlayer?
    @State private var swipeTranslation: CGFloat = 0.0
    @State private var pinchScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            let threshold = CullingLayoutCalculator.swipeNavigationThreshold(for: geo.size.width)
            let isSwipeCullingActive = session.isSwipeModeEnabled
            let isSwipeNavActive = !session.isSwipeModeEnabled
            let isAtLeading = !session.canSelectPreviousItem
            let isAtTrailing = !session.canSelectNextItem

            ZStack {
                Group {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .scaleEffect(min(1.0, max(0.75, pinchScale)))
                .offset(x: (isSwipeCullingActive || isSwipeNavActive) ? swipeTranslation : 0)
                .rotationEffect(
                    Angle.degrees(
                        isSwipeCullingActive
                            ? Double(min(12.0, max(-12.0, swipeTranslation / 25.0)))
                            : 0
                    )
                )

                if isSwipeCullingActive {
                    if swipeTranslation > 20 {
                        let progress = min(1.0, (swipeTranslation - 20) / max(1.0, threshold - 20))
                        SwipeActionBadgeView(action: session.swipeRightAction, direction: .right)
                            .opacity(Double(progress))
                            .scaleEffect(0.85 + 0.15 * progress)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else if swipeTranslation < -20 {
                        let progress = min(1.0, (-swipeTranslation - 20) / max(1.0, threshold - 20))
                        SwipeActionBadgeView(action: session.swipeLeftAction, direction: .left)
                            .opacity(Double(progress))
                            .scaleEffect(0.85 + 0.15 * progress)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        pinchScale = value.magnification
                        if swipeTranslation != 0 {
                            swipeTranslation = 0
                        }
                    }
                    .onEnded { value in
                        if CullingLayoutCalculator.shouldCommitPinchToGrid(currentZoom: 1.0, magnification: value.magnification) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                session.setViewMode(.grid)
                            }
                            pinchScale = 1.0
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                pinchScale = 1.0
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        if isSwipeCullingActive {
                            swipeTranslation = value.translation.width
                        } else if isSwipeNavActive && pinchScale == 1.0 {
                            swipeTranslation = CullingLayoutCalculator.swipeNavigationTranslation(
                                offset: value.translation.width,
                                isAtLeadingBoundary: isAtLeading,
                                isAtTrailingBoundary: isAtTrailing
                            )
                        }
                    }
                    .onEnded { value in
                        if isSwipeCullingActive {
                            if value.translation.width >= threshold {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeTranslation = geo.size.width + 100
                                } completion: {
                                    swipeTranslation = 0
                                }
                                session.executeSwipe(.right, for: item)
                            } else if value.translation.width <= -threshold {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeTranslation = -geo.size.width - 100
                                } completion: {
                                    swipeTranslation = 0
                                }
                                session.executeSwipe(.left, for: item)
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    swipeTranslation = 0
                                }
                            }
                        } else if isSwipeNavActive && pinchScale == 1.0 {
                            // SwipeNavigation: Dragging left -> Next, Dragging right -> Previous
                            if value.translation.width <= -threshold && session.canSelectNextItem {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeTranslation = -geo.size.width
                                } completion: {
                                    swipeTranslation = 0
                                    session.selectNextItem()
                                }
                            } else if value.translation.width >= threshold && session.canSelectPreviousItem {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    swipeTranslation = geo.size.width
                                } completion: {
                                    swipeTranslation = 0
                                    session.selectPreviousItem()
                                }
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    swipeTranslation = 0
                                }
                            }
                        }
                    }
            )
            .onAppear {
                player = AVPlayer(url: url)
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }
}

// MARK: - Filmstrip Thumbnail Cell

struct FilmstripThumbnailCell: View, Equatable {
    let item: MediaItem
    let curation: CurationMetadata
    let syncState: SyncState
    let isSelected: Bool
    var dockPosition: FilmstripDockPosition = .bottom
    var previewSource: PreviewSource = .preferRaster
    var cacheGeneration: Int = 0
    var cachedThumbnail: CGImage? = nil
    var aspectRatio: CGFloat? = nil
    var onSelect: (() -> Void)? = nil
    var loadThumbnail: (() async -> CGImage?)? = nil
    var onThumbnailLoaded: ((CGImage) -> Void)? = nil
    var hydrateMetadata: (() async -> Void)? = nil

    @State private var thumbnail: CGImage?

    var thumbnailTaskKey: String {
        "\(item.id)-\(previewSource.rawValue)-\(cacheGeneration)"
    }

    private var displayedImage: CGImage? {
        thumbnail ?? cachedThumbnail
    }

    private var thumbnailSize: CGSize {
        CullingLayoutCalculator.filmstripThumbnailSize(
            aspectRatio: aspectRatio,
            displayedThumbnail: displayedImage,
            dockPosition: dockPosition,
            mediaKind: item.kind
        )
    }

    private var neutralMattingColor: Color {
        #if canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.secondary.opacity(0.15)
        #endif
    }

    var body: some View {
        let size = thumbnailSize
        let isCompact = size.width < 70

        Button(action: {
            onSelect?()
        }) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(neutralMattingColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )

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
                        // Top row: format and sync badges with 3pt spacing and corner offsets
                        HStack(spacing: 3) {
                            if item.isMediaPair {
                                Text("RAW+JPG")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.8), in: Capsule())
                                    .foregroundStyle(.yellow)
                            } else if item.kind == .video {
                                Image(systemName: "video.fill")
                                    .font(.caption2)
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
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            case .conflicted:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            case .loading:
                                ProgressView()
                                    .controlSize(.mini)
                            case .syncError:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.top, 3)
                        .padding(.horizontal, (curation.colorLabel != .none) ? 8 : 3)

                        Spacer()

                        // Bottom row: star rating pill and pick flag circle with compact adjustments
                        HStack(spacing: isCompact ? 1 : 2) {
                            if curation.starRating > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                    Text("\(curation.starRating.value)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, isCompact ? 2.5 : 4)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.8), in: Capsule())
                            }

                            Spacer()

                            switch curation.pickFlag {
                            case .picked:
                                Image(systemName: "flag.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                    .padding(isCompact ? 2 : 3)
                                    .background(.black.opacity(0.8), in: Circle())
                            case .rejected:
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.red)
                                    .padding(isCompact ? 2 : 3)
                                    .background(.black.opacity(0.8), in: Circle())
                            case .unflagged:
                                EmptyView()
                            }
                        }
                        .padding(.bottom, 3)
                        .padding(.horizontal, (curation.colorLabel != .none) ? (isCompact ? 8 : 9) : (isCompact ? 3 : 4))
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )

                Text(item.baseName)
                    .font(.caption.weight(isSelected ? .bold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .frame(width: max(size.width, 64))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.baseName), \(curation.starRating.value) stars, \(curation.pickFlag.rawValue), sync: \(syncState.rawValue)")
        .task(id: thumbnailTaskKey) {
            guard let loadThumbnail else { return }
            if let decoded = await loadThumbnail() {
                if !Task.isCancelled {
                    thumbnail = decoded
                    onThumbnailLoaded?(decoded)
                }
            } else {
                if !Task.isCancelled {
                    thumbnail = nil
                }
            }
        }
        .task(id: syncState == .loading) {
            if syncState == .loading {
                await hydrateMetadata?()
            }
        }
    }
}

extension FilmstripThumbnailCell {
    static func == (lhs: FilmstripThumbnailCell, rhs: FilmstripThumbnailCell) -> Bool {
        lhs.item == rhs.item &&
        lhs.curation == rhs.curation &&
        lhs.syncState == rhs.syncState &&
        lhs.isSelected == rhs.isSelected &&
        lhs.dockPosition == rhs.dockPosition &&
        lhs.previewSource == rhs.previewSource &&
        lhs.cacheGeneration == rhs.cacheGeneration &&
        lhs.aspectRatio == rhs.aspectRatio &&
        lhs.cachedThumbnail === rhs.cachedThumbnail
    }
}
