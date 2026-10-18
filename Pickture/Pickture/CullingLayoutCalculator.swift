import CoreGraphics
import Foundation

enum BorderTapDirection: Sendable, Equatable {
    case previous
    case next
}

enum CullingLayoutCalculator {
    static let defaultGridMetadataDeckHeight: CGFloat = 48.0

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

    // MARK: - PinchToGrid & SwipeNavigation Calculations

    static let pinchToGridScaleThreshold: CGFloat = 0.85

    static func shouldCommitPinchToGrid(currentZoom: CGFloat, magnification: CGFloat) -> Bool {
        guard currentZoom <= 1.0 else { return false }
        return magnification <= pinchToGridScaleThreshold
    }

    static func swipeNavigationThreshold(for containerWidth: CGFloat) -> CGFloat {
        guard !containerWidth.isNaN, !containerWidth.isInfinite, containerWidth > 0 else {
            return 60.0
        }
        let calculated = containerWidth * 0.20
        return min(max(calculated, 60.0), 140.0)
    }

    static func swipeNavigationTranslation(
        offset: CGFloat,
        isAtLeadingBoundary: Bool,
        isAtTrailingBoundary: Bool
    ) -> CGFloat {
        guard !offset.isNaN, !offset.isInfinite else { return 0.0 }
        let boundaryDamping: CGFloat = 0.30

        if offset > 0 && isAtLeadingBoundary {
            return offset * boundaryDamping
        } else if offset < 0 && isAtTrailingBoundary {
            return offset * boundaryDamping
        }
        return offset
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

    // MARK: - ZoomLock Coordinate Calculations

    static func fittedImageSize(imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return containerSize
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        if imageAspect >= containerAspect {
            let width = containerSize.width
            let height = width / imageAspect
            return CGSize(width: width, height: height)
        } else {
            let height = containerSize.height
            let width = height * imageAspect
            return CGSize(width: width, height: height)
        }
    }

    static func fittedImageRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        let fittedSize = fittedImageSize(imageSize: imageSize, in: containerSize)
        let originX = (containerSize.width - fittedSize.width) / 2.0
        let originY = (containerSize.height - fittedSize.height) / 2.0
        return CGRect(origin: CGPoint(x: originX, y: originY), size: fittedSize)
    }

    static func calculatePanOffset(
        forNormalizedAnchor anchor: CGPoint,
        containerSize: CGSize,
        imageSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0, scale >= 1.0 else {
            return .zero
        }
        let fitted = fittedImageSize(imageSize: imageSize, in: containerSize)
        let scaledWidth = fitted.width * scale
        let scaledHeight = fitted.height * scale

        let maxPanX = max(0, (scaledWidth - containerSize.width) / 2.0)
        let maxPanY = max(0, (scaledHeight - containerSize.height) / 2.0)

        let targetX = -(anchor.x - 0.5) * scaledWidth
        let targetY = -(anchor.y - 0.5) * scaledHeight

        let clampedX = min(maxPanX, max(-maxPanX, targetX))
        let clampedY = min(maxPanY, max(-maxPanY, targetY))

        return CGSize(width: clampedX, height: clampedY)
    }

    static func calculateNormalizedAnchor(
        forPanOffset panOffset: CGSize,
        containerSize: CGSize,
        imageSize: CGSize,
        scale: CGFloat
    ) -> CGPoint {
        guard containerSize.width > 0, containerSize.height > 0, scale > 1.0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let fitted = fittedImageSize(imageSize: imageSize, in: containerSize)
        let scaledWidth = fitted.width * scale
        let scaledHeight = fitted.height * scale

        let u: CGFloat
        if scaledWidth > 0 {
            u = 0.5 - (panOffset.width / scaledWidth)
        } else {
            u = 0.5
        }

        let v: CGFloat
        if scaledHeight > 0 {
            v = 0.5 - (panOffset.height / scaledHeight)
        } else {
            v = 0.5
        }

        return CGPoint(x: min(1.0, max(0.0, u)), y: min(1.0, max(0.0, v)))
    }

    static func normalizedAnchor(
        forTapLocation tapLocation: CGPoint,
        inContainerSize containerSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        let rect = fittedImageRect(imageSize: imageSize, in: containerSize)
        guard rect.width > 0, rect.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let u = (tapLocation.x - rect.minX) / rect.width
        let v = (tapLocation.y - rect.minY) / rect.height
        return CGPoint(x: min(1.0, max(0.0, u)), y: min(1.0, max(0.0, v)))
    }

    static func clampPanOffset(
        _ rawOffset: CGSize,
        containerSize: CGSize,
        imageSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0, scale > 1.0 else {
            return .zero
        }
        let fitted = fittedImageSize(imageSize: imageSize, in: containerSize)
        let scaledWidth = fitted.width * scale
        let scaledHeight = fitted.height * scale
        let maxPanX = max(0, (scaledWidth - containerSize.width) / 2.0)
        let maxPanY = max(0, (scaledHeight - containerSize.height) / 2.0)
        return CGSize(
            width: min(maxPanX, max(-maxPanX, rawOffset.width)),
            height: min(maxPanY, max(-maxPanY, rawOffset.height))
        )
    }
}
