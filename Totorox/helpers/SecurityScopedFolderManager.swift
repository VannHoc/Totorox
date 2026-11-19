import Combine
import Foundation

/// A user-authorized folder picked through Apple's `UIDocumentPickerViewController` (Files app).
struct BookmarkedFolder: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let url: URL
    let addedAt: Date
}

private struct StoredFolderBookmark: Codable {
    let id: String
    let displayName: String
    let fallbackPath: String
    let bookmarkData: Data?
    let addedAt: Date
}

/// Manages security-scoped folder access and persistent bookmarks for folders
/// explicitly granted by the user through iOS's Files document picker.
final class SecurityScopedFolderManager: ObservableObject {
    static let shared = SecurityScopedFolderManager()

    private static let maxBookmarkedFolders = 12

    @Published private(set) var folders: [BookmarkedFolder] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private var activeScopedURLs: [String: URL] = [:]
    private var storedRecords: [StoredFolderBookmark] = []

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "totorox.files.bookmarked_folders.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        restoreBookmarks()
    }

    deinit {
        lock.lock()
        let urls = Array(activeScopedURLs.values)
        activeScopedURLs.removeAll()
        lock.unlock()
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Registers a folder URL returned by `UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)`.
    @discardableResult
    func addFolder(url: URL) -> BookmarkedFolder {
        let accessed = url.startAccessingSecurityScopedResource()
        let standardized = url.standardizedFileURL
        let canonicalID = Self.canonicalPath(standardized.path)
        let displayName = standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
        let now = Date()

        // On iOS, bookmarks created from a security-scoped URL with `.minimalBookmark`
        // preserve security scope across launches (`.withSecurityScope` is macOS-only).
        let bookmarkData = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let entry = BookmarkedFolder(
            id: canonicalID,
            displayName: displayName,
            url: standardized,
            addedAt: now
        )
        let record = StoredFolderBookmark(
            id: canonicalID,
            displayName: displayName,
            fallbackPath: standardized.path,
            bookmarkData: bookmarkData,
            addedAt: now
        )

        var previousScopeToStop: URL?
        var evictedScopes: [URL] = []

        lock.lock()
        if accessed {
            if let existing = activeScopedURLs[canonicalID], existing != url {
                previousScopeToStop = existing
            }
            activeScopedURLs[canonicalID] = url
        }

        storedRecords.removeAll { $0.id == canonicalID }
        storedRecords.insert(record, at: 0)
        if storedRecords.count > Self.maxBookmarkedFolders {
            let overflow = storedRecords.suffix(from: Self.maxBookmarkedFolders)
            for dropped in overflow {
                if let droppedURL = activeScopedURLs.removeValue(forKey: dropped.id) {
                    evictedScopes.append(droppedURL)
                }
            }
            storedRecords = Array(storedRecords.prefix(Self.maxBookmarkedFolders))
        }
        persistLocked()
        let snapshot = buildFolderListLocked()
        lock.unlock()

        previousScopeToStop?.stopAccessingSecurityScopedResource()
        for evicted in evictedScopes {
            evicted.stopAccessingSecurityScopedResource()
        }

        publish(snapshot)
        return entry
    }

    func removeFolder(id: String) {
        let canonicalID = Self.canonicalPath(id)
        lock.lock()
        let stoppedURL = activeScopedURLs.removeValue(forKey: canonicalID)
        storedRecords.removeAll { $0.id == canonicalID }
        persistLocked()
        let snapshot = buildFolderListLocked()
        lock.unlock()

        stoppedURL?.stopAccessingSecurityScopedResource()
        publish(snapshot)
    }

    func clearAll() {
        lock.lock()
        let urls = Array(activeScopedURLs.values)
        activeScopedURLs.removeAll()
        storedRecords.removeAll()
        defaults.removeObject(forKey: storageKey)
        lock.unlock()

        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
        publish([])
    }

    /// Returns the matching bookmarked folder if `path` is equal to or nested inside it.
    func matchingFolder(forPath path: String) -> BookmarkedFolder? {
        let target = Self.canonicalPath(path)
        lock.lock()
        let current = buildFolderListLocked()
        lock.unlock()

        for folder in current {
            let root = folder.id
            if target == root {
                return folder
            }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if target.hasPrefix(prefix) {
                return folder
            }
        }
        return nil
    }

    /// Ensures security-scoped access is active for `url` (or its enclosing bookmarked folder)
    /// for the duration of `operation`.
    func withScopedAccess<T>(for url: URL, perform operation: () throws -> T) rethrows -> T {
        let alreadyManaged = matchingFolder(forPath: url.path) != nil
        let localScope = alreadyManaged ? false : url.startAccessingSecurityScopedResource()
        defer {
            if localScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    /// Re-validates stored bookmarks from `UserDefaults` and starts security-scoped access
    /// for accessible folders.
    func restoreBookmarks() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([StoredFolderBookmark].self, from: data) else {
            return
        }

        var restoredRecords: [StoredFolderBookmark] = []
        var restoredScopes: [String: URL] = [:]
        var seen = Set<String>()

        for record in decoded {
            var resolvedURL: URL?
            var didStartScope = false
            var updatedBookmark = record.bookmarkData

            if let bookmarkData = record.bookmarkData {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    if url.startAccessingSecurityScopedResource() {
                        resolvedURL = url
                        didStartScope = true
                        if isStale,
                           let refreshed = try? url.bookmarkData(
                               options: .minimalBookmark,
                               includingResourceValuesForKeys: nil,
                               relativeTo: nil
                           ) {
                            updatedBookmark = refreshed
                        }
                    } else if FileManager.default.fileExists(atPath: url.path) {
                        resolvedURL = url
                    }
                }
            }

            if resolvedURL == nil, FileManager.default.fileExists(atPath: record.fallbackPath) {
                resolvedURL = URL(fileURLWithPath: record.fallbackPath, isDirectory: true)
            }

            guard let finalURL = resolvedURL else { continue }
            let standardized = finalURL.standardizedFileURL
            let canonicalID = Self.canonicalPath(standardized.path)
            guard seen.insert(canonicalID).inserted else {
                if didStartScope {
                    finalURL.stopAccessingSecurityScopedResource()
                }
                continue
            }

            if didStartScope {
                restoredScopes[canonicalID] = finalURL
            }
            restoredRecords.append(StoredFolderBookmark(
                id: canonicalID,
                displayName: record.displayName.isEmpty ? standardized.lastPathComponent : record.displayName,
                fallbackPath: standardized.path,
                bookmarkData: updatedBookmark,
                addedAt: record.addedAt
            ))
        }

        lock.lock()
        let oldScopes = Array(activeScopedURLs.values)
        let keptSet = Set(restoredRecords.prefix(Self.maxBookmarkedFolders).map(\.id))
        var droppedScopes: [URL] = []
        for (key, scopedURL) in restoredScopes where !keptSet.contains(key) {
            droppedScopes.append(scopedURL)
            restoredScopes.removeValue(forKey: key)
        }
        activeScopedURLs = restoredScopes
        storedRecords = Array(restoredRecords.prefix(Self.maxBookmarkedFolders))
        persistLocked()
        let snapshot = buildFolderListLocked()
        lock.unlock()

        for old in oldScopes where !restoredScopes.values.contains(old) {
            old.stopAccessingSecurityScopedResource()
        }
        for dropped in droppedScopes {
            dropped.stopAccessingSecurityScopedResource()
        }
        publish(snapshot)
    }

    static func canonicalPath(_ path: String) -> String {
        var clean = URL(fileURLWithPath: path).standardizedFileURL.path
        if clean.hasPrefix("/private/var/") {
            clean = String(clean.dropFirst("/private".count))
        }
        while clean.count > 1 && clean.hasSuffix("/") {
            clean.removeLast()
        }
        return clean
    }

    private func buildFolderListLocked() -> [BookmarkedFolder] {
        storedRecords.map { record in
            let url = activeScopedURLs[record.id]?.standardizedFileURL
                ?? URL(fileURLWithPath: record.fallbackPath, isDirectory: true).standardizedFileURL
            return BookmarkedFolder(
                id: record.id,
                displayName: record.displayName,
                url: url,
                addedAt: record.addedAt
            )
        }
    }

    private func persistLocked() {
        if let encoded = try? JSONEncoder().encode(storedRecords) {
            defaults.set(encoded, forKey: storageKey)
        }
    }

    private func publish(_ snapshot: [BookmarkedFolder]) {
        if Thread.isMainThread {
            folders = snapshot
        } else {
            DispatchQueue.main.async {
                self.folders = snapshot
            }
        }
    }
}
