import Foundation
import UIKit
import Darwin

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

    // MARK: - Persisted scan snapshot
    //
    // Reference app `Exploit-v2.2.1` keeps its inventory in
    // `<caches>/wq-container-scan.plist` and serves `[RESOLVER] Cache hit and
    // validated` from it before touching LaunchServices, MCM or the bundle
    // directories. Totorox used to rebuild everything on every launch, which is
    // where the multi-second cold start came from. The snapshot below is the
    // same idea: cheap to read, validated entry by entry, refreshed by the
    // background scan.

    private struct PersistedEntry: Codable {
        let uuid: String
        let path: String
        let bundleID: String
        let name: String
        let isUserApp: Bool
    }

    private struct PersistedScan: Codable {
        let savedAt: Date
        let entries: [PersistedEntry]
        let launchServicesIDs: [String]
        let launchServicesStorePath: String?
    }

    /// Container list may change when the user installs/removes an app; names
    /// and the LaunchServices store path only change at the same moments.
    static let snapshotTTL: TimeInterval = 600
    static let launchServicesTTL: TimeInterval = 7 * 24 * 3600

    private var lastPersistAt: Date?
    private var persistedSavedAt: Date?
    private var persistedLaunchServicesStore: String?
    private var containerRecordsCache: [[String: Any]] = []
    private var containerRecordsAt: Date?

    private static var snapshotURL: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return directory.appendingPathComponent("totorox-container-scan.plist")
    }

    /// LaunchServices `.csstore` found earlier; retried before running the MCM
    /// `com.apple.lsd` lookup again (reference `WQLaunchServicesStore`).
    var launchServicesStorePath: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return persistedLaunchServicesStore
        }
        set {
            lock.lock()
            persistedLaunchServicesStore = newValue
            lock.unlock()
        }
    }

    func persistedSnapshotAge() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let savedAt = persistedSavedAt else { return nil }
        return Date().timeIntervalSince(savedAt)
    }

    /// Container-manager inventory shared by the scanner and the LaunchServices
    /// lookup: `MCMEnumerateContainerRecords` costs up to 28 daemon round-trips,
    /// and both used to issue it independently on every pass.
    func cachedContainerRecords(maxAge: TimeInterval = 60) -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        guard let at = containerRecordsAt,
              !containerRecordsCache.isEmpty,
              Date().timeIntervalSince(at) <= maxAge else { return nil }
        return containerRecordsCache
    }

    func storeContainerRecords(_ records: [[String: Any]]) {
        guard !records.isEmpty else { return }
        lock.lock()
        containerRecordsCache = records
        containerRecordsAt = Date()
        lock.unlock()
    }

    private static func containerStillExists(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1 else { return false }
        var st = stat()
        if lstat(path, &st) == 0 { return true }
        // A sandbox denial is not proof that the container is gone.
        return errno == EPERM || errno == EACCES
    }

    /// Load the previous session's inventory. Entries whose container vanished
    /// (app uninstalled) or whose bundle id/uuid pair is invalid are dropped.
    @discardableResult
    func hydratePersistedSnapshot() -> [AppContainerMetadata] {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let scan = try? PropertyListDecoder().decode(PersistedScan.self, from: data) else {
            return []
        }

        lock.lock()
        persistedSavedAt = scan.savedAt
        if let store = scan.launchServicesStorePath, !store.isEmpty {
            persistedLaunchServicesStore = store
        }
        if _cachedLaunchServicesIDs == nil, !scan.launchServicesIDs.isEmpty {
            _cachedLaunchServicesIDs = scan.launchServicesIDs
        }
        lock.unlock()

        var result: [AppContainerMetadata] = []
        var seenBundleIDs = Set<String>()
        for entry in scan.entries {
            guard ContainerStore.isValidAppBundleID(entry.bundleID, uuid: entry.uuid),
                  Self.containerStillExists(entry.path),
                  seenBundleIDs.insert(entry.bundleID.lowercased()).inserted else { continue }
            let meta = AppContainerMetadata(
                uuid: entry.uuid,
                containerPath: entry.path,
                bundleID: entry.bundleID,
                appName: entry.name,
                icon: cachedIcon(for: entry.bundleID),
                isUserApp: entry.isUserApp
            )
            store(app: meta)
            result.append(meta)
        }
        return result
    }

    /// Write the inventory for the next launch. Debounced: a full scan stores
    /// hundreds of entries and calls this repeatedly.
    func persistSnapshot(force: Bool = false) {
        lock.lock()
        let now = Date()
        if !force, let last = lastPersistAt, now.timeIntervalSince(last) < 5 {
            lock.unlock()
            return
        }
        lastPersistAt = now
        let apps = appMetadataByBundleID
        let launchServicesIDs = _cachedLaunchServicesIDs ?? []
        let store = persistedLaunchServicesStore
        lock.unlock()

        var seen = Set<String>()
        var entries: [PersistedEntry] = []
        for (key, meta) in apps where key == meta.bundleID.lowercased() {
            guard seen.insert(meta.bundleID.lowercased()).inserted else { continue }
            entries.append(PersistedEntry(
                uuid: meta.uuid,
                path: meta.containerPath,
                bundleID: meta.bundleID,
                name: meta.appName,
                isUserApp: meta.isUserApp
            ))
        }
        guard !entries.isEmpty || !launchServicesIDs.isEmpty else { return }

        let scan = PersistedScan(
            savedAt: now,
            entries: entries,
            launchServicesIDs: Array(launchServicesIDs.prefix(4_096)),
            launchServicesStorePath: store
        )
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? PropertyListEncoder().encode(scan) else { return }
            try? data.write(to: Self.snapshotURL, options: .atomic)
        }
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
        containerRecordsCache.removeAll()
        containerRecordsAt = nil
        _cachedFilesystemDirs = nil
        iconCache.removeAllObjects()
    }
}
