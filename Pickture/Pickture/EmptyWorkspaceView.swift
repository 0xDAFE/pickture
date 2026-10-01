import SwiftUI

struct EmptyWorkspaceView: View {
    let recentFolders: [RecentFolder]
    @Binding var isFolderImporterPresented: Bool
    let onReopenRecentFolder: (RecentFolder) -> Void

    init(
        recentFolders: [RecentFolder],
        isFolderImporterPresented: Binding<Bool> = .constant(false),
        onReopenRecentFolder: @escaping (RecentFolder) -> Void = { _ in }
    ) {
        self.recentFolders = recentFolders
        self._isFolderImporterPresented = isFolderImporterPresented
        self.onReopenRecentFolder = onReopenRecentFolder
    }

    init(
        session: CullingSession,
        isFolderImporterPresented: Binding<Bool> = .constant(false),
        onReopenRecentFolder: @escaping (RecentFolder) -> Void = { _ in }
    ) {
        self.init(
            recentFolders: session.recentFolders,
            isFolderImporterPresented: isFolderImporterPresented,
            onReopenRecentFolder: onReopenRecentFolder
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("Open a Folder to Start Culling")
                        .font(.title2.weight(.semibold))
                    Text("Select a local folder, SD card, or network share (NAS/SMB) in Files.app. RAW + JPEG/HEIC files in the same directory are paired into a single MediaPair automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                .padding(.top, 40)

                Button {
                    isFolderImporterPresented = true
                } label: {
                    Label("Open Folder in Files…", systemImage: "folder.badge.plus")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !recentFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent Folders")
                            .font(.headline)
                        ForEach(recentFolders) { recent in
                            Button {
                                onReopenRecentFolder(recent)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recent.name)
                                            .font(.body.weight(.medium))
                                        Text(recent.displayPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(.quaternary.opacity(0.4))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 500)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
