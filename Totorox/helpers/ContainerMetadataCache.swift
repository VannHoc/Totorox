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
    /// App containers that were enumerated but whose metadata could not be read.
    /// They still belong in the browser list: hiding them is what made a pass
    /// over 276 containers display 274 apps (and, on a build without a working
    /// token, display none at all).
    private var unresolvedContainers: [String: (uuid: String, path: String)] = [:]
    private var activatedBundleIDs: Set<String> = []
    private var directoryListCache: [String: [FileEntry]] = [:]
    private var directorySizes: [String: DirectorySizeResult] = [:]
    private var _cachedFilesystemDirs: [String]? = nil
    private var _cachedLaunchServicesIDs: [String]? = nil
    /// Snapshot đầy đủ của LaunchServices csstore (tên app + UUID→path + group id).
    /// Port từ WQFiles 0.9.19; chỉ là cache nền, không liên quan giao diện.
    private var _cachedLSStore: LSStoreSnapshot? = nil
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
        unresolvedContainers.removeValue(forKey: upperUUID)
        if let icon = app.icon {
            iconCache.setObject(icon, forKey: app.bundleID as NSString)
        }
    }

    var unresolvedContainerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unresolvedContainers.count
    }

    func unresolvedContainerUUIDList() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(unresolvedContainers.keys)
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

    func storeUnresolvedContainer(uuid: String, containerPath: String) {
        let cleanUUID = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: cleanUUID) != nil, !containerPath.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        unresolvedContainers[cleanUUID.uppercased()] = (uuid: cleanUUID, path: containerPath)
    }

    /// Drops the "could not read" skip marks so a forced refresh retries those
    /// containers instead of skipping them for the rest of the session. The
    /// entries stay listed meanwhile, so the browser never loses rows.
    func retryUnresolvedContainers() {
        lock.lock()
        defer { lock.unlock() }
        unresolvedUUIDs.removeAll()
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

    var cachedLSStore: LSStoreSnapshot? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _cachedLSStore
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _cachedLSStore = newValue
        }
    }

    /// WQ Files style: drop a LaunchServices entry whose data container no longer
    /// exists. The snapshot uses `let` fields, so rebuild it with the entry removed.
    func removeLaunchServicesPath(forBundleID bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let store = _cachedLSStore else { return }

        let removedPaths = store.bundleIDByContainerPath
            .filter { $0.value.caseInsensitiveCompare(bundleID) == .orderedSame }
            .map { $0.key }
        guard !removedPaths.isEmpty || store.pathByBundleID[bundleID] != nil else { return }

        var paths = store.pathByBundleID
        paths.removeValue(forKey: bundleID)

        // Bỏ MỌI path lịch sử của bundle này, không chỉ path đầu tiên.
        var byContainer = store.bundleIDByContainerPath
        for path in removedPaths {
            byContainer.removeValue(forKey: path)
            byContainer.removeValue(forKey: ContainerDiscoveryMerger.canonicalPath(path))
        }
        byContainer = byContainer.filter {
            $0.value.caseInsensitiveCompare(bundleID) != .orderedSame
        }

        var identifiers = store.identifiers
        identifiers.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
        var cachedIDs = _cachedLaunchServicesIDs
        cachedIDs?.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }

        _cachedLSStore = LSStoreSnapshot(
            identifiers: identifiers,
            bundleIDByContainerPath: byContainer,
            pathByBundleID: paths,
            displayNameByBundleID: store.displayNameByBundleID,
            bundleNameByBundleID: store.bundleNameByBundleID,
            bundlePathByBundleID: store.bundlePathByBundleID,
            groupIDByContainerPath: store.groupIDByContainerPath,
            layout: store.layout,
            containerPathCount: byContainer.count
        )
        _cachedLaunchServicesIDs = cachedIDs
    }

    /// Drop a cached directory listing. Used when a read failed because of a
    /// sandbox denial — an empty list from a denial must never become a cache hit.
    func removeList(for path: String) {
        lock.lock()
        defer { lock.unlock() }
        directoryListCache.removeValue(forKey: Self.canonicalPath(path))
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
        guard !appMetadataByBundleID.isEmpty || !unresolvedContainers.isEmpty else { return [] }
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
        for (_, item) in unresolvedContainers {
            guard seenUUIDs.insert(item.uuid.uppercased()).inserted else { continue }
            entries.append(
                FileEntry(
                    name: item.uuid,
                    path: item.path,
                    isDirectory: true,
                    size: -1,
                    modifiedAt: nil,
                    createdAt: nil,
                    isSymlink: false,
                    posixPermissions: 0o755,
                    childCount: nil,
                    appName: nil,
                    bundleID: nil,
                    appIcon: nil,
                    isAppContainer: true,
                    shortUUID: item.uuid.count >= 8
                        ? "\(item.uuid.prefix(4))...\(item.uuid.suffix(4))"
                        : item.uuid
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
        unresolvedContainers.removeAll()
        activatedBundleIDs.removeAll()
        directoryListCache.removeAll()
        directorySizes.removeAll()
        _cachedFilesystemDirs = nil
        iconCache.removeAllObjects()
    }
}
