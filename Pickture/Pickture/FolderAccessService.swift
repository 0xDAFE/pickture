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

        // Preserve the original security-scoped URL instance so its sandbox token is never stripped
        let didStartScope = url.startAccessingSecurityScopedResource()
        if didStartScope {
            activeSecurityScopedURL = url
        }

        let bookmark = Self.makeBookmarkData(for: url)
        let canonicalPath = url.standardizedFileURL.path
        let entry = RecentFolder(
            id: canonicalPath,
            name: url.lastPathComponent,
            displayPath: canonicalPath,
            bookmarkData: bookmark,
            lastOpenedAt: Date()
        )

        var list = loadRecentFolders().filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        if list.count > maxRecentFoldersCount {
            list = Array(list.prefix(maxRecentFoldersCount))
        }
        try persistRecentFolders(list)
        return (url, list)
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

    private static var bookmarkCreationOptionCandidates: [URL.BookmarkCreationOptions] {
        #if os(macOS)
        return [[.withSecurityScope], []]
        #else
        return [[]]
        #endif
    }

    private static var bookmarkResolutionOptionCandidates: [URL.BookmarkResolutionOptions] {
        #if os(macOS)
        return [[.withSecurityScope], []]
        #else
        return [[]]
        #endif
    }

    private static func makeBookmarkData(for url: URL) -> Data {
        for options in bookmarkCreationOptionCandidates {
            if let data = try? url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                return data
            }
        }
        return Data(url.standardizedFileURL.path.utf8)
    }

    private static func resolveURL(from recentFolder: RecentFolder) -> URL {
        for options in bookmarkResolutionOptionCandidates {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: recentFolder.bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        return URL(fileURLWithPath: recentFolder.displayPath)
    }
}
