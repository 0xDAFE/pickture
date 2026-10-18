import AVKit
import CoreGraphics
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct FilmstripView: View {
    let session: CullingSession
    var targetGridCellRect: CGRect? = nil
    var isHeroTransitionActive: Binding<Bool>? = nil

    @State private var pageDragOffset: CGFloat = 0.0
    @State private var mainCanvasSize: CGSize = CGSize(width: 1000.0, height: 800.0)
    @State private var canvasWorkspaceRect: CGRect = .zero
    @State private var heroMetrics: HeroGridTransitionMetrics = .inactive
    @State private var committedHeroScale: CGFloat = 1.0
    @State private var committedHeroOffset: CGSize = .zero
    @State private var isCommittingToGrid: Bool = false
    @State private var isExpandingFromGrid: Bool = false
    @State private var hasTriggeredInitialExpand: Bool = false

    private var effectiveChromeOpacity: Double {
        if isCommittingToGrid || isExpandingFromGrid {
            return 0.0
        }
        return heroMetrics.chromeOpacity
    }

    private var effectiveBackdropOpacity: Double {
        if isCommittingToGrid || isExpandingFromGrid {
            return 0.0
        }
        return heroMetrics.backdropOpacity
    }

    private var effectiveHeroScale: CGFloat {
        if isCommittingToGrid || isExpandingFromGrid {
            return committedHeroScale
        }
        return heroMetrics.interactiveScale
    }

    private var effectiveHeroOffset: CGSize {
        if isCommittingToGrid || isExpandingFromGrid {
            return committedHeroOffset
        }
        return heroMetrics.interactiveOffset
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.conflictedItemsCount > 0 {
                conflictAlertBanner
                    .opacity(effectiveChromeOpacity)
                Divider()
                    .opacity(effectiveChromeOpacity)
            }

            switch session.filmstripDockPosition {
            case .bottom:
                VStack(spacing: 0) {
                    mainCanvasArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .opacity(effectiveChromeOpacity)

                    FilmstripScrubber(
                        session: session,
                        dockPosition: .bottom,
                        pageDragOffset: pageDragOffset,
                        mainCanvasWidth: mainCanvasSize.width
                    )
                    .frame(height: CullingLayoutCalculator.scrubberDockSpan(for: .bottom))
                    .background(.bar)
                    .opacity(effectiveChromeOpacity)
                }
            case .right:
                HStack(spacing: 0) {
                    mainCanvasArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .opacity(effectiveChromeOpacity)

                    FilmstripScrubber(
                        session: session,
                        dockPosition: .right,
                        pageDragOffset: pageDragOffset,
                        mainCanvasWidth: mainCanvasSize.width
                    )
                    .frame(width: CullingLayoutCalculator.scrubberDockSpan(for: .right))
                    .background(.bar)
                    .opacity(effectiveChromeOpacity)
                }
            }
        }
        .onChange(of: session.selectedItemID) { _, _ in
            if pageDragOffset != 0 {
                pageDragOffset = 0
            }
        }
    }

    // MARK: - Main Canvas Area

    @ViewBuilder
    private var mainCanvasArea: some View {
        if let currentItem = session.selectedItem {
            GeometryReader { geo in
                let zoneWidth = CullingLayoutCalculator.borderTapZoneWidth(for: geo.size.width)
                let neighbors = session.adjacentItems(for: currentItem.id)
                let hudItem = session.displayedHUDItem(pageDragOffset: pageDragOffset, containerWidth: geo.size.width) ?? currentItem
                let pageStride = max(1.0, geo.size.width + CullingLayoutCalculator.filmstripInterPageGutter)
                let workspaceFrame = geo.frame(in: .named(CullingLayoutCalculator.workspaceCoordinateSpaceName))

                ZStack {
                    Color.black.opacity(effectiveBackdropOpacity)
                        .ignoresSafeArea()

                    // 3-Page Live Carousel (previous, current, next) separated by 16pt black gutter
                    ZStack {
                        if !session.isSwipeModeEnabled || pageDragOffset != 0 {
                            if let previousItem = neighbors.previous {
                                carouselPageView(
                                    for: previousItem,
                                    isCurrentPage: false,
                                    containerSize: geo.size,
                                    workspaceFrame: workspaceFrame,
                                    neighbors: neighbors
                                )
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .offset(x: -pageStride + pageDragOffset)
                            }

                            if let nextItem = neighbors.next {
                                carouselPageView(
                                    for: nextItem,
                                    isCurrentPage: false,
                                    containerSize: geo.size,
                                    workspaceFrame: workspaceFrame,
                                    neighbors: neighbors
                                )
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .offset(x: pageStride + pageDragOffset)
                            }
                        }

                        carouselPageView(
                            for: currentItem,
                            isCurrentPage: true,
                            containerSize: geo.size,
                            workspaceFrame: workspaceFrame,
                            neighbors: neighbors
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(effectiveHeroScale)
                        .offset(
                            x: pageDragOffset + effectiveHeroOffset.width,
                            y: effectiveHeroOffset.height
                        )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                    // BorderTapNavigation visual affordance (non-hit-testing so drags & pinches are never swallowed)
                    if session.isBorderTapNavigationEnabled {
                        HStack {
                            Image(systemName: "chevron.left")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.25))
                                .padding(.leading, 8)
                                .frame(width: zoneWidth, alignment: .leading)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.25))
                                .padding(.trailing, 8)
                                .frame(width: zoneWidth, alignment: .trailing)
                        }
                        .allowsHitTesting(false)
                        .opacity(effectiveChromeOpacity)
                    }

                    // Stationary Top & Bottom HUD overlays
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hudItem.displayFileName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                if !hudItem.relativeDirectoryPath.isEmpty {
                                    Text(hudItem.relativeDirectoryPath)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))

                            Spacer()

                            if hudItem.isMediaPair || hudItem.hasRAWFile {
                                FilmstripRepresentationControls(item: hudItem, session: session)
                            }
                        }
                        .padding(12)

                        Spacer()

                        floatingCurationBar(for: hudItem)
                            .padding(.bottom, 12)
                    }
                    .opacity(effectiveChromeOpacity)
                }
                .accessibilityAction(named: "Previous MediaItem") {
                    if session.isBorderTapNavigationEnabled {
                        performInstantBorderCut(to: .previous)
                    }
                }
                .accessibilityAction(named: "Next MediaItem") {
                    if session.isBorderTapNavigationEnabled {
                        performInstantBorderCut(to: .next)
                    }
                }
                .onAppear {
                    mainCanvasSize = geo.size
                    canvasWorkspaceRect = workspaceFrame
                    triggerExpandFromGridIfNeeded(workspaceFrame: workspaceFrame)
                }
                .onChange(of: geo.size) { _, newSize in
                    mainCanvasSize = newSize
                }
                .onChange(of: workspaceFrame) { _, newFrame in
                    canvasWorkspaceRect = newFrame
                    triggerExpandFromGridIfNeeded(workspaceFrame: newFrame)
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

    @ViewBuilder
    private func carouselPageView(
        for pageItem: MediaItem,
        isCurrentPage: Bool,
        containerSize: CGSize,
        workspaceFrame: CGRect,
        neighbors: (previous: MediaItem?, current: MediaItem?, next: MediaItem?)
    ) -> some View {
        if pageItem.kind == .video {
            FilmstripVideoCanvasView(
                url: pageItem.primaryFile.url,
                item: pageItem,
                session: session,
                isCurrentPage: isCurrentPage,
                isExternalGestureActive: !isCurrentPage || pageDragOffset != 0 || heroMetrics.isActive || isCommittingToGrid,
                pageDragOffset: isCurrentPage ? $pageDragOffset : .constant(0),
                onCommitPageTurn: { direction in
                    commitCarouselPageTurn(direction, containerWidth: containerSize.width, neighbors: neighbors)
                },
                onInstantBorderTap: { location in
                    handleInstantBorderTap(at: location, in: containerSize)
                },
                onHeroGestureChanged: { rawScale, translation, predictedEnd in
                    updateHeroGesture(
                        rawScale: rawScale,
                        translation: translation,
                        predictedEnd: predictedEnd,
                        workspaceFrame: workspaceFrame
                    )
                },
                onHeroGestureEnded: {
                    finishHeroGesture(for: pageItem, workspaceFrame: workspaceFrame)
                }
            )
            .id(pageItem.id)
        } else {
            FilmstripImageCanvasView(
                item: pageItem,
                session: session,
                isCurrentPage: isCurrentPage,
                pageDragOffset: isCurrentPage ? $pageDragOffset : .constant(0),
                onCommitPageTurn: { direction in
                    commitCarouselPageTurn(direction, containerWidth: containerSize.width, neighbors: neighbors)
                },
                onInstantBorderTap: { location in
                    handleInstantBorderTap(at: location, in: containerSize)
                },
                onHeroGestureChanged: { rawScale, translation, predictedEnd in
                    updateHeroGesture(
                        rawScale: rawScale,
                        translation: translation,
                        predictedEnd: predictedEnd,
                        workspaceFrame: workspaceFrame
                    )
                },
                onHeroGestureEnded: {
                    finishHeroGesture(for: pageItem, workspaceFrame: workspaceFrame)
                }
            )
            .id("\(pageItem.id)-\(session.previewSource.rawValue)")
        }
    }

    private func handleInstantBorderTap(at location: CGPoint, in containerSize: CGSize) -> Bool {
        guard session.isBorderTapNavigationEnabled,
              let direction = CullingLayoutCalculator.borderTapDirection(at: location, in: containerSize) else {
            return false
        }
        performInstantBorderCut(to: direction)
        return true
    }

    private func performInstantBorderCut(to direction: BorderTapDirection) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageDragOffset = 0
            switch direction {
            case .previous:
                session.selectPreviousItem()
            case .next:
                session.selectNextItem()
            }
        }
    }

    private func commitCarouselPageTurn(
        _ direction: BorderTapDirection?,
        containerWidth: CGFloat,
        neighbors: (previous: MediaItem?, current: MediaItem?, next: MediaItem?)
    ) {
        let pageStride = max(1.0, containerWidth + CullingLayoutCalculator.filmstripInterPageGutter)
        switch direction {
        case .previous:
            guard let prev = neighbors.previous else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    pageDragOffset = 0
                }
                return
            }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                pageDragOffset = pageStride
            } completion: {
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) {
                    session.selectedItemID = prev.id
                    pageDragOffset = 0
                }
            }

        case .next:
            guard let next = neighbors.next else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    pageDragOffset = 0
                }
                return
            }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                pageDragOffset = -pageStride
            } completion: {
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) {
                    session.selectedItemID = next.id
                    pageDragOffset = 0
                }
            }

        case nil:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                pageDragOffset = 0
            }
        }
    }

    private func updateHeroGesture(
        rawScale: CGFloat,
        translation: CGSize,
        predictedEnd: CGSize,
        workspaceFrame: CGRect
    ) {
        let metrics = CullingLayoutCalculator.resolveHeroGridTransition(
            rawScale: rawScale,
            dragTranslation: translation,
            predictedEndTranslation: predictedEnd,
            canvasRect: workspaceFrame,
            targetGridCellRect: targetGridCellRect,
            isVerticalPullAllowed: session.isVerticalPullToGridAllowed
        )
        heroMetrics = metrics
        isHeroTransitionActive?.wrappedValue = metrics.isActive
    }

    private func finishHeroGesture(for item: MediaItem, workspaceFrame: CGRect) {
        guard heroMetrics.isActive else {
            isHeroTransitionActive?.wrappedValue = false
            return
        }

        if heroMetrics.shouldCommit {
            isCommittingToGrid = true
            isHeroTransitionActive?.wrappedValue = true

            let targetTransform = computeTargetGridTransform(for: item, workspaceFrame: workspaceFrame)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                committedHeroScale = targetTransform.scale
                committedHeroOffset = targetTransform.offset
            } completion: {
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) {
                    session.setViewMode(.grid)
                    isCommittingToGrid = false
                    heroMetrics = .inactive
                    committedHeroScale = 1.0
                    committedHeroOffset = .zero
                    isHeroTransitionActive?.wrappedValue = false
                }
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                heroMetrics = .inactive
            } completion: {
                isHeroTransitionActive?.wrappedValue = false
            }
        }
    }

    private func triggerExpandFromGridIfNeeded(workspaceFrame: CGRect) {
        guard !hasTriggeredInitialExpand,
              let item = session.selectedItem,
              let cellRect = targetGridCellRect,
              cellRect.width > 0, cellRect.height > 0,
              workspaceFrame.width > 0, workspaceFrame.height > 0 else {
            return
        }
        hasTriggeredInitialExpand = true
        let startTransform = computeTargetGridTransform(for: item, workspaceFrame: workspaceFrame)
        var tx = Transaction(animation: nil)
        tx.disablesAnimations = true
        withTransaction(tx) {
            isExpandingFromGrid = true
            isHeroTransitionActive?.wrappedValue = true
            committedHeroScale = startTransform.scale
            committedHeroOffset = startTransform.offset
        }

        Task { @MainActor in
            await Task.yield()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isExpandingFromGrid = false
                committedHeroScale = 1.0
                committedHeroOffset = .zero
            } completion: {
                isHeroTransitionActive?.wrappedValue = false
            }
        }
    }

    private func computeTargetGridTransform(for item: MediaItem, workspaceFrame: CGRect) -> (scale: CGFloat, offset: CGSize) {
        guard let targetRect = targetGridCellRect,
              targetRect.width > 0, targetRect.height > 0,
              workspaceFrame.width > 0, workspaceFrame.height > 0 else {
            return (scale: 0.25, offset: heroMetrics.interactiveOffset)
        }
        let ratio = session.thumbnailAspectRatio(for: item)
        let fitted = CullingLayoutCalculator.fittedImageSize(
            aspectRatio: ratio,
            in: workspaceFrame.size,
            mediaKind: item.kind
        )
        let scaleX = targetRect.width / max(1.0, fitted.width)
        let scaleY = targetRect.height / max(1.0, fitted.height)
        let targetScale = max(0.08, min(1.0, min(scaleX, scaleY)))
        let offset = CGSize(
            width: targetRect.midX - workspaceFrame.midX,
            height: targetRect.midY - workspaceFrame.midY
        )
        return (scale: targetScale, offset: offset)
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

// MARK: - Centered-Playhead FilmstripScrubber

struct FilmstripScrubber: View {
    let session: CullingSession
    let dockPosition: FilmstripDockPosition
    var pageDragOffset: CGFloat = 0.0
    var mainCanvasWidth: CGFloat = 1000.0

    @State private var scrubbedItemID: String?
    @State private var isProgrammaticJump: Bool = false
    @State private var isUserScrolling: Bool = false
    @State private var macDragAnchorIndex: Int? = nil

    private var effectiveSelectedItemID: String? {
        isUserScrolling ? (scrubbedItemID ?? session.selectedItemID) : session.selectedItemID
    }

    private var scrollPositionBinding: Binding<String?> {
        Binding(
            get: {
                effectiveSelectedItemID
            },
            set: { newID in
                scrubbedItemID = newID
                guard isUserScrolling, !isProgrammaticJump else { return }
                guard let newID, newID != session.selectedItemID else { return }
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) {
                    session.selectedItemID = newID
                }
                ScrubberHaptics.fireSelectionChanged()
            }
        )
    }

    var body: some View {
        GeometryReader { geo in
            let isHorizontal = dockPosition == .bottom
            let axis: Axis.Set = isHorizontal ? .horizontal : .vertical
            let scrubberSpan = isHorizontal ? geo.size.width : geo.size.height
            let activeTileRawSize: CGSize = {
                if let selected = session.selectedItem {
                    return session.filmstripThumbnailSize(for: selected, dockPosition: dockPosition)
                }
                return CullingLayoutCalculator.filmstripThumbnailSize(aspectRatio: 1.5, dockPosition: dockPosition)
            }()
            let activeTileSpan = isHorizontal ? activeTileRawSize.width : activeTileRawSize.height
            let inactiveTileRawSize = CullingLayoutCalculator.scrubberInactiveTileSize(for: dockPosition)
            let inactiveTileSpan = isHorizontal ? inactiveTileRawSize.width : inactiveTileRawSize.height
            let referenceSlotSpan = inactiveTileSpan + CullingLayoutCalculator.scrubberActiveTileBreathingMargin * 2.0
            let halfViewportInset = CullingLayoutCalculator.scrubberHalfViewportInset(
                scrubberSpan: scrubberSpan,
                activeTileSpan: referenceSlotSpan
            )
            let pageStride = max(1.0, mainCanvasWidth + CullingLayoutCalculator.filmstripInterPageGutter)
            let liveSwipeOffset = CullingLayoutCalculator.scrubberDragInterpolationOffset(
                pageDragOffset: pageDragOffset,
                pageStride: pageStride,
                activeTileSpan: activeTileSpan,
                dockPosition: dockPosition
            )

            ScrollViewReader { proxy in
                ScrollView(axis) {
                    if isHorizontal {
                        LazyHStack(spacing: CullingLayoutCalculator.scrubberInterTileSpacing) {
                            ForEach(session.visibleItems) { item in
                                scrubberCell(for: item, proxy: proxy)
                            }
                        }
                        .scrollTargetLayout()
                        .offset(x: liveSwipeOffset)
                    } else {
                        LazyVStack(spacing: CullingLayoutCalculator.scrubberInterTileSpacing) {
                            ForEach(session.visibleItems) { item in
                                scrubberCell(for: item, proxy: proxy)
                            }
                        }
                        .scrollTargetLayout()
                        .offset(y: liveSwipeOffset)
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
                .contentMargins(isHorizontal ? .horizontal : .vertical, halfViewportInset, for: .scrollContent)
                .scrollPosition(id: scrollPositionBinding, anchor: .center)
                .scrollIndicators(.hidden)
                .modifier(
                    ScrubberScrollPhaseAndVelocityModifier(
                        isHorizontal: isHorizontal,
                        onScrollStateChanged: { isScrolling, velocity in
                            isUserScrolling = isScrolling
                            if !isScrolling {
                                isProgrammaticJump = false
                            }
                            session.updateScrubState(
                                isScrubbing: isScrolling,
                                velocityPointsPerSecond: velocity
                            )
                        }
                    )
                )
                #if os(macOS)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            handleMacClickAndDragScrub(value: value, isHorizontal: isHorizontal, proxy: proxy)
                        }
                        .onEnded { _ in
                            macDragAnchorIndex = nil
                            session.updateScrubState(isScrubbing: false, velocityPointsPerSecond: 0)
                        }
                )
                #endif
                .onAppear {
                    scrubbedItemID = session.selectedItemID
                    if let selectedID = session.selectedItemID {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
                .onChange(of: session.selectedItemID) { _, newID in
                    guard let newID else { return }
                    scrubbedItemID = newID
                    guard !isUserScrolling, !isProgrammaticJump else { return }
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func scrubberCell(for item: MediaItem, proxy: ScrollViewProxy) -> some View {
        let isSelected = effectiveSelectedItemID == item.id
        return FilmstripThumbnailCell(
            item: item,
            curation: session.curationMetadata(for: item),
            syncState: session.syncState(for: item),
            isSelected: isSelected,
            dockPosition: dockPosition,
            previewSource: session.previewSource,
            cacheGeneration: session.cacheGeneration,
            cachedThumbnail: session.inMemoryThumbnailImage(for: item, maxPixelSize: 360),
            aspectRatio: isSelected ? session.thumbnailAspectRatio(for: item) : nil,
            onSelect: {
                guard session.selectedItemID != item.id else { return }
                isProgrammaticJump = true
                session.updateScrubState(isScrubbing: false, velocityPointsPerSecond: 0)
                // Direct cut on the main viewport without flashing intermediate photos
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) {
                    scrubbedItemID = item.id
                    session.selectedItemID = item.id
                }
                // Smoothly scroll the scrubber ribbon to center the tapped tile
                withAnimation(.snappy(duration: 0.22)) {
                    proxy.scrollTo(item.id, anchor: .center)
                } completion: {
                    isProgrammaticJump = false
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
        .padding(
            dockPosition == .bottom ? .horizontal : .vertical,
            isSelected ? CullingLayoutCalculator.scrubberActiveTileBreathingMargin : 0.0
        )
        .zIndex(isSelected ? 1 : 0)
        .id(item.id)
    }

    #if os(macOS)
    private func handleMacClickAndDragScrub(
        value: DragGesture.Value,
        isHorizontal: Bool,
        proxy: ScrollViewProxy
    ) {
        let visible = session.visibleItems
        guard !visible.isEmpty else { return }
        if macDragAnchorIndex == nil {
            if let currentID = session.selectedItemID,
               let idx = session.cullingSequence.index(for: currentID) {
                macDragAnchorIndex = idx
            } else {
                macDragAnchorIndex = 0
            }
        }
        guard let anchorIndex = macDragAnchorIndex else { return }
        let delta = isHorizontal ? -value.translation.width : -value.translation.height
        let predictedDelta = isHorizontal ? -value.predictedEndTranslation.width : -value.predictedEndTranslation.height
        let velocityEstimate = abs(predictedDelta - delta) * 8.0
        session.updateScrubState(isScrubbing: true, velocityPointsPerSecond: velocityEstimate)

        let stepSpan: CGFloat = 32.0
        let indexDelta = Int((delta / stepSpan).rounded())
        let targetIndex = min(visible.count - 1, max(0, anchorIndex + indexDelta))
        let targetID = visible[targetIndex].id
        if session.selectedItemID != targetID {
            var tx = Transaction(animation: nil)
            tx.disablesAnimations = true
            withTransaction(tx) {
                session.selectedItemID = targetID
                scrubbedItemID = targetID
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }
    #endif
}

@MainActor
private final class ScrollVelocityTracker {
    var lastTime: TimeInterval = 0.0
    var currentVelocity: CGFloat = 0.0
    var isCurrentlyScrolling: Bool = false
    var isHighVelocity: Bool = false
}

private struct ScrubberScrollPhaseAndVelocityModifier: ViewModifier {
    let isHorizontal: Bool
    let onScrollStateChanged: (Bool, CGFloat) -> Void

    @State private var tracker = ScrollVelocityTracker()

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    isHorizontal ? geo.contentOffset.x : geo.contentOffset.y
                } action: { oldOffset, newOffset in
                    let now = ProcessInfo.processInfo.systemUptime
                    let dt = now - tracker.lastTime
                    tracker.lastTime = now
                    guard dt > 0.002 && dt < 0.5 else { return }
                    let v = abs(newOffset - oldOffset) / CGFloat(dt)
                    tracker.currentVelocity = v
                    guard tracker.isCurrentlyScrolling else { return }
                    let highVelocity = v >= CullingSession.highVelocityScrubThresholdPointsPerSecond
                    if highVelocity != tracker.isHighVelocity {
                        tracker.isHighVelocity = highVelocity
                        onScrollStateChanged(true, v)
                    }
                }
                .onScrollPhaseChange { _, newPhase in
                    let scrolling = (newPhase == .interacting || newPhase == .decelerating)
                    tracker.isCurrentlyScrolling = scrolling
                    if !scrolling {
                        tracker.currentVelocity = 0.0
                        tracker.isHighVelocity = false
                    }
                    onScrollStateChanged(scrolling, scrolling ? tracker.currentVelocity : 0.0)
                }
        } else {
            content
                .scrollTargetBehavior(.viewAligned)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            let delta = isHorizontal ? value.translation.width : value.translation.height
                            let predicted = isHorizontal ? value.predictedEndTranslation.width : value.predictedEndTranslation.height
                            let velocity = abs(predicted - delta) * 8.0
                            let highVelocity = velocity >= CullingSession.highVelocityScrubThresholdPointsPerSecond
                            if !tracker.isCurrentlyScrolling || highVelocity != tracker.isHighVelocity {
                                tracker.isCurrentlyScrolling = true
                                tracker.isHighVelocity = highVelocity
                                onScrollStateChanged(true, velocity)
                            }
                        }
                        .onEnded { _ in
                            tracker.isCurrentlyScrolling = false
                            tracker.isHighVelocity = false
                            onScrollStateChanged(false, 0.0)
                        }
                )
        }
    }
}

@MainActor
private enum ScrubberHaptics {
    #if canImport(UIKit) && !os(visionOS)
    private static let generator = UISelectionFeedbackGenerator()
    #endif

    static func fireSelectionChanged() {
        #if canImport(UIKit) && !os(visionOS)
        generator.selectionChanged()
        #endif
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

// MARK: - Shared Swipe Curation Overlay & Gesture Completion

private struct SwipeCurationOverlayView: View {
    let session: CullingSession
    let swipeTranslation: CGFloat
    let threshold: CGFloat

    var body: some View {
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

@MainActor
private func completeSwipeCurationGesture(
    translationWidth: CGFloat,
    threshold: CGFloat,
    containerWidth: CGFloat,
    item: MediaItem,
    session: CullingSession,
    swipeTranslation: Binding<CGFloat>
) {
    if translationWidth >= threshold {
        withAnimation(.easeOut(duration: 0.2)) {
            swipeTranslation.wrappedValue = containerWidth + 100
        } completion: {
            swipeTranslation.wrappedValue = 0
        }
        session.executeSwipe(.right, for: item)
    } else if translationWidth <= -threshold {
        withAnimation(.easeOut(duration: 0.2)) {
            swipeTranslation.wrappedValue = -containerWidth - 100
        } completion: {
            swipeTranslation.wrappedValue = 0
        }
        session.executeSwipe(.left, for: item)
    } else {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            swipeTranslation.wrappedValue = 0
        }
    }
}

// MARK: - Active Drag Gesture Mode

private enum CanvasDragMode {
    case undecided
    case zoomedPanAndHandoff
    case verticalPullToGrid
    case swipeCuration
    case horizontalPaging
}

// MARK: - Filmstrip Image Canvas View

struct FilmstripImageCanvasView: View {
    let item: MediaItem
    let session: CullingSession
    var isCurrentPage: Bool = true
    var pageDragOffset: Binding<CGFloat> = .constant(0)
    var onCommitPageTurn: ((BorderTapDirection?) -> Void)? = nil
    var onInstantBorderTap: ((CGPoint) -> Bool)? = nil
    var onHeroGestureChanged: ((CGFloat, CGSize, CGSize) -> Void)? = nil
    var onHeroGestureEnded: (() -> Void)? = nil

    @State private var previewImage: CGImage?
    @State private var zoomScale: CGFloat = 1.0
    @State private var pinchScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var liveClampedPanOffset: CGSize? = nil
    @State private var swipeTranslation: CGFloat = 0.0
    @State private var activeDragMode: CanvasDragMode = .undecided
    @State private var isLoading = false

    private var rawCombinedScale: CGFloat {
        zoomScale * pinchScale
    }

    private var effectiveScale: CGFloat {
        min(4.0, max(1.0, rawCombinedScale))
    }

    private var effectivePanOffset: CGSize {
        liveClampedPanOffset ?? panOffset
    }

    private var displayedImage: CGImage? {
        if (session.previewSource == .preferRAW || !item.isMediaPair),
           session.isFullRAWLoaded(for: item),
           let fullRaw = session.inMemoryFullRAWImage(for: item) {
            return fullRaw
        }
        if let preview = previewImage ?? session.inMemoryPreviewImage(for: item, maxPixelSize: 2048) {
            return preview
        }
        return session.inMemoryThumbnailImage(for: item, maxPixelSize: 360)
    }

    private var resolvedAspectRatio: CGFloat {
        CullingLayoutCalculator.resolveAspectRatio(
            aspectRatio: session.thumbnailAspectRatio(for: item),
            displayedThumbnail: displayedImage,
            mediaKind: item.kind
        )
    }

    var body: some View {
        GeometryReader { geo in
            let threshold = min(max(80.0, geo.size.width * 0.22), 140.0)
            let isSwipeActive = session.isSwipeModeEnabled && effectiveScale <= 1.0 && isCurrentPage
            let fittedSize = CullingLayoutCalculator.fittedImageSize(
                aspectRatio: resolvedAspectRatio,
                in: geo.size,
                mediaKind: item.kind
            )
            let neighbors = session.adjacentItems(for: item.id)

            ZStack {
                Color.clear

                if let cgImage = displayedImage {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(effectiveScale)
                        .offset(
                            x: effectivePanOffset.width + (isSwipeActive ? swipeTranslation : 0),
                            y: effectivePanOffset.height
                        )
                        .rotationEffect(
                            Angle.degrees(
                                isSwipeActive
                                    ? Double(min(12.0, max(-12.0, swipeTranslation / 25.0)))
                                    : 0
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                }

                // Overlay action badge when swiping horizontally at 1.0x zoom in SwipeMode
                if isSwipeActive {
                    SwipeCurationOverlayView(
                        session: session,
                        swipeTranslation: swipeTranslation,
                        threshold: threshold
                    )
                }
            }
            .contentShape(Rectangle())
            // Point-anchored double-tap zoom (1.0x <-> 2.5x) outside active border tap zones
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        guard isCurrentPage else { return }
                        if session.isBorderTapNavigationEnabled,
                           CullingLayoutCalculator.borderTapDirection(at: value.location, in: geo.size) != nil {
                            resetZoomState(animated: false)
                            _ = onInstantBorderTap?(value.location) ?? session.handleBorderTap(at: value.location, in: geo.size)
                            return
                        }
                        let result = CullingLayoutCalculator.resolveDoubleTapZoom(
                            currentScale: zoomScale,
                            tapLocation: value.location,
                            containerSize: geo.size,
                            fittedSize: fittedSize
                        )
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            zoomScale = result.scale
                            panOffset = result.panOffset
                            liveClampedPanOffset = nil
                        }
                    }
            )
            // Stationary single-tap BorderTapNavigation (instant 0ms cut, resets zoom to 1.0x)
            .simultaneousGesture(
                SpatialTapGesture(count: 1)
                    .onEnded { value in
                        guard isCurrentPage, session.isBorderTapNavigationEnabled else { return }
                        guard CullingLayoutCalculator.borderTapDirection(at: value.location, in: geo.size) != nil else {
                            return
                        }
                        resetZoomState(animated: false)
                        if let onInstantBorderTap {
                            _ = onInstantBorderTap(value.location)
                        } else {
                            _ = session.handleBorderTap(at: value.location, in: geo.size)
                        }
                    }
            )
            // Pinch-to-zoom (1.0x - 4.0x) AND continuous pinch-out (< 1.0x) to Grid
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard isCurrentPage else { return }
                        pinchScale = value.magnification
                        if swipeTranslation != 0 {
                            swipeTranslation = 0
                        }
                        let combined = zoomScale * value.magnification
                        if combined < 1.0 {
                            liveClampedPanOffset = .zero
                            onHeroGestureChanged?(combined, .zero, .zero)
                        } else {
                            onHeroGestureChanged?(1.0, .zero, .zero)
                            liveClampedPanOffset = CullingLayoutCalculator.clampPanOffset(
                                panOffset,
                                fittedSize: fittedSize,
                                scale: min(4.0, combined)
                            )
                        }
                    }
                    .onEnded { value in
                        guard isCurrentPage else { return }
                        let combined = zoomScale * value.magnification
                        if combined < 1.0 {
                            zoomScale = 1.0
                            pinchScale = 1.0
                            panOffset = .zero
                            liveClampedPanOffset = nil
                            onHeroGestureEnded?()
                        } else {
                            zoomScale = min(4.0, max(1.0, combined))
                            pinchScale = 1.0
                            if zoomScale <= 1.01 {
                                zoomScale = 1.0
                                panOffset = .zero
                                liveClampedPanOffset = nil
                            } else {
                                panOffset = CullingLayoutCalculator.clampPanOffset(
                                    panOffset,
                                    fittedSize: fittedSize,
                                    scale: zoomScale
                                )
                                liveClampedPanOffset = nil
                            }
                            onHeroGestureEnded?()
                        }
                    }
            )
            // Multiplexed 1-finger drag: Zoomed Pan + Edge-Pan Handoff | Vertical Pull-to-Grid | SwipeMode | 3-Page Carousel
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard isCurrentPage else { return }
                        if activeDragMode == .undecided {
                            if effectiveScale > 1.01 {
                                activeDragMode = .zoomedPanAndHandoff
                            } else if session.isVerticalPullToGridAllowed
                                        && value.translation.height > 12.0
                                        && value.translation.height > abs(value.translation.width) * 1.15 {
                                activeDragMode = .verticalPullToGrid
                            } else if session.isSwipeModeEnabled {
                                activeDragMode = .swipeCuration
                            } else {
                                activeDragMode = .horizontalPaging
                            }
                        }

                        switch activeDragMode {
                        case .zoomedPanAndHandoff:
                            let handoff = CullingLayoutCalculator.resolveZoomPanAndPageHandoff(
                                currentPanOffset: panOffset,
                                dragTranslation: value.translation,
                                fittedSize: fittedSize,
                                scale: effectiveScale,
                                hasPrevious: neighbors.previous != nil,
                                hasNext: neighbors.next != nil
                            )
                            liveClampedPanOffset = handoff.clampedPanOffset
                            pageDragOffset.wrappedValue = handoff.pageDragOffset

                        case .verticalPullToGrid:
                            onHeroGestureChanged?(1.0, value.translation, value.predictedEndTranslation)

                        case .swipeCuration:
                            swipeTranslation = value.translation.width

                        case .horizontalPaging:
                            pageDragOffset.wrappedValue = CullingLayoutCalculator.rubberBandedPageOffset(
                                value.translation.width,
                                hasPrevious: neighbors.previous != nil,
                                hasNext: neighbors.next != nil
                            )

                        case .undecided:
                            break
                        }
                    }
                    .onEnded { value in
                        guard isCurrentPage else { return }
                        let completedMode = activeDragMode
                        activeDragMode = .undecided

                        switch completedMode {
                        case .zoomedPanAndHandoff:
                            let handoff = CullingLayoutCalculator.resolveZoomPanAndPageHandoff(
                                currentPanOffset: panOffset,
                                dragTranslation: value.translation,
                                fittedSize: fittedSize,
                                scale: effectiveScale,
                                hasPrevious: neighbors.previous != nil,
                                hasNext: neighbors.next != nil
                            )
                            let velocityDeltaX = value.predictedEndTranslation.width - value.translation.width
                            let predictedOverflowX = handoff.pageDragOffset + velocityDeltaX
                            let committedDirection = CullingLayoutCalculator.shouldCommitPageTurn(
                                pageDragOffset: handoff.pageDragOffset,
                                predictedEndTranslationX: predictedOverflowX,
                                containerWidth: geo.size.width,
                                hasPrevious: neighbors.previous != nil,
                                hasNext: neighbors.next != nil
                            )
                            if let committedDirection {
                                // Page transition committed: reset outgoing item's zoom to 1.0x
                                resetZoomState(animated: true)
                                onCommitPageTurn?(committedDirection)
                            } else {
                                // Sprung back to current page: preserve zoom state and clamped pan
                                panOffset = handoff.clampedPanOffset
                                liveClampedPanOffset = nil
                                onCommitPageTurn?(nil)
                            }

                        case .verticalPullToGrid:
                            onHeroGestureEnded?()

                        case .swipeCuration:
                            completeSwipeCurationGesture(
                                translationWidth: value.translation.width,
                                threshold: threshold,
                                containerWidth: geo.size.width,
                                item: item,
                                session: session,
                                swipeTranslation: $swipeTranslation
                            )

                        case .horizontalPaging:
                            let committedDirection = CullingLayoutCalculator.shouldCommitPageTurn(
                                pageDragOffset: pageDragOffset.wrappedValue,
                                predictedEndTranslationX: value.predictedEndTranslation.width,
                                containerWidth: geo.size.width,
                                hasPrevious: neighbors.previous != nil,
                                hasNext: neighbors.next != nil
                            )
                            onCommitPageTurn?(committedDirection)

                        case .undecided:
                            break
                        }
                    }
            )
            .task(id: "\(item.id)-\(session.previewSource.rawValue)-\(session.cacheGeneration)-\(session.isHighVelocityScrubbing)") {
                if let inMemory = session.inMemoryPreviewImage(for: item, maxPixelSize: 2048) {
                    previewImage = inMemory
                    return
                }
                // Suppress new full-resolution decodes while actively scrubbing at high velocity
                guard !session.isHighVelocityScrubbing else {
                    return
                }
                isLoading = true
                defer { isLoading = false }
                let decoded = await session.loadPreviewImage(for: item, maxPixelSize: 2048)
                if !Task.isCancelled {
                    previewImage = decoded
                }
            }
        }
    }

    private func resetZoomState(animated: Bool) {
        if animated {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                zoomScale = 1.0
                pinchScale = 1.0
                panOffset = .zero
                liveClampedPanOffset = nil
            }
        } else {
            zoomScale = 1.0
            pinchScale = 1.0
            panOffset = .zero
            liveClampedPanOffset = nil
        }
    }
}

// MARK: - Filmstrip Video Canvas View

struct FilmstripVideoCanvasView: View {
    let url: URL
    var item: MediaItem? = nil
    var session: CullingSession? = nil
    var isCurrentPage: Bool = true
    var isExternalGestureActive: Bool = false
    var pageDragOffset: Binding<CGFloat> = .constant(0)
    var onCommitPageTurn: ((BorderTapDirection?) -> Void)? = nil
    var onInstantBorderTap: ((CGPoint) -> Bool)? = nil
    var onHeroGestureChanged: ((CGFloat, CGSize, CGSize) -> Void)? = nil
    var onHeroGestureEnded: (() -> Void)? = nil

    @State private var player: AVPlayer?
    @State private var swipeTranslation: CGFloat = 0.0
    @State private var activeDragMode: CanvasDragMode = .undecided

    var body: some View {
        GeometryReader { geo in
            let threshold = min(max(80.0, geo.size.width * 0.22), 140.0)
            let isSwipeActive = (session?.isSwipeModeEnabled == true) && item != nil && isCurrentPage
            let neighbors: (previous: MediaItem?, current: MediaItem?, next: MediaItem?) = session?.adjacentItems(for: item?.id) ?? (nil, item, nil)

            ZStack {
                Group {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .offset(x: isSwipeActive ? swipeTranslation : 0)
                .rotationEffect(
                    Angle.degrees(
                        isSwipeActive
                            ? Double(min(12.0, max(-12.0, swipeTranslation / 25.0)))
                            : 0
                    )
                )

                if isSwipeActive, let session {
                    SwipeCurationOverlayView(
                        session: session,
                        swipeTranslation: swipeTranslation,
                        threshold: threshold
                    )
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture(count: 1)
                    .onEnded { value in
                        guard isCurrentPage, let session, session.isBorderTapNavigationEnabled else { return }
                        guard CullingLayoutCalculator.borderTapDirection(at: value.location, in: geo.size) != nil else {
                            return
                        }
                        player?.pause()
                        if let onInstantBorderTap {
                            _ = onInstantBorderTap(value.location)
                        } else {
                            _ = session.handleBorderTap(at: value.location, in: geo.size)
                        }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard isCurrentPage else { return }
                        if value.magnification < 1.0 {
                            player?.pause()
                            onHeroGestureChanged?(value.magnification, .zero, .zero)
                        } else {
                            onHeroGestureChanged?(1.0, .zero, .zero)
                        }
                    }
                    .onEnded { _ in
                        guard isCurrentPage else { return }
                        onHeroGestureEnded?()
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard isCurrentPage, let session else { return }
                        if activeDragMode == .undecided {
                            player?.pause()
                            if session.isVerticalPullToGridAllowed
                                && value.translation.height > 12.0
                                && value.translation.height > abs(value.translation.width) * 1.15 {
                                activeDragMode = .verticalPullToGrid
                            } else if session.isSwipeModeEnabled {
                                activeDragMode = .swipeCuration
                            } else {
                                activeDragMode = .horizontalPaging
                            }
                        }

                        switch activeDragMode {
                        case .verticalPullToGrid:
                            onHeroGestureChanged?(1.0, value.translation, value.predictedEndTranslation)

                        case .swipeCuration:
                            swipeTranslation = value.translation.width

                        case .horizontalPaging:
                            pageDragOffset.wrappedValue = CullingLayoutCalculator.rubberBandedPageOffset(
                                value.translation.width,
                                hasPrevious: neighbors.previous != nil,
                                hasNext: neighbors.next != nil
                            )

                        default:
                            break
                        }
                    }
                    .onEnded { value in
                        guard isCurrentPage, let session else { return }
                        let completedMode = activeDragMode
                        activeDragMode = .undecided

                        switch completedMode {
                        case .verticalPullToGrid:
                            onHeroGestureEnded?()

                        case .swipeCuration:
                            guard let item else { return }
                            completeSwipeCurationGesture(
                                translationWidth: value.translation.width,
                                threshold: threshold,
                                containerWidth: geo.size.width,
                                item: item,
                                session: session,
                                swipeTranslation: $swipeTranslation
                            )

                        case .horizontalPaging:
                            let committedDirection = CullingLayoutCalculator.shouldCommitPageTurn(
                                pageDragOffset: pageDragOffset.wrappedValue,
                                predictedEndTranslationX: value.predictedEndTranslation.width,
                                containerWidth: geo.size.width,
                                hasPrevious: neighbors.previous != nil,
                                hasNext: neighbors.next != nil
                            )
                            onCommitPageTurn?(committedDirection)

                        default:
                            break
                        }
                    }
            )
            .onChange(of: isExternalGestureActive) { _, isActive in
                if isActive {
                    player?.pause()
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

    var thumbnailSize: CGSize {
        CullingLayoutCalculator.scrubberTileSize(
            isSelected: isSelected,
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
        let isCompact = size.width < 60 || size.height < 52

        Button(action: {
            onSelect?()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(neutralMattingColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )

                if let cgImage = displayedImage {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: isSelected ? .fit : .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .opacity(curation.pickFlag == .rejected ? 0.45 : 1.0)
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
                            .frame(width: 3.5)
                            .padding(.vertical, 4)
                            .padding(.leading, 2.5)
                        Spacer()
                    }
                }

                // Compact Rating & Flag overlays
                VStack {
                    HStack(spacing: 2) {
                        if item.isMediaPair {
                            Text(isCompact ? "R+J" : "RAW+JPG")
                                .font(.system(size: isCompact ? 8 : 9, weight: .bold))
                                .padding(.horizontal, isCompact ? 3 : 4)
                                .padding(.vertical, 1.5)
                                .background(.black.opacity(0.8), in: Capsule())
                                .foregroundStyle(.yellow)
                        } else if item.kind == .video {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(2.5)
                                .background(.black.opacity(0.8), in: Circle())
                                .foregroundStyle(.white)
                        }

                        Spacer(minLength: 0)

                        switch syncState {
                        case .synced:
                            EmptyView()
                        case .pendingWrite:
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        case .conflicted:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
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
                    .padding(.top, 2.5)
                    .padding(.horizontal, (curation.colorLabel != .none) ? 6 : 2.5)

                    Spacer(minLength: 0)

                    HStack(spacing: 1) {
                        if curation.starRating > 0 {
                            HStack(spacing: 1) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.yellow)
                                Text("\(curation.starRating.value)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, isCompact ? 2.5 : 3.5)
                            .padding(.vertical, 1.5)
                            .background(.black.opacity(0.8), in: Capsule())
                        }

                        Spacer(minLength: 0)

                        switch curation.pickFlag {
                        case .picked:
                            Image(systemName: "flag.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                                .padding(2)
                                .background(.black.opacity(0.8), in: Circle())
                        case .rejected:
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.red)
                                .padding(2)
                                .background(.black.opacity(0.8), in: Circle())
                        case .unflagged:
                            EmptyView()
                        }
                    }
                    .padding(.bottom, 2.5)
                    .padding(.horizontal, (curation.colorLabel != .none) ? 6 : 2.5)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.0)
            )
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
