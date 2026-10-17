import Foundation

/// Storage medium profile governing decoder concurrency, worker limits, and prefetch depth.
public nonisolated enum StorageVolumeProfile: String, CaseIterable, Codable, Sendable {
    case internalSSD
    case removableMedia
    case networkShare

    public var displayName: String {
        switch self {
        case .internalSSD: return "Internal SSD"
        case .removableMedia: return "Removable Media"
        case .networkShare: return "Network Share"
        }
    }

    public var defaultThumbnailWorkers: Int {
        switch self {
        case .internalSSD: return 6
        case .removableMedia: return 3
        case .networkShare: return 2
        }
    }

    public var defaultHeavyDecodePermits: Int {
        switch self {
        case .internalSSD: return 4
        case .removableMedia: return 2
        case .networkShare: return 1
        }
    }

    public var defaultSidecarWriteWorkers: Int {
        switch self {
        case .internalSSD: return 4
        case .removableMedia: return 2
        case .networkShare: return 1
        }
    }

    public var defaultSidecarHydrationWorkers: Int {
        switch self {
        case .internalSSD: return 6
        case .removableMedia: return 3
        case .networkShare: return 2
        }
    }

    public var defaultExifPreloadWorkers: Int {
        switch self {
        case .internalSSD: return 6
        case .removableMedia: return 4
        case .networkShare: return 2
        }
    }

    public var exifPreloadWorkers: Int {
        defaultExifPreloadWorkers
    }

    public func effectiveExifPreloadWorkers(isHighSpeedLAN: Bool) -> Int {
        if self == .networkShare && isHighSpeedLAN { return 4 }
        return defaultExifPreloadWorkers
    }

    public var defaultPrefetchWorkers: (baseline: Int, max: Int) {
        switch self {
        case .internalSSD: return (baseline: 2, max: 6)
        case .removableMedia: return (baseline: 2, max: 3)
        case .networkShare: return (baseline: 1, max: 2)
        }
    }

    public var defaultLookaheadDepth: Int {
        switch self {
        case .internalSSD: return 8
        case .removableMedia: return 4
        case .networkShare: return 3
        }
    }

    public var maxConcurrentThumbnailGenerations: Int {
        defaultThumbnailWorkers
    }

    public var maxConcurrentHeavyDecodes: Int {
        defaultHeavyDecodePermits
    }

    public var prefetchMinWorkers: Int {
        defaultPrefetchWorkers.baseline
    }

    public var prefetchMaxWorkers: Int {
        defaultPrefetchWorkers.max
    }

    public var prefetchLookaheadDepth: Int {
        defaultLookaheadDepth
    }

    public func effectiveThumbnailWorkers(isHighSpeedLAN: Bool) -> Int {
        if self == .networkShare && isHighSpeedLAN { return 4 }
        return defaultThumbnailWorkers
    }

    public func effectiveHeavyDecodes(isHighSpeedLAN: Bool) -> Int {
        if self == .networkShare && isHighSpeedLAN { return 2 }
        return defaultHeavyDecodePermits
    }

    public func effectivePrefetchMinWorkers(isHighSpeedLAN: Bool) -> Int {
        if self == .networkShare && isHighSpeedLAN { return 2 }
        return defaultPrefetchWorkers.baseline
    }

    public func effectivePrefetchMaxWorkers(isHighSpeedLAN: Bool) -> Int {
        if self == .networkShare && isHighSpeedLAN { return 4 }
        return defaultPrefetchWorkers.max
    }

    public func effectivePrefetchLookahead(isHighSpeedLAN: Bool) -> Int {
        if self == .networkShare && isHighSpeedLAN { return 6 }
        return defaultLookaheadDepth
    }

    public func effectiveSidecarHydrationWorkers(isHighSpeedLAN: Bool) -> Int {
        if self == .networkShare && isHighSpeedLAN { return 4 }
        return defaultSidecarHydrationWorkers
    }
}

#if canImport(Darwin)
import Darwin
#endif

/// Automatically inspects storage volume attributes (`volumeIsInternalKey`, `volumeIsLocalKey`, etc.)
/// and Darwin statfs to determine the appropriate StorageVolumeProfile.
public nonisolated struct StorageVolumeDetector {

    public nonisolated struct VolumeAttributes: Sendable {
        public var path: String
        public var volumeIsLocal: Bool?
        public var volumeIsInternal: Bool?
        public var volumeIsRemovable: Bool?
        public var volumeIsEjectable: Bool?
        public var volumeTypeName: String?
        public var volumeURLForRemounting: URL?
        public var volumeMountFromLocation: String?
        public var statfsIsLocal: Bool?
        public var statfsFSTypeName: String?

        public init(
            path: String,
            volumeIsLocal: Bool? = nil,
            volumeIsInternal: Bool? = nil,
            volumeIsRemovable: Bool? = nil,
            volumeIsEjectable: Bool? = nil,
            volumeTypeName: String? = nil,
            volumeURLForRemounting: URL? = nil,
            volumeMountFromLocation: String? = nil,
            statfsIsLocal: Bool? = nil,
            statfsFSTypeName: String? = nil
        ) {
            self.path = path
            self.volumeIsLocal = volumeIsLocal
            self.volumeIsInternal = volumeIsInternal
            self.volumeIsRemovable = volumeIsRemovable
            self.volumeIsEjectable = volumeIsEjectable
            self.volumeTypeName = volumeTypeName
            self.volumeURLForRemounting = volumeURLForRemounting
            self.volumeMountFromLocation = volumeMountFromLocation
            self.statfsIsLocal = statfsIsLocal
            self.statfsFSTypeName = statfsFSTypeName
        }
    }

    private static func isNetworkFilesystemType(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "smbfs" || lower == "nfs" || lower == "webdav" || lower == "afpfs" || lower.contains("smb")
    }

    public static func profile(for attributes: VolumeAttributes) -> StorageVolumeProfile {
        // Tier 1: Foundation URLResourceKey checks
        if let isLocal = attributes.volumeIsLocal, !isLocal {
            return .networkShare
        }
        if attributes.volumeURLForRemounting != nil {
            return .networkShare
        }
        if let typeName = attributes.volumeTypeName, isNetworkFilesystemType(typeName) {
            return .networkShare
        }
        if let mountLocation = attributes.volumeMountFromLocation?.lowercased() {
            if mountLocation.hasPrefix("//") || mountLocation.contains("smb:") || mountLocation.contains("nfs:") || mountLocation.contains("afp:") {
                return .networkShare
            }
        }

        // Tier 2: Darwin POSIX statfs checks
        if let statfsLocal = attributes.statfsIsLocal, !statfsLocal {
            return .networkShare
        }
        if let fsName = attributes.statfsFSTypeName, isNetworkFilesystemType(fsName) {
            return .networkShare
        }

        // Fallback: Standard network mount paths (/net/)
        let pathLower = attributes.path.lowercased()
        if pathLower.hasPrefix("/net/") {
            return .networkShare
        }

        // Tier 3: Local hardware classification
        if let isInternal = attributes.volumeIsInternal, isInternal {
            return .internalSSD
        }
        if let isRemovable = attributes.volumeIsRemovable, isRemovable {
            return .removableMedia
        }
        if let isEjectable = attributes.volumeIsEjectable, isEjectable {
            return .removableMedia
        }
        if let isLocal = attributes.volumeIsLocal, isLocal {
            if attributes.path.hasPrefix("/Volumes/") {
                return .removableMedia
            }
            return .internalSSD
        }

        if attributes.path.hasPrefix("/Volumes/") {
            return .removableMedia
        }
        return .internalSSD
    }

    public static func profile(for url: URL) -> StorageVolumeProfile {
        detectProfile(for: url)
    }

    public static func detectProfile(for url: URL) -> StorageVolumeProfile {
        let attrs = queryAttributes(for: url)
        return profile(for: attrs)
    }

    public static func queryAttributes(for url: URL) -> VolumeAttributes {
        let standardized = url.standardizedFileURL
        var attrs = VolumeAttributes(path: standardized.path)

        // Query Foundation resource keys
        if let values = try? standardized.resourceValues(forKeys: [
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeTypeNameKey,
            .volumeURLForRemountingKey,
            .volumeMountFromLocationKey
        ]) {
            attrs.volumeIsLocal = values.volumeIsLocal
            attrs.volumeIsInternal = values.volumeIsInternal
            attrs.volumeIsRemovable = values.volumeIsRemovable
            attrs.volumeIsEjectable = values.volumeIsEjectable
            attrs.volumeTypeName = values.volumeTypeName
            attrs.volumeURLForRemounting = values.volumeURLForRemounting
            attrs.volumeMountFromLocation = values.volumeMountFromLocation
        }

        // Query Darwin statfs
        #if canImport(Darwin)
        var stat = statfs()
        if standardized.path.withCString({ statfs($0, &stat) }) == 0 {
            attrs.statfsIsLocal = (stat.f_flags & UInt32(MNT_LOCAL)) != 0
            let fsTypeName = withUnsafePointer(to: &stat.f_fstypename) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            attrs.statfsFSTypeName = fsTypeName
        }
        #endif

        return attrs
    }
}


/// Thread-safe in-memory cache for session-duration directory file listings (ADR-0009).
/// Avoids repetitive contentsOfDirectory round-trips over network shares during sidecar resolution.
///
/// - Note: Concurrency Safety Invariant: Marked `@unchecked Sendable` because all mutations, lookups,
///   and clear operations on `listings` are protected by an internal `NSLock`.
public nonisolated final class DirectoryListingCache: @unchecked Sendable {
    public static let shared = DirectoryListingCache()

    private let lock = NSLock()
    private var listings: [URL: [URL]] = [:]

    public init() {}

    public func setContents(_ contents: [URL], for directoryURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        listings[directoryURL.standardizedFileURL] = contents
    }

    public func store(urls: [URL], for directoryURL: URL) {
        setContents(urls, for: directoryURL)
    }

    public func contents(for directoryURL: URL) -> [URL]? {
        lock.lock()
        defer { lock.unlock() }
        return listings[directoryURL.standardizedFileURL]
    }

    public func findFile(named name: String, in directoryURL: URL) -> URL? {
        guard let list = contents(for: directoryURL) else { return nil }
        let target = name.lowercased()
        return list.first { $0.lastPathComponent.lowercased() == target }
    }

    public func removeContents(for directoryURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        listings.removeValue(forKey: directoryURL.standardizedFileURL)
    }

    public func clear(for directoryURL: URL) {
        removeContents(for: directoryURL)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        listings.removeAll()
    }
}
