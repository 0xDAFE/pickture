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


