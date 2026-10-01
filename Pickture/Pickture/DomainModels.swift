import Foundation

nonisolated enum MediaKind: String, Codable, Hashable, Sendable {
    case photo
    case video
}

nonisolated enum MediaFormatKind: String, Codable, Hashable, Sendable {
    case raw
    case raster
    case video

    static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "nrw", "dng", "orf", "raf",
        "rw2", "pef", "srw", "3fr", "fff", "iiq", "raw", "rwl"
    ]

    static let rasterExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v"
    ]

    static func classify(fileExtension: String) -> MediaFormatKind? {
        let lower = fileExtension.lowercased()
        if rawExtensions.contains(lower) {
            return .raw
        } else if rasterExtensions.contains(lower) {
            return .raster
        } else if videoExtensions.contains(lower) {
            return .video
        } else {
            return nil
        }
    }

    static func rasterPriority(fileExtension: String) -> Int {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": return 0
        case "heic", "heif": return 1
        case "png": return 2
        case "tif", "tiff": return 3
        default: return 4
        }
    }
}

nonisolated struct MediaFile: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let url: URL
    let fileName: String
    let baseName: String
    let fileExtension: String
    let formatKind: MediaFormatKind
    let directoryURL: URL

    init(url: URL, formatKind: MediaFormatKind) {
        let standardized = url.standardizedFileURL
        self.id = standardized.path
        self.url = standardized
        self.fileName = standardized.lastPathComponent
        self.baseName = standardized.deletingPathExtension().lastPathComponent
        self.fileExtension = standardized.pathExtension
        self.formatKind = formatKind
        self.directoryURL = standardized.deletingLastPathComponent().standardizedFileURL
    }
}

nonisolated struct MediaPair: Hashable, Codable, Sendable {
    let rawFile: MediaFile
    let rasterFile: MediaFile
}

nonisolated struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let baseName: String
    let directoryURL: URL
    let relativeDirectoryPath: String
    let kind: MediaKind
    let primaryFile: MediaFile
    let mediaPair: MediaPair?
    let sidecarURL: URL?

    var isMediaPair: Bool {
        mediaPair != nil
    }

    var displayFileName: String {
        if let pair = mediaPair {
            return "\(baseName) (\(pair.rawFile.fileExtension.uppercased())+\(pair.rasterFile.fileExtension.uppercased()))"
        }
        return primaryFile.fileName
    }

    var badgeText: String {
        if isMediaPair {
            return "RAW+JPG"
        }
        switch kind {
        case .photo:
            return primaryFile.fileExtension.uppercased()
        case .video:
            return "VIDEO"
        }
    }

    var mediaTypeBadge: String {
        switch kind {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        }
    }

    func preferredFile(for source: PreviewSource) -> MediaFile {
        guard let pair = mediaPair else {
            return primaryFile
        }
        switch source {
        case .preferRaster:
            return pair.rasterFile
        case .preferRAW:
            return pair.rawFile
        }
    }
}

nonisolated enum SubfolderMode: String, Codable, CaseIterable, Hashable, Sendable {
    case immediate
    case recursive

    var isRecursive: Bool {
        self == .recursive
    }
}

nonisolated enum PreviewSource: String, Codable, CaseIterable, Hashable, Sendable {
    case preferRaster
    case preferRAW
}

nonisolated struct RecentFolder: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let displayPath: String
    let bookmarkData: Data
    let lastOpenedAt: Date
}

nonisolated struct StarRating: Hashable, Codable, Comparable, ExpressibleByIntegerLiteral, Sendable {
    let value: Int

    static let unrated = StarRating(0)

    init(_ value: Int) {
        self.value = min(5, max(0, value))
    }

    init(integerLiteral value: Int) {
        self.init(value)
    }

    static func < (lhs: StarRating, rhs: StarRating) -> Bool {
        lhs.value < rhs.value
    }
}

nonisolated enum PickFlag: String, Codable, CaseIterable, Hashable, Sendable {
    case picked
    case unflagged
    case rejected

    var xmpPickValue: Int {
        switch self {
        case .picked: return 1
        case .unflagged: return 0
        case .rejected: return -1
        }
    }
}

nonisolated enum ColorLabel: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case grey
}

nonisolated struct CurationMetadata: Hashable, Codable, Sendable {
    var starRating: StarRating
    var pickFlag: PickFlag
    var colorLabel: ColorLabel

    init(
        starRating: StarRating = .unrated,
        pickFlag: PickFlag = .unflagged,
        colorLabel: ColorLabel = .none
    ) {
        self.starRating = starRating
        self.pickFlag = pickFlag
        self.colorLabel = colorLabel
    }
}

nonisolated enum SyncState: String, Codable, CaseIterable, Hashable, Sendable {
    case synced
    case loading
    case pendingWrite
    case conflicted
    case syncError
}

nonisolated struct ExifMetadata: Hashable, Codable, Sendable {
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var fNumber: Double?
    var exposureTime: Double?
    var isoSpeedRatings: [Int]
    var dateTimeOriginal: Date?

    init(
        cameraModel: String? = nil,
        lensModel: String? = nil,
        focalLength: Double? = nil,
        fNumber: Double? = nil,
        exposureTime: Double? = nil,
        isoSpeedRatings: [Int] = [],
        dateTimeOriginal: Date? = nil
    ) {
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.isoSpeedRatings = isoSpeedRatings
        self.dateTimeOriginal = dateTimeOriginal
    }

    var isEmpty: Bool {
        cameraModel == nil &&
        lensModel == nil &&
        focalLength == nil &&
        fNumber == nil &&
        exposureTime == nil &&
        isoSpeedRatings.isEmpty &&
        dateTimeOriginal == nil
    }

    func supplementing(with fallback: ExifMetadata) -> ExifMetadata {
        ExifMetadata(
            cameraModel: self.cameraModel ?? fallback.cameraModel,
            lensModel: self.lensModel ?? fallback.lensModel,
            focalLength: self.focalLength ?? fallback.focalLength,
            fNumber: self.fNumber ?? fallback.fNumber,
            exposureTime: self.exposureTime ?? fallback.exposureTime,
            isoSpeedRatings: !self.isoSpeedRatings.isEmpty ? self.isoSpeedRatings : fallback.isoSpeedRatings,
            dateTimeOriginal: self.dateTimeOriginal ?? fallback.dateTimeOriginal
        )
    }
}

nonisolated struct BaseSnapshot: Hashable, Codable, Sendable {
    let metadata: CurationMetadata
    let fileDigest: String
    let modificationDate: Date?

    init(metadata: CurationMetadata, fileDigest: String, modificationDate: Date? = nil) {
        self.metadata = metadata
        self.fileDigest = fileDigest
        self.modificationDate = modificationDate
    }
}

nonisolated struct FieldDiff<T: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    let base: T?
    let local: T
    let remote: T

    var isConflicted: Bool {
        guard local != remote else {
            return false
        }
        guard let base else {
            return true
        }
        return local != base && remote != base
    }
}

nonisolated struct MetadataConflict: Hashable, Codable, Sendable {
    let itemID: String
    let base: CurationMetadata?
    let local: CurationMetadata
    let remote: CurationMetadata
    let starRatingDiff: FieldDiff<StarRating>
    let pickFlagDiff: FieldDiff<PickFlag>
    let colorLabelDiff: FieldDiff<ColorLabel>

    init(
        itemID: String,
        base: CurationMetadata?,
        local: CurationMetadata,
        remote: CurationMetadata
    ) {
        self.itemID = itemID
        self.base = base
        self.local = local
        self.remote = remote
        self.starRatingDiff = FieldDiff(base: base?.starRating, local: local.starRating, remote: remote.starRating)
        self.pickFlagDiff = FieldDiff(base: base?.pickFlag, local: local.pickFlag, remote: remote.pickFlag)
        self.colorLabelDiff = FieldDiff(base: base?.colorLabel, local: local.colorLabel, remote: remote.colorLabel)
    }

    var hasConflict: Bool {
        starRatingDiff.isConflicted || pickFlagDiff.isConflicted || colorLabelDiff.isConflicted
    }
}

nonisolated enum ConflictResolutionStrategy: Hashable, Sendable {
    case useLocal
    case useRemote
    case cherryPick(CurationMetadata)
}

nonisolated enum CloseFolderResult: Hashable, Sendable {
    case success
    case pendingWritesRemaining(Int)
    case closedWithPendingJournaled
}

#if canImport(SwiftUI)
import SwiftUI

extension ColorLabel {
    public var displayColor: Color {
        switch self {
        case .none: return .clear
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .grey: return .gray
        }
    }
}
#endif

nonisolated enum ViewMode: String, Codable, CaseIterable, Hashable, Sendable {
    case grid
    case filmstrip
}

nonisolated enum FilmstripDockPosition: String, Codable, CaseIterable, Hashable, Sendable {
    case bottom
    case right

    public var displayName: String {
        switch self {
        case .bottom: return "Bottom"
        case .right: return "Right"
        }
    }
}

nonisolated enum SwipeDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right
}

nonisolated struct SwipeRecord: Hashable, Codable, Sendable {
    public let itemID: String
    public let previousMetadata: CurationMetadata
    public let appliedAction: CurationAction
    public let direction: SwipeDirection
    public let timestamp: Date

    public init(
        itemID: String,
        previousMetadata: CurationMetadata,
        appliedAction: CurationAction,
        direction: SwipeDirection,
        timestamp: Date = Date()
    ) {
        self.itemID = itemID
        self.previousMetadata = previousMetadata
        self.appliedAction = appliedAction
        self.direction = direction
        self.timestamp = timestamp
    }
}

nonisolated enum CurationAction: Hashable, Codable, Sendable {
    case starRating(StarRating)
    case pickFlag(PickFlag)
    case colorLabel(ColorLabel)
    case compound(starRating: StarRating? = nil, pickFlag: PickFlag? = nil, colorLabel: ColorLabel? = nil)

    public static func setStarRating(_ rating: StarRating) -> CurationAction {
        .starRating(rating)
    }

    public static func setPickFlag(_ flag: PickFlag) -> CurationAction {
        .pickFlag(flag)
    }

    public static func setColorLabel(_ label: ColorLabel) -> CurationAction {
        .colorLabel(label)
    }

    public var starRatingValue: StarRating? {
        switch self {
        case .starRating(let r): return r
        case .compound(let r, _, _): return r
        default: return nil
        }
    }

    public var pickFlagValue: PickFlag? {
        switch self {
        case .pickFlag(let f): return f
        case .compound(_, let f, _): return f
        default: return nil
        }
    }

    public var colorLabelValue: ColorLabel? {
        switch self {
        case .colorLabel(let l): return l
        case .compound(_, _, let l): return l
        default: return nil
        }
    }

    public var displayName: String {
        var parts: [String] = []
        if let flag = pickFlagValue {
            switch flag {
            case .picked: parts.append("Picked")
            case .rejected: parts.append("Rejected")
            case .unflagged: parts.append("Unflagged")
            }
        }
        if let star = starRatingValue {
            if star.value > 0 {
                parts.append("\(star.value) Star\(star.value == 1 ? "" : "s")")
            } else {
                parts.append("0 Stars (Unrated)")
            }
        }
        if let label = colorLabelValue {
            if label != .none {
                parts.append("\(label.rawValue.capitalized) Label")
            } else {
                parts.append("No Color")
            }
        }
        if parts.isEmpty {
            return "No Action"
        }
        return parts.joined(separator: " + ")
    }

    public static func make(
        starRating: StarRating? = nil,
        pickFlag: PickFlag? = nil,
        colorLabel: ColorLabel? = nil
    ) -> CurationAction {
        let nonNilCount = (starRating != nil ? 1 : 0) + (pickFlag != nil ? 1 : 0) + (colorLabel != nil ? 1 : 0)
        if nonNilCount == 1 {
            if let starRating { return .starRating(starRating) }
            if let pickFlag { return .pickFlag(pickFlag) }
            if let colorLabel { return .colorLabel(colorLabel) }
        }
        return .compound(starRating: starRating, pickFlag: pickFlag, colorLabel: colorLabel)
    }
}

nonisolated enum SessionCommand: Hashable, Codable, Sendable {
    case curation(CurationAction)
    case selectPrevious
    case selectNext
    case selectFirst
    case selectLast
    case toggleViewMode
    case setViewMode(ViewMode)
    case togglePreviewSource
    case setPreviewSource(PreviewSource)
    case toggleAutoAdvance
    case setAutoAdvance(Bool)
    case toggleBorderTapNavigation
    case toggleSwipeMode
    case setSwipeMode(Bool)
    case undoLastSwipe
}

nonisolated enum ShortcutProfileKind: String, Codable, CaseIterable, Hashable, Sendable {
    case lightroom
    case captureOne
    case custom

    public var displayName: String {
        switch self {
        case .lightroom: return "Lightroom"
        case .captureOne: return "Capture One"
        case .custom: return "Custom"
        }
    }

    public var defaultKeyMappings: [String: SessionCommand] {
        switch self {
        case .lightroom:
            return [
                "0": .curation(.setStarRating(0)),
                "1": .curation(.setStarRating(1)),
                "2": .curation(.setStarRating(2)),
                "3": .curation(.setStarRating(3)),
                "4": .curation(.setStarRating(4)),
                "5": .curation(.setStarRating(5)),
                "p": .curation(.setPickFlag(.picked)),
                "x": .curation(.setPickFlag(.rejected)),
                "u": .curation(.setPickFlag(.unflagged)),
                "6": .curation(.setColorLabel(.red)),
                "7": .curation(.setColorLabel(.yellow)),
                "8": .curation(.setColorLabel(.green)),
                "9": .curation(.setColorLabel(.blue)),
                "g": .setViewMode(.grid),
                "e": .setViewMode(.filmstrip),
                " ": .toggleViewMode,
                "space": .toggleViewMode,
                "j": .togglePreviewSource,
                "a": .toggleAutoAdvance,
                "left": .selectPrevious,
                "arrowleft": .selectPrevious,
                "h": .selectPrevious,
                "[": .selectPrevious,
                "right": .selectNext,
                "arrowright": .selectNext,
                "l": .selectNext,
                "]": .selectNext,
                "up": .selectPrevious,
                "arrowup": .selectPrevious,
                "down": .selectNext,
                "arrowdown": .selectNext
            ]
        case .captureOne:
            return [
                "0": .curation(.setStarRating(0)),
                "1": .curation(.setStarRating(1)),
                "2": .curation(.setStarRating(2)),
                "3": .curation(.setStarRating(3)),
                "4": .curation(.setStarRating(4)),
                "5": .curation(.setStarRating(5)),
                "+": .curation(.setPickFlag(.picked)),
                "=": .curation(.setPickFlag(.picked)),
                "-": .curation(.setPickFlag(.rejected)),
                "u": .curation(.setPickFlag(.unflagged)),
                "p": .curation(.setPickFlag(.picked)),
                "x": .curation(.setPickFlag(.rejected)),
                "*": .curation(.setColorLabel(.green)),
                "6": .curation(.setColorLabel(.red)),
                "7": .curation(.setColorLabel(.yellow)),
                "8": .curation(.setColorLabel(.green)),
                "9": .curation(.setColorLabel(.blue)),
                "g": .setViewMode(.grid),
                "e": .setViewMode(.filmstrip),
                " ": .toggleViewMode,
                "space": .toggleViewMode,
                "j": .togglePreviewSource,
                "a": .toggleAutoAdvance,
                "left": .selectPrevious,
                "arrowleft": .selectPrevious,
                "h": .selectPrevious,
                "[": .selectPrevious,
                "right": .selectNext,
                "arrowright": .selectNext,
                "l": .selectNext,
                "]": .selectNext,
                "up": .selectPrevious,
                "arrowup": .selectPrevious,
                "down": .selectNext,
                "arrowdown": .selectNext
            ]
        case .custom:
            return ShortcutProfileKind.lightroom.defaultKeyMappings
        }
    }
}

nonisolated struct ShortcutProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: String { kind.rawValue }
    public var kind: ShortcutProfileKind
    public var name: String
    public var keyMappings: [String: SessionCommand]

    public init(kind: ShortcutProfileKind, name: String? = nil, keyMappings: [String: SessionCommand]? = nil) {
        self.kind = kind
        self.name = name ?? kind.displayName
        self.keyMappings = keyMappings ?? kind.defaultKeyMappings
    }

    public static let lightroom = ShortcutProfile(kind: .lightroom)
    public static let captureOne = ShortcutProfile(kind: .captureOne)

    public static func custom(overrides: [String: SessionCommand] = [:]) -> ShortcutProfile {
        var mappings = ShortcutProfileKind.lightroom.defaultKeyMappings
        for (k, v) in overrides {
            mappings[k.lowercased()] = v
        }
        return ShortcutProfile(kind: .custom, name: "Custom", keyMappings: mappings)
    }

    public func command(for key: String) -> SessionCommand? {
        let lower = key.lowercased()
        if let direct = keyMappings[key] { return direct }
        if let lowerMapped = keyMappings[lower] { return lowerMapped }
        if key == " " || lower == "space" {
            return keyMappings[" "] ?? keyMappings["space"]
        }
        if key == "\u{F702}" || lower == "arrowleft" || lower == "left" {
            return keyMappings["left"] ?? keyMappings["arrowleft"]
        }
        if key == "\u{F703}" || lower == "arrowright" || lower == "right" {
            return keyMappings["right"] ?? keyMappings["arrowright"]
        }
        if key == "\u{F700}" || lower == "arrowup" || lower == "up" {
            return keyMappings["up"] ?? keyMappings["arrowup"]
        }
        if key == "\u{F701}" || lower == "arrowdown" || lower == "down" {
            return keyMappings["down"] ?? keyMappings["arrowdown"]
        }
        return nil
    }
}

// MARK: - Multi-Facet FilterCriteria & Sorting Models

nonisolated enum StarRatingFilterMode: String, Codable, CaseIterable, Hashable, Sendable {
    case exact
    case minimum

    public var displayName: String {
        switch self {
        case .exact: return "Exact"
        case .minimum: return "Minimum (≥)"
        }
    }
}

nonisolated struct StarRatingFilter: Codable, Hashable, Sendable {
    public var mode: StarRatingFilterMode
    public var exactRatings: Set<Int>
    public var minimumRating: Int

    public init(mode: StarRatingFilterMode = .exact, exactRatings: Set<Int> = [], minimumRating: Int = 1) {
        self.mode = mode
        self.exactRatings = exactRatings
        self.minimumRating = minimumRating
    }

    public static func exact(_ ratings: Set<Int>) -> StarRatingFilter {
        StarRatingFilter(mode: .exact, exactRatings: ratings)
    }

    public static func exact(_ rating: Int) -> StarRatingFilter {
        StarRatingFilter(mode: .exact, exactRatings: [rating])
    }

    public static func minimum(_ min: Int) -> StarRatingFilter {
        StarRatingFilter(mode: .minimum, minimumRating: min)
    }

    public func matches(_ rating: Int) -> Bool {
        switch mode {
        case .exact:
            if exactRatings.isEmpty { return true }
            return exactRatings.contains(rating)
        case .minimum:
            return rating >= minimumRating
        }
    }
}

nonisolated enum MediaTypeFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case photo
    case video
    case mediaPair

    public var displayName: String {
        switch self {
        case .photo: return "Photo"
        case .video: return "Video"
        case .mediaPair: return "RAW+JPG"
        }
    }
}

nonisolated struct FilterCriteria: Codable, Hashable, Sendable {
    public var searchQuery: String = ""
    public var starRatingFilter: StarRatingFilter? = nil
    public var pickFlags: Set<PickFlag> = []
    public var colorLabels: Set<ColorLabel> = []
    public var cameraModels: Set<String> = []
    public var lensModels: Set<String> = []
    public var mediaTypes: Set<MediaTypeFilter> = []
    public var syncStates: Set<SyncState> = []

    public init(
        searchQuery: String = "",
        starRatingFilter: StarRatingFilter? = nil,
        pickFlags: Set<PickFlag> = [],
        colorLabels: Set<ColorLabel> = [],
        cameraModels: Set<String> = [],
        lensModels: Set<String> = [],
        mediaTypes: Set<MediaTypeFilter> = [],
        syncStates: Set<SyncState> = []
    ) {
        self.searchQuery = searchQuery
        self.starRatingFilter = starRatingFilter
        self.pickFlags = pickFlags
        self.colorLabels = colorLabels
        self.cameraModels = cameraModels
        self.lensModels = lensModels
        self.mediaTypes = mediaTypes
        self.syncStates = syncStates
    }

    public var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isStarRatingActive: Bool {
        guard let starRatingFilter else { return false }
        switch starRatingFilter.mode {
        case .exact:
            return !starRatingFilter.exactRatings.isEmpty
        case .minimum:
            return starRatingFilter.minimumRating > 0
        }
    }

    public var isPickFlagActive: Bool {
        !pickFlags.isEmpty
    }

    public var isColorLabelActive: Bool {
        !colorLabels.isEmpty
    }

    public var isCameraModelActive: Bool {
        !cameraModels.isEmpty
    }

    public var isLensModelActive: Bool {
        !lensModels.isEmpty
    }

    public var isMediaTypeActive: Bool {
        !mediaTypes.isEmpty
    }

    public var isSyncStateActive: Bool {
        !syncStates.isEmpty
    }

    public var activeFilterCount: Int {
        var count = 0
        if isSearchActive { count += 1 }
        if isStarRatingActive { count += 1 }
        if isPickFlagActive { count += 1 }
        if isColorLabelActive { count += 1 }
        if isCameraModelActive { count += 1 }
        if isLensModelActive { count += 1 }
        if isMediaTypeActive { count += 1 }
        if isSyncStateActive { count += 1 }
        return count
    }

    public var isActive: Bool {
        activeFilterCount > 0
    }

    public mutating func reset() {
        searchQuery = ""
        starRatingFilter = nil
        pickFlags.removeAll()
        colorLabels.removeAll()
        cameraModels.removeAll()
        lensModels.removeAll()
        mediaTypes.removeAll()
        syncStates.removeAll()
    }

    public func matches(
        item: MediaItem,
        curation: CurationMetadata,
        exif: ExifMetadata?,
        syncState: SyncState
    ) -> Bool {
        // 1. Search Query (filename substring, case-insensitive)
        if isSearchActive {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesPrimary = item.primaryFile.fileName.lowercased().contains(query)
            let matchesBase = item.baseName.lowercased().contains(query)
            let matchesDisplay = item.displayFileName.lowercased().contains(query)
            let matchesRaw = item.mediaPair?.rawFile.fileName.lowercased().contains(query) ?? false
            let matchesRaster = item.mediaPair?.rasterFile.fileName.lowercased().contains(query) ?? false
            if !matchesPrimary && !matchesBase && !matchesDisplay && !matchesRaw && !matchesRaster {
                return false
            }
        }

        // 2. Star Rating (exact or minimum >=)
        if isStarRatingActive, let filter = starRatingFilter {
            if !filter.matches(curation.starRating.value) {
                return false
            }
        }

        // 3. Pick Flag (OR within category)
        if isPickFlagActive {
            if !pickFlags.contains(curation.pickFlag) {
                return false
            }
        }

        // 4. Color Label (OR within category)
        if isColorLabelActive {
            if !colorLabels.contains(curation.colorLabel) {
                return false
            }
        }

        // 5. Camera Model (OR within category)
        if isCameraModelActive {
            guard let cam = exif?.cameraModel, cameraModels.contains(cam) else {
                return false
            }
        }

        // 6. Lens Model (OR within category)
        if isLensModelActive {
            guard let lens = exif?.lensModel, lensModels.contains(lens) else {
                return false
            }
        }

        // 7. Media Type (Photo, Video, MediaPair) (OR within category)
        if isMediaTypeActive {
            var matchedType = false
            if item.isMediaPair && mediaTypes.contains(.mediaPair) {
                matchedType = true
            } else if item.kind == .photo && !item.isMediaPair && mediaTypes.contains(.photo) {
                matchedType = true
            } else if item.kind == .video && mediaTypes.contains(.video) {
                matchedType = true
            }
            if !matchedType {
                return false
            }
        }

        // 8. Sync State (OR within category)
        if isSyncStateActive {
            if !syncStates.contains(syncState) {
                return false
            }
        }

        return true
    }
}

nonisolated enum SortField: String, Codable, CaseIterable, Hashable, Sendable {
    case fileName
    case captureDate
    case starRating

    public var displayName: String {
        switch self {
        case .fileName: return "Filename"
        case .captureDate: return "Capture Date"
        case .starRating: return "Star Rating"
        }
    }
}

nonisolated enum SortOrder: String, Codable, CaseIterable, Hashable, Sendable {
    case ascending
    case descending

    public var displayName: String {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }
}

nonisolated struct SortOption: Codable, Hashable, Sendable {
    public var field: SortField = .fileName
    public var order: SortOrder = .ascending

    public init(field: SortField = .fileName, order: SortOrder = .ascending) {
        self.field = field
        self.order = order
    }
}
