//
//  ContentView.swift
//  Pickture
//
//  Created by David on 27.09.26.
//

import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var session: CullingSession
    @State private var isFolderImporterPresented = false
    @State private var isSettingsPresented = false

    init(session: CullingSession? = nil) {
        _session = State(initialValue: session ?? CullingSession())
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 185, maximum: 260), spacing: 12)
    ]

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let folderURL = urls.first else { return }
                do {
                    try session.openFolder(at: folderURL)
                    session.lastErrorMessage = nil
                } catch {
                    session.lastErrorMessage = error.localizedDescription
                }
            case .failure(let error):
                session.lastErrorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheetView(session: session)
        }
        .sheet(isPresented: $session.isConflictSheetPresented) {
            ConflictResolutionSheetView(session: session)
        }
    }

    private var sidebarContent: some View {
        List {
            Section("Folder") {
                Button {
                    isFolderImporterPresented = true
                } label: {
                    Label("Open Folder…", systemImage: "folder.badge.plus")
                }

                Toggle(
                    isOn: Binding(
                        get: { session.subfolderMode == .recursive },
                        set: { isRecursive in
                            do {
                                try session.setSubfolderMode(isRecursive ? .recursive : .immediate)
                            } catch {
                                session.lastErrorMessage = error.localizedDescription
                            }
                        }
                    )
                ) {
                    Label("SubfolderMode (Recursive)", systemImage: "list.bullet.indent")
                }

                Picker(
                    selection: Binding(
                        get: { session.previewSource },
                        set: { session.previewSource = $0 }
                    )
                ) {
                    Text("Prefer Raster").tag(PreviewSource.preferRaster)
                    Text("Prefer RAW").tag(PreviewSource.preferRAW)
                } label: {
                    Label("PreviewSource", systemImage: "photo.stack")
                }
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
                                handleReopenRecentFolder(recent)
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
        .navigationTitle("Pickture")
        .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 320)
    }

    private func handleReopenRecentFolder(_ recent: RecentFolder) {
        do {
            try session.reopenRecentFolder(recent)
            session.lastErrorMessage = nil
        } catch {
            session.lastErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var detailContent: some View {
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

            if session.currentFolderURL == nil {
                emptyWorkspaceView
            } else if session.items.isEmpty {
                ContentUnavailableView {
                    Label("No MediaItems Found", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(
                        session.subfolderMode == .immediate
                            ? "No supported RAW, raster, or video files in this folder. Try enabling SubfolderMode to scan subdirectories."
                            : "No supported RAW, raster, or video files were found in this folder or its subdirectories."
                    )
                } actions: {
                    if session.subfolderMode == .immediate {
                        Button("Enable SubfolderMode") {
                            try? session.setSubfolderMode(.recursive)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Open Another Folder…") {
                        isFolderImporterPresented = true
                    }
                }
            } else {
                gridContentView
            }
        }
        .navigationTitle(session.currentFolderURL?.lastPathComponent ?? "Pickture Grid")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isFolderImporterPresented = true
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    Task {
                        try? await session.refreshFolder()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh Folder and re-check sidecars")

                // Workspace-level Sync Summary Badge
                Button {
                    if session.conflictedItemsCount > 0 {
                        session.activeConflictItemID = nil
                        session.isConflictSheetPresented = true
                    } else if session.pendingWritesCount > 0 {
                        Task { await session.flushPendingWrites() }
                    }
                } label: {
                    HStack(spacing: 5) {
                        switch session.syncSummaryState {
                        case .synced:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .pendingWrite:
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                        case .loading:
                            ProgressView()
                                .controlSize(.mini)
                        case .conflicted:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        case .syncError:
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                        Text(session.syncSummaryBadgeText)
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(session.syncSummaryState == .conflicted ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .help("Sync Status — Click to resolve conflicts or flush pending writes")

                Menu {
                    if session.recentFolders.isEmpty {
                        Text("No Recent Folders")
                    } else {
                        ForEach(session.recentFolders) { recent in
                            Button(recent.name) {
                                handleReopenRecentFolder(recent)
                            }
                        }
                    }
                } label: {
                    Label("Recent Folders", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    try? session.toggleSubfolderMode()
                } label: {
                    Label(
                        session.subfolderMode == .recursive ? "Subfolders: On" : "Subfolders: Off",
                        systemImage: session.subfolderMode == .recursive
                            ? "folder.fill.badge.gearshape"
                            : "folder"
                    )
                }
                .help("Toggle recursive SubfolderMode")

                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }

    private var emptyWorkspaceView: some View {
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

                if !session.recentFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent Folders")
                            .font(.headline)
                        ForEach(session.recentFolders) { recent in
                            Button {
                                handleReopenRecentFolder(recent)
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

    private var gridContentView: some View {
        VStack(spacing: 0) {
            if session.conflictedItemsCount > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(session.conflictedItemsCount) Metadata Conflict\(session.conflictedItemsCount == 1 ? "" : "s") Detected")
                            .font(.subheadline.weight(.semibold))
                        Text("External edits on disk diverged from local changes. Review and resolve before syncing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Resolve Conflicts…") {
                        session.activeConflictItemID = nil
                        session.isConflictSheetPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.15))
                Divider()
            }

            HStack(spacing: 12) {
                Label("\(session.items.count) MediaItems", systemImage: "square.grid.3x3")
                    .font(.caption.weight(.medium))

                let pairCount = session.items.filter(\.isMediaPair).count
                if pairCount > 0 {
                    Text("• \(pairCount) MediaPairs (RAW+JPG)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let videoCount = session.items.filter { $0.kind == .video }.count
                if videoCount > 0 {
                    Text("• \(videoCount) Videos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(session.items) { item in
                        MediaGridCellView(
                            item: item,
                            isSelected: session.selectedItemID == item.id,
                            isRecursiveMode: session.subfolderMode == .recursive,
                            previewSource: session.previewSource,
                            cacheGeneration: session.cacheGeneration,
                            session: session
                        ) {
                            session.selectedItemID = item.id
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

#Preview("Grid View (Sample Shoot)") {
    ContentView(session: SelfContainedPreviewData.makeSampleSession())
        .frame(minWidth: 1040, minHeight: 640)
}

@MainActor
private enum SelfContainedPreviewData {
    static func makeSampleSession() -> CullingSession {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickturePreviewShoot", isDirectory: true)
        let day1 = root.appendingPathComponent("Day1_Ceremony", isDirectory: true)
        let day2 = root.appendingPathComponent("Day2_Portraits", isDirectory: true)
        try? FileManager.default.createDirectory(at: day1, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: day2, withIntermediateDirectories: true)

        writePreviewImage(to: day1.appendingPathComponent("DSC0101.JPG"), r: 64, g: 132, b: 214)
        try? Data("raw".utf8).write(to: day1.appendingPathComponent("DSC0101.ARW"))

        writePreviewImage(to: day1.appendingPathComponent("DSC0102.JPG"), r: 218, g: 124, b: 68)
        try? Data("raw".utf8).write(to: day1.appendingPathComponent("DSC0102.CR3"))

        writePreviewImage(to: day1.appendingPathComponent("DSC0103.PNG"), r: 72, g: 168, b: 118)
        try? Data("video".utf8).write(to: day1.appendingPathComponent("DSC0103.MOV"))

        writePreviewImage(to: day2.appendingPathComponent("IMG_2040.JPG"), r: 158, g: 96, b: 196)
        try? Data("raw".utf8).write(to: day2.appendingPathComponent("IMG_2040.NEF"))

        writePreviewImage(to: day2.appendingPathComponent("IMG_2041.JPG"), r: 214, g: 172, b: 64)

        let videoThumbURL = day1.appendingPathComponent(".video_preview.jpg")
        writePreviewImage(to: videoThumbURL, r: 58, g: 82, b: 124)
        let videoThumbData = try? Data(contentsOf: videoThumbURL)

        let storeURL = root.appendingPathComponent(".preview-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeURL)
        try? session.setSubfolderMode(.recursive)
        try? session.openFolder(at: root)
        for item in session.items {
            let key = session.thumbnailCacheKey(for: item, maxPixelSize: 360)
            if item.kind == .photo {
                let file = item.preferredFile(for: session.previewSource)
                if let extracted = PreviewLoader.extractImageThumbnail(from: file.url, maxPixelSize: 360) {
                    session.mediaCache.storeData(extracted.jpegData, forKey: key)
                }
            } else if let videoThumbData {
                session.mediaCache.storeData(videoThumbData, forKey: key)
            }
        }
        session.setCacheSizeLimitBytes(session.cacheSizeLimitBytes)
        session.selectedItemID = session.items.first?.id
        return session
    }

    private static func writePreviewImage(to url: URL, r: UInt8, g: UInt8, b: UInt8) {
        let width = 320
        let height = 240
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let boost = UInt8((x + y) % 36)
                pixels[offset] = r &+ boost
                pixels[offset + 1] = g &+ boost
                pixels[offset + 2] = b &+ boost
                pixels[offset + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        if CGImageDestinationFinalize(dest) {
            try? (mutableData as Data).write(to: url)
        }
    }
}

