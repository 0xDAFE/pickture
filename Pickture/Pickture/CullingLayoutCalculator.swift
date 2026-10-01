import CoreGraphics
import Foundation

enum CullingLayoutCalculator {
    static let defaultGridMetadataDeckHeight: CGFloat = 48.0

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
}
