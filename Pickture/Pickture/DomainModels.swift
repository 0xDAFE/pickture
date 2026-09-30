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




