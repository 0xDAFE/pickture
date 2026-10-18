import CoreGraphics
import Foundation

enum BorderTapDirection: Sendable, Equatable {
    case previous
    case next
}

struct ZoomPanHandoffResult: Sendable, Equatable {
    let clampedPanOffset: CGSize
    let pageDragOffset: CGFloat
}

struct DoubleTapZoomResult: Sendable, Equatable {
    let scale: CGFloat
    let panOffset: CGSize
}

struct HeroGridTransitionMetrics: Sendable, Equatable {
    let isActive: Bool
    let progress: CGFloat
    let chromeOpacity: Double
    let backdropOpacity: Double
    let interactiveScale: CGFloat
    let interactiveOffset: CGSize
    let shouldCommit: Bool

    static let inactive = HeroGridTransitionMetrics(
        isActive: false,
        progress: 0.0,
        chromeOpacity: 1.0,
        backdropOpacity: 0.92,
        interactiveScale: 1.0,
        interactiveOffset: .zero,
        shouldCommit: false
    )
}

enum CullingLayoutCalculator {
    static let workspaceCoordinateSpaceName = "CullingWorkspaceSpace"
    static let defaultGridMetadataDeckHeight: CGFloat = 48.0
    static let scrubberInterTileSpacing: CGFloat = 2.0
    static let scrubberActiveTileBreathingMargin: CGFloat = 8.0
    static let filmstripInterPageGutter: CGFloat = 16.0
    static let doubleTapZoomScale: CGFloat = 2.5
    static let boundaryRubberBandFactor: CGFloat = 0.35
    static let heroPinchCommitScaleThreshold: CGFloat = 0.75
    static let heroVerticalPullCommitThreshold: CGFloat = 110.0

    static func scrubberDockSpan(for dockPosition: FilmstripDockPosition) -> CGFloat {
        switch dockPosition {
        case .bottom:
            return 92.0
        case .right:
            return 128.0
        }
    }

    static func scrubberInactiveTileSize(for dockPosition: FilmstripDockPosition) -> CGSize {
        switch dockPosition {
        case .bottom:
            return CGSize(width: 40.0, height: 72.0)
        case .right:
            return CGSize(width: 112.0, height: 44.0)
        }
    }

    static func scrubberTileSize(
        isSelected: Bool,
        aspectRatio: CGFloat?,
        displayedThumbnail: CGImage? = nil,
        dockPosition: FilmstripDockPosition,
        mediaKind: MediaKind = .photo
    ) -> CGSize {
        guard isSelected else {
            return scrubberInactiveTileSize(for: dockPosition)
        }
        return filmstripThumbnailSize(
            aspectRatio: aspectRatio,
            displayedThumbnail: displayedThumbnail,
            dockPosition: dockPosition,
            mediaKind: mediaKind
        )
    }

    static func scrubberHalfViewportInset(scrubberSpan: CGFloat, activeTileSpan: CGFloat) -> CGFloat {
        guard !scrubberSpan.isNaN, !scrubberSpan.isInfinite,
              !activeTileSpan.isNaN, !activeTileSpan.isInfinite else {
            return 0.0
        }
        return max(0.0, (scrubberSpan - activeTileSpan) / 2.0)
    }

    static func scrubberDragInterpolationOffset(
        pageDragOffset: CGFloat,
        pageStride: CGFloat,
        activeTileSpan: CGFloat,
        dockPosition: FilmstripDockPosition
    ) -> CGFloat {
        guard pageStride > 0, !pageDragOffset.isNaN, !pageDragOffset.isInfinite else {
            return 0.0
        }
        let clampedProgress = min(1.0, max(-1.0, pageDragOffset / pageStride))
        let inactiveSpan = (dockPosition == .bottom)
            ? scrubberInactiveTileSize(for: .bottom).width
            : scrubberInactiveTileSize(for: .right).height
        let stepDistance = (activeTileSpan / 2.0)
            + scrubberActiveTileBreathingMargin
            + scrubberInterTileSpacing
            + (inactiveSpan / 2.0)
        return clampedProgress * stepDistance
    }

    static func shouldCommitPageTurn(
        pageDragOffset: CGFloat,
        predictedEndTranslationX: CGFloat,
        containerWidth: CGFloat,
        hasPrevious: Bool,
        hasNext: Bool
    ) -> BorderTapDirection? {
        let distanceThreshold = min(max(60.0, containerWidth * 0.18), 140.0)
        let velocityThreshold = max(120.0, containerWidth * 0.32)

        if pageDragOffset > 0 && hasPrevious {
            if pageDragOffset >= distanceThreshold || predictedEndTranslationX >= velocityThreshold {
                return .previous
            }
        } else if pageDragOffset < 0 && hasNext {
            if abs(pageDragOffset) >= distanceThreshold || abs(predictedEndTranslationX) >= velocityThreshold {
                return .next
            }
        }
        return nil
    }

    static func compensatedPageDragOffset(
        currentOffset: CGFloat,
        direction: BorderTapDirection,
        pageStride: CGFloat
    ) -> CGFloat {
        guard !currentOffset.isNaN, !currentOffset.isInfinite,
              !pageStride.isNaN, !pageStride.isInfinite else {
            return 0.0
        }
        switch direction {
        case .next:
            return currentOffset + pageStride
        case .previous:
            return currentOffset - pageStride
        }
    }

    static func resolveHeroGridTransition(
        rawScale: CGFloat,
        dragTranslation: CGSize,
        predictedEndTranslation: CGSize,
        canvasRect: CGRect,
        targetGridCellRect: CGRect?,
        isVerticalPullAllowed: Bool
    ) -> HeroGridTransitionMetrics {
        let isPinchingOut = rawScale < 0.995
        let isVerticalPullDominant = isVerticalPullAllowed
            && rawScale <= 1.01
            && dragTranslation.height > 12.0
            && dragTranslation.height > abs(dragTranslation.width) * 1.15

        guard isPinchingOut || isVerticalPullDominant else {
            return .inactive
        }

        let pinchProgress: CGFloat = isPinchingOut
            ? min(1.0, max(0.0, (1.0 - rawScale) / (1.0 - 0.55)))
            : 0.0
        let pullProgress: CGFloat = isVerticalPullDominant
            ? min(1.0, max(0.0, dragTranslation.height / 220.0))
            : 0.0
        let progress = min(1.0, max(pinchProgress, pullProgress))

        let chromeOpacity = Double(max(0.0, 1.0 - progress * 1.25))
        let backdropOpacity = Double(0.92 * max(0.0, 1.0 - progress * 0.85))

        let baseScale: CGFloat
        if isPinchingOut {
            baseScale = max(0.35, min(1.0, rawScale))
        } else {
            baseScale = max(0.55, 1.0 - pullProgress * 0.35)
        }

        let interactiveOffset: CGSize
        if let targetRect = targetGridCellRect, canvasRect.width > 0, canvasRect.height > 0 {
            let canvasCenter = CGPoint(x: canvasRect.midX, y: canvasRect.midY)
            let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
            let toTargetX = targetCenter.x - canvasCenter.x
            let toTargetY = targetCenter.y - canvasCenter.y
            let blend = progress * 0.35
            interactiveOffset = CGSize(
                width: dragTranslation.width + toTargetX * blend,
                height: dragTranslation.height + toTargetY * blend
            )
        } else {
            interactiveOffset = dragTranslation
        }

        let commitsByPinch = isPinchingOut && rawScale <= heroPinchCommitScaleThreshold
        let commitsByPull = isVerticalPullDominant && (
            dragTranslation.height >= heroVerticalPullCommitThreshold ||
            predictedEndTranslation.height >= heroVerticalPullCommitThreshold * 1.55
        )

        return HeroGridTransitionMetrics(
            isActive: true,
            progress: progress,
            chromeOpacity: chromeOpacity,
            backdropOpacity: backdropOpacity,
            interactiveScale: baseScale,
            interactiveOffset: interactiveOffset,
            shouldCommit: commitsByPinch || commitsByPull
        )
    }

    static func fittedImageSize(
        aspectRatio: CGFloat,
        in containerSize: CGSize,
        mediaKind: MediaKind = .photo
    ) -> CGSize {
        let safeRatio: CGFloat
        if aspectRatio.isNaN || aspectRatio.isInfinite || aspectRatio <= 0 {
            safeRatio = fallbackAspectRatio(for: mediaKind)
        } else {
            safeRatio = aspectRatio
        }

        let safeWidth = max(1.0, containerSize.width.isNaN || containerSize.width.isInfinite ? 1.0 : containerSize.width)
        let safeHeight = max(1.0, containerSize.height.isNaN || containerSize.height.isInfinite ? 1.0 : containerSize.height)
        let containerRatio = safeWidth / safeHeight

        if safeRatio >= containerRatio {
            let width = safeWidth
            let height = width / safeRatio
            return CGSize(width: width, height: height)
        } else {
            let height = safeHeight
            let width = height * safeRatio
            return CGSize(width: width, height: height)
        }
    }

    static func maxPanOffset(fittedSize: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1.0, !scale.isNaN, !scale.isNaN, !scale.isInfinite else {
            return .zero
        }
        let maxPanX = max(0.0, (fittedSize.width * (scale - 1.0)) / 2.0)
        let maxPanY = max(0.0, (fittedSize.height * (scale - 1.0)) / 2.0)
        return CGSize(width: maxPanX, height: maxPanY)
    }

    static func clampPanOffset(_ proposedOffset: CGSize, fittedSize: CGSize, scale: CGFloat) -> CGSize {
        let maxPan = maxPanOffset(fittedSize: fittedSize, scale: scale)
        let clampedX = min(maxPan.width, max(-maxPan.width, proposedOffset.width))
        let clampedY = min(maxPan.height, max(-maxPan.height, proposedOffset.height))
        return CGSize(width: clampedX, height: clampedY)
    }

    static func rubberBandedPageOffset(
        _ rawOffset: CGFloat,
        hasPrevious: Bool,
        hasNext: Bool
    ) -> CGFloat {
        if (rawOffset > 0 && !hasPrevious) || (rawOffset < 0 && !hasNext) {
            return rawOffset * boundaryRubberBandFactor
        }
        return rawOffset
    }

    static func resolveZoomPanAndPageHandoff(
        currentPanOffset: CGSize,
        dragTranslation: CGSize,
        fittedSize: CGSize,
        scale: CGFloat,
        hasPrevious: Bool,
        hasNext: Bool
    ) -> ZoomPanHandoffResult {
        let proposed = CGSize(
            width: currentPanOffset.width + dragTranslation.width,
            height: currentPanOffset.height + dragTranslation.height
        )
        let clamped = clampPanOffset(proposed, fittedSize: fittedSize, scale: scale)
        let rawOverflowX = proposed.width - clamped.width
        let pageOffset = rubberBandedPageOffset(rawOverflowX, hasPrevious: hasPrevious, hasNext: hasNext)
        return ZoomPanHandoffResult(clampedPanOffset: clamped, pageDragOffset: pageOffset)
    }

    static func resolveDoubleTapZoom(
        currentScale: CGFloat,
        tapLocation: CGPoint,
        containerSize: CGSize,
        fittedSize: CGSize,
        targetZoomScale: CGFloat = doubleTapZoomScale
    ) -> DoubleTapZoomResult {
        if currentScale > 1.01 {
            return DoubleTapZoomResult(scale: 1.0, panOffset: .zero)
        }
        let center = CGPoint(x: containerSize.width / 2.0, y: containerSize.height / 2.0)
        let deltaX = tapLocation.x - center.x
        let deltaY = tapLocation.y - center.y
        let proposedPan = CGSize(
            width: -deltaX * (targetZoomScale - 1.0),
            height: -deltaY * (targetZoomScale - 1.0)
        )
        let clampedPan = clampPanOffset(proposedPan, fittedSize: fittedSize, scale: targetZoomScale)
        return DoubleTapZoomResult(scale: targetZoomScale, panOffset: clampedPan)
    }

    static func borderTapZoneWidth(for containerWidth: CGFloat) -> CGFloat {
        guard !containerWidth.isNaN, !containerWidth.isInfinite, containerWidth > 0 else {
            return 0.0
        }
        return min(containerWidth * 0.12, 64.0)
    }

    static func borderTapDirection(at location: CGPoint, in containerSize: CGSize) -> BorderTapDirection? {
        guard containerSize.width > 0 else { return nil }
        let zoneWidth = borderTapZoneWidth(for: containerSize.width)
        guard zoneWidth > 0 else { return nil }
        if location.x <= zoneWidth {
            return .previous
        } else if location.x >= (containerSize.width - zoneWidth) {
            return .next
        }
        return nil
    }

    static func filmstripThumbnailSize(
        aspectRatio: CGFloat?,
        displayedThumbnail: CGImage? = nil,
        dockPosition: FilmstripDockPosition,
        mediaKind: MediaKind = .photo
    ) -> CGSize {
        let resolvedRatio = resolveAspectRatio(
            aspectRatio: aspectRatio,
            displayedThumbnail: displayedThumbnail,
            mediaKind: mediaKind
        )
        return filmstripThumbnailSize(
            aspectRatio: resolvedRatio,
            dockPosition: dockPosition,
            mediaKind: mediaKind
        )
    }

    static func filmstripThumbnailSize(
        aspectRatio: CGFloat,
        dockPosition: FilmstripDockPosition,
        mediaKind: MediaKind = .photo
    ) -> CGSize {
        let safeRatio: CGFloat
        if aspectRatio.isNaN || aspectRatio.isInfinite || aspectRatio <= 0 {
            safeRatio = (mediaKind == .video) ? 1.777 : 1.5
        } else {
            safeRatio = aspectRatio
        }

        switch dockPosition {
        case .bottom:
            let height: CGFloat = 72.0
            let unroundedWidth = height * safeRatio
            let clampedWidth = min(128.0, max(48.0, unroundedWidth.rounded()))
            return CGSize(width: clampedWidth, height: height)

        case .right:
            let width: CGFloat = 112.0
            let divisor = max(0.1, safeRatio)
            let unroundedHeight = width / divisor
            let clampedHeight = min(150.0, max(64.0, unroundedHeight.rounded()))
            return CGSize(width: width, height: clampedHeight)
        }
    }

    static func fallbackAspectRatio(for kind: MediaKind) -> CGFloat {
        kind == .video ? 1.777 : 1.5
    }

    static func resolveAspectRatio(
        aspectRatio: CGFloat?,
        displayedThumbnail: CGImage?,
        mediaKind: MediaKind
    ) -> CGFloat {
        if let cgImage = displayedThumbnail {
            return cgImage.aspectRatio
        }
        if let ratio = aspectRatio, !ratio.isNaN, !ratio.isInfinite, ratio > 0 {
            return ratio
        }
        return fallbackAspectRatio(for: mediaKind)
    }

    static func gridStageHeight(for columnWidth: CGFloat) -> CGFloat {
        guard !columnWidth.isNaN, !columnWidth.isInfinite, columnWidth > 0 else {
            return 140.0
        }
        return (columnWidth * 0.75).rounded()
    }

    static func gridItemSilhouetteSize(
        aspectRatio: CGFloat,
        stageWidth: CGFloat,
        stageHeight: CGFloat,
        mediaKind: MediaKind = .photo
    ) -> CGSize {
        let safeRatio: CGFloat
        if aspectRatio.isNaN || aspectRatio.isInfinite || aspectRatio <= 0 {
            safeRatio = fallbackAspectRatio(for: mediaKind)
        } else {
            safeRatio = aspectRatio
        }

        let safeStageWidth = max(1.0, stageWidth)
        let safeStageHeight = max(1.0, stageHeight)
        let stageRatio = safeStageWidth / safeStageHeight

        if safeRatio >= stageRatio {
            // Wider than or equal to stage ceiling: constrained by stageWidth
            let width = safeStageWidth
            let height = width / safeRatio
            return CGSize(width: width, height: height)
        } else {
            // Taller than stage ceiling: constrained by stageHeight
            let height = safeStageHeight
            let width = height * safeRatio
            return CGSize(width: width, height: height)
        }
    }

    static func gridItemSilhouetteSize(
        aspectRatio: CGFloat,
        columnWidth: CGFloat,
        mediaKind: MediaKind = .photo
    ) -> CGSize {
        let stageHeight = gridStageHeight(for: columnWidth)
        return gridItemSilhouetteSize(
            aspectRatio: aspectRatio,
            stageWidth: columnWidth,
            stageHeight: stageHeight,
            mediaKind: mediaKind
        )
    }
}
