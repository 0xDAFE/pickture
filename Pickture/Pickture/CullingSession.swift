import Foundation
import Observation

@MainActor
@Observable
final class CullingSession {
    let storageRootURL: URL
    private let folderAccessService: FolderAccessService
    let mediaCache: MediaCache
    let metadataSyncStore: MetadataSyncStore
    private(set) var currentFolderURL: URL?
    private(set) var items: [MediaItem] = []
    private(set) var recentFolders: [RecentFolder] = []
    private(set) var mediaCacheTotalBytes: Int64 = 0
    private(set) var cacheSizeLimitBytes: Int64 = MediaCache.defaultQuotaBytes
    private(set) var cacheGeneration: Int = 0
    var selectedItemID: String?
    var lastErrorMessage: String?
    private var metadataByItemID: [String: CurationMetadata] = [:]
    private var syncStateByItemID: [String: SyncState] = [:]
    var subfolderMode: SubfolderMode = .immediate
    var previewSource: PreviewSource = .preferRaster

    var formattedCacheUsage: String {
        ByteCountFormatter.string(fromByteCount: mediaCacheTotalBytes, countStyle: .file)
    }

    var formattedCacheLimit: String {
        ByteCountFormatter.string(fromByteCount: cacheSizeLimitBytes, countStyle: .file)
    }

    init(storageRootURL: URL? = nil, cacheDirectoryURL: URL? = nil) {
        let resolvedStorageRoot: URL
        let resolvedCacheDir: URL
        if let storageRootURL {
            resolvedStorageRoot = storageRootURL.standardizedFileURL
            resolvedCacheDir = (cacheDirectoryURL ?? resolvedStorageRoot.appendingPathComponent("MediaCache", isDirectory: true)).standardizedFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolvedStorageRoot = appSupport.appendingPathComponent("Pickture", isDirectory: true).standardizedFileURL
            let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolvedCacheDir = (cacheDirectoryURL ?? cachesRoot.appendingPathComponent("PicktureMediaCache", isDirectory: true)).standardizedFileURL
        }
        self.storageRootURL = resolvedStorageRoot
        self.folderAccessService = FolderAccessService(storageRootURL: resolvedStorageRoot)
        self.mediaCache = MediaCache(cacheDirectoryURL: resolvedCacheDir)
        self.metadataSyncStore = MetadataSyncStore(
            storeDirectoryURL: resolvedStorageRoot.appendingPathComponent("MetadataSyncStore", isDirectory: true)
        )
        self.recentFolders = self.folderAccessService.loadRecentFolders()
        self.mediaCacheTotalBytes = self.mediaCache.totalCachedBytes
        self.cacheSizeLimitBytes = self.mediaCache.cacheSizeLimitBytes
    }

    func thumbnailCacheKey(for item: MediaItem, maxPixelSize: Int = 360) -> String {
        let file = item.preferredFile(for: previewSource)
        return "\(file.id)#\(previewSource.rawValue)#\(maxPixelSize)"
    }

    func isThumbnailCached(for item: MediaItem, maxPixelSize: Int = 360) -> Bool {
        mediaCache.contains(key: thumbnailCacheKey(for: item, maxPixelSize: maxPixelSize))
    }

    func setCacheSizeLimitBytes(_ limitBytes: Int64) {
        mediaCache.setCacheSizeLimitBytes(limitBytes)
        self.cacheSizeLimitBytes = mediaCache.cacheSizeLimitBytes
        self.mediaCacheTotalBytes = mediaCache.totalCachedBytes
    }

    func setUserConfiguredCacheSizeLimitBytes(_ limitBytes: Int64) {
        let clamped = min(
            MediaCache.maxUserQuotaBytes,
            max(MediaCache.minUserQuotaBytes, limitBytes)
        )
        setCacheSizeLimitBytes(clamped)
    }

    func clearMediaCache() {
        mediaCache.clear()
        self.mediaCacheTotalBytes = mediaCache.totalCachedBytes
        self.cacheGeneration &+= 1
    }

    func stagePendingMetadata(_ metadata: CurationMetadata, for item: MediaItem) {
        metadataSyncStore.stagePendingWrite(metadata, for: item.id)
        metadataByItemID[item.id] = metadata
        syncStateByItemID[item.id] = .pendingWrite
    }

    func curationMetadata(for item: MediaItem) -> CurationMetadata {
        if let local = metadataByItemID[item.id] {
            return local
        }
        if let persisted = metadataSyncStore.record(for: item.id) {
            return persisted.metadata
        }
        return CurationMetadata()
    }

    func syncState(for item: MediaItem) -> SyncState {
        if let state = syncStateByItemID[item.id] {
            return state
        }
        if let persisted = metadataSyncStore.record(for: item.id) {
            return persisted.syncState
        }
        return .synced
    }

    func loadThumbnailData(for item: MediaItem, maxPixelSize: Int = 360) async -> Data? {
        let key = thumbnailCacheKey(for: item, maxPixelSize: maxPixelSize)
        if let cached = mediaCache.readData(forKey: key) {
            self.mediaCacheTotalBytes = mediaCache.totalCachedBytes
            return cached
        }
        let source = previewSource
        let extracted = await Task.detached(priority: .userInitiated) {
            await PreviewLoader.extractThumbnail(for: item, previewSource: source, maxPixelSize: maxPixelSize)
        }.value
        guard let extracted else {
            return nil
        }
        mediaCache.storeData(extracted.jpegData, forKey: key)
        self.mediaCacheTotalBytes = mediaCache.totalCachedBytes
        return extracted.jpegData
    }

    func openFolder(at url: URL) throws {
        let (resolvedURL, updatedRecents) = try folderAccessService.beginAccessingAndRecordFolder(at: url)
        try applyOpenedFolder(resolvedURL: resolvedURL, updatedRecents: updatedRecents)
    }

    func reopenRecentFolder(_ recentFolder: RecentFolder) throws {
        let (resolvedURL, updatedRecents) = try folderAccessService.resolveAndAccess(recentFolder: recentFolder)
        try applyOpenedFolder(resolvedURL: resolvedURL, updatedRecents: updatedRecents)
    }

    func removeRecentFolder(_ recentFolder: RecentFolder) {
        self.recentFolders = folderAccessService.removeRecentFolder(id: recentFolder.id)
    }

    private func applyOpenedFolder(resolvedURL: URL, updatedRecents: [RecentFolder]) throws {
        self.recentFolders = updatedRecents
        self.currentFolderURL = resolvedURL
        self.items = try discoverItems(in: resolvedURL.standardizedFileURL, mode: subfolderMode)
    }

    func setSubfolderMode(_ mode: SubfolderMode) throws {
        self.subfolderMode = mode
        if let currentFolderURL {
            self.items = try discoverItems(in: currentFolderURL.standardizedFileURL, mode: mode)
        }
    }

    func toggleSubfolderMode() throws {
        let next: SubfolderMode = (subfolderMode == .immediate) ? .recursive : .immediate
        try setSubfolderMode(next)
    }

    private func discoverItems(in rootURL: URL, mode: SubfolderMode) throws -> [MediaItem] {
        let fm = FileManager.default
        let directories = try collectDirectories(from: rootURL, mode: mode, fileManager: fm)
        var allItems: [MediaItem] = []

        for directoryURL in directories {
            let contents = try fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            var mediaFiles: [MediaFile] = []
            var sidecarByLowerBase: [String: URL] = [:]

            for fileURL in contents {
                let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    continue
                }
                let ext = fileURL.pathExtension.lowercased()
                if ext == "xmp" {
                    let baseLower = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                    sidecarByLowerBase[baseLower] = fileURL.standardizedFileURL
                    continue
                }
                guard let formatKind = MediaFormatKind.classify(fileExtension: ext) else {
                    continue
                }
                mediaFiles.append(MediaFile(url: fileURL, formatKind: formatKind))
            }

            let dirItems = Self.pairDirectoryMediaFiles(
                mediaFiles,
                sidecarsByLowerBase: sidecarByLowerBase,
                directoryURL: directoryURL,
                rootURL: rootURL
            )
            allItems.append(contentsOf: dirItems)
        }

        return allItems.sorted { lhs, rhs in
            let cmp = lhs.baseName.localizedStandardCompare(rhs.baseName)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            let dirCmp = lhs.relativeDirectoryPath.localizedStandardCompare(rhs.relativeDirectoryPath)
            if dirCmp != .orderedSame {
                return dirCmp == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private func collectDirectories(from rootURL: URL, mode: SubfolderMode, fileManager: FileManager) throws -> [URL] {
        let standardizedRoot = rootURL.standardizedFileURL
        guard mode == .recursive else {
            return [standardizedRoot]
        }

        var directories: [URL] = [standardizedRoot]
        let storagePathPrefix = storageRootURL.standardizedFileURL.path

        if let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                let standardized = url.standardizedFileURL
                if standardized.path.hasPrefix(storagePathPrefix) {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    directories.append(standardized)
                }
            }
        }

        return directories.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated static func pairDirectoryMediaFiles(
        _ files: [MediaFile],
        sidecarsByLowerBase: [String: URL],
        directoryURL: URL,
        rootURL: URL
    ) -> [MediaItem] {
        var photosByLowerBase: [String: [MediaFile]] = [:]
        var result: [MediaItem] = []

        let relativeDir: String = {
            let rootPath = rootURL.standardizedFileURL.path
            let dirPath = directoryURL.standardizedFileURL.path
            if dirPath == rootPath {
                return ""
            } else if dirPath.hasPrefix(rootPath + "/") {
                return String(dirPath.dropFirst(rootPath.count + 1))
            }
            return directoryURL.lastPathComponent
        }()

        for file in files {
            if file.formatKind == .video {
                let lowerBase = file.baseName.lowercased()
                result.append(
                    MediaItem(
                        id: file.id,
                        baseName: file.baseName,
                        directoryURL: directoryURL,
                        relativeDirectoryPath: relativeDir,
                        kind: .video,
                        primaryFile: file,
                        mediaPair: nil,
                        sidecarURL: sidecarsByLowerBase[lowerBase]
                    )
                )
            } else {
                photosByLowerBase[file.baseName.lowercased(), default: []].append(file)
            }
        }

        for (lowerBase, candidates) in photosByLowerBase {
            let raws = candidates
                .filter { $0.formatKind == .raw }
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            let rasters = candidates
                .filter { $0.formatKind == .raster }
                .sorted {
                    let p0 = MediaFormatKind.rasterPriority(fileExtension: $0.fileExtension)
                    let p1 = MediaFormatKind.rasterPriority(fileExtension: $1.fileExtension)
                    if p0 != p1 { return p0 < p1 }
                    return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                }

            let sidecarURL = sidecarsByLowerBase[lowerBase]

            if let primaryRaw = raws.first, let primaryRaster = rasters.first {
                let pair = MediaPair(rawFile: primaryRaw, rasterFile: primaryRaster)
                let itemID = "\(directoryURL.path)#pair:\(lowerBase)"
                result.append(
                    MediaItem(
                        id: itemID,
                        baseName: primaryRaw.baseName,
                        directoryURL: directoryURL,
                        relativeDirectoryPath: relativeDir,
                        kind: .photo,
                        primaryFile: primaryRaster,
                        mediaPair: pair,
                        sidecarURL: sidecarURL
                    )
                )

                // Preserve any additional unpaired files sharing the same basename in this directory
                let remainingFiles = Array(raws.dropFirst()) + Array(rasters.dropFirst())
                for extraFile in remainingFiles.sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }) {
                    result.append(
                        MediaItem(
                            id: extraFile.id,
                            baseName: extraFile.baseName,
                            directoryURL: directoryURL,
                            relativeDirectoryPath: relativeDir,
                            kind: .photo,
                            primaryFile: extraFile,
                            mediaPair: nil,
                            sidecarURL: sidecarURL
                        )
                    )
                }
            } else {
                for single in candidates.sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }) {
                    result.append(
                        MediaItem(
                            id: single.id,
                            baseName: single.baseName,
                            directoryURL: directoryURL,
                            relativeDirectoryPath: relativeDir,
                            kind: .photo,
                            primaryFile: single,
                            mediaPair: nil,
                            sidecarURL: sidecarURL
                        )
                    )
                }
            }
        }

        return result.sorted { lhs, rhs in
            let cmp = lhs.baseName.localizedStandardCompare(rhs.baseName)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}
