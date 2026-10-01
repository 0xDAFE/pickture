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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var session: CullingSession
    /// Intentional one-time state seed: on compact screens (iPhone / Slide Over), the app
    /// always launches anchored to the sidebar (.sidebar) per ADR 0004.
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var isFolderImporterPresented = false
    @State private var isSettingsPresented = false
    @State private var isCloseConfirmationPresented = false
    @State private var pendingWritesCountForClose = 0

    init(session: CullingSession) {
        self.session = session
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            SidebarContentView(
                session: session,
                isFolderImporterPresented: $isFolderImporterPresented,
                isSettingsPresented: $isSettingsPresented,
                preferredCompactColumn: $preferredCompactColumn,
                onCloseFolder: { handleCloseFolder(force: false) },
                onReopenRecentFolder: handleReopenRecentFolder
            )
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
                    preferredCompactColumn = .detail
                } catch {
                    session.lastErrorMessage = error.localizedDescription
                    preferredCompactColumn = .sidebar
                }
            case .failure(let error):
                session.lastErrorMessage = error.localizedDescription
                preferredCompactColumn = .sidebar
            }
        }
        .confirmationDialog(
            "Pending Writes in Progress",
            isPresented: $isCloseConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Close Anyway", role: .destructive) {
                handleCloseFolder(force: true)
            }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text("\(pendingWritesCountForClose) pending write\(pendingWritesCountForClose == 1 ? "" : "s") have not finished syncing to disk. If you close now, curation metadata changes are safely preserved in the local journal and will sync when you reopen this folder.")
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheetView(session: session)
        }
        .sheet(isPresented: $session.isConflictSheetPresented) {
            ConflictResolutionSheetView(session: session)
        }
    }

    private func handleReopenRecentFolder(_ recent: RecentFolder) {
        do {
            try session.reopenRecentFolder(recent)
            session.lastErrorMessage = nil
            preferredCompactColumn = .detail
        } catch {
            session.lastErrorMessage = error.localizedDescription
            preferredCompactColumn = .sidebar
        }
    }

    private func handleCloseFolder(force: Bool = false) {
        Task {
            let result = await session.closeFolder(force: force)
            switch result {
            case .success, .closedWithPendingJournaled:
                preferredCompactColumn = .sidebar
            case .pendingWritesRemaining(let count):
                pendingWritesCountForClose = count
                isCloseConfirmationPresented = true
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if session.currentFolderURL == nil {
                EmptyWorkspaceView(
                    session: session,
                    isFolderImporterPresented: $isFolderImporterPresented,
                    onReopenRecentFolder: handleReopenRecentFolder
                )
            } else if session.items.isEmpty {
                emptyFolderView
            } else {
                FilterCriteriaBarView(session: session)

                if session.visibleItems.isEmpty {
                    noMatchingItemsView
                } else if session.viewMode == .grid {
                    GridContentView(session: session)
                } else {
                    FilmstripView(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            // When search field is focused, do not intercept single-key curation shortcuts
            if session.isSearchFieldFocused {
                if press.key == .escape {
                    session.filterCriteria.searchQuery = ""
                    session.isSearchFieldFocused = false
                    return .handled
                }
                return .ignored
            }

            if press.modifiers.contains(.command) && press.characters.lowercased() == "z" {
                if session.undoLastSwipe() { return .handled }
            }
            if session.handleShortcutKey(press.characters) {
                return .handled
            }
            if press.key == .space {
                if session.handleShortcutKey(" ") { return .handled }
            } else if press.key == .leftArrow {
                if session.handleShortcutKey("left") { return .handled }
            } else if press.key == .rightArrow {
                if session.handleShortcutKey("right") { return .handled }
            } else if press.key == .upArrow {
                if session.handleShortcutKey("up") { return .handled }
            } else if press.key == .downArrow {
                if session.handleShortcutKey("down") { return .handled }
            }
            return .ignored
        }
        .navigationTitle(session.currentFolderURL?.lastPathComponent ?? "Pickture")
        .toolbar {
            PicktureToolbarContent(
                session: session,
                horizontalSizeClass: horizontalSizeClass,
                isFolderImporterPresented: $isFolderImporterPresented,
                isSettingsPresented: $isSettingsPresented,
                onReopenRecentFolder: handleReopenRecentFolder
            )
        }
    }

    private var emptyFolderView: some View {
        ContentUnavailableView {
            Label("No MediaItems Found", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(
                session.subfolderMode == .immediate
                    ? "No supported RAW, raster, or video files in this folder. Try enabling Subfolder Mode to scan subdirectories."
                    : "No supported RAW, raster, or video files were found in this folder or its subdirectories."
            )
        } actions: {
            if session.subfolderMode == .immediate {
                Button("Enable Subfolder Mode") {
                    try? session.setSubfolderMode(.recursive)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Open Another Folder…") {
                isFolderImporterPresented = true
            }
        }
    }

    private var noMatchingItemsView: some View {
        ContentUnavailableView {
            Label("No Matching MediaItems", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No items match your active filter criteria. Try adjusting or resetting filters.")
        } actions: {
            Button("Reset Filters") {
                session.resetFilters()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
