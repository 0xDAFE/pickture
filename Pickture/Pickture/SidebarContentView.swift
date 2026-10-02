import SwiftUI

struct SidebarContentView: View {
    @Bindable var session: CullingSession
    @Binding var isFolderImporterPresented: Bool
    @Binding var isSettingsPresented: Bool
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    let onCloseFolder: () -> Void
    let onReopenRecentFolder: (RecentFolder) -> Void

    init(
        session: CullingSession,
        isFolderImporterPresented: Binding<Bool> = .constant(false),
        isSettingsPresented: Binding<Bool> = .constant(false),
        preferredCompactColumn: Binding<NavigationSplitViewColumn> = .constant(.sidebar),
        onCloseFolder: @escaping () -> Void = {},
        onReopenRecentFolder: @escaping (RecentFolder) -> Void = { _ in }
    ) {
        self.session = session
        self._isFolderImporterPresented = isFolderImporterPresented
        self._isSettingsPresented = isSettingsPresented
        self._preferredCompactColumn = preferredCompactColumn
        self.onCloseFolder = onCloseFolder
        self.onReopenRecentFolder = onReopenRecentFolder
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = session.lastErrorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        session.lastErrorMessage = nil
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.15))
            }

            List {
                if let folderURL = session.currentFolderURL {
                    Section("Active Workspace") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill.badge.gearshape")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folderURL.lastPathComponent)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text("\(session.items.count) MediaItem\(session.items.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)

                            Button {
                                session.viewMode = .grid
                                preferredCompactColumn = .detail
                            } label: {
                                Label("Return to Grid", systemImage: "arrow.right.circle.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)

                            Button(role: .destructive) {
                                onCloseFolder()
                            } label: {
                                Label("Close Folder", systemImage: "xmark.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Folder") {
                    Button {
                        isFolderImporterPresented = true
                    } label: {
                        Label("Open Folder…", systemImage: "folder.badge.plus")
                    }

                    Toggle("Subfolder Mode", isOn: $session.isRecursiveSubfolderMode)
                }

                Section("Recent Folders") {
                    if session.recentFolders.isEmpty {
                        Text("No recent folders yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(session.recentFolders) { recent in
                            HStack {
                                Button {
                                    onReopenRecentFolder(recent)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "folder.fill")
                                                .foregroundStyle(Color.accentColor)
                                            Text(recent.name)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                        }
                                        Text(recent.displayPath)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    session.removeRecentFolder(recent)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(recent.name) from Recent Folders")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Pickture")
        .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 320)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Pickture Settings")
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Pickture Settings")
            }
            #endif
        }
    }
}
