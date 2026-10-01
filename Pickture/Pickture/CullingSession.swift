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
    var filterCriteria: FilterCriteria = FilterCriteria()
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
    private var flushContinuations: [CheckedContinuation<Void, Never>] = []
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
        let safeRatio: CGFloat
        if aspectRatio.isNaN || aspectRatio.isInfinite || aspectRatio <= 0 {
            safeRatio = (mediaKind == .video) ? 1.777 : 1.5
        } else {
            safeRatio = aspectRatio
        }

        switch dockPosition {
        case .bottom:
            let height: CGFloat = 72.0
            let unroundedWidth = height * safeRatio
            let clampedWidth = min(128.0, max(48.0, unroundedWidth.rounded()))
            return CGSize(width: clampedWidth, height: height)

        case .right:
            let width: CGFloat = 112.0
            let divisor = max(0.1, safeRatio)
            let unroundedHeight = width / divisor
            let clampedHeight = min(150.0, max(64.0, unroundedHeight.rounded()))
            return CGSize(width: width, height: clampedHeight)
        }
    }

    func fallbackAspectRatio(for kind: MediaKind) -> CGFloat {
        kind == .video ? 1.777 : 1.5
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
        guard !columnWidth.isNaN, !columnWidth.isInfinite, columnWidth > 0 else {
            return 140.0
        }
        return (columnWidth * 0.75).rounded()
    }

    /// Computes the exact silhouette size of a media item floating inside the bounded Image Stage,
    /// preserving its true uncropped aspect ratio while resting on the uniform baseline shelf.
    func gridItemSilhouetteSize(
        aspectRatio: CGFloat,
        stageWidth: CGFloat,
        stageHeight: CGFloat,
        mediaKind: MediaKind? = nil
    ) -> CGSize {
        let safeRatio: CGFloat
        if aspectRatio.isNaN || aspectRatio.isInfinite || aspectRatio <= 0 {
            safeRatio = fallbackAspectRatio(for: mediaKind ?? .photo)
        } else {
            safeRatio = aspectRatio
        }

        let safeStageWidth = max(1.0, stageWidth)
        let safeStageHeight = max(1.0, stageHeight)
        let stageRatio = safeStageWidth / safeStageHeight

        if safeRatio >= stageRatio {
            // Wider than or equal to stage ceiling: constrained by stageWidth
            let width = safeStageWidth
            let height = width / safeRatio
            return CGSize(width: width, height: height)
        } else {
            // Taller than stage ceiling: constrained by stageHeight
            let height = safeStageHeight
            let width = height * safeRatio
            return CGSize(width: width, height: height)
        }
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
        thumbnailAspectRatios.removeAll()
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

    func preloadExifMetadata(for targetItems: [MediaItem]) async {
        let itemsToLoad = targetItems.filter { item in
            if headerSupplementedItemIDs.contains(item.id) { return false }
            let existing = exifByItemID[item.id] ?? metadataSyncStore.record(for: item.id)?.exif ?? ExifMetadata()
            if existing.cameraModel != nil && existing.lensModel != nil && existing.dateTimeOriginal != nil && !existing.isoSpeedRatings.isEmpty && existing.focalLength != nil {
                headerSupplementedItemIDs.insert(item.id)
                exifByItemID[item.id] = existing
                return false
            }
            return true
        }
        guard !itemsToLoad.isEmpty else { return }

        let extracted = await ExifHeaderExtractor.extractBatch(for: itemsToLoad)

        for (itemID, headerExif) in extracted {
            let existing = exifByItemID[itemID] ?? metadataSyncStore.record(for: itemID)?.exif ?? ExifMetadata()
            let merged = existing.supplementing(with: headerExif)
            headerSupplementedItemIDs.insert(itemID)
            exifByItemID[itemID] = merged
            metadataSyncStore.recordExif(merged, for: itemID)
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

    var syncErrorItemsCount: Int {
        items.filter { syncState(for: $0) == .syncError }.count
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
        let errors = syncErrorItemsCount
        if errors > 0 {
            return "\(errors) Error\(errors == 1 ? "" : "s")"
        }
        return "Synced"
    }

    func flushPendingWrites() async {
        guard !isFlushingPendingWrites else {
            await withCheckedContinuation { continuation in
                flushContinuations.append(continuation)
            }
            return
        }
        isFlushingPendingWrites = true
        defer {
            isFlushingPendingWrites = false
            let continuations = flushContinuations
            flushContinuations.removeAll()
            for c in continuations {
                c.resume()
            }
        }

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
                    print("[DEBUG-SMB-SYNC] Flush error on \(item.displayFileName): domain=\(nsError.domain) code=\(nsError.code) underlying=\(underlying?.domain ?? "none")(\(underlying?.code ?? -1)) desc=\(error.localizedDescription)")
                    lastErrorMessage = "Sync error on \(item.displayFileName): \(error.localizedDescription)"
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
        await flushPendingWrites()
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

            let writtenTargets = try await SidecarCodec.write(curation: pendingCuration, for: item)

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
                try await SidecarCodec.write(curation: chosen, for: item)
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
        await preloadExifMetadata(for: self.items)
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

    func reopenRecentFolder(_ recentFolder: RecentFolder) throws {
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

    func removeRecentFolder(_ recentFolder: RecentFolder) {
        self.recentFolders = folderAccessService.removeRecentFolder(id: recentFolder.id)
    }

    private func applyOpenedFolder(resolvedURL: URL, updatedRecents: [RecentFolder]) throws {
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
            Task { [weak self] in
                guard let self else { return }
                await self.preloadExifMetadata(for: self.items)
            }
        } catch {
            folderAccessService.stopAccessingCurrentFolder()
            throw error
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
            Task { [weak self] in
                guard let self else { return }
                await self.preloadExifMetadata(for: self.items)
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
                if let diskExif, !diskExif.isEmpty {
                    if let persistedExif = persisted.exif {
                        exifByItemID[item.id] = diskExif.supplementing(with: persistedExif)
                    } else {
                        exifByItemID[item.id] = diskExif
                    }
                } else if let persistedExif = persisted.exif {
                    exifByItemID[item.id] = persistedExif
                }

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
                        metadataSyncStore.recordBaseSnapshot(snapshot, exif: exifByItemID[item.id] ?? diskExif, for: item.id)
                    } else {
                        metadataByItemID[item.id] = persisted.metadata
                        syncStateByItemID[item.id] = .synced
                        baseSnapshotByItemID[item.id] = persisted.baseSnapshot
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
