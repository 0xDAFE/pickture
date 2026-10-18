import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CullingSession: CullingInteractionTarget {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pickture", category: "sync")
    let storageRootURL: URL
    private let folderAccessService: FolderAccessService
    let mediaPipeline: MediaPipeline
    var mediaCache: MediaCache { mediaPipeline.cache }
    let metadataSyncEngine: MetadataSyncEngine
    var metadataSyncStore: MetadataSyncStore { metadataSyncEngine.syncStore }
    let interactionController: CullingInteractionController
    let prefetchCoordinator: PrefetchCoordinator
    private(set) var currentFolderURL: URL?
    private(set) var items: [MediaItem] = [] {
        didSet {
            recomputeCullingSequence(force: true)
            refreshDerivedCounts()
            triggerPrefetch()
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
    private(set) var loadingFullRAWItemIDs: Set<String> = []
    private(set) var loadedFullRAWItemIDs: Set<String> = []

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

    private(set) var cullingSequence: CullingSequence = CullingSequence()
    var visibleItems: [MediaItem] {
        cullingSequence.items
    }
    var visibleMediaPairCount: Int {
        cullingSequence.visibleMediaPairCount
    }
    var visibleVideoCount: Int {
        cullingSequence.visibleVideoCount
    }
    private(set) var conflictedItemsCount: Int = 0
    private(set) var pendingWritesCount: Int = 0

    var selectedItemID: String? {
        didSet {
            guard selectedItemID != oldValue else { return }
            triggerPrefetch()
        }
    }
    var lastErrorMessage: String?
    var filterCriteria: FilterCriteria = FilterCriteria() {
        didSet {
            recomputeCullingSequence(force: true)
            refreshDerivedCounts()
            triggerPrefetch()
        }
    }
    var sortOption: SortOption = SortOption(field: .fileName, order: .ascending) {
        didSet {
            recomputeCullingSequence(force: true)
            refreshDerivedCounts()
            triggerPrefetch()
        }
    }
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
    private(set) var indexedExifCount: Int = 0
    private(set) var totalExifTargetCount: Int = 0
    private(set) var isCullingNavigating: Bool = false
    private var navigationIdleTask: Task<Void, Never>? = nil
    private(set) var storageVolumeProfile: StorageVolumeProfile = .internalSSD
    var isHighSpeedLANOverrideEnabled: Bool = false {
        didSet {
            applyActiveVolumeProfile()
        }
    }
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
    var isResetSyncStoreAlertPresented: Bool = false
    var activeConflictItemID: String?
    var subfolderMode: SubfolderMode = .immediate
    var previewSource: PreviewSource = .preferRaster
    var isBorderTapNavigationEnabled: Bool = true
    var viewMode: ViewMode = .grid
    var filmstripDockPosition: FilmstripDockPosition = .bottom
    var isAutoAdvanceEnabled: Bool = false
    var isSwipeModeEnabled: Bool = false

    var shortcutProfileKind: ShortcutProfileKind {
        get { interactionController.shortcutProfileKind }
        set { interactionController.shortcutProfileKind = newValue }
    }

    var customShortcutMappings: [String: SessionCommand] {
        get { interactionController.customShortcutMappings }
        set { interactionController.customShortcutMappings = newValue }
    }

    var swipeRightAction: CurationAction {
        get { interactionController.swipeRightAction }
        set { interactionController.swipeRightAction = newValue }
    }

    var swipeLeftAction: CurationAction {
        get { interactionController.swipeLeftAction }
        set { interactionController.swipeLeftAction = newValue }
    }

    var swipeHistory: [SwipeRecord] {
        interactionController.swipeHistory
    }

    var canUndoSwipe: Bool {
        interactionController.canUndoSwipe
    }

    var activeShortcutProfile: ShortcutProfile {
        interactionController.activeShortcutProfile
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
        interactionController.setShortcutProfileKind(kind)
    }

    func setCustomShortcut(key: String, command: SessionCommand) {
        interactionController.setCustomShortcut(key: key, command: command)
    }

    func toggleAutoAdvance() {
        isAutoAdvanceEnabled.toggle()
    }

    func setAutoAdvance(_ enabled: Bool) {
        isAutoAdvanceEnabled = enabled
    }

    func togglePreviewSource() {
        previewSource = (previewSource == .preferRaster) ? .preferRAW : .preferRaster
        triggerPrefetch()
    }

    func setPreviewSource(_ source: PreviewSource) {
        previewSource = source
        triggerPrefetch()
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
        interactionController.setSwipeRightAction(action)
    }

    func setSwipeLeftAction(_ action: CurationAction) {
        interactionController.setSwipeLeftAction(action)
    }

    func borderTapZoneWidth(for containerWidth: CGFloat) -> CGFloat {
        CullingLayoutCalculator.borderTapZoneWidth(for: containerWidth)
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

    func aspectRatioKey(for itemID: String, previewSource: PreviewSource) -> String {
        "\(itemID)#\(previewSource.rawValue)"
    }

    func aspectRatioKey(for item: MediaItem, previewSource: PreviewSource) -> String {
        aspectRatioKey(for: item.id, previewSource: previewSource)
    }

    func thumbnailAspectRatio(for item: MediaItem, previewSource: PreviewSource? = nil) -> CGFloat {
        let source = previewSource ?? self.previewSource
        let key = aspectRatioKey(for: item, previewSource: source)
        if let cachedRatio = thumbnailAspectRatios[key] {
            return cachedRatio
        }
        if let legacyRatio = thumbnailAspectRatios[item.id] {
            return legacyRatio
        }
        return fallbackAspectRatio(for: item)
    }

    func recordThumbnailAspectRatio(
        _ ratio: CGFloat,
        for item: MediaItem,
        previewSource: PreviewSource? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        guard !ratio.isNaN && !ratio.isInfinite && ratio > 0 else { return }
        let source = previewSource ?? self.previewSource
        let key = aspectRatioKey(for: item, previewSource: source)
        thumbnailAspectRatios[key] = ratio
        if source == self.previewSource {
            thumbnailAspectRatios[item.id] = ratio
        }

        if let width = pixelWidth, let height = pixelHeight, width > 0, height > 0 {
            let cacheKey = mediaPipeline.thumbnailCacheKey(for: item, previewSource: source)
            Task { [cache = mediaPipeline.cache] in
                await cache.recordDimensions(key: cacheKey, pixelWidth: width, pixelHeight: height)
            }
        }
    }

    func recordThumbnailAspectRatio(_ ratio: CGFloat, for itemID: String) {
        guard !ratio.isNaN && !ratio.isInfinite && ratio > 0 else { return }
        thumbnailAspectRatios[itemID] = ratio
        let key = aspectRatioKey(for: itemID, previewSource: self.previewSource)
        thumbnailAspectRatios[key] = ratio
    }

    @discardableResult
    func warmThumbnailAspectRatios(for targetItems: [MediaItem]) -> Task<Void, Never>? {
        guard !targetItems.isEmpty else { return nil }
        let pipeline = self.mediaPipeline
        var keysToQuery: [String] = []
        var itemSourceToKey: [(itemID: String, source: PreviewSource, cacheKey: String)] = []
        for item in targetItems {
            if item.isMediaPair {
                let rasterKey = pipeline.thumbnailCacheKey(for: item, previewSource: .preferRaster)
                let rawKey = pipeline.thumbnailCacheKey(for: item, previewSource: .preferRAW)
                keysToQuery.append(rasterKey)
                keysToQuery.append(rawKey)
                itemSourceToKey.append((item.id, .preferRaster, rasterKey))
                itemSourceToKey.append((item.id, .preferRAW, rawKey))
            } else {
                let key = pipeline.thumbnailCacheKey(for: item, previewSource: .preferRaster)
                keysToQuery.append(key)
                itemSourceToKey.append((item.id, .preferRaster, key))
                itemSourceToKey.append((item.id, .preferRAW, key))
            }
        }

        return Task.detached(priority: .userInitiated) { [weak self, pipeline, keysToQuery, itemSourceToKey] in
            let cachedRatios = await pipeline.cache.batchAspectRatios(keys: keysToQuery)
            guard !cachedRatios.isEmpty, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                for mapping in itemSourceToKey {
                    if let ratio = cachedRatios[mapping.cacheKey] {
                        let memoryKey = self.aspectRatioKey(for: mapping.itemID, previewSource: mapping.source)
                        self.thumbnailAspectRatios[memoryKey] = ratio
                        if mapping.source == self.previewSource {
                            self.thumbnailAspectRatios[mapping.itemID] = ratio
                        }
                    }
                }
            }
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
        CullingLayoutCalculator.defaultGridMetadataDeckHeight
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
        return CullingLayoutCalculator.gridItemSilhouetteSize(
            aspectRatio: ratio,
            columnWidth: columnWidth,
            mediaKind: item.kind
        )
    }

    @discardableResult
    func handleBorderTap(at location: CGPoint, in containerSize: CGSize) -> Bool {
        guard isBorderTapNavigationEnabled else { return false }
        guard let direction = CullingLayoutCalculator.borderTapDirection(at: location, in: containerSize) else {
            return false
        }
        switch direction {
        case .previous:
            selectPreviousItem()
            return true
        case .next:
            selectNextItem()
            return true
        }
    }

    var currentSequenceIndex: Int? {
        let items = cullingSequence.items
        guard !items.isEmpty else { return nil }
        if let currentID = selectedItemID,
           let currentIndex = cullingSequence.index(for: currentID) {
            return currentIndex
        }
        return 0
    }

    var canSelectNextItem: Bool {
        guard let currentIndex = currentSequenceIndex else { return false }
        return currentIndex + 1 < cullingSequence.items.count
    }

    var canSelectPreviousItem: Bool {
        guard let currentIndex = currentSequenceIndex else { return false }
        return currentIndex > 0
    }

    func selectNextItem() {
        let items = cullingSequence.items
        guard let currentIndex = currentSequenceIndex else { return }
        if currentIndex + 1 < items.count {
            selectedItemID = items[currentIndex + 1].id
        }
    }

    func selectPreviousItem() {
        let items = cullingSequence.items
        guard let currentIndex = currentSequenceIndex else { return }
        if currentIndex > 0 {
            selectedItemID = items[currentIndex - 1].id
        }
    }

    func selectFirstItem() {
        if let first = cullingSequence.items.first {
            selectedItemID = first.id
        }
    }

    func selectLastItem() {
        if let last = cullingSequence.items.last {
            selectedItemID = last.id
        }
    }

    @discardableResult
    func executeCommand(_ command: SessionCommand) -> Bool {
        interactionController.executeCommand(command)
    }

    @discardableResult
    func handleShortcutKey(_ rawKey: String) -> Bool {
        interactionController.handleShortcutKey(rawKey)
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
        interactionController.executeSwipe(direction)
    }

    @discardableResult
    func executeSwipe(_ direction: SwipeDirection, for item: MediaItem) -> Bool {
        interactionController.executeSwipe(direction, for: item)
    }

    @discardableResult
    func undoLastSwipe() -> Bool {
        interactionController.undoLastSwipe()
    }

    func restoreSwipeState(for itemID: String, metadata: CurationMetadata) -> Bool {
        guard let item = items.first(where: { $0.id == itemID }) else { return false }
        updateCurationMetadata(metadata, for: item)
        selectedItemID = itemID
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
        let pipeline = self.mediaPipeline
        self.prefetchCoordinator = PrefetchCoordinator(
            cacheCapacityProvider: {
                DecodedImageCache.shared.countLimit
            },
            isItemCached: { [weak pipeline] item, source in
                guard let pipeline else { return false }
                let key = pipeline.previewCacheKey(for: item, previewSource: source, maxPixelSize: 2048)
                return DecodedImageCache.shared.image(forKey: key) != nil
            },
            previewFetcher: { [weak pipeline] item, source in
                guard let pipeline else { return }
                _ = await pipeline.loadPreviewImage(for: item, previewSource: source, maxPixelSize: 2048)
            }
        )
        let syncStoreURL = resolvedStorageRoot.appendingPathComponent("MetadataSyncStore", isDirectory: true)
        self.metadataSyncEngine = MetadataSyncEngine(storeDirectoryURL: syncStoreURL)
        self.interactionController = CullingInteractionController()
        self.recentFolders = self.folderAccessService.loadRecentFolders()
        self.setupMetadataSyncEngineBindings()
        self.interactionController.target = self
    }

    private func triggerPrefetch() {
        guard let id = selectedItemID else { return }
        let currentVisible = visibleItems
        let currentSource = previewSource
        let coordinator = prefetchCoordinator

        // Flag active culling navigation to pause background EXIF extraction
        isCullingNavigating = true
        navigationIdleTask?.cancel()
        navigationIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.isCullingNavigating = false
        }

        Task {
            await coordinator.navigate(
                selectedID: id,
                visibleItems: currentVisible,
                previewSource: currentSource
            )
        }
    }

    func toggleHighSpeedLANOverride() {
        isHighSpeedLANOverrideEnabled.toggle()
    }

    func setHighSpeedLANOverride(_ enabled: Bool) {
        isHighSpeedLANOverrideEnabled = enabled
    }

    func setStorageVolumeProfile(_ profile: StorageVolumeProfile) {
        self.storageVolumeProfile = profile
        applyActiveVolumeProfile()
    }

    private func applyActiveVolumeProfile() {
        let profile = storageVolumeProfile
        let highSpeed = isHighSpeedLANOverrideEnabled
        metadataSyncEngine.setStorageVolumeProfile(profile, isHighSpeedLAN: highSpeed)
        Task {
            await mediaPipeline.applyStorageVolumeProfile(profile, isHighSpeedLAN: highSpeed)
            await prefetchCoordinator.applyStorageVolumeProfile(profile, isHighSpeedLAN: highSpeed)
        }
    }

    private func setupMetadataSyncEngineBindings() {
        metadataSyncEngine.setStorageVolumeProfile(storageVolumeProfile, isHighSpeedLAN: isHighSpeedLANOverrideEnabled)
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
            if let existing = self?.exifByItemID[itemID] {
                self?.exifByItemID[itemID] = exif.supplementing(with: existing)
            } else {
                self?.exifByItemID[itemID] = exif
            }
        }
    }

    func thumbnailCacheKey(for item: MediaItem, maxPixelSize: Int = 360) -> String {
        mediaPipeline.thumbnailCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func isThumbnailCached(for item: MediaItem, maxPixelSize: Int = 360) async -> Bool {
        await mediaPipeline.isThumbnailCached(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func inMemoryThumbnailImage(for item: MediaItem, maxPixelSize: Int = 360) -> CGImage? {
        mediaPipeline.inMemoryThumbnailImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func cachedThumbnailImage(for item: MediaItem, maxPixelSize: Int = 360) async -> CGImage? {
        await mediaPipeline.cachedThumbnailImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func setCacheSizeLimitBytes(_ limitBytes: Int64) async {
        await mediaPipeline.setCacheSizeLimitBytes(limitBytes)
    }

    func setUserConfiguredCacheSizeLimitBytes(_ limitBytes: Int64) {
        mediaPipeline.setUserConfiguredCacheSizeLimitBytes(limitBytes)
    }

    func clearMediaCache() async {
        DecodedImageCache.shared.clear()
        thumbnailAspectRatios.removeAll()
        loadedFullRAWItemIDs.removeAll()
        loadingFullRAWItemIDs.removeAll()
        self.cacheGeneration &+= 1
        await mediaPipeline.clearCache()
    }

    /// Flushes the thumbnail cache index immediately to disk.
    /// Called on session close, background transition, or application termination.
    func flushMediaCacheIndex() async {
        await mediaPipeline.flushIndexImmediately()
    }

    /// Resets the persistent SQLite MetadataSyncStore and re-hydrates in-memory state.
    func resetMetadataSyncStore() async {
        backgroundExifTask?.cancel()
        _ = await backgroundExifTask?.value
        backgroundExifTask = nil
        isExifPreloading = false
        await metadataSyncEngine.resetMetadataSyncStore()
        refreshDerivedCounts()
        recomputeCullingSequence(force: true)
    }

    /// Waits for any background SQLite point writes to complete.
    func waitForPendingStoreWrites() async {
        await metadataSyncEngine.waitForPendingStoreWrites()
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
        if filterCriteria.isActive || sortOption.field == .starRating {
            recomputeCullingSequence()
        }
    }

    func stagePendingMetadata(_ metadata: CurationMetadata, for item: MediaItem) {
        metadataSyncEngine.stagePendingMetadata(metadata, for: item)
        refreshDerivedCounts()
        if filterCriteria.isActive || sortOption.field == .starRating {
            recomputeCullingSequence()
        }
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

    func exifMetadata(forItemID itemID: String) -> ExifMetadata {
        exifByItemID[itemID] ?? metadataSyncStore.cachedRecord(for: itemID)?.exif ?? ExifMetadata()
    }

    func exifMetadata(for item: MediaItem) -> ExifMetadata {
        exifMetadata(forItemID: item.id)
    }

    /// Preloads EXIF metadata for all current items in the culling session adhering to storageVolumeProfile.
    func preloadExifMetadataForCurrentItems() {
        startBackgroundExifPreloading(for: self.items)
    }

    /// Preloads EXIF metadata in the background off the MainActor.
    /// Runs via Task.detached at .utility priority so network-bound header reads over NAS/SMB
    /// do not inherit @MainActor isolation or block UI event processing.
    func startBackgroundExifPreloading(for targetItems: [MediaItem]) {
        backgroundExifTask?.cancel()
        let itemsToLoad = targetItems.filter { item in
            guard item.kind != .video else { return false }
            if headerSupplementedItemIDs.contains(item.id) { return false }
            let existing = exifMetadata(for: item)
            if existing.cameraModel != nil && existing.lensModel != nil && existing.dateTimeOriginal != nil && !existing.isoSpeedRatings.isEmpty && existing.focalLength != nil {
                headerSupplementedItemIDs.insert(item.id)
                exifByItemID[item.id] = existing
                return false
            }
            return true
        }
        guard !itemsToLoad.isEmpty else {
            isExifPreloading = false
            indexedExifCount = 0
            totalExifTargetCount = 0
            return
        }

        isExifPreloading = true
        totalExifTargetCount = itemsToLoad.count
        indexedExifCount = 0

        var lastThrottledTime = Date.distantPast
        let volumeProfile = self.storageVolumeProfile

        backgroundExifTask = Task.detached(priority: .utility) { [weak self] in
            let extracted = await ExifHeaderExtractor.extractBatch(
                for: itemsToLoad,
                volumeProfile: volumeProfile,
                isPaused: { [weak self] in
                    await MainActor.run { [weak self] in
                        self?.isCullingNavigating ?? false
                    }
                },
                onProgress: { [weak self] count, itemID, exif in
                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        self.indexedExifCount = count
                        let existing = self.exifMetadata(forItemID: itemID)
                        let merged = existing.supplementing(with: exif)
                        self.headerSupplementedItemIDs.insert(itemID)
                        self.exifByItemID[itemID] = merged
                        self.metadataSyncEngine.enqueueStoreOperation { [metadataSyncStore] in
                            await metadataSyncStore.recordExif(merged, for: itemID)
                        }

                        let now = Date()
                        if now.timeIntervalSince(lastThrottledTime) >= 0.25 {
                            lastThrottledTime = now
                            if self.sortOption.field == .captureDate || self.filterCriteria.isCameraModelActive || self.filterCriteria.isLensModelActive {
                                self.recomputeCullingSequence(force: true)
                                self.refreshDerivedCounts()
                            }
                        }
                    }
                }
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.isExifPreloading = false
                self.backgroundExifTask = nil
                for (itemID, headerExif) in extracted {
                    let existing = self.exifMetadata(forItemID: itemID)
                    let merged = existing.supplementing(with: headerExif)
                    self.headerSupplementedItemIDs.insert(itemID)
                    self.exifByItemID[itemID] = merged
                    self.metadataSyncEngine.enqueueStoreOperation { [metadataSyncStore] in
                        await metadataSyncStore.recordExif(merged, for: itemID)
                    }
                }
                self.recomputeCullingSequence(force: true)
                self.refreshDerivedCounts()
            }
        }
    }

    func waitForBackgroundExifPreloading() async {
        _ = await backgroundExifTask?.value
    }

    func captureDate(for item: MediaItem) -> Date? {
        exifMetadata(for: item).dateTimeOriginal
    }

    func recomputeCullingSequence(force: Bool = false) {
        if !force && !filterCriteria.isActive && sortOption.field != .starRating && cullingSequence.items.count == items.count {
            return
        }

        let filtered = items.filter { item in
            let curation = curationMetadata(for: item)
            let exif = exifMetadata(for: item)
            let sync = syncState(for: item)
            return filterCriteria.matches(item: item, curation: curation, exif: exif, syncState: sync)
        }

        let sorted = filtered.sorted { itemA, itemB in
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

        if sorted != cullingSequence.items {
            cullingSequence = CullingSequence(items: sorted)
        }
    }

    func refreshDerivedCounts() {
        pendingWritesCount = metadataSyncEngine.pendingWritesCount
        conflictedItemsCount = metadataSyncEngine.conflictedItemsCount
    }

    var availableCameraModels: [String] {
        var set = Set<String>()
        for item in items {
            let exif = exifMetadata(for: item)
            if let model = exif.cameraModel, !model.isEmpty {
                set.insert(model)
            }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var availableLensModels: [String] {
        var set = Set<String>()
        for item in items {
            let exif = exifMetadata(for: item)
            if let lens = exif.lensModel, !lens.isEmpty {
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
            await mediaPipeline.flushIndexImmediately()
            return .success
        }

        let result = await metadataSyncEngine.close(
            timeoutNanoseconds: timeoutNanoseconds,
            force: force,
            items: items
        )
        if result == .success || result == .closedWithPendingJournaled {
            cleanCloseSession()
            await mediaPipeline.flushIndexImmediately()
        }
        return result
    }

    private func cleanCloseSession() {
        let coordinator = prefetchCoordinator
        Task {
            await coordinator.cancelAll()
        }
        metadataSyncEngine.reset()
        interactionController.clearSwipeHistory()
        backgroundExifTask?.cancel()
        isExifPreloading = false
        indexedExifCount = 0
        totalExifTargetCount = 0
        isCullingNavigating = false
        navigationIdleTask?.cancel()
        navigationIdleTask = nil
        DirectoryListingCache.shared.clear()
        Task { @concurrent [mediaPipeline] in
            await mediaPipeline.flushIndexImmediately()
        }
        isDiscovering = false
        openFolderProgress = nil
        folderAccessService.stopAccessingCurrentFolder()
        currentFolderURL = nil
        items.removeAll()
        selectedItemID = nil
        thumbnailAspectRatios.removeAll()
        activeConflictItemID = nil
        isConflictSheetPresented = false
        lastErrorMessage = nil
        loadedFullRAWItemIDs.removeAll()
        loadingFullRAWItemIDs.removeAll()
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

    func loadThumbnailImage(for item: MediaItem, maxPixelSize: Int = 360) async -> CGImage? {
        let image = await mediaPipeline.loadThumbnailImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let image {
            recordThumbnailAspectRatio(image.aspectRatio, for: item, previewSource: previewSource)
        }
        return image
    }

    func loadThumbnailData(for item: MediaItem, maxPixelSize: Int = 360) async -> Data? {
        let data = await mediaPipeline.loadThumbnailData(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
        if let data, let image = await ImageDecoderActor.shared.decode(from: data) {
            recordThumbnailAspectRatio(image.aspectRatio, for: item, previewSource: previewSource)
        }
        return data
    }

    func previewCacheKey(for item: MediaItem, maxPixelSize: Int = 2048) -> String {
        mediaPipeline.previewCacheKey(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func inMemoryPreviewImage(for item: MediaItem, maxPixelSize: Int = 2048) -> CGImage? {
        mediaPipeline.inMemoryPreviewImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func inMemoryFullRAWImage(for item: MediaItem) -> CGImage? {
        mediaPipeline.inMemoryFullRAWImage(for: item)
    }

    func cachedPreviewImage(for item: MediaItem, maxPixelSize: Int = 2048) async -> CGImage? {
        await mediaPipeline.cachedPreviewImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func cachedFullRAWImage(for item: MediaItem) async -> CGImage? {
        await mediaPipeline.cachedFullRAWImage(for: item)
    }

    func loadPreviewImage(for item: MediaItem, maxPixelSize: Int = 2048) async -> CGImage? {
        await mediaPipeline.loadPreviewImage(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func loadPreviewImageData(for item: MediaItem, maxPixelSize: Int = 2048) async -> Data? {
        await mediaPipeline.loadPreviewImageData(for: item, previewSource: previewSource, maxPixelSize: maxPixelSize)
    }

    func isLoadingFullRAW(for item: MediaItem) -> Bool {
        loadingFullRAWItemIDs.contains(item.id)
    }

    func isFullRAWLoaded(for item: MediaItem) -> Bool {
        loadedFullRAWItemIDs.contains(item.id) || inMemoryFullRAWImage(for: item) != nil
    }

    func previewRepresentation(for item: MediaItem) -> PreviewRepresentation {
        if item.isMediaPair && previewSource == .preferRaster {
            return .raster
        }
        return isFullRAWLoaded(for: item) ? .fullRAW : .rawPreview
    }

    func loadFullRAW(for item: MediaItem) async -> CGImage? {
        if let existing = inMemoryFullRAWImage(for: item) {
            loadedFullRAWItemIDs.insert(item.id)
            return existing
        }
        loadingFullRAWItemIDs.insert(item.id)
        defer {
            loadingFullRAWItemIDs.remove(item.id)
        }
        let image = await mediaPipeline.loadFullRAW(for: item)
        if image != nil {
            loadedFullRAWItemIDs.insert(item.id)
        }
        return image
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

    private static func mergeSortedMediaItems(
        _ lhs: [MediaItem],
        _ rhs: [MediaItem],
        by comparator: (MediaItem, MediaItem) -> Bool = MediaDiscovery.mediaItemSortComparator
    ) -> [MediaItem] {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        var merged: [MediaItem] = []
        merged.reserveCapacity(lhs.count + rhs.count)
        var i = 0
        var j = 0
        while i < lhs.count && j < rhs.count {
            if comparator(lhs[i], rhs[j]) {
                merged.append(lhs[i])
                i += 1
            } else {
                merged.append(rhs[j])
                j += 1
            }
        }
        if i < lhs.count {
            merged.append(contentsOf: lhs[i...])
        }
        if j < rhs.count {
            merged.append(contentsOf: rhs[j...])
        }
        return merged
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
        var pendingMetadataBatch: [MediaItem] = []
        var lastPublishedTime = Date.distantPast
        var hasSetCurrentFolder = false

        self.storageVolumeProfile = StorageVolumeDetector.detectProfile(for: resolvedURL)
        applyActiveVolumeProfile()

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
                accumulatedItems = Self.mergeSortedMediaItems(accumulatedItems, batch.items)
                pendingMetadataBatch.append(contentsOf: batch.items)

                let now = Date()
                if now.timeIntervalSince(lastPublishedTime) >= 0.25 {
                    lastPublishedTime = now
                    self.items = accumulatedItems
                    self.initializeMetadata(for: pendingMetadataBatch)
                    pendingMetadataBatch.removeAll()
                    self.openFolderProgress = batch.progress
                    self.recomputeCullingSequence(force: true)
                    await Task.yield()
                }
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

        self.items = accumulatedItems
        if !pendingMetadataBatch.isEmpty {
            self.initializeMetadata(for: pendingMetadataBatch)
            pendingMetadataBatch.removeAll()
        }
        self.openFolderProgress = 1.0
        self.recomputeCullingSequence(force: true)
        self.refreshDerivedCounts()

        self.lastErrorMessage = nil
        if !isSyncSuspended {
            scheduleFlushPendingWrites()
        }
        warmThumbnailAspectRatios(for: self.items)
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
            self.storageVolumeProfile = StorageVolumeDetector.detectProfile(for: resolvedURL)
            applyActiveVolumeProfile()
            let discoveredItems = try discoverItems(in: resolvedURL.standardizedFileURL, mode: subfolderMode)
            self.recentFolders = updatedRecents
            self.currentFolderURL = resolvedURL
            self.items = discoveredItems
            initializeMetadata(for: self.items)
            warmThumbnailAspectRatios(for: self.items)
            self.lastErrorMessage = nil
            if !isSyncSuspended {
                scheduleFlushPendingWrites()
            }
            recomputeCullingSequence(force: true)
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

    func waitForBackgroundHydration() async {
        await metadataSyncEngine.waitForBackgroundHydration()
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
