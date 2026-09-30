import CoreGraphics
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
    private var baseSnapshotByItemID: [String: BaseSnapshot] = [:]
    private var conflictsByItemID: [String: MetadataConflict] = [:]
    private var isFlushingPendingWrites: Bool = false
    var isSyncSuspended: Bool = false {
        didSet {
            if !isSyncSuspended {
                scheduleFlushPendingWrites()
            }
        }
    }
    var isConflictSheetPresented: Bool = false
    var activeConflictItemID: String?
    var subfolderMode: SubfolderMode = .immediate
    var previewSource: PreviewSource = .preferRaster
    var isBorderTapNavigationEnabled: Bool = true
    var viewMode: ViewMode = .grid
    var filmstripDockPosition: FilmstripDockPosition = .bottom
    var shortcutProfileKind: ShortcutProfileKind = .lightroom
    var customShortcutMappings: [String: SessionCommand] = [:]
    var isAutoAdvanceEnabled: Bool = false

    var activeShortcutProfile: ShortcutProfile {
        switch shortcutProfileKind {
        case .lightroom:
            return .lightroom
        case .captureOne:
            return .captureOne
        case .custom:
            return .custom(overrides: customShortcutMappings)
        }
    }

    var selectedItem: MediaItem? {
        if let id = selectedItemID, let found = items.first(where: { $0.id == id }) {
            return found
        }
        return items.first
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
    }

    func toggleViewMode() {
        viewMode = (viewMode == .grid) ? .filmstrip : .grid
    }

    func setFilmstripDockPosition(_ position: FilmstripDockPosition) {
        filmstripDockPosition = position
    }

    func setShortcutProfileKind(_ kind: ShortcutProfileKind) {
        shortcutProfileKind = kind
    }

    func setCustomShortcut(key: String, command: SessionCommand) {
        customShortcutMappings[key.lowercased()] = command
    }

    func toggleAutoAdvance() {
        isAutoAdvanceEnabled.toggle()
    }

    func togglePreviewSource() {
        previewSource = (previewSource == .preferRaster) ? .preferRAW : .preferRaster
    }

    func toggleBorderTapNavigation() {
        isBorderTapNavigationEnabled.toggle()
    }

    func borderTapZoneWidth(for containerWidth: CGFloat) -> CGFloat {
        min(containerWidth * 0.12, 64.0)
    }

    @discardableResult
    func handleBorderTap(at location: CGPoint, in containerSize: CGSize) -> Bool {
        guard isBorderTapNavigationEnabled else { return false }
        guard containerSize.width > 0 else { return false }
        let zoneWidth = borderTapZoneWidth(for: containerSize.width)
        if location.x <= zoneWidth {
            selectPreviousItem()
            return true
        } else if location.x >= (containerSize.width - zoneWidth) {
            selectNextItem()
            return true
        }
        return false
    }

    func selectNextItem() {
        guard !items.isEmpty else { return }
        guard let currentID = selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            selectedItemID = items.first?.id
            return
        }
        if currentIndex + 1 < items.count {
            selectedItemID = items[currentIndex + 1].id
        }
    }

    func selectPreviousItem() {
        guard !items.isEmpty else { return }
        guard let currentID = selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            selectedItemID = items.first?.id
            return
        }
        if currentIndex > 0 {
            selectedItemID = items[currentIndex - 1].id
        }
    }

    func selectFirstItem() {
        if let first = items.first {
            selectedItemID = first.id
        }
    }

    func selectLastItem() {
        if let last = items.last {
            selectedItemID = last.id
        }
    }

    @discardableResult
    func executeCommand(_ command: SessionCommand) -> Bool {
        switch command {
        case .curation(let action):
            guard let item = selectedItem else { return false }
            applyCurationAction(action, to: item)
            return true

        case .selectPrevious:
            selectPreviousItem()
            return true

        case .selectNext:
            selectNextItem()
            return true

        case .selectFirst:
            selectFirstItem()
            return true

        case .selectLast:
            selectLastItem()
            return true

        case .toggleViewMode:
            toggleViewMode()
            return true

        case .setViewMode(let mode):
            setViewMode(mode)
            return true

        case .togglePreviewSource:
            togglePreviewSource()
            return true

        case .setPreviewSource(let source):
            self.previewSource = source
            return true

        case .toggleAutoAdvance:
            toggleAutoAdvance()
            return true

        case .setAutoAdvance(let enabled):
            self.isAutoAdvanceEnabled = enabled
            return true

        case .toggleBorderTapNavigation:
            toggleBorderTapNavigation()
            return true
        }
    }

    @discardableResult
    func handleShortcutKey(_ rawKey: String) -> Bool {
        guard let command = activeShortcutProfile.command(for: rawKey) else {
            return false
        }
        return executeCommand(command)
    }

    func applyCurationAction(_ action: CurationAction, to item: MediaItem) {
        var current = curationMetadata(for: item)
        switch action {
        case .starRating(let rating):
            current.starRating = rating
        case .pickFlag(let flag):
            current.pickFlag = flag
        case .colorLabel(let label):
            current.colorLabel = label
        case .compound(let star, let flag, let label):
            if let star { current.starRating = star }
            if let flag { current.pickFlag = flag }
            if let label { current.colorLabel = label }
        }
        updateCurationMetadata(current, for: item)
        if isAutoAdvanceEnabled && (selectedItemID == nil || selectedItemID == item.id) {
            selectNextItem()
        }
    }

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

    func cachedThumbnailImage(for item: MediaItem, maxPixelSize: Int = 360) -> CGImage? {
        let key = thumbnailCacheKey(for: item, maxPixelSize: maxPixelSize)
        guard let cachedData = mediaCache.readData(forKey: key) else {
            return nil
        }
        self.mediaCacheTotalBytes = mediaCache.totalCachedBytes
        return PreviewLoader.decodeCGImage(from: cachedData)
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

    func setStarRating(_ rating: StarRating, for item: MediaItem) {
        applyCurationAction(.starRating(rating), to: item)
    }

    func setPickFlag(_ flag: PickFlag, for item: MediaItem) {
        applyCurationAction(.pickFlag(flag), to: item)
    }

    func setColorLabel(_ label: ColorLabel, for item: MediaItem) {
        applyCurationAction(.colorLabel(label), to: item)
    }

    func updateCurationMetadata(_ metadata: CurationMetadata, for item: MediaItem) {
        let base = baseSnapshot(for: item)
        metadataByItemID[item.id] = metadata
        syncStateByItemID[item.id] = .pendingWrite
        conflictsByItemID.removeValue(forKey: item.id)
        metadataSyncStore.stagePendingWrite(metadata, baseSnapshot: base, for: item.id)

        if !isSyncSuspended {
            scheduleFlushPendingWrites()
        }
    }

    func stagePendingMetadata(_ metadata: CurationMetadata, for item: MediaItem) {
        updateCurationMetadata(metadata, for: item)
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

    func baseSnapshot(for item: MediaItem) -> BaseSnapshot? {
        if let local = baseSnapshotByItemID[item.id] {
            return local
        }
        return metadataSyncStore.record(for: item.id)?.baseSnapshot
    }

    func conflict(for item: MediaItem) -> MetadataConflict? {
        if let local = conflictsByItemID[item.id] {
            return local
        }
        return metadataSyncStore.record(for: item.id)?.conflict
    }

    var pendingWritesCount: Int {
        items.filter { syncState(for: $0) == .pendingWrite }.count
    }

    var conflictedItemsCount: Int {
        items.filter { syncState(for: $0) == .conflicted }.count
    }

    var conflictedItems: [MediaItem] {
        items.filter { syncState(for: $0) == .conflicted }
    }

    var activeConflictItem: MediaItem? {
        guard let id = activeConflictItemID else { return conflictedItems.first }
        return items.first { $0.id == id } ?? conflictedItems.first
    }

    var syncSummaryState: SyncState {
        if conflictedItemsCount > 0 {
            return .conflicted
        }
        if items.contains(where: { syncState(for: $0) == .syncError }) {
            return .syncError
        }
        if items.contains(where: { syncState(for: $0) == .loading }) {
            return .loading
        }
        if pendingWritesCount > 0 {
            return .pendingWrite
        }
        return .synced
    }

    var syncSummaryBadgeText: String {
        let conflicts = conflictedItemsCount
        if conflicts > 0 {
            return "\(conflicts) Conflict\(conflicts == 1 ? "" : "s")"
        }
        let pending = pendingWritesCount
        if pending > 0 {
            return "\(pending) Pending"
        }
        let errors = items.filter { syncState(for: $0) == .syncError }.count
        if errors > 0 {
            return "\(errors) Error\(errors == 1 ? "" : "s")"
        }
        return "Synced"
    }

    func flushPendingWrites() async {
        guard !isFlushingPendingWrites else { return }
        isFlushingPendingWrites = true
        defer { isFlushingPendingWrites = false }

        let pending = items.filter { syncState(for: $0) == .pendingWrite }
        for item in pending {
            do {
                try await flushPendingWrite(for: item.id)
            } catch {
                syncStateByItemID[item.id] = .syncError
                metadataSyncStore.updateSyncState(.syncError, for: item.id)
                lastErrorMessage = "Sync error on \(item.displayFileName): \(error.localizedDescription)"
            }
        }
    }

    func flushPendingWrite(for itemID: String) async throws {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        let pendingCuration = curationMetadata(for: item)
        let base = baseSnapshot(for: item)

        syncStateByItemID[item.id] = .loading

        enum FlushOutcome: Sendable {
            case conflict(MetadataConflict)
            case success(BaseSnapshot)
        }

        let outcome = try await Task.detached(priority: .utility) { () -> FlushOutcome in
            let readURL = SidecarCodec.resolveSidecarReadURL(for: item)
            var diskCuration: CurationMetadata? = nil
            var diskDigest = ""

            if let readURL, let data = try? Data(contentsOf: readURL) {
                diskDigest = SidecarCodec.computeDigest(for: data)
                if let parsed = try? SidecarCodec.parse(data: data) {
                    diskCuration = parsed.curation
                }
            }

            let remoteDigestChanged = (base?.fileDigest != diskDigest)

            if let diskCuration, remoteDigestChanged {
                let conflict = XMPConflictEngine.evaluate(
                    itemID: item.id,
                    base: base,
                    local: pendingCuration,
                    remote: diskCuration,
                    remoteDigestChanged: true
                )
                if let conflict {
                    return .conflict(conflict)
                }
            }

            let writtenTargets = try SidecarCodec.write(curation: pendingCuration, for: item)

            if let primaryTarget = writtenTargets.first, let writtenData = try? Data(contentsOf: primaryTarget) {
                let newDigest = SidecarCodec.computeDigest(for: writtenData)
                let modDate = (try? primaryTarget.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let newBase = BaseSnapshot(metadata: pendingCuration, fileDigest: newDigest, modificationDate: modDate)
                return .success(newBase)
            } else {
                let fallbackBase = BaseSnapshot(metadata: pendingCuration, fileDigest: "")
                return .success(fallbackBase)
            }
        }.value

        switch outcome {
        case .conflict(let conflict):
            syncStateByItemID[item.id] = .conflicted
            conflictsByItemID[item.id] = conflict
            metadataSyncStore.recordConflict(conflict, for: item.id)

        case .success(let newBase):
            baseSnapshotByItemID[item.id] = newBase
            syncStateByItemID[item.id] = .synced
            conflictsByItemID.removeValue(forKey: item.id)
            metadataSyncStore.markSynced(for: item.id, baseSnapshot: newBase)
        }
    }

    func resolveConflict(for item: MediaItem, strategy: ConflictResolutionStrategy) async throws {
        guard let conflict = conflict(for: item) else { return }

        let resolvedMetadata: CurationMetadata
        let newBase: BaseSnapshot

        switch strategy {
        case .useRemote:
            resolvedMetadata = conflict.remote
            let readURL = SidecarCodec.resolveSidecarReadURL(for: item)
            let diskData = (try? readURL.flatMap { try? Data(contentsOf: $0) }) ?? Data()
            let digest = SidecarCodec.computeDigest(for: diskData)
            let modDate = readURL.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            newBase = BaseSnapshot(metadata: resolvedMetadata, fileDigest: digest, modificationDate: modDate)

        case .useLocal, .cherryPick:
            let chosen: CurationMetadata
            switch strategy {
            case .useLocal:
                chosen = conflict.local
            case .cherryPick(let custom):
                chosen = custom
            case .useRemote:
                chosen = conflict.remote
            }
            resolvedMetadata = chosen

            let writtenTargets = try await Task.detached(priority: .utility) {
                try SidecarCodec.write(curation: chosen, for: item)
            }.value

            let primaryTarget = writtenTargets.first ?? SidecarCodec.resolveSidecarReadURL(for: item)
            let writtenData = (try? primaryTarget.flatMap { try? Data(contentsOf: $0) }) ?? Data()
            let digest = SidecarCodec.computeDigest(for: writtenData)
            let modDate = primaryTarget.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            newBase = BaseSnapshot(metadata: resolvedMetadata, fileDigest: digest, modificationDate: modDate)
        }

        metadataByItemID[item.id] = resolvedMetadata
        syncStateByItemID[item.id] = .synced
        baseSnapshotByItemID[item.id] = newBase
        conflictsByItemID.removeValue(forKey: item.id)
        metadataSyncStore.resolveConflict(for: item.id, resolvedMetadata: resolvedMetadata, newBaseSnapshot: newBase)
    }

    func resolveAllConflicts(strategy: ConflictResolutionStrategy) async throws {
        for item in conflictedItems {
            try await resolveConflict(for: item, strategy: strategy)
        }
    }

    func resolveAllConflictsWithLocal() async throws {
        try await resolveAllConflicts(strategy: .useLocal)
    }

    func resolveAllConflictsWithRemote() async throws {
        try await resolveAllConflicts(strategy: .useRemote)
    }

    private func scheduleFlushPendingWrites() {
        guard !isSyncSuspended else { return }
        Task { [weak self] in
            await self?.flushPendingWrites()
        }
    }

    func refreshFolder() async throws {
        guard let currentFolderURL else { return }
        self.items = try discoverItems(in: currentFolderURL.standardizedFileURL, mode: subfolderMode)
        initializeMetadata(for: self.items)
        if !isSyncSuspended {
            await flushPendingWrites()
        }
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

    func previewCacheKey(for item: MediaItem, maxPixelSize: Int = 2048) -> String {
        let file = item.preferredFile(for: previewSource)
        return "\(file.id)#preview#\(previewSource.rawValue)#\(maxPixelSize)"
    }

    func cachedPreviewImage(for item: MediaItem, maxPixelSize: Int = 2048) -> CGImage? {
        let key = previewCacheKey(for: item, maxPixelSize: maxPixelSize)
        guard let cachedData = mediaCache.readData(forKey: key) else {
            return nil
        }
        self.mediaCacheTotalBytes = mediaCache.totalCachedBytes
        return PreviewLoader.decodeCGImage(from: cachedData)
    }

    func loadPreviewImageData(for item: MediaItem, maxPixelSize: Int = 2048) async -> Data? {
        let key = previewCacheKey(for: item, maxPixelSize: maxPixelSize)
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
        initializeMetadata(for: self.items)
        if !isSyncSuspended {
            scheduleFlushPendingWrites()
        }
    }

    func setSubfolderMode(_ mode: SubfolderMode) throws {
        self.subfolderMode = mode
        if let currentFolderURL {
            self.items = try discoverItems(in: currentFolderURL.standardizedFileURL, mode: mode)
            initializeMetadata(for: self.items)
            if !isSyncSuspended {
                scheduleFlushPendingWrites()
            }
        }
    }

    private func initializeMetadata(for items: [MediaItem]) {
        for item in items {
            let persisted = metadataSyncStore.record(for: item.id)
            let sidecarURL = SidecarCodec.resolveSidecarReadURL(for: item)

            var diskData: Data? = nil
            var diskCuration: CurationMetadata? = nil
            var diskExif: ExifMetadata? = nil
            var diskDigest = ""
            var diskModDate: Date? = nil

            if let sidecarURL, let data = try? Data(contentsOf: sidecarURL) {
                diskData = data
                diskDigest = SidecarCodec.computeDigest(for: data)
                diskModDate = (try? sidecarURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let parsed = try? SidecarCodec.parse(data: data) {
                    diskCuration = parsed.curation
                    diskExif = parsed.exif
                }
            }

            if let persisted {
                if persisted.syncState == .pendingWrite {
                    metadataByItemID[item.id] = persisted.metadata
                    syncStateByItemID[item.id] = .pendingWrite
                    baseSnapshotByItemID[item.id] = persisted.baseSnapshot

                    // Check if external edit happened on disk while pending
                    if let diskCuration, let base = persisted.baseSnapshot {
                        let remoteChanged = diskDigest != base.fileDigest
                        if remoteChanged, let conflict = XMPConflictEngine.evaluate(
                            itemID: item.id,
                            base: base,
                            local: persisted.metadata,
                            remote: diskCuration,
                            remoteDigestChanged: true
                        ) {
                            syncStateByItemID[item.id] = .conflicted
                            conflictsByItemID[item.id] = conflict
                            metadataSyncStore.recordConflict(conflict, for: item.id)
                        }
                    }
                } else if persisted.syncState == .conflicted, let conflict = persisted.conflict {
                    metadataByItemID[item.id] = persisted.metadata
                    syncStateByItemID[item.id] = .conflicted
                    conflictsByItemID[item.id] = conflict
                    baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                } else {
                    if let diskCuration {
                        let snapshot = BaseSnapshot(metadata: diskCuration, fileDigest: diskDigest, modificationDate: diskModDate)
                        metadataByItemID[item.id] = diskCuration
                        syncStateByItemID[item.id] = .synced
                        baseSnapshotByItemID[item.id] = snapshot
                        metadataSyncStore.recordBaseSnapshot(snapshot, exif: diskExif, for: item.id)
                    } else {
                        metadataByItemID[item.id] = persisted.metadata
                        syncStateByItemID[item.id] = .synced
                        baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                    }
                }
            } else {
                if let diskCuration {
                    let snapshot = BaseSnapshot(metadata: diskCuration, fileDigest: diskDigest, modificationDate: diskModDate)
                    metadataByItemID[item.id] = diskCuration
                    syncStateByItemID[item.id] = .synced
                    baseSnapshotByItemID[item.id] = snapshot
                    metadataSyncStore.recordBaseSnapshot(snapshot, exif: diskExif, for: item.id)
                } else {
                    let emptySnapshot = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
                    metadataByItemID[item.id] = CurationMetadata()
                    syncStateByItemID[item.id] = .synced
                    baseSnapshotByItemID[item.id] = emptySnapshot
                    metadataSyncStore.recordBaseSnapshot(emptySnapshot, exif: nil, for: item.id)
                }
            }
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
            var sidecarsByLowerBase: [String: URL] = [:]

            for fileURL in contents {
                let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    continue
                }
                let ext = fileURL.pathExtension.lowercased()
                if ext == "xmp" {
                    let baseLower = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                    sidecarsByLowerBase[baseLower] = fileURL.standardizedFileURL
                    continue
                }
                guard let formatKind = MediaFormatKind.classify(fileExtension: ext) else {
                    continue
                }
                mediaFiles.append(MediaFile(url: fileURL, formatKind: formatKind))
            }

            let dirItems = Self.pairDirectoryMediaFiles(
                mediaFiles,
                sidecarsByLowerBase: sidecarsByLowerBase,
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
                let item = MediaItem(
                    id: file.id,
                    baseName: file.baseName,
                    directoryURL: directoryURL,
                    relativeDirectoryPath: relativeDir,
                    kind: .video,
                    primaryFile: file,
                    mediaPair: nil,
                    sidecarURL: nil
                )
                let sidecar = SidecarCodec.resolveSidecarReadURL(for: item) ?? sidecarsByLowerBase[lowerBase]
                result.append(
                    MediaItem(
                        id: file.id,
                        baseName: file.baseName,
                        directoryURL: directoryURL,
                        relativeDirectoryPath: relativeDir,
                        kind: .video,
                        primaryFile: file,
                        mediaPair: nil,
                        sidecarURL: sidecar
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

            if let primaryRaw = raws.first, let primaryRaster = rasters.first {
                let pair = MediaPair(rawFile: primaryRaw, rasterFile: primaryRaster)
                let itemID = "\(directoryURL.path)#pair:\(lowerBase)"
                let pairItem = MediaItem(
                    id: itemID,
                    baseName: primaryRaw.baseName,
                    directoryURL: directoryURL,
                    relativeDirectoryPath: relativeDir,
                    kind: .photo,
                    primaryFile: primaryRaster,
                    mediaPair: pair,
                    sidecarURL: nil
                )
                let sidecarURL = SidecarCodec.resolveSidecarReadURL(for: pairItem) ?? sidecarsByLowerBase[lowerBase]

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
                    let extraItem = MediaItem(
                        id: extraFile.id,
                        baseName: extraFile.baseName,
                        directoryURL: directoryURL,
                        relativeDirectoryPath: relativeDir,
                        kind: .photo,
                        primaryFile: extraFile,
                        mediaPair: nil,
                        sidecarURL: nil
                    )
                    let extraSidecar = SidecarCodec.resolveSidecarReadURL(for: extraItem) ?? sidecarsByLowerBase[lowerBase]
                    result.append(
                        MediaItem(
                            id: extraFile.id,
                            baseName: extraFile.baseName,
                            directoryURL: directoryURL,
                            relativeDirectoryPath: relativeDir,
                            kind: .photo,
                            primaryFile: extraFile,
                            mediaPair: nil,
                            sidecarURL: extraSidecar
                        )
                    )
                }
            } else {
                for single in candidates.sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }) {
                    let singleItem = MediaItem(
                        id: single.id,
                        baseName: single.baseName,
                        directoryURL: directoryURL,
                        relativeDirectoryPath: relativeDir,
                        kind: .photo,
                        primaryFile: single,
                        mediaPair: nil,
                        sidecarURL: nil
                    )
                    let singleSidecar = SidecarCodec.resolveSidecarReadURL(for: singleItem) ?? sidecarsByLowerBase[lowerBase]
                    result.append(
                        MediaItem(
                            id: single.id,
                            baseName: single.baseName,
                            directoryURL: directoryURL,
                            relativeDirectoryPath: relativeDir,
                            kind: .photo,
                            primaryFile: single,
                            mediaPair: nil,
                            sidecarURL: singleSidecar
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
