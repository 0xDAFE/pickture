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
    let metadataSyncEngine: MetadataSyncEngine
    var metadataSyncStore: MetadataSyncStore { metadataSyncEngine.syncStore }
    private(set) var currentFolderURL: URL?
    private(set) var items: [MediaItem] = [] {
        didSet {
            refreshDerivedCounts()
        }
    }
    private(set) var recentFolders: [RecentFolder] = []
    var mediaCacheTotalBytes: Int64 {
        mediaPipeline.totalCachedBytes
    }
    var cacheSizeLimitBytes: Int64 {
        mediaPipeline.cacheSizeLimitBytes
    }
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
    private var thumbnailAspectRatios: [String: CGFloat] = [:]
    var isFlushingPendingWrites: Bool {
        metadataSyncEngine.isFlushingPendingWrites
    }
    private(set) var isDiscovering: Bool = false
    private(set) var openFolderProgress: Double? = nil
    var isLazySidecarHydrationEnabled: Bool = false
    private(set) var isExifPreloading: Bool = false
    private var backgroundExifTask: Task<Void, Never>? = nil
    var flushDebounceNanoseconds: UInt64 {
        get { metadataSyncEngine.flushDebounceNanoseconds }
        set { metadataSyncEngine.flushDebounceNanoseconds = newValue }
    }
    var isAccessingFolder: Bool {
        folderAccessService.isAccessingFolder
    }
    /// Testing hook to simulate slow I/O or network file sync during session flush.
    var simulatedFlushDelayNanoseconds: UInt64 {
        get { metadataSyncEngine.simulatedFlushDelayNanoseconds }
        set { metadataSyncEngine.simulatedFlushDelayNanoseconds = newValue }
    }
    var isSyncSuspended: Bool {
        get { metadataSyncEngine.isSyncSuspended }
        set { metadataSyncEngine.isSyncSuspended = newValue }
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
        let syncStoreURL = resolvedStorageRoot.appendingPathComponent("MetadataSyncStore", isDirectory: true)
        self.metadataSyncEngine = MetadataSyncEngine(storeDirectoryURL: syncStoreURL)
        self.recentFolders = self.folderAccessService.loadRecentFolders()
        self.setupMetadataSyncEngineBindings()
    }

    private func setupMetadataSyncEngineBindings() {
        metadataSyncEngine.itemsProvider = { [weak self] in
            self?.items ?? []
        }
        metadataSyncEngine.onStateChange = { [weak self] in
            self?.refreshDerivedCounts()
        }
        metadataSyncEngine.onSyncError = { [weak self] error, item in
            self?.recordSyncError(error, fallback: "Sync error on \(item.displayFileName): \(error.localizedDescription)")
        }
        metadataSyncEngine.existingExifProvider = { [weak self] itemID in
            self?.exifByItemID[itemID]
        }
        metadataSyncEngine.onExifDiscovered = { [weak self] itemID, exif in
            self?.exifByItemID[itemID] = exif
        }
    }

    func thumbnailCacheKey(for item: MediaItem, maxPixelSize: Int = 360) -> String {
        mediaPipeline.thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func isThumbnailCached(for item: MediaItem, maxPixelSize: Int = 360) -> Bool {
        mediaPipeline.isThumbnailCached(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func cachedThumbnailImage(for item: MediaItem, maxPixelSize: Int = 360) -> CGImage? {
        mediaPipeline.cachedThumbnailImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func setCacheSizeLimitBytes(_ limitBytes: Int64) {
        mediaPipeline.setCacheSizeLimitBytes(limitBytes)
    }

    func setUserConfiguredCacheSizeLimitBytes(_ limitBytes: Int64) {
        mediaPipeline.setUserConfiguredCacheSizeLimitBytes(limitBytes)
    }

    func clearMediaCache() {
        mediaPipeline.clearCache()
        thumbnailAspectRatios.removeAll()
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
        metadataSyncEngine.updateCurationMetadata(metadata, for: item)
        refreshDerivedCounts()
    }

    func stagePendingMetadata(_ metadata: CurationMetadata, for item: MediaItem) {
        metadataSyncEngine.stagePendingMetadata(metadata, for: item)
        refreshDerivedCounts()
    }

    func curationMetadata(for item: MediaItem) -> CurationMetadata {
        metadataSyncEngine.curationMetadata(for: item)
    }

    func syncState(for item: MediaItem) -> SyncState {
        metadataSyncEngine.syncState(for: item)
    }

    func baseSnapshot(for item: MediaItem) -> BaseSnapshot? {
        metadataSyncEngine.baseSnapshot(for: item)
    }

    func conflict(for item: MediaItem) -> MetadataConflict? {
        metadataSyncEngine.conflict(for: item)
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
        pendingWritesCount = metadataSyncEngine.pendingWritesCount
        conflictedItemsCount = metadataSyncEngine.conflictedItemsCount

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
        metadataSyncEngine.conflictedItems(from: items)
    }

    var activeConflictItem: MediaItem? {
        metadataSyncEngine.activeConflictItem(selectedItemID: activeConflictItemID, from: items)
    }

    var syncSummaryState: SyncState {
        metadataSyncEngine.syncSummaryState
    }

    var syncErrorItemsCount: Int {
        metadataSyncEngine.syncErrorItemsCount
    }

    var syncSummaryBadgeText: String {
        metadataSyncEngine.syncSummaryBadgeText
    }

    func recordSyncError(_ error: Error, fallback: String? = nil) {
        let fallbackText = fallback ?? error.localizedDescription
        lastErrorMessage = SidecarCodec.userFacingErrorMessage(for: error, fallback: fallbackText)
    }

    func flushPendingWrites() async {
        await metadataSyncEngine.flushPendingWrites()
    }

    func retryFailedWrites() async {
        lastErrorMessage = nil
        await metadataSyncEngine.retryFailedWrites(in: items)
        refreshDerivedCounts()
    }

    @discardableResult
    func closeFolder(
        force: Bool = false,
        timeoutNanoseconds: UInt64 = 2_500_000_000
    ) async -> CloseFolderResult {
        guard currentFolderURL != nil else {
            cleanCloseSession()
            return .success
        }

        let result = await metadataSyncEngine.close(
            timeoutNanoseconds: timeoutNanoseconds,
            force: force,
            items: items
        )
        if result == .success || result == .closedWithPendingJournaled {
            cleanCloseSession()
        }
        return result
    }

    private func cleanCloseSession() {
        metadataSyncEngine.reset()
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
        try await metadataSyncEngine.flushPendingWrite(for: itemID, in: items)
    }

    func resolveConflict(for item: MediaItem, strategy: ConflictResolutionStrategy) async throws {
        try await metadataSyncEngine.resolveConflict(for: item, strategy: strategy)
        refreshDerivedCounts()
    }

    func resolveAllConflicts(strategy: ConflictResolutionStrategy) async throws {
        try await metadataSyncEngine.resolveAllConflicts(in: items, strategy: strategy)
        refreshDerivedCounts()
    }

    func resolveAllConflictsWithLocal() async throws {
        try await metadataSyncEngine.resolveAllConflictsWithLocal(in: items)
        refreshDerivedCounts()
    }

    func resolveAllConflictsWithRemote() async throws {
        try await metadataSyncEngine.resolveAllConflictsWithRemote(in: items)
        refreshDerivedCounts()
    }

    func scheduleFlushPendingWrites() {
        metadataSyncEngine.scheduleFlushPendingWrites()
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
            try MediaDiscovery.discoverItems(in: rootURL, mode: mode, storageRootURL: storeURL)
        }.value
        self.items = discoveredItems
        initializeMetadata(for: self.items)
        if !isSyncSuspended {
            await flushPendingWrites()
        }
        startBackgroundExifPreloading(for: self.items)
    }

    func loadThumbnailData(for item: MediaItem, maxPixelSize: Int = 360) async -> Data? {
        await mediaPipeline.loadThumbnailData(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func previewCacheKey(for item: MediaItem, maxPixelSize: Int = 2048) -> String {
        mediaPipeline.previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func cachedPreviewImage(for item: MediaItem, maxPixelSize: Int = 2048) -> CGImage? {
        mediaPipeline.cachedPreviewImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func loadPreviewImageData(for item: MediaItem, maxPixelSize: Int = 2048) async -> Data? {
        await mediaPipeline.loadPreviewImageData(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
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

        let stream = MediaDiscovery.streamDiscoveredItems(
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
                self.items = accumulatedItems.sorted(by: MediaDiscovery.mediaItemSortComparator)
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
            try MediaDiscovery.discoverItems(in: rootURL, mode: mode, storageRootURL: storeURL)
        }.value
        guard self.subfolderMode == mode, self.currentFolderURL == currentFolderURL else { return }
        self.items = discoveredItems
        initializeMetadata(for: self.items)
        if !isSyncSuspended {
            scheduleFlushPendingWrites()
        }
        startBackgroundExifPreloading(for: self.items)
    }

    func initializeMetadata(for items: [MediaItem]) {
        metadataSyncEngine.initializeMetadata(for: items, isLazy: isLazySidecarHydrationEnabled)
        refreshDerivedCounts()
    }

    func hydrateMetadata(for item: MediaItem, refreshCounts: Bool = true) async {
        await metadataSyncEngine.hydrateMetadata(for: item, refreshCounts: refreshCounts)
    }

    func startBackgroundSidecarHydration() {
        metadataSyncEngine.startBackgroundSidecarHydration(for: items)
    }

    func toggleSubfolderMode() async throws {
        let next: SubfolderMode = (subfolderMode == .immediate) ? .recursive : .immediate
        try await setSubfolderMode(next)
    }

    func discoverItems(in rootURL: URL, mode: SubfolderMode) throws -> [MediaItem] {
        try MediaDiscovery.discoverItems(in: rootURL, mode: mode, storageRootURL: storageRootURL)
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

    nonisolated static func streamDiscoveredItems(
        from rootURL: URL,
        mode: SubfolderMode,
        storageRootURL: URL,
        fileManagerFactory: (@Sendable () -> FileManager)? = nil
    ) -> AsyncThrowingStream<DiscoveredBatch, Error> {
        MediaDiscovery.streamDiscoveredItems(
            from: rootURL,
            mode: mode,
            storageRootURL: storageRootURL,
            fileManagerFactory: fileManagerFactory
        )
    }
}
