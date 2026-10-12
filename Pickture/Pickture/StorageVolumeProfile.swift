import Foundation

/// Storage medium profile governing decoder concurrency, worker limits, and prefetch depth.
public enum StorageVolumeProfile: String, CaseIterable, Codable, Sendable {
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
}

/// Automatically inspects storage volume attributes (`volumeIsInternalKey`, `volumeIsLocalKey`)
/// to determine the appropriate StorageVolumeProfile.
public struct StorageVolumeDetector {
    public static func profile(for url: URL) -> StorageVolumeProfile {
        detectProfile(for: url)
    }

    public static func detectProfile(for url: URL) -> StorageVolumeProfile {
        let standardized = url.standardizedFileURL
        do {
            let values = try standardized.resourceValues(forKeys: [
                .volumeIsInternalKey,
                .volumeIsLocalKey
            ])
            if let isLocal = values.volumeIsLocal, !isLocal {
                return .networkShare
            }
            if let isInternal = values.volumeIsInternal, isInternal {
                return .internalSSD
            }
            if let isLocal = values.volumeIsLocal, isLocal {
                return .removableMedia
            }
        } catch {
            // Fallback heuristics
        }

        let path = standardized.path
        if path.hasPrefix("/net/") || (path.hasPrefix("/Volumes/") && path.lowercased().contains("smb")) {
            return .networkShare
        } else if path.hasPrefix("/Volumes/") {
            return .removableMedia
        }
        return .internalSSD
    }
}

/// Thread-safe in-memory cache for session-duration directory file listings (ADR-0009).
/// Avoids repetitive contentsOfDirectory round-trips over network shares during sidecar resolution.
///
/// - Note: Concurrency Safety Invariant: Marked `@unchecked Sendable` because all mutations, lookups,
///   and clear operations on `listings` are protected by an internal `NSLock`.
public final class DirectoryListingCache: @unchecked Sendable {
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
