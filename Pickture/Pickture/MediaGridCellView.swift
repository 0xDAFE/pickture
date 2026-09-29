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

    private var taskKey: String {
        "\(item.id)-\(previewSource.rawValue)-\(cacheGeneration)"
    }

    private var displayedThumbnail: CGImage? {
        thumbnailImage ?? session.cachedThumbnailImage(for: item, maxPixelSize: 360)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.5))

                    if let cgImage = displayedThumbnail {
                        Image(decorative: cgImage, scale: 1.0, orientation: .up)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
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
                    }

                    // Overlay badges
                    VStack {
                        HStack(spacing: 6) {
                            if item.isMediaPair {
                                Text(item.badgeText)
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.75), in: Capsule())
                                    .foregroundStyle(.yellow)
                            } else {
                                Text(item.badgeText)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.65), in: Capsule())
                                    .foregroundStyle(.white)
                            }

                            Spacer()

                            Label(
                                item.mediaTypeBadge,
                                systemImage: item.kind == .video ? "video.fill" : "camera.fill"
                            )
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .padding(6)

                        Spacer()
                    }
                }
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayFileName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isRecursiveMode && !item.relativeDirectoryPath.isEmpty {
                        Text(item.relativeDirectoryPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayFileName), \(item.mediaTypeBadge)\(item.isMediaPair ? ", RAW+JPG pair" : "")")
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
            }
        }
    }
}
