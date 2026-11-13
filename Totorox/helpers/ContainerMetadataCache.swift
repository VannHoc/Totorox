import Foundation
import UIKit

extension Notification.Name {
    static let totoroxContainersDidUpdate = Notification.Name("TotoroxContainersDidUpdate")
}

struct AppContainerMetadata {
    let uuid: String
    let containerPath: String
    let bundleID: String
    let appName: String
    let icon: UIImage?
    let isUserApp: Bool
    let modificationDate: Date?
    let shortUUID: String

    init(
        uuid: String,
        containerPath: String,
        bundleID: String,
        appName: String,
        icon: UIImage?,
        isUserApp: Bool,
        modificationDate: Date? = nil
    ) {
        self.uuid = uuid
        self.containerPath = containerPath
        self.bundleID = bundleID
        self.appName = appName
        self.icon = icon
        self.isUserApp = isUserApp
        self.modificationDate = modificationDate
        if uuid.count >= 8 {
            self.shortUUID = "\(uuid.prefix(4))...\(uuid.suffix(4))"
        } else {
            self.shortUUID = uuid
        }
    }
}

final class ContainerMetadataCache: @unchecked Sendable {
    static let shared = ContainerMetadataCache()

    private let lock = NSRecursiveLock()
    private var appMetadataCache: [String: AppContainerMetadata] = [:]
    private var appMetadataByBundleID: [String: AppContainerMetadata] = [:]
    private var unresolvedUUIDs: Set<String> = []
    private var activatedBundleIDs: Set<String> = []
    private var directoryListCache: [String: [FileEntry]] = [:]
    private var directorySizes: [String: DirectorySizeResult] = [:]
    private var _cachedFilesystemDirs: [String]? = nil
    private var _cachedLaunchServicesIDs: [String]? = nil
    private let iconCache = NSCache<NSString, UIImage>()

    private init() {
        iconCache.countLimit = 400
    }

    static func canonicalPath(_ path: String) -> String {
        var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.count > 1 && clean.hasSuffix("/") {
            clean.removeLast()
        }
        if clean == "/private/var" {
            return "/var"
        } else if clean.hasPrefix("/private/var/") {
            clean = String(clean.dropFirst("/private".count))
        } else if clean == "/private/tmp" {
            return "/tmp"
        } else if clean.hasPrefix("/private/tmp/") {
            clean = String(clean.dropFirst("/private".count))
        } else if clean == "/private/etc" {
            return "/etc"
        } else if clean.hasPrefix("/private/etc/") {
            clean = String(clean.dropFirst("/private".count))
        }
        return clean.isEmpty ? "/" : clean
    }

    static func isApplicationContainersRoot(_ path: String) -> Bool {
        let canon = canonicalPath(path)
        return canon == "/var/mobile/Containers/Data/Application"
    }

    func cachedApp(forUUID uuid: String) -> AppContainerMetadata? {
        let clean = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let found = appMetadataCache[clean.uppercased()]
            ?? appMetadataCache[clean]
            ?? appMetadataCache[clean.lowercased()] else {
            return nil
        }
        guard ContainerStore.isValidAppBundleID(found.bundleID, uuid: clean) else {
            return nil
        }
        return found
    }

    func cachedApp(forBundleID bundleID: String) -> AppContainerMetadata? {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ContainerStore.isValidAppBundleID(clean) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return appMetadataByBundleID[clean.lowercased()] ?? appMetadataByBundleID[clean]
    }

    func allApps() -> [AppContainerMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return Array(appMetadataByBundleID.values)
    }

    func bundleID(forUUID uuid: String) -> String? {
        return cachedApp(forUUID: uuid)?.bundleID
    }

    func store(app: AppContainerMetadata) {
        guard ContainerStore.isValidAppBundleID(app.bundleID, uuid: app.uuid) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        let upperUUID = app.uuid.uppercased()
        appMetadataCache[app.uuid] = app
        appMetadataCache[upperUUID] = app
        appMetadataCache[app.uuid.lowercased()] = app
        appMetadataByBundleID[app.bundleID] = app
        appMetadataByBundleID[app.bundleID.lowercased()] = app
        unresolvedUUIDs.remove(upperUUID)
        if let icon = app.icon {
            iconCache.setObject(icon, forKey: app.bundleID as NSString)
        }
    }

    func isUnresolved(uuid: String) -> Bool {
        let clean = uuid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !clean.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return unresolvedUUIDs.contains(clean)
    }

    func markUnresolved(uuid: String) {
        let clean = uuid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !clean.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if appMetadataCache[clean] == nil {
            unresolvedUUIDs.insert(clean)
        }
    }

    func isBundleActivated(_ bundleID: String) -> Bool {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return activatedBundleIDs.contains(clean)
    }

    func markBundleActivated(_ bundleID: String) {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        activatedBundleIDs.insert(clean)
    }

    var cachedFilesystemDirs: [String]? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _cachedFilesystemDirs
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _cachedFilesystemDirs = newValue
        }
    }

    var cachedLaunchServicesIDs: [String]? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _cachedLaunchServicesIDs
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _cachedLaunchServicesIDs = newValue
        }
    }

    func cachedIcon(for bundleID: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return iconCache.object(forKey: bundleID as NSString)
    }

    func storeIcon(_ icon: UIImage, for bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        iconCache.setObject(icon, forKey: bundleID as NSString)
    }

    func cachedList(for path: String) -> [FileEntry]? {
        lock.lock()
        defer { lock.unlock() }
        let canon = Self.canonicalPath(path)
        if Self.isApplicationContainersRoot(canon) {
            if let list = directoryListCache[canon], !list.isEmpty {
                return list
            }
            let built = buildApplicationDirectoryEntriesLocked()
            if !built.isEmpty {
                directoryListCache[canon] = built
                return built
            }
            return nil
        }
        return directoryListCache[canon]
    }

    func storeList(_ entries: [FileEntry], for path: String) {
        lock.lock()
        defer { lock.unlock() }
        let canon = Self.canonicalPath(path)
        directoryListCache[canon] = entries
    }

    @discardableResult
    func rebuildApplicationDirectoryListCache() -> [FileEntry] {
        lock.lock()
        defer { lock.unlock() }
        let built = buildApplicationDirectoryEntriesLocked()
        if !built.isEmpty {
            directoryListCache["/var/mobile/Containers/Data/Application"] = built
        }
        return built
    }

    private func buildApplicationDirectoryEntriesLocked() -> [FileEntry] {
        guard !appMetadataByBundleID.isEmpty else { return [] }
        var seenUUIDs = Set<String>()
        var entries: [FileEntry] = []
        for meta in appMetadataByBundleID.values {
            guard ContainerStore.isValidAppBundleID(meta.bundleID, uuid: meta.uuid) else { continue }
            let upperUUID = meta.uuid.uppercased()
            guard !upperUUID.isEmpty, seenUUIDs.insert(upperUUID).inserted else { continue }
            entries.append(
                FileEntry(
                    name: meta.uuid,
                    path: meta.containerPath,
                    isDirectory: true,
                    size: -1,
                    modifiedAt: meta.modificationDate,
                    createdAt: nil,
                    isSymlink: false,
                    posixPermissions: 0o755,
                    childCount: nil,
                    appName: meta.appName,
                    bundleID: meta.bundleID,
                    appIcon: meta.icon,
                    isAppContainer: true,
                    shortUUID: meta.shortUUID
                )
            )
        }
        return ContainerStore.sortedEntries(entries)
    }

    func cachedDirectorySize(for path: String) -> DirectorySizeResult? {
        lock.lock()
        defer { lock.unlock() }
        let canon = Self.canonicalPath(path)
        return directorySizes[canon]
    }

    func storeDirectorySize(_ size: DirectorySizeResult, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        let canon = Self.canonicalPath(path)
        directorySizes[canon] = size
    }

    func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let canon = Self.canonicalPath(path)
        directoryListCache.removeValue(forKey: canon)
        directorySizes.removeValue(forKey: canon)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        appMetadataCache.removeAll()
        appMetadataByBundleID.removeAll()
        unresolvedUUIDs.removeAll()
        activatedBundleIDs.removeAll()
        directoryListCache.removeAll()
        directorySizes.removeAll()
        _cachedFilesystemDirs = nil
        iconCache.removeAllObjects()
    }
}
