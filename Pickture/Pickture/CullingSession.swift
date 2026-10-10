import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CullingSession {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pickture", category: "sync")
    let storageRootURL: URL
    private let folderAccessService: FolderAccessService
    let mediaPipeline: MediaPipeline
    var mediaCache: MediaCache { mediaPipeline.cache }
    let metadataSyncStore: MetadataSyncStore
    private(set) var currentFolderURL: URL?
    private(set) var items: [MediaItem] = [] {
        didSet {
            refreshDerivedCounts()
        }
    }
    private(set) var recentFolders: [RecentFolder] = []
    private(set) var mediaCacheTotalBytes: Int64 = 0
    private(set) var cacheSizeLimitBytes: Int64 = MediaCache.defaultQuotaBytes
    private(set) var cacheGeneration: Int = 0

    var cacheSizeLimitMegabytes: Double {
        get {
            Double(cacheSizeLimitBytes) / (1_024.0 * 1_024.0)
        }
        set {
            setUserConfiguredCacheSizeLimitBytes(Int64(newValue * 1_024.0 * 1_024.0))
        }
    }

    var isRecursiveSubfolderMode: Bool {
        get {
            subfolderMode == .recursive
        }
        set {
            let targetMode: SubfolderMode = newValue ? .recursive : .immediate
            guard subfolderMode != targetMode else { return }
            subfolderMode = targetMode
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.rediscoverItemsForSubfolderModeChange()
                } catch {
                    self.lastErrorMessage = "Failed to switch subfolder mode: \(error.localizedDescription)"
                }
            }
        }
    }

    private(set) var visibleMediaPairCount: Int = 0
    private(set) var visibleVideoCount: Int = 0
    private(set) var conflictedItemsCount: Int = 0
    private(set) var pendingWritesCount: Int = 0

    var selectedItemID: String?
    var lastErrorMessage: String?
    var filterCriteria: FilterCriteria = FilterCriteria() {
        didSet {
            refreshDerivedCounts()
        }
    }
    var sortOption: SortOption = SortOption(field: .fileName, order: .ascending)
    var isSearchFieldFocused: Bool = false
    private var exifByItemID: [String: ExifMetadata] = [:]
    private var headerSupplementedItemIDs: Set<String> = []
    private var metadataByItemID: [String: CurationMetadata] = [:]
    private var syncStateByItemID: [String: SyncState] = [:]
    private var baseSnapshotByItemID: [String: BaseSnapshot] = [:]
    private var conflictsByItemID: [String: MetadataConflict] = [:]
    private var thumbnailAspectRatios: [String: CGFloat] = [:]
    private(set) var isFlushingPendingWrites: Bool = false
    private var activeFlushTask: Task<Void, Never>? = nil
    private(set) var isDiscovering: Bool = false
    private(set) var openFolderProgress: Double? = nil
    var isLazySidecarHydrationEnabled: Bool = false
    private(set) var isExifPreloading: Bool = false
    private var backgroundExifTask: Task<Void, Never>? = nil
    var flushDebounceNanoseconds: UInt64 = 500_000_000
    private var debouncedFlushTask: Task<Void, Never>? = nil
    private var backgroundHydrationTask: Task<Void, Never>? = nil
    var isAccessingFolder: Bool {
        folderAccessService.isAccessingFolder
    }
    /// Testing hook to simulate slow I/O or network file sync during session flush.
    var simulatedFlushDelayNanoseconds: UInt64 = 0
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
    var isSwipeModeEnabled: Bool = false
    var swipeRightAction: CurationAction = .setPickFlag(.picked)
    var swipeLeftAction: CurationAction = .setPickFlag(.rejected)
    private(set) var swipeHistory: [SwipeRecord] = []

    var canUndoSwipe: Bool {
        !swipeHistory.isEmpty
    }

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
        let currentVisible = visibleItems
        if let id = selectedItemID, let found = currentVisible.first(where: { $0.id == id }) {
            return found
        }
        return currentVisible.first
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

    func toggleSwipeMode() {
        isSwipeModeEnabled.toggle()
    }

    func setSwipeMode(_ enabled: Bool) {
        isSwipeModeEnabled = enabled
    }

    func setSwipeRightAction(_ action: CurationAction) {
        swipeRightAction = action
    }

    func setSwipeLeftAction(_ action: CurationAction) {
        swipeLeftAction = action
    }

    func borderTapZoneWidth(for containerWidth: CGFloat) -> CGFloat {
        min(containerWidth * 0.12, 64.0)
    }

    func filmstripThumbnailSize(
        aspectRatio: CGFloat,
        dockPosition: FilmstripDockPosition,
        mediaKind: MediaKind? = nil
    ) -> CGSize {
        CullingLayoutCalculator.filmstripThumbnailSize(
            aspectRatio: aspectRatio,
            dockPosition: dockPosition,
            mediaKind: mediaKind ?? .photo
        )
    }

    func fallbackAspectRatio(for kind: MediaKind) -> CGFloat {
        CullingLayoutCalculator.fallbackAspectRatio(for: kind)
    }

    func fallbackAspectRatio(for item: MediaItem) -> CGFloat {
        fallbackAspectRatio(for: item.kind)
    }

    func thumbnailAspectRatio(for item: MediaItem) -> CGFloat {
        if let cachedRatio = thumbnailAspectRatios[item.id] {
            return cachedRatio
        }
        if let cachedImage = cachedThumbnailImage(for: item, maxPixelSize: 360) {
            let ratio = cachedImage.aspectRatio
            thumbnailAspectRatios[item.id] = ratio
            return ratio
        }
        return fallbackAspectRatio(for: item)
    }

    func recordThumbnailAspectRatio(_ ratio: CGFloat, for itemID: String) {
        if !ratio.isNaN && !ratio.isInfinite && ratio > 0 {
            thumbnailAspectRatios[itemID] = ratio
        }
    }

    func filmstripThumbnailSize(for item: MediaItem, dockPosition: FilmstripDockPosition? = nil) -> CGSize {
        let position = dockPosition ?? self.filmstripDockPosition
        let ratio = thumbnailAspectRatio(for: item)
        return filmstripThumbnailSize(aspectRatio: ratio, dockPosition: position, mediaKind: item.kind)
    }

    // MARK: - Grid Cell Layout Metrics (Frameless Floating Canvas & Uniform Baseline Shelf)

    /// Fixed height for the metadata deck (Row 1: filename, Row 2: interactive curation toolbar).
    /// Pinned height guarantees that across any row of the grid, filenames and toolbars align to an exact pixel-matched horizontal line.
    var gridMetadataDeckHeight: CGFloat {
        48.0
    }

    /// Returns the uniform Image Stage height for a given column width in the adaptive grid.
    /// The standard 4:3 stage ceiling provides balanced vertical headroom for both landscape
    /// and portrait media without layout explosion.
    func gridStageHeight(for columnWidth: CGFloat) -> CGFloat {
        CullingLayoutCalculator.gridStageHeight(for: columnWidth)
    }

    /// Computes the exact silhouette size of a media item floating inside the bounded Image Stage,
    /// preserving its true uncropped aspect ratio while resting on the uniform baseline shelf.
    func gridItemSilhouetteSize(
        aspectRatio: CGFloat,
        stageWidth: CGFloat,
        stageHeight: CGFloat,
        mediaKind: MediaKind? = nil
    ) -> CGSize {
        CullingLayoutCalculator.gridItemSilhouetteSize(
            aspectRatio: aspectRatio,
            stageWidth: stageWidth,
            stageHeight: stageHeight,
            mediaKind: mediaKind ?? .photo
        )
    }

    /// Convenience method to compute the silhouette size for a MediaItem given the column width.
    func gridItemSilhouetteSize(for item: MediaItem, columnWidth: CGFloat) -> CGSize {
        let ratio = thumbnailAspectRatio(for: item)
        let stageHeight = gridStageHeight(for: columnWidth)
        return gridItemSilhouetteSize(
            aspectRatio: ratio,
            stageWidth: columnWidth,
            stageHeight: stageHeight,
            mediaKind: item.kind
        )
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
        let currentVisible = visibleItems
        guard !currentVisible.isEmpty else { return }
        guard let currentID = selectedItemID,
              let currentIndex = currentVisible.firstIndex(where: { $0.id == currentID }) else {
            selectedItemID = currentVisible.first?.id
            return
        }
        if currentIndex + 1 < currentVisible.count {
            selectedItemID = currentVisible[currentIndex + 1].id
        }
    }

    func selectPreviousItem() {
        let currentVisible = visibleItems
        guard !currentVisible.isEmpty else { return }
        guard let currentID = selectedItemID,
              let currentIndex = currentVisible.firstIndex(where: { $0.id == currentID }) else {
            selectedItemID = currentVisible.first?.id
            return
        }
        if currentIndex > 0 {
            selectedItemID = currentVisible[currentIndex - 1].id
        }
    }

    func selectFirstItem() {
        if let first = visibleItems.first {
            selectedItemID = first.id
        }
    }

    func selectLastItem() {
        if let last = visibleItems.last {
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

        case .toggleSwipeMode:
            toggleSwipeMode()
            return true

        case .setSwipeMode(let enabled):
            setSwipeMode(enabled)
            return true

        case .undoLastSwipe:
            return undoLastSwipe()
        }
    }

    @discardableResult
    func handleShortcutKey(_ rawKey: String) -> Bool {
        guard let command = activeShortcutProfile.command(for: rawKey) else {
            return false
        }
        return executeCommand(command)
    }

    func applyCurationAction(_ action: CurationAction, to item: MediaItem, shouldAutoAdvance: Bool = true) {
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
        if shouldAutoAdvance && isAutoAdvanceEnabled && (selectedItemID == nil || selectedItemID == item.id) {
            selectNextItem()
        }
    }

    @discardableResult
    func executeSwipe(_ direction: SwipeDirection) -> Bool {
        guard let item = selectedItem else { return false }
        return executeSwipe(direction, for: item)
    }

    @discardableResult
    func executeSwipe(_ direction: SwipeDirection, for item: MediaItem) -> Bool {
        let action = (direction == .right) ? swipeRightAction : swipeLeftAction
        let prev = curationMetadata(for: item)
        applyCurationAction(action, to: item, shouldAutoAdvance: false)
        let record = SwipeRecord(
            itemID: item.id,
            previousMetadata: prev,
            appliedAction: action,
            direction: direction
        )
        swipeHistory.append(record)
        selectNextItem()
        return true
    }

    @discardableResult
    func undoLastSwipe() -> Bool {
        guard let last = swipeHistory.popLast() else { return false }
        guard let item = items.first(where: { $0.id == last.itemID }) else { return false }
        updateCurationMetadata(last.previousMetadata, for: item)
        selectedItemID = last.itemID
        return true
    }

    var formattedCacheUsage: String {
        ByteCountFormatter.string(fromByteCount: mediaCacheTotalBytes, countStyle: .file)
    }

    var formattedCacheLimit: String {
        ByteCountFormatter.string(fromByteCount: cacheSizeLimitBytes, countStyle: .file)
    }

    init(storageRootURL: URL? = nil, cacheDirectoryURL: URL? = nil, subfolderMode: SubfolderMode = .immediate) {
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
        self.subfolderMode = subfolderMode
        self.storageRootURL = resolvedStorageRoot
        self.folderAccessService = FolderAccessService(storageRootURL: resolvedStorageRoot)
        self.mediaPipeline = MediaPipeline(cacheDirectoryURL: resolvedCacheDir)
        self.metadataSyncStore = MetadataSyncStore(
            storeDirectoryURL: resolvedStorageRoot.appendingPathComponent("MetadataSyncStore", isDirectory: true)
        )
        self.recentFolders = self.folderAccessService.loadRecentFolders()
        self.mediaCacheTotalBytes = self.mediaPipeline.totalCachedBytes
        self.cacheSizeLimitBytes = self.mediaPipeline.cacheSizeLimitBytes
    }

    func thumbnailCacheKey(for item: MediaItem, maxPixelSize: Int = 360) -> String {
        mediaPipeline.thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func isThumbnailCached(for item: MediaItem, maxPixelSize: Int = 360) -> Bool {
        mediaPipeline.isThumbnailCached(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func cachedThumbnailImage(for item: MediaItem, maxPixelSize: Int = 360) -> CGImage? {
        let image = mediaPipeline.cachedThumbnailImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        self.mediaCacheTotalBytes = mediaPipeline.totalCachedBytes
        return image
    }

    func setCacheSizeLimitBytes(_ limitBytes: Int64) {
        mediaPipeline.setCacheSizeLimitBytes(limitBytes)
        self.cacheSizeLimitBytes = mediaPipeline.cacheSizeLimitBytes
        self.mediaCacheTotalBytes = mediaPipeline.totalCachedBytes
    }

    func setUserConfiguredCacheSizeLimitBytes(_ limitBytes: Int64) {
        mediaPipeline.setUserConfiguredCacheSizeLimitBytes(limitBytes)
        self.cacheSizeLimitBytes = mediaPipeline.cacheSizeLimitBytes
        self.mediaCacheTotalBytes = mediaPipeline.totalCachedBytes
    }

    func clearMediaCache() {
        mediaPipeline.clearCache()
        thumbnailAspectRatios.removeAll()
        self.mediaCacheTotalBytes = mediaPipeline.totalCachedBytes
        self.cacheGeneration &+= 1
    }

    /// Flushes the thumbnail cache index immediately to disk.
    /// Called on session close, background transition, or application termination.
    func flushMediaCacheIndex() {
        mediaPipeline.flushIndexImmediately()
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
        refreshDerivedCounts()

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

    func exifMetadata(for item: MediaItem) -> ExifMetadata {
        if headerSupplementedItemIDs.contains(item.id) {
            return exifByItemID[item.id] ?? ExifMetadata()
        }

        let existing = exifByItemID[item.id] ?? metadataSyncStore.record(for: item.id)?.exif ?? ExifMetadata()
        // If already completely populated across all fields, no header read needed
        if existing.cameraModel != nil && existing.lensModel != nil && existing.dateTimeOriginal != nil && !existing.isoSpeedRatings.isEmpty && existing.focalLength != nil {
            headerSupplementedItemIDs.insert(item.id)
            exifByItemID[item.id] = existing
            return existing
        }

        // Lazy supplementation via header-only extraction (preferring raster in MediaPair or RAW header bytes)
        let headerExif = ExifHeaderExtractor.extractHeaderExif(for: item)
        let resolved = existing.supplementing(with: headerExif)

        headerSupplementedItemIDs.insert(item.id)
        exifByItemID[item.id] = resolved
        metadataSyncStore.recordExif(resolved, for: item.id)
        return resolved
    }

    /// Preloads EXIF metadata in the background off the MainActor.
    /// Runs via Task.detached at .utility priority so network-bound header reads over NAS/SMB
    /// do not inherit @MainActor isolation or block UI event processing.
    func startBackgroundExifPreloading(for targetItems: [MediaItem]) {
        backgroundExifTask?.cancel()
        let itemsToLoad = targetItems.filter { item in
            guard item.kind != .video else { return false }
            if headerSupplementedItemIDs.contains(item.id) { return false }
            let existing = exifByItemID[item.id] ?? metadataSyncStore.record(for: item.id)?.exif ?? ExifMetadata()
            if existing.cameraModel != nil && existing.lensModel != nil && existing.dateTimeOriginal != nil && !existing.isoSpeedRatings.isEmpty && existing.focalLength != nil {
                headerSupplementedItemIDs.insert(item.id)
                exifByItemID[item.id] = existing
                return false
            }
            return true
        }
        guard !itemsToLoad.isEmpty else {
            isExifPreloading = false
            return
        }

        isExifPreloading = true
        backgroundExifTask = Task.detached(priority: .utility) { [weak self] in
            let extracted = await ExifHeaderExtractor.extractBatch(for: itemsToLoad)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.isExifPreloading = false
                self.backgroundExifTask = nil
                for (itemID, headerExif) in extracted {
                    let existing = self.exifByItemID[itemID] ?? self.metadataSyncStore.record(for: itemID)?.exif ?? ExifMetadata()
                    let merged = existing.supplementing(with: headerExif)
                    self.headerSupplementedItemIDs.insert(itemID)
                    self.exifByItemID[itemID] = merged
                    self.metadataSyncStore.recordExif(merged, for: itemID)
                }
                if self.filterCriteria.isCameraModelActive || self.filterCriteria.isLensModelActive {
                    self.refreshDerivedCounts()
                }
            }
        }
    }

    func captureDate(for item: MediaItem) -> Date? {
        exifMetadata(for: item).dateTimeOriginal
    }

    var visibleItems: [MediaItem] {
        let needsExif = filterCriteria.isCameraModelActive || filterCriteria.isLensModelActive || sortOption.field == .captureDate
        let filtered = items.filter { item in
            let curation = curationMetadata(for: item)
            let exif = needsExif ? exifMetadata(for: item) : (exifByItemID[item.id] ?? metadataSyncStore.record(for: item.id)?.exif)
            let sync = syncState(for: item)
            return filterCriteria.matches(item: item, curation: curation, exif: exif, syncState: sync)
        }

        return filtered.sorted { itemA, itemB in
            switch sortOption.field {
            case .fileName:
                let comp = itemA.primaryFile.fileName.localizedStandardCompare(itemB.primaryFile.fileName)
                if comp != .orderedSame {
                    return sortOption.order == .ascending ? (comp == .orderedAscending) : (comp == .orderedDescending)
                }
                return itemA.id < itemB.id

            case .captureDate:
                let dateA = captureDate(for: itemA)
                let dateB = captureDate(for: itemB)
                switch (dateA, dateB) {
                case let (dA?, dB?):
                    if dA != dB {
                        return sortOption.order == .ascending ? (dA < dB) : (dA > dB)
                    }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                let comp = itemA.primaryFile.fileName.localizedStandardCompare(itemB.primaryFile.fileName)
                return sortOption.order == .ascending ? (comp == .orderedAscending) : (comp == .orderedDescending)

            case .starRating:
                let ratingA = curationMetadata(for: itemA).starRating.value
                let ratingB = curationMetadata(for: itemB).starRating.value
                if ratingA != ratingB {
                    return sortOption.order == .ascending ? (ratingA < ratingB) : (ratingA > ratingB)
                }
                let comp = itemA.primaryFile.fileName.localizedStandardCompare(itemB.primaryFile.fileName)
                return sortOption.order == .ascending ? (comp == .orderedAscending) : (comp == .orderedDescending)
            }
        }
    }

    func refreshDerivedCounts() {
        var pending = 0
        var conflicts = 0
        for item in items {
            let state = syncState(for: item)
            if state == .pendingWrite {
                pending += 1
            } else if state == .conflicted {
                conflicts += 1
            }
        }
        pendingWritesCount = pending
        conflictedItemsCount = conflicts

        let current = visibleItems
        visibleMediaPairCount = current.filter(\.isMediaPair).count
        visibleVideoCount = current.filter { $0.kind == .video }.count
    }

    var availableCameraModels: [String] {
        var set = Set<String>()
        for item in items {
            if let model = exifMetadata(for: item).cameraModel, !model.isEmpty {
                set.insert(model)
            }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var availableLensModels: [String] {
        var set = Set<String>()
        for item in items {
            if let lens = exifMetadata(for: item).lensModel, !lens.isEmpty {
                set.insert(lens)
            }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func setFilterCriteria(_ criteria: FilterCriteria) {
        filterCriteria = criteria
    }

    func resetFilters() {
        filterCriteria.reset()
    }

    func setSortOption(_ option: SortOption) {
        sortOption = option
    }

    func setSortField(_ field: SortField) {
        if sortOption.field == field {
            sortOption.order = (sortOption.order == .ascending) ? .descending : .ascending
        } else {
            sortOption.field = field
            sortOption.order = .ascending
        }
    }

    func setSortOrder(_ order: SortOrder) {
        sortOption.order = order
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

    var syncErrorItemsCount: Int {
        items.filter { syncState(for: $0) == .syncError }.count
    }

    var syncSummaryBadgeText: String {
        let conflicts = conflictedItemsCount
        if conflicts > 0 {
            return "\(conflicts) Conflict\(conflicts == 1 ? "" : "s")"
        }
        let errors = syncErrorItemsCount
        if errors > 0 {
            return "\(errors) Error\(errors == 1 ? "" : "s")"
        }
        let pending = pendingWritesCount
        if pending > 0 {
            return "\(pending) Pending"
        }
        return "Synced"
    }

    func recordSyncError(_ error: Error, fallback: String? = nil) {
        let fallbackText = fallback ?? error.localizedDescription
        lastErrorMessage = SidecarCodec.userFacingErrorMessage(for: error, fallback: fallbackText)
    }

    func flushPendingWrites() async {
        debouncedFlushTask?.cancel()
        debouncedFlushTask = nil
        while !Task.isCancelled {
            if let existing = activeFlushTask {
                await existing.value
            } else {
                let pendingCount = items.filter { syncState(for: $0) == .pendingWrite }.count
                guard pendingCount > 0 else { break }

                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isFlushingPendingWrites = true
                    defer {
                        self.isFlushingPendingWrites = false
                        self.activeFlushTask = nil
                    }
                    await self.performPendingWritesFlush()
                }
                activeFlushTask = task
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            let remainingPending = items.contains { syncState(for: $0) == .pendingWrite }
            if !remainingPending {
                break
            }
        }
    }

    private func performPendingWritesFlush() async {
        while !Task.isCancelled {
            let pending = items.filter { syncState(for: $0) == .pendingWrite }
            guard !pending.isEmpty else { break }

            for item in pending {
                if Task.isCancelled { break }
                if simulatedFlushDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: simulatedFlushDelayNanoseconds)
                }
                if Task.isCancelled { break }
                do {
                    try await flushPendingWrite(for: item.id)
                } catch {
                    syncStateByItemID[item.id] = .syncError
                    metadataSyncStore.updateSyncState(.syncError, for: item.id)
                    let nsError = error as NSError
                    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                    Self.logger.error("Flush error on \(item.displayFileName, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) underlying=\(underlying?.domain ?? "none", privacy: .public)(\(underlying?.code ?? -1)) desc=\(error.localizedDescription, privacy: .public)")
                    recordSyncError(error, fallback: "Sync error on \(item.displayFileName): \(error.localizedDescription)")
                    refreshDerivedCounts()
                }
            }
        }
    }

    func retryFailedWrites() async {
        lastErrorMessage = nil
        let failedItems = items.filter { syncState(for: $0) == .syncError }
        guard !failedItems.isEmpty else { return }

        for item in failedItems {
            syncStateByItemID[item.id] = .pendingWrite
            metadataSyncStore.updateSyncState(.pendingWrite, for: item.id)
        }
        refreshDerivedCounts()
        await flushPendingWrites()
    }

    @discardableResult
    func closeFolder(
        force: Bool = false,
        timeoutNanoseconds: UInt64 = 2_500_000_000
    ) async -> CloseFolderResult {
        debouncedFlushTask?.cancel()
        debouncedFlushTask = nil
        guard currentFolderURL != nil else {
            cleanCloseSession()
            return .success
        }

        if pendingWritesCount == 0 {
            cleanCloseSession()
            return .success
        }

        if force {
            cleanCloseSession()
            return .closedWithPendingJournaled
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await self.flushPendingWrites()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }
            _ = await group.next()
            group.cancelAll()
        }

        if pendingWritesCount == 0 {
            cleanCloseSession()
            return .success
        } else {
            return .pendingWritesRemaining(pendingWritesCount)
        }
    }

    private func cleanCloseSession() {
        debouncedFlushTask?.cancel()
        debouncedFlushTask = nil
        backgroundHydrationTask?.cancel()
        backgroundHydrationTask = nil
        backgroundExifTask?.cancel()
        backgroundExifTask = nil
        isExifPreloading = false
        mediaPipeline.flushIndexImmediately()
        isDiscovering = false
        openFolderProgress = nil
        folderAccessService.stopAccessingCurrentFolder()
        currentFolderURL = nil
        items.removeAll()
        selectedItemID = nil
        metadataByItemID.removeAll()
        syncStateByItemID.removeAll()
        baseSnapshotByItemID.removeAll()
        conflictsByItemID.removeAll()
        thumbnailAspectRatios.removeAll()
        swipeHistory.removeAll()
        activeConflictItemID = nil
        isConflictSheetPresented = false
        lastErrorMessage = nil
        exifByItemID.removeAll()
        headerSupplementedItemIDs.removeAll()
        filterCriteria.reset()
        sortOption = SortOption(field: .fileName, order: .ascending)
        isSearchFieldFocused = false
        refreshDerivedCounts()
    }

    func flushPendingWrite(for itemID: String) async throws {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        let pendingCuration = curationMetadata(for: item)
        let base = baseSnapshot(for: item)

        syncStateByItemID[item.id] = .loading
        refreshDerivedCounts()

        enum FlushOutcome: Sendable {
            case conflict(MetadataConflict)
            case success(BaseSnapshot)
        }

        let outcome = try await Task.detached(priority: .utility) { () -> FlushOutcome in
            let readURL = SidecarCodec.resolveSidecarReadURL(for: item)
            var diskCuration: CurationMetadata? = nil
            var diskDigest = ""

            if let readURL, let data = SidecarCodec.readData(from: readURL) {
                diskDigest = SidecarCodec.computeDigest(for: data)
                if let parsed = try? SidecarCodec.parse(data: data) {
                    diskCuration = parsed.curation
                }
            }

            let remoteDigestChanged = (base?.fileDigest != diskDigest)

            let mergeEvaluation = XMPConflictEngine.evaluateThreeWay(
                itemID: item.id,
                base: base,
                local: pendingCuration,
                remote: diskCuration,
                remoteDigestChanged: remoteDigestChanged
            )

            let curationToWrite: CurationMetadata

            switch mergeEvaluation {
            case .conflict(let conflict):
                return .conflict(conflict)

            case .cleanMerge(let mergedCuration):
                if diskCuration == nil && pendingCuration == base?.metadata {
                    return .success(BaseSnapshot(metadata: CurationMetadata(), fileDigest: ""))
                }
                curationToWrite = mergedCuration

            case .noChange:
                curationToWrite = pendingCuration
            }

            let writtenTargets = try await SidecarCodec.write(curation: curationToWrite, for: item)

            if let primaryTarget = writtenTargets.first, let writtenData = SidecarCodec.readData(from: primaryTarget) {
                let newDigest = SidecarCodec.computeDigest(for: writtenData)
                let modDate = (try? primaryTarget.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let newBase = BaseSnapshot(metadata: curationToWrite, fileDigest: newDigest, modificationDate: modDate)
                return .success(newBase)
            } else {
                let fallbackBase = BaseSnapshot(metadata: curationToWrite, fileDigest: "")
                return .success(fallbackBase)
            }
        }.value

        switch outcome {
        case .conflict(let conflict):
            syncStateByItemID[item.id] = .conflicted
            conflictsByItemID[item.id] = conflict
            metadataSyncStore.recordConflict(conflict, for: item.id)

        case .success(let newBase):
            metadataByItemID[item.id] = newBase.metadata
            baseSnapshotByItemID[item.id] = newBase
            syncStateByItemID[item.id] = .synced
            conflictsByItemID.removeValue(forKey: item.id)
            metadataSyncStore.markSynced(for: item.id, baseSnapshot: newBase)
        }
        refreshDerivedCounts()
    }

    func resolveConflict(for item: MediaItem, strategy: ConflictResolutionStrategy) async throws {
        guard let conflict = conflict(for: item) else { return }

        let resolvedMetadata: CurationMetadata
        let newBase: BaseSnapshot

        switch strategy {
        case .useRemote:
            resolvedMetadata = conflict.remote
            let readURL = SidecarCodec.resolveSidecarReadURL(for: item)
            let diskData = readURL.flatMap { SidecarCodec.readData(from: $0) } ?? Data()
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

            let writtenTargets = try await SidecarCodec.write(curation: chosen, for: item)

            let primaryTarget = writtenTargets.first ?? SidecarCodec.resolveSidecarReadURL(for: item)
            let writtenData = primaryTarget.flatMap { SidecarCodec.readData(from: $0) } ?? Data()
            let digest = SidecarCodec.computeDigest(for: writtenData)
            let modDate = primaryTarget.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            newBase = BaseSnapshot(metadata: resolvedMetadata, fileDigest: digest, modificationDate: modDate)
        }

        metadataByItemID[item.id] = resolvedMetadata
        syncStateByItemID[item.id] = .synced
        baseSnapshotByItemID[item.id] = newBase
        conflictsByItemID.removeValue(forKey: item.id)
        metadataSyncStore.resolveConflict(for: item.id, resolvedMetadata: resolvedMetadata, newBaseSnapshot: newBase)
        refreshDerivedCounts()
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
        debouncedFlushTask?.cancel()
        debouncedFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.flushDebounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: self.flushDebounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self.debouncedFlushTask = nil
            await self.flushPendingWrites()
        }
    }

    /// Refreshes the active folder by re-discovering items.
    /// Traversal runs in Task.detached at .userInitiated priority to prevent
    /// synchronous file system calls from blocking @MainActor.
    func refreshFolder() async throws {
        guard let currentFolderURL else { return }
        let rootURL = currentFolderURL.standardizedFileURL
        let mode = self.subfolderMode
        let storeURL = self.storageRootURL
        let discoveredItems = try await Task.detached(priority: .userInitiated) {
            try Self.discoverItems(in: rootURL, mode: mode, storageRootURL: storeURL)
        }.value
        self.items = discoveredItems
        initializeMetadata(for: self.items)
        if !isSyncSuspended {
            await flushPendingWrites()
        }
        startBackgroundExifPreloading(for: self.items)
    }

    func loadThumbnailData(for item: MediaItem, maxPixelSize: Int = 360) async -> Data? {
        let data = await mediaPipeline.loadThumbnailData(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        self.mediaCacheTotalBytes = mediaPipeline.totalCachedBytes
        return data
    }

    func previewCacheKey(for item: MediaItem, maxPixelSize: Int = 2048) -> String {
        mediaPipeline.previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func cachedPreviewImage(for item: MediaItem, maxPixelSize: Int = 2048) -> CGImage? {
        let image = mediaPipeline.cachedPreviewImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        self.mediaCacheTotalBytes = mediaPipeline.totalCachedBytes
        return image
    }

    func loadPreviewImageData(for item: MediaItem, maxPixelSize: Int = 2048) async -> Data? {
        let data = await mediaPipeline.loadPreviewImageData(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        self.mediaCacheTotalBytes = mediaPipeline.totalCachedBytes
        return data
    }

    func cancelThumbnail(for item: MediaItem, maxPixelSize: Int = 360) {
        mediaPipeline.cancelThumbnail(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func openFolder(at url: URL, lazySidecars: Bool? = nil) throws {
        if let lazySidecars {
            self.isLazySidecarHydrationEnabled = lazySidecars
        }
        do {
            let (resolvedURL, updatedRecents) = try folderAccessService.beginAccessingAndRecordFolder(at: url)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedURL.standardizedFileURL.path, isDirectory: &isDir), isDir.boolValue else {
                folderAccessService.stopAccessingCurrentFolder()
                throw CocoaError(.fileReadNoSuchFile)
            }
            try applyOpenedFolder(resolvedURL: resolvedURL, updatedRecents: updatedRecents)
        } catch {
            self.lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func reopenRecentFolder(_ recentFolder: RecentFolder, lazySidecars: Bool? = nil) throws {
        if let lazySidecars {
            self.isLazySidecarHydrationEnabled = lazySidecars
        }
        do {
            let (resolvedURL, updatedRecents) = try folderAccessService.resolveAndAccess(recentFolder: recentFolder)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedURL.standardizedFileURL.path, isDirectory: &isDir), isDir.boolValue else {
                folderAccessService.stopAccessingCurrentFolder()
                throw CocoaError(.fileReadNoSuchFile)
            }
            try applyOpenedFolder(resolvedURL: resolvedURL, updatedRecents: updatedRecents)
        } catch {
            self.lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func reopenRecentFolderAsync(_ recentFolder: RecentFolder, lazySidecars: Bool = true) async throws {
        let (resolvedURL, updatedRecents) = try folderAccessService.resolveAndAccess(recentFolder: recentFolder)
        try await openResolvedFolderAsync(resolvedURL: resolvedURL, updatedRecents: updatedRecents, lazySidecars: lazySidecars)
    }

    func openFolderAsync(at url: URL, lazySidecars: Bool = true) async throws {
        let (resolvedURL, updatedRecents) = try folderAccessService.beginAccessingAndRecordFolder(at: url)
        try await openResolvedFolderAsync(resolvedURL: resolvedURL, updatedRecents: updatedRecents, lazySidecars: lazySidecars)
    }

    private func openResolvedFolderAsync(resolvedURL: URL, updatedRecents: [RecentFolder], lazySidecars: Bool) async throws {
        if pendingWritesCount > 0 {
            await flushPendingWrites()
        }
        self.isLazySidecarHydrationEnabled = lazySidecars
        self.isDiscovering = true
        self.openFolderProgress = 0.0
        defer {
            self.isDiscovering = false
            self.openFolderProgress = nil
        }

        var accumulatedItems: [MediaItem] = []
        var hasSetCurrentFolder = false

        let stream = Self.streamDiscoveredItems(
            from: resolvedURL,
            mode: subfolderMode,
            storageRootURL: storageRootURL
        )

        do {
            for try await batch in stream {
                if !hasSetCurrentFolder {
                    self.recentFolders = updatedRecents
                    self.currentFolderURL = resolvedURL
                    hasSetCurrentFolder = true
                }
                if Task.isCancelled { break }
                accumulatedItems.append(contentsOf: batch.items)
                self.items = accumulatedItems.sorted(by: Self.mediaItemSortComparator)
                self.initializeMetadata(for: batch.items)
                self.openFolderProgress = batch.progress
                await Task.yield()
            }
        } catch {
            if !hasSetCurrentFolder {
                folderAccessService.stopAccessingCurrentFolder()
            }
            self.lastErrorMessage = error.localizedDescription
            throw error
        }

        if !hasSetCurrentFolder {
            self.recentFolders = updatedRecents
            self.currentFolderURL = resolvedURL
        }

        self.lastErrorMessage = nil
        if !isSyncSuspended {
            scheduleFlushPendingWrites()
        }
        startBackgroundExifPreloading(for: self.items)
    }

    func removeRecentFolder(_ recentFolder: RecentFolder) {
        self.recentFolders = folderAccessService.removeRecentFolder(id: recentFolder.id)
    }

    private func applyOpenedFolder(resolvedURL: URL, updatedRecents: [RecentFolder]) throws {
        if pendingWritesCount > 0 {
            Task { [weak self] in
                await self?.flushPendingWrites()
            }
        }
        self.isDiscovering = true
        defer { self.isDiscovering = false }
        do {
            let discoveredItems = try discoverItems(in: resolvedURL.standardizedFileURL, mode: subfolderMode)
            self.recentFolders = updatedRecents
            self.currentFolderURL = resolvedURL
            self.items = discoveredItems
            initializeMetadata(for: self.items)
            self.lastErrorMessage = nil
            if !isSyncSuspended {
                scheduleFlushPendingWrites()
            }
            startBackgroundExifPreloading(for: self.items)
        } catch {
            folderAccessService.stopAccessingCurrentFolder()
            throw error
        }
    }

    /// Sets the subfolder mode and re-discovers items asynchronously off the MainActor.
    /// If a folder is open, directory traversal runs in Task.detached to prevent
    /// synchronous FileManager operations from blocking @MainActor.
    func setSubfolderMode(_ mode: SubfolderMode) async throws {
        self.subfolderMode = mode
        try await rediscoverItemsForSubfolderModeChange()
    }

    private func rediscoverItemsForSubfolderModeChange() async throws {
        guard let currentFolderURL else { return }
        let rootURL = currentFolderURL.standardizedFileURL
        let mode = self.subfolderMode
        let storeURL = self.storageRootURL
        self.isDiscovering = true
        defer { self.isDiscovering = false }
        let discoveredItems = try await Task.detached(priority: .userInitiated) {
            try Self.discoverItems(in: rootURL, mode: mode, storageRootURL: storeURL)
        }.value
        guard self.subfolderMode == mode, self.currentFolderURL == currentFolderURL else { return }
        self.items = discoveredItems
        initializeMetadata(for: self.items)
        if !isSyncSuspended {
            scheduleFlushPendingWrites()
        }
        startBackgroundExifPreloading(for: self.items)
    }

    private func initializeMetadata(for items: [MediaItem]) {
        if isLazySidecarHydrationEnabled {
            for item in items {
                let persisted = metadataSyncStore.record(for: item.id)

                if let persisted {
                    if let persistedExif = persisted.exif {
                        exifByItemID[item.id] = persistedExif
                    }

                    if persisted.syncState == .pendingWrite || persisted.syncState == .syncError {
                        metadataByItemID[item.id] = persisted.metadata
                        syncStateByItemID[item.id] = persisted.syncState
                        baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                    } else if persisted.syncState == .conflicted, let conflict = persisted.conflict {
                        metadataByItemID[item.id] = persisted.metadata
                        syncStateByItemID[item.id] = .conflicted
                        conflictsByItemID[item.id] = conflict
                        baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                    } else {
                        metadataByItemID[item.id] = persisted.metadata
                        syncStateByItemID[item.id] = .synced
                        baseSnapshotByItemID[item.id] = persisted.baseSnapshot
                    }
                } else {
                    syncStateByItemID[item.id] = .loading
                    metadataByItemID[item.id] = CurationMetadata()
                    baseSnapshotByItemID[item.id] = nil
                }
            }
            refreshDerivedCounts()
            startBackgroundSidecarHydration()
        } else {
            for item in items {
                hydrateItemSynchronously(item)
            }
            refreshDerivedCounts()
        }
    }

    private func hydrateItemSynchronously(_ item: MediaItem) {
        let persisted = metadataSyncStore.record(for: item.id)
        let sidecarURL = SidecarCodec.resolveSidecarReadURL(for: item)

        var diskData: Data? = nil
        var diskCuration: CurationMetadata? = nil
        var diskExif: ExifMetadata? = nil
        var diskDigest = ""
        var diskModDate: Date? = nil

        if let sidecarURL, let data = SidecarCodec.readData(from: sidecarURL) {
            diskData = data
            diskDigest = SidecarCodec.computeDigest(for: data)
            diskModDate = (try? sidecarURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let parsed = try? SidecarCodec.parse(data: data) {
                diskCuration = parsed.curation
                diskExif = parsed.exif
            }
        }

        if let persisted {
            if let diskExif, !diskExif.isEmpty {
                if let persistedExif = persisted.exif {
                    exifByItemID[item.id] = diskExif.supplementing(with: persistedExif)
                } else {
                    exifByItemID[item.id] = diskExif
                }
            } else if let persistedExif = persisted.exif {
                exifByItemID[item.id] = persistedExif
            }

            if persisted.syncState == .pendingWrite || persisted.syncState == .syncError {
                metadataByItemID[item.id] = persisted.metadata
                syncStateByItemID[item.id] = persisted.syncState
                baseSnapshotByItemID[item.id] = persisted.baseSnapshot

                if let base = persisted.baseSnapshot {
                    let remoteChanged = diskDigest != base.fileDigest
                    let threeWay = XMPConflictEngine.evaluateThreeWay(
                        itemID: item.id,
                        base: base,
                        local: persisted.metadata,
                        remote: diskCuration,
                        remoteDigestChanged: remoteChanged
                    )
                    switch threeWay {
                    case .conflict(let conflict):
                        syncStateByItemID[item.id] = .conflicted
                        conflictsByItemID[item.id] = conflict
                        metadataSyncStore.recordConflict(conflict, for: item.id)
                    case .cleanMerge(let merged):
                        metadataByItemID[item.id] = merged
                        metadataSyncStore.stagePendingWrite(merged, baseSnapshot: base, for: item.id)
                    case .noChange:
                        break
                    }
                } else if let diskCuration {
                    let threeWay = XMPConflictEngine.evaluateThreeWay(
                        itemID: item.id,
                        base: nil,
                        local: persisted.metadata,
                        remote: diskCuration,
                        remoteDigestChanged: true
                    )
                    switch threeWay {
                    case .conflict(let conflict):
                        syncStateByItemID[item.id] = .conflicted
                        conflictsByItemID[item.id] = conflict
                        metadataSyncStore.recordConflict(conflict, for: item.id)
                    case .cleanMerge(let merged):
                        metadataByItemID[item.id] = merged
                        let newBase = BaseSnapshot(metadata: diskCuration, fileDigest: diskDigest, modificationDate: diskModDate)
                        metadataSyncStore.stagePendingWrite(merged, baseSnapshot: newBase, for: item.id)
                        baseSnapshotByItemID[item.id] = newBase
                    case .noChange:
                        break
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
                    metadataSyncStore.recordBaseSnapshot(snapshot, exif: exifByItemID[item.id] ?? diskExif, for: item.id)
                } else {
                    let emptySnapshot = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
                    metadataByItemID[item.id] = CurationMetadata()
                    syncStateByItemID[item.id] = .synced
                    baseSnapshotByItemID[item.id] = emptySnapshot
                    metadataSyncStore.recordBaseSnapshot(emptySnapshot, exif: exifByItemID[item.id] ?? diskExif, for: item.id)
                }
            }
        } else {
            if let diskExif {
                exifByItemID[item.id] = diskExif
            }

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
                metadataSyncStore.recordBaseSnapshot(emptySnapshot, exif: exifByItemID[item.id], for: item.id)
            }
        }
    }

    private enum HydrationOutcome: Sendable {
        case sidecar(curation: CurationMetadata, exif: ExifMetadata?, digest: String, modDate: Date?)
        case none
    }

    nonisolated private static func readSidecarData(for item: MediaItem) -> HydrationOutcome {
        let sidecarURL = item.sidecarURL ?? SidecarCodec.resolveSidecarReadURL(for: item)
        guard let sidecarURL, let data = SidecarCodec.readData(from: sidecarURL) else {
            return .none
        }
        let digest = SidecarCodec.computeDigest(for: data)
        let modDate = (try? sidecarURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let parsed = try? SidecarCodec.parse(data: data) {
            return .sidecar(curation: parsed.curation, exif: parsed.exif, digest: digest, modDate: modDate)
        }
        return .sidecar(curation: CurationMetadata(), exif: nil, digest: digest, modDate: modDate)
    }

    func hydrateMetadata(for item: MediaItem, refreshCounts: Bool = true) async {
        guard syncStateByItemID[item.id] == .loading else { return }

        let outcome = Self.readSidecarData(for: item)

        guard !Task.isCancelled else { return }
        guard syncStateByItemID[item.id] == .loading else { return }

        switch outcome {
        case .sidecar(let curation, let exif, let digest, let modDate):
            let snapshot = BaseSnapshot(metadata: curation, fileDigest: digest, modificationDate: modDate)
            metadataByItemID[item.id] = curation
            syncStateByItemID[item.id] = .synced
            baseSnapshotByItemID[item.id] = snapshot
            if let exif {
                exifByItemID[item.id] = exif
            }
            metadataSyncStore.recordBaseSnapshot(snapshot, exif: exifByItemID[item.id] ?? exif, for: item.id)

        case .none:
            let emptySnapshot = BaseSnapshot(metadata: CurationMetadata(), fileDigest: "")
            metadataByItemID[item.id] = CurationMetadata()
            syncStateByItemID[item.id] = .synced
            baseSnapshotByItemID[item.id] = emptySnapshot
            metadataSyncStore.recordBaseSnapshot(emptySnapshot, exif: exifByItemID[item.id], for: item.id)
        }

        if refreshCounts {
            refreshDerivedCounts()
        }
    }

    func startBackgroundSidecarHydration() {
        backgroundHydrationTask?.cancel()
        backgroundHydrationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let pendingItems: [MediaItem] = await MainActor.run {
                self.items.filter { self.syncStateByItemID[$0.id] == .loading }
            }
            guard !pendingItems.isEmpty else { return }

            for item in pendingItems {
                if Task.isCancelled { break }
                await self.hydrateMetadata(for: item, refreshCounts: false)
                await Task.yield()
            }
            await MainActor.run {
                self.refreshDerivedCounts()
            }
        }
    }

    func toggleSubfolderMode() async throws {
        let next: SubfolderMode = (subfolderMode == .immediate) ? .recursive : .immediate
        try await setSubfolderMode(next)
    }

    func discoverItems(in rootURL: URL, mode: SubfolderMode) throws -> [MediaItem] {
        try Self.discoverItems(in: rootURL, mode: mode, storageRootURL: storageRootURL)
    }

    typealias DiscoveredBatch = MediaDiscovery.DiscoveredBatch

    nonisolated static func discoverItems(
        inSingleDirectory directoryURL: URL,
        rootURL: URL,
        fileManager: FileManager = FileManager()
    ) throws -> [MediaItem] {
        try MediaDiscovery.discoverItems(
            inSingleDirectory: directoryURL,
            rootURL: rootURL,
            fileManager: fileManager
        )
    }

    nonisolated static func discoverItems(
        in rootURL: URL,
        mode: SubfolderMode,
        storageRootURL: URL,
        fileManager: FileManager = FileManager()
    ) throws -> [MediaItem] {
        try MediaDiscovery.discoverItems(
            in: rootURL,
            mode: mode,
            storageRootURL: storageRootURL,
            fileManager: fileManager
        )
    }

    nonisolated static func mediaItemSortComparator(lhs: MediaItem, rhs: MediaItem) -> Bool {
        MediaDiscovery.mediaItemSortComparator(lhs: lhs, rhs: rhs)
    }

    nonisolated static func isIgnoredNonMediaDirectory(name: String) -> Bool {
        MediaDiscovery.isIgnoredNonMediaDirectory(name: name)
    }

    nonisolated static func collectDirectories(
        from rootURL: URL,
        mode: SubfolderMode,
        storageRootURL: URL,
        fileManager: FileManager = FileManager()
    ) throws -> [URL] {
        try MediaDiscovery.collectDirectories(
            from: rootURL,
            mode: mode,
            storageRootURL: storageRootURL,
            fileManager: fileManager
        )
    }

    nonisolated static func streamDiscoveredItems(
        from rootURL: URL,
        mode: SubfolderMode,
        storageRootURL: URL
    ) -> AsyncThrowingStream<DiscoveredBatch, Error> {
        MediaDiscovery.streamDiscoveredItems(
            from: rootURL,
            mode: mode,
            storageRootURL: storageRootURL
        )
    }

    nonisolated static func pairDirectoryMediaFiles(
        _ files: [MediaFile],
        sidecarsByLowerBase: [String: URL],
        directoryURL: URL,
        rootURL: URL
    ) -> [MediaItem] {
        MediaDiscovery.pairDirectoryMediaFiles(
            files,
            sidecarsByLowerBase: sidecarsByLowerBase,
            directoryURL: directoryURL,
            rootURL: rootURL
        )
    }
}
