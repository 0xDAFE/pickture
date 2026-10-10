import Foundation

/// Encapsulates directory traversal, cache folder skipping, and MediaPair matching
/// behind a deep module seam.
nonisolated enum MediaDiscovery {

    struct DiscoveredBatch: Sendable {
        let items: [MediaItem]
        let progress: Double
    }

    /// Discovers media items across a directory tree according to the specified SubfolderMode.
    static func discoverItems(
        in rootURL: URL,
        mode: SubfolderMode,
        storageRootURL: URL,
        fileManager: FileManager = FileManager()
    ) throws -> [MediaItem] {
        let directories = try collectDirectories(
            from: rootURL,
            mode: mode,
            storageRootURL: storageRootURL,
            fileManager: fileManager
        )
        var allItems: [MediaItem] = []

        for directoryURL in directories {
            let dirItems = try discoverItems(
                inSingleDirectory: directoryURL,
                rootURL: rootURL,
                fileManager: fileManager
            )
            allItems.append(contentsOf: dirItems)
        }

        return allItems.sorted(by: Self.mediaItemSortComparator)
    }

    /// Discovers media items strictly within a single directory, pairing RAW + raster files sharing a common basename.
    static func discoverItems(
        inSingleDirectory directoryURL: URL,
        rootURL: URL,
        fileManager: FileManager = FileManager()
    ) throws -> [MediaItem] {
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var mediaFiles: [MediaFile] = []
        var sidecarsByLowerBase: [String: URL] = [:]
        var exactBasenameSidecars: Set<String> = []

        for fileURL in contents {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if ext == "xmp" {
                let urlWithoutXmp = fileURL.deletingPathExtension()
                let nameWithoutXmp = urlWithoutXmp.lastPathComponent
                let innerExt = urlWithoutXmp.pathExtension.lowercased()
                let isDarktableFormat = !innerExt.isEmpty && MediaFormatKind.classify(fileExtension: innerExt) != nil

                if isDarktableFormat {
                    let fileKey = nameWithoutXmp.lowercased()
                    let doubleBase = urlWithoutXmp.deletingPathExtension().lastPathComponent.lowercased()
                    sidecarsByLowerBase[fileKey] = fileURL.standardizedFileURL
                    // Only populate doubleBase fallback if not already claimed by an exact <basename>.xmp
                    if !exactBasenameSidecars.contains(doubleBase) && sidecarsByLowerBase[doubleBase] == nil {
                        sidecarsByLowerBase[doubleBase] = fileURL.standardizedFileURL
                    }
                } else {
                    let baseLower = nameWithoutXmp.lowercased()
                    sidecarsByLowerBase[baseLower] = fileURL.standardizedFileURL
                    exactBasenameSidecars.insert(baseLower)
                }
                continue
            }
            guard let formatKind = MediaFormatKind.classify(fileExtension: ext) else {
                continue
            }
            mediaFiles.append(MediaFile(url: fileURL, formatKind: formatKind))
        }

        return Self.pairDirectoryMediaFiles(
            mediaFiles,
            sidecarsByLowerBase: sidecarsByLowerBase,
            directoryURL: directoryURL,
            rootURL: rootURL
        )
    }

    /// Deterministic comparator for MediaItems: primary sort by baseName, secondary by relative directory path, fallback to ID.
    static func mediaItemSortComparator(lhs: MediaItem, rhs: MediaItem) -> Bool {
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

    /// Returns true if a directory name matches known non-media cache directories that must be skipped.
    static func isIgnoredNonMediaDirectory(name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".lrdata") || lower.hasSuffix(".lrcat") {
            return true
        }
        if lower == "captureone" || lower.hasPrefix("captureone") {
            return true
        }
        if lower == "@eadir" || lower.contains("@eadir") {
            return true
        }
        if lower == ".trashes" || lower == ".spotlight-v100" || lower == ".fseventsd" || lower == ".temporaryitems" {
            return true
        }
        return false
    }

    /// Collects candidate directories according to SubfolderMode, skipping internal storage and non-media cache bundles.
    static func collectDirectories(
        from rootURL: URL,
        mode: SubfolderMode,
        storageRootURL: URL,
        fileManager: FileManager = FileManager()
    ) throws -> [URL] {
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
                if standardized.path.hasPrefix(storagePathPrefix) || Self.isIgnoredNonMediaDirectory(name: standardized.lastPathComponent) {
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

    /// Streams discovered items asynchronously in directory batches.
    /// Traversal runs in Task.detached at .userInitiated priority with an isolated FileManager
    /// to eliminate Main Thread NAS beachballs and stream results progressively to the UI.
    static func streamDiscoveredItems(
        from rootURL: URL,
        mode: SubfolderMode,
        storageRootURL: URL,
        fileManager: FileManager = FileManager()
    ) -> AsyncThrowingStream<DiscoveredBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let fm = fileManager
                    let standardizedRoot = rootURL.standardizedFileURL
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: standardizedRoot.path, isDirectory: &isDir), isDir.boolValue else {
                        continuation.finish(throwing: CocoaError(.fileReadNoSuchFile))
                        return
                    }

                    let directories = try collectDirectories(
                        from: standardizedRoot,
                        mode: mode,
                        storageRootURL: storageRootURL,
                        fileManager: fm
                    )
                    let totalDirs = max(directories.count, 1)

                    for (index, dirURL) in directories.enumerated() {
                        if Task.isCancelled { break }
                        let dirItems = try discoverItems(
                            inSingleDirectory: dirURL,
                            rootURL: standardizedRoot,
                            fileManager: fm
                        )
                        let progress = Double(index + 1) / Double(totalDirs)
                        continuation.yield(DiscoveredBatch(items: dirItems, progress: progress))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Pairs RAW + raster files sharing a common basename within a single directory,
    /// isolating video files as standalone items and preserving any additional unpaired files.
    static func pairDirectoryMediaFiles(
        _ files: [MediaFile],
        sidecarsByLowerBase: [String: URL],
        directoryURL: URL,
        rootURL: URL
    ) -> [MediaItem] {
        var mediaFilesByLowerBase: [String: [MediaFile]] = [:]
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

        func resolveSidecarURL(for item: MediaItem, lowerBase: String) -> URL? {
            if let sidecar = sidecarsByLowerBase[lowerBase] {
                return sidecar
            }
            let primaryFileNameKey = item.primaryFile.fileName.lowercased()
            if let sidecar = sidecarsByLowerBase[primaryFileNameKey] {
                return sidecar
            }
            if let rawFile = item.mediaPair?.rawFile {
                let rawFileNameKey = rawFile.fileName.lowercased()
                if let sidecar = sidecarsByLowerBase[rawFileNameKey] {
                    return sidecar
                }
            }
            return SidecarCodec.resolveSidecarReadURL(for: item)
        }

        func makeItem(
            id: String,
            baseName: String,
            kind: MediaKind,
            primaryFile: MediaFile,
            mediaPair: MediaPair?
        ) -> MediaItem {
            let lowerBase = baseName.lowercased()
            let prototype = MediaItem(
                id: id,
                baseName: baseName,
                directoryURL: directoryURL,
                relativeDirectoryPath: relativeDir,
                kind: kind,
                primaryFile: primaryFile,
                mediaPair: mediaPair,
                sidecarURL: nil
            )
            let sidecarURL = resolveSidecarURL(for: prototype, lowerBase: lowerBase)
            return MediaItem(
                id: id,
                baseName: baseName,
                directoryURL: directoryURL,
                relativeDirectoryPath: relativeDir,
                kind: kind,
                primaryFile: primaryFile,
                mediaPair: mediaPair,
                sidecarURL: sidecarURL
            )
        }

        for file in files {
            if file.formatKind == .video {
                result.append(
                    makeItem(
                        id: file.id,
                        baseName: file.baseName,
                        kind: .video,
                        primaryFile: file,
                        mediaPair: nil
                    )
                )
            } else {
                mediaFilesByLowerBase[file.baseName.lowercased(), default: []].append(file)
            }
        }

        for (lowerBase, candidates) in mediaFilesByLowerBase {
            let raws = candidates
                .filter { $0.formatKind == .raw }
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            let rasters = candidates
                .filter { $0.formatKind == .raster }
                .sorted {
                    let lhsPriority = MediaFormatKind.rasterPriority(fileExtension: $0.fileExtension)
                    let rhsPriority = MediaFormatKind.rasterPriority(fileExtension: $1.fileExtension)
                    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                    return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                }

            if let primaryRaw = raws.first, let primaryRaster = rasters.first {
                let pair = MediaPair(rawFile: primaryRaw, rasterFile: primaryRaster)
                let itemID = "\(directoryURL.path)#pair:\(lowerBase)"
                result.append(
                    makeItem(
                        id: itemID,
                        baseName: primaryRaw.baseName,
                        kind: .photo,
                        primaryFile: primaryRaster,
                        mediaPair: pair
                    )
                )

                // Preserve any additional unpaired files sharing the same basename in this directory
                let remainingFiles = Array(raws.dropFirst()) + Array(rasters.dropFirst())
                for extraFile in remainingFiles.sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }) {
                    result.append(
                        makeItem(
                            id: extraFile.id,
                            baseName: extraFile.baseName,
                            kind: .photo,
                            primaryFile: extraFile,
                            mediaPair: nil
                        )
                    )
                }
            } else {
                for single in candidates.sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }) {
                    result.append(
                        makeItem(
                            id: single.id,
                            baseName: single.baseName,
                            kind: .photo,
                            primaryFile: single,
                            mediaPair: nil
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
