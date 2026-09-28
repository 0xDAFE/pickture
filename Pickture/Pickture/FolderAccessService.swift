import Foundation

@MainActor
final class FolderAccessService {
    private let recentFoldersFileURL: URL
    private let maxRecentFoldersCount = 15
    private var activeSecurityScopedURL: URL?

    init(storageRootURL: URL) {
        self.recentFoldersFileURL = storageRootURL
            .standardizedFileURL
            .appendingPathComponent("recent-folders.json")
    }

    func loadRecentFolders() -> [RecentFolder] {
        guard let data = try? Data(contentsOf: recentFoldersFileURL),
              let decoded = try? JSONDecoder().decode([RecentFolder].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    @discardableResult
    func beginAccessingAndRecordFolder(at url: URL) throws -> (resolvedURL: URL, recentFolders: [RecentFolder]) {
        stopAccessingCurrentFolder()

        let didStartScope = url.startAccessingSecurityScopedResource()
        let standardized = url.standardizedFileURL
        if didStartScope {
            activeSecurityScopedURL = standardized
        }

        let bookmark = Self.makeBookmarkData(for: standardized)
        let entry = RecentFolder(
            id: standardized.path,
            name: standardized.lastPathComponent,
            displayPath: standardized.path,
            bookmarkData: bookmark,
            lastOpenedAt: Date()
        )

        var list = loadRecentFolders().filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        if list.count > maxRecentFoldersCount {
            list = Array(list.prefix(maxRecentFoldersCount))
        }
        try persistRecentFolders(list)
        return (standardized, list)
    }

    func resolveAndAccess(recentFolder: RecentFolder) throws -> (resolvedURL: URL, recentFolders: [RecentFolder]) {
        let resolvedURL = Self.resolveURL(from: recentFolder)
        return try beginAccessingAndRecordFolder(at: resolvedURL)
    }

    func removeRecentFolder(id: String) -> [RecentFolder] {
        let list = loadRecentFolders().filter { $0.id != id }
        try? persistRecentFolders(list)
        return list
    }

    func stopAccessingCurrentFolder() {
        if let activeSecurityScopedURL {
            activeSecurityScopedURL.stopAccessingSecurityScopedResource()
            self.activeSecurityScopedURL = nil
        }
    }

    private func persistRecentFolders(_ folders: [RecentFolder]) throws {
        let directory = recentFoldersFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(folders)
        try data.write(to: recentFoldersFileURL, options: .atomic)
    }

    private static func makeBookmarkData(for url: URL) -> Data {
        #if os(macOS)
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        #endif
        if let standard = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return standard
        }
        return Data(url.path.utf8)
    }

    private static func resolveURL(from recentFolder: RecentFolder) -> URL {
        var isStale = false
        #if os(macOS)
        if let url = try? URL(
            resolvingBookmarkData: recentFolder.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url.standardizedFileURL
        }
        #endif
        if let url = try? URL(
            resolvingBookmarkData: recentFolder.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: recentFolder.displayPath).standardizedFileURL
    }
}
