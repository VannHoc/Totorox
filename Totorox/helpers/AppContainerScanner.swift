import Foundation
import UIKit
import SwiftUI

// MARK: - App Container Info Model

struct AppContainerInfo: Identifiable, Hashable, Sendable {
    let id: String
    let appName: String
    let bundleID: String
    let udid: String
    let dataPath: String
    let bundlePath: String?
    let appIcon: UIImage?

    var containerPath: String { dataPath }

    init(
        appName: String,
        bundleID: String,
        udid: String,
        dataPath: String,
        bundlePath: String? = nil,
        appIcon: UIImage? = nil
    ) {
        self.id = bundleID.isEmpty ? udid : bundleID
        self.appName = appName
        self.bundleID = bundleID
        self.udid = udid
        self.dataPath = dataPath
        self.bundlePath = bundlePath
        self.appIcon = appIcon
    }

    var shortUDID: String {
        if udid.count >= 16 {
            return "\(udid.prefix(8))-\(udid.dropFirst(8).prefix(4))-...\(udid.suffix(4))"
        }
        return udid
    }

    var shortDataPath: String {
        let prefix = "/private/v..."
        if udid.count >= 12 {
            return "\(prefix)\(udid.suffix(16))/"
        }
        return dataPath
    }

    var shortBundlePath: String? {
        guard let b = bundlePath, !b.isEmpty else { return nil }
        if b.count > 36 {
            let last = (b as NSString).lastPathComponent
            return "/.../\(last)"
        }
        return b
    }

    var initialLetter: String {
        let clean = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = clean.first, first.isLetter {
            return String(first).uppercased()
        }
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = bid.first, first.isLetter {
            return String(first).uppercased()
        }
        return "A"
    }

    static func == (lhs: AppContainerInfo, rhs: AppContainerInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - App Icon Avatar View (Used for App Selection Sheet)

struct AppIconAvatarView: View {
    let icon: UIImage?
    let title: String
    let bundleID: String
    var size: CGFloat

    init(info: AppContainerInfo, size: CGFloat = 48) {
        self.icon = info.appIcon
        self.title = info.appName
        self.bundleID = info.bundleID
        self.size = size
    }

    init(icon: UIImage?, title: String, bundleID: String = "", size: CGFloat = 48) {
        self.icon = icon
        self.title = title
        self.bundleID = bundleID
        self.size = size
    }

    private var initialLetter: String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = clean.first, first.isLetter {
            return String(first).uppercased()
        }
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = bid.first, first.isLetter {
            return String(first).uppercased()
        }
        return "A"
    }

    private var gradientColors: [Color] {
        let hash = abs(bundleID.hashValue ^ title.hashValue)
        let palettes: [[Color]] = [
            [Color(red: 0.58, green: 0.28, blue: 0.96), Color(red: 0.78, green: 0.35, blue: 0.95)],
            [Color(red: 0.12, green: 0.58, blue: 0.95), Color(red: 0.25, green: 0.75, blue: 0.98)],
            [Color(red: 0.95, green: 0.32, blue: 0.55), Color(red: 0.98, green: 0.52, blue: 0.68)],
            [Color(red: 0.96, green: 0.52, blue: 0.22), Color(red: 0.98, green: 0.68, blue: 0.32)],
            [Color(red: 0.18, green: 0.72, blue: 0.62), Color(red: 0.35, green: 0.85, blue: 0.75)],
            [Color(red: 0.20, green: 0.45, blue: 0.95), Color(red: 0.42, green: 0.62, blue: 0.98)]
        ]
        return palettes[hash % palettes.count]
    }

    var body: some View {
        if let icon = icon {
            Image(uiImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: gradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)

                Text(initialLetter)
                    .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.15), radius: 1, y: 1)
            }
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 3, y: 1.5)
        }
    }
}

// MARK: - App Container Scanner Engine

final class AppContainerScanner: ObservableObject, @unchecked Sendable {
    static let shared = AppContainerScanner()

    @Published private(set) var apps: [AppContainerInfo] = []
    var scannedApps: [AppContainerInfo] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return _cachedAppsSnapshot.isEmpty ? apps : _cachedAppsSnapshot
    }
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var statusMessage: String = ""

    private let cacheLock = NSRecursiveLock()
    private var cacheByBundleID: [String: AppContainerInfo] = [:]
    private var cacheByUDID: [String: AppContainerInfo] = [:]
    private var _cachedAppsSnapshot: [AppContainerInfo] = []
    private var mcmContainerPaths: [String] = []
    private(set) var hasCompletedFullScan: Bool = false
    private var hasCompletedFastPass: Bool = false
    private var activeScanTask: Task<[AppContainerInfo], Never>? = nil

    private init() {}

    func getCachedInfo(forUDID udid: String) -> AppContainerInfo? {
        let clean = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let found = cacheByUDID[clean.uppercased()] ?? cacheByUDID[clean.lowercased()] ?? cacheByUDID[clean] else {
            return nil
        }
        guard ContainerStore.isValidAppBundleID(found.bundleID, uuid: clean) else {
            return nil
        }
        return found
    }

    func getCachedInfo(forBundleID bundleID: String) -> AppContainerInfo? {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ContainerStore.isValidAppBundleID(clean) else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cacheByBundleID[clean] ?? cacheByBundleID[clean.lowercased()]
    }

    func allCachedApps() -> [AppContainerInfo] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return _cachedAppsSnapshot
    }

    @discardableResult
    private func registerResolvedApp(
        bundleID: String,
        containerPath: String,
        preferredName: String? = nil,
        preferredBundlePath: String? = nil,
        preferredIcon: UIImage? = nil,
        bundleCatalog: [String: ApplicationBundleMetadata] = [:]
    ) -> AppContainerInfo? {
        let cleanBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalPath = ContainerDiscoveryMerger.canonicalPath(containerPath)
        let finalPath = canonicalPath.isEmpty ? containerPath : canonicalPath
        guard !finalPath.isEmpty else { return nil }

        let udid = (finalPath as NSString).lastPathComponent
        guard ContainerStore.isValidAppBundleID(cleanBundleID, uuid: udid) else {
            return nil
        }

        let proxyInfo = appInfoForBundleID(cleanBundleID) as? [String: Any] ?? [:]
        let proxyName = proxyInfo["name"] as? String
        let catalogMeta = bundleCatalog[cleanBundleID]

        let resolvedName = AppDisplayNamePolicy.resolve(
            bundleID: cleanBundleID,
            candidates: [preferredName, catalogMeta?.displayName, proxyName]
        )
        let bPath = preferredBundlePath ?? (proxyInfo["bundlePath"] as? String)
        let icon = preferredIcon
            ?? (proxyInfo["icon"] as? UIImage)
            ?? ContainerMetadataCache.shared.cachedIcon(for: cleanBundleID)
            ?? iconForBundleID(cleanBundleID)

        let info = AppContainerInfo(
            appName: resolvedName,
            bundleID: cleanBundleID,
            udid: udid,
            dataPath: finalPath,
            bundlePath: bPath,
            appIcon: icon
        )
        storeInCache(info)
        return info
    }

    private func storeInCache(_ app: AppContainerInfo) {
        guard ContainerStore.isValidAppBundleID(app.bundleID, uuid: app.udid) else {
            return
        }
        cacheLock.lock()
        cacheByBundleID[app.bundleID] = app
        cacheByBundleID[app.bundleID.lowercased()] = app
        if !app.udid.isEmpty {
            cacheByUDID[app.udid.uppercased()] = app
            cacheByUDID[app.udid.lowercased()] = app
            cacheByUDID[app.udid] = app
        }
        cacheLock.unlock()

        if !app.udid.isEmpty {
            let meta = AppContainerMetadata(
                uuid: app.udid,
                containerPath: app.dataPath,
                bundleID: app.bundleID,
                appName: app.appName,
                icon: app.appIcon,
                isUserApp: !app.bundleID.hasPrefix("com.apple."),
                modificationDate: nil
            )
            ContainerMetadataCache.shared.store(app: meta)
            ContainerStore.setCachedMapping(uuid: app.udid, bundleID: app.bundleID)
        }
    }

    private func buildSortedSnapshotFromCache() -> [AppContainerInfo] {
        cacheLock.lock()
        var uniqueByBundleID: [String: AppContainerInfo] = [:]
        for (k, v) in cacheByBundleID where k == v.bundleID {
            uniqueByBundleID[v.bundleID.lowercased()] = v
        }
        if uniqueByBundleID.isEmpty {
            for v in cacheByBundleID.values {
                uniqueByBundleID[v.bundleID.lowercased()] = v
            }
        }
        let sorted = Array(uniqueByBundleID.values).sorted { a, b in
            let aIsSystem = a.bundleID.hasPrefix("com.apple.")
            let bIsSystem = b.bundleID.hasPrefix("com.apple.")
            if aIsSystem != bIsSystem {
                return !aIsSystem
            }
            let cmp = a.appName.localizedCaseInsensitiveCompare(b.appName)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return a.bundleID.localizedCaseInsensitiveCompare(b.bundleID) == .orderedAscending
        }
        _cachedAppsSnapshot = sorted
        cacheLock.unlock()
        ContainerMetadataCache.shared.rebuildApplicationDirectoryListCache()
        return sorted
    }

    /// Starts a non-blocking background container scan if not already running or completed.
    func prewarmOnLaunch() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        #if targetEnvironment(simulator)
        return
        #else
        cacheLock.lock()
        if hasCompletedFullScan || activeScanTask != nil {
            cacheLock.unlock()
            return
        }
        cacheLock.unlock()
        Task.detached(priority: .userInitiated) {
            _ = await self.scanAllContainers(forceRefresh: false)
        }
        #endif
    }

    /// Fast synchronous pass (<100ms) for immediate container resolution without running
    /// 2,000,000-inode brute-force or 12 MB .csstore scans. Must be called from a background thread.
    func performFastPassSync() {
        cacheLock.lock()
        if hasCompletedFastPass && !_cachedAppsSnapshot.isEmpty {
            cacheLock.unlock()
            return
        }
        hasCompletedFastPass = true
        cacheLock.unlock()

        // 1. Direct POSIX opendir of /var/mobile/Containers/Data/Application (if accessible without inode scan)
        for root in ["/var/mobile/Containers/Data/Application", "/private/var/mobile/Containers/Data/Application"] {
            if let dir = opendir(root) {
                defer { closedir(dir) }
                while let dp = readdir(dir) {
                    let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                        String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                    }
                    guard UUID(uuidString: name) != nil else { continue }
                    let full = (root as NSString).appendingPathComponent(name)
                    if let meta = ContainerStore.readContainerMetadata(containerPath: full),
                       ContainerStore.isValidAppBundleID(meta.bundleID, uuid: name) {
                        _ = registerResolvedApp(
                            bundleID: meta.bundleID,
                            containerPath: full,
                            preferredName: meta.displayName
                        )
                    }
                }
            }
        }

        // 2. Container-manager enumeration: identifier+path pairs for every app
        //    container, with no sandbox extension. One class is not enough on
        //    iOS 27 (27.0.1 answered a class-2 query with a single container and
        //    that emptied the browser), so the bridge walks the classes the
        //    reference app walks and keeps what lives under the app-data root.
        var mcmDetail: NSString? = nil
        let mcmRecords = MCMEnumerateApplicationContainers(4_096, &mcmDetail)
        log("browser: MCM app containers=\(mcmRecords.count) " +
            "classes=\(mcmDetail.map(String.init) ?? "none")")
        // Enumeration fallback (Approach B): only on iOS builds where bad_query is
        // genuinely broken (iOS 26.6.2+, iOS 27 release) and there is no kernel
        // sandbox escape — on those, MCM reports <= 1 container. On iOS 26.0–26.6.1
        // (incl. 26.6.1, see device log) bad_query still answers, so forcing Tier 4
        // here only adds a failing worse_query round-trip per container and slows
        // the scan without improving coverage. Tier 4 must actually be enabled.
        // NOTE: Do NOT force bad_query blocked here based solely on a short MCM
        // list. On devices where Tier 4 (worse_query) is non-functional (it returns
        // WQ_ERR_NO_TOKEN for every path, see device logs), forcing the memo on
        // makes Tier 4 the primary for every grant while it can never succeed,
        // doubling the work per container and poisoning the negative cache. Tier 4
        // must prove itself first (SandboxTierState.noteWorseQuerySuccess only
        // flips the memo after a strict Tier 4 success), so leave the memo alone
        // here. Removing this automatic force-block restores the original,
        // safer ordering: bad_query first, worse_query only as a fallback.
        _ = mcmRecords
        var containerManagerPaths: [String] = []
        containerManagerPaths.reserveCapacity(mcmRecords.count)
        var mcmActivationFailures = 0
        var mcmActivationAttempts = 0
        for record in mcmRecords {
            guard let containerPath = record["path"] as? String,
                  let identifier = record["identifier"] as? String,
                  ContainerStore.isApplicationContainerPath(containerPath) else { continue }
            let containerClass = (record["class"] as? NSNumber)?.uint64Value ?? 2
            let udid = (containerPath as NSString).lastPathComponent
            containerManagerPaths.append(containerPath)
            if getCachedInfo(forUDID: udid) != nil { continue }

            // Activate the container lease with the identifier the daemon itself
            // reported: on iOS 27 a container is registered under its UUID, and
            // the lease token is what makes its files readable. When the daemon
            // hands out no token at all, stop after a few probes instead of
            // paying one round-trip per container on every scan.
            if mcmActivationAttempts < 3 || mcmActivationFailures < mcmActivationAttempts {
                mcmActivationAttempts += 1
                var activateError: NSString?
                if MCMActivateContainerPath(containerClass, identifier, false, &activateError) == nil {
                    mcmActivationFailures += 1
                }
            }

            // Older builds report the bundle id as the class-2 identifier: no
            // metadata read, no grant, straight into the list.
            if ContainerStore.isValidAppBundleID(identifier, uuid: udid) {
                _ = registerResolvedApp(bundleID: identifier, containerPath: containerPath)
                continue
            }

            // Newer builds report the container UUID, so the name only exists in
            // the container's metadata plist. One lease here; the result is
            // cached by UUID afterwards, so this is a first-scan cost only.
            if let meta = ContainerStore.readContainerMetadata(containerPath: containerPath),
               ContainerStore.isValidAppBundleID(meta.bundleID, uuid: udid) {
                _ = registerResolvedApp(
                    bundleID: meta.bundleID,
                    containerPath: containerPath,
                    preferredName: meta.displayName
                )
            }
            // Deliberately not `markUnresolved` here: a missing token is
            // transient, and the unresolved set has no TTL, so a poisoned entry
            // would hide the app for the rest of the session.
        }
        if mcmActivationFailures > 0 {
            log("browser: MCM lease activation failed for \(mcmActivationFailures)/\(mcmActivationAttempts) probes")
        }
        cacheLock.lock()
        mcmContainerPaths = containerManagerPaths
        cacheLock.unlock()

        // 3. LaunchServices / MobileInstallation API
        let lsInfo = installedAppInfo() as? [String: [String: Any]] ?? [:]
        for (bundleID, info) in lsInfo where ContainerStore.isValidAppBundleID(bundleID) {
            if getCachedInfo(forBundleID: bundleID) != nil { continue }
            var dataPath = info["container"] as? String ?? ""
            if dataPath.isEmpty {
                var lookupError: NSString?
                if let mcmPath = MCMActivateContainerPath(2, bundleID, false, &lookupError)
                    ?? MCMContainerPathForIdentifier(2, bundleID, false, &lookupError) {
                    dataPath = mcmPath
                    ContainerMetadataCache.shared.markBundleActivated(bundleID)
                }
            }
            guard !dataPath.isEmpty else { continue }
            let meta = ContainerStore.readContainerMetadata(containerPath: dataPath)
            _ = registerResolvedApp(
                bundleID: meta?.bundleID ?? bundleID,
                containerPath: dataPath,
                preferredName: meta?.displayName ?? (info["name"] as? String),
                preferredBundlePath: info["bundlePath"] as? String,
                preferredIcon: info["icon"] as? UIImage
            )
        }

        // 4. Built-in Research / Common iOS App Identifiers via MCM
        for candidateID in ContainerStore.researchAppIdentifiers where ContainerStore.isValidAppBundleID(candidateID) {
            if getCachedInfo(forBundleID: candidateID) != nil { continue }
            var actError: NSString? = nil
            if let path = MCMActivateContainerPath(2, candidateID, false, &actError),
               ContainerStore.isApplicationContainerPath(path) {
                ContainerMetadataCache.shared.markBundleActivated(candidateID)
                let meta = ContainerStore.readContainerMetadata(containerPath: path)
                _ = registerResolvedApp(
                    bundleID: meta?.bundleID ?? candidateID,
                    containerPath: path,
                    preferredName: meta?.displayName
                )
            }
        }

        _ = buildSortedSnapshotFromCache()
    }

    /// Scans all application containers on a background thread using a deduplicated two-stage pipeline.
    func scanAllContainers(forceRefresh: Bool = false) async -> [AppContainerInfo] {
        cacheLock.lock()
        // A scan already in flight answers both a plain and a forced request:
        // it re-resolves every container it finds anyway. The iOS 27.0.1 log
        // shows four overlapping scans (refresh button + app-list load + prewarm)
        // paying 549 Tier-4 grants for 276 containers, with one scan stalled at
        // 44.9s waiting on the same serialized grant session while the others
        // were still resolving — the browser then looked like it was missing apps.
        if let inFlight = activeScanTask {
            cacheLock.unlock()
            return await inFlight.value
        }
        if !forceRefresh && hasCompletedFullScan && !_cachedAppsSnapshot.isEmpty {
            let existing = _cachedAppsSnapshot
            cacheLock.unlock()
            await MainActor.run {
                if self.apps.isEmpty {
                    self.apps = existing
                }
            }
            return existing
        }
        if forceRefresh {
            // Retry the containers a previous pass could not name, so a
            // transient token failure does not hide an app for the session.
            ContainerMetadataCache.shared.retryUnresolvedContainers()
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> [AppContainerInfo] in
            guard let self = self else { return [] }

            await MainActor.run {
                self.isLoading = true
                self.statusMessage = AppLanguage.current.text("scanner.scanning")
            }

            // STAGE 1: Fast Pass (<100ms) — MCM + LaunchServices + Direct POSIX
            self.performFastPassSync()
            let stage1Snapshot = self.buildSortedSnapshotFromCache()
            if !stage1Snapshot.isEmpty {
                await MainActor.run {
                    self.apps = stage1Snapshot
                    self.isLoading = false
                    NotificationCenter.default.post(name: .totoroxContainersDidUpdate, object: nil)
                }
            }

            // STAGE 2: Progressive MHA-C2 Discovery via LaunchServices Store (.csstore)
            #if !targetEnvironment(simulator)
            let lsStoreCandidates = ContainerStore.launchServicesStoreIdentifiers()
            let prioritizedCandidates = MHAIdentifierCatalog.identifiers(
                dynamic: [],
                installed: [],
                research: ContainerStore.researchAppIdentifiers,
                custom: [],
                launchServices: lsStoreCandidates
            )

            var newlyResolvedInStage2 = 0
            for candidateID in prioritizedCandidates {
                guard ContainerStore.isValidAppBundleID(candidateID) else { continue }
                if self.getCachedInfo(forBundleID: candidateID) != nil { continue }

                var actError: NSString? = nil
                if let path = MCMActivateContainerPath(2, candidateID, false, &actError),
                   ContainerStore.isApplicationContainerPath(path) {
                    ContainerMetadataCache.shared.markBundleActivated(candidateID)
                    let meta = ContainerStore.readContainerMetadata(containerPath: path)
                    let actualBundleID = (meta != nil && ContainerStore.isValidAppBundleID(meta!.bundleID))
                        ? meta!.bundleID
                        : candidateID
                    if self.registerResolvedApp(
                        bundleID: actualBundleID,
                        containerPath: path,
                        preferredName: meta?.displayName
                    ) != nil {
                        newlyResolvedInStage2 += 1
                        if newlyResolvedInStage2 == 10 || newlyResolvedInStage2.isMultiple(of: 25) {
                            let partial = self.buildSortedSnapshotFromCache()
                            await MainActor.run {
                                self.apps = partial
                                self.isLoading = false
                                NotificationCenter.default.post(name: .totoroxContainersDidUpdate, object: nil)
                            }
                        }
                    }
                }
            }

            // STAGE 3: Filesystem Container Discovery (only when a tier can grant raw
            // UUID paths: kernel sandbox escape, iOS < 26, a directly readable root,
            // or Tier 4 worse_query on iOS 26+ sideloads)
            let canOpenRootDirectly: Bool = {
                if let d = opendir(ContainerStore.appDataRoot) {
                    closedir(d)
                    return true
                }
                return false
            }()
            let canReadRawUUIDContainers = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
                || KernelExploit.hasSandboxAccess()
                || canOpenRootDirectly
                // Tier 4 grants traversal of the app-data root exactly like Tier 1
                // does, so raw UUID containers stay reachable on iOS 26+ sideloads.
                // Only counts while Tier 4 is actually functional: once it has
                // been auto-disabled (repeated WQ_ERR_NO_TOKEN) it must not be
                // treated as a traversal-capable tier.
                || (WorseQuery.grantGroup != nil && !SandboxGrantRouter.isTier4Disabled)
            self.cacheLock.lock()
            let containerManagerDirs = self.mcmContainerPaths
            self.cacheLock.unlock()
            // Guaranteed resolution for required apps: try direct MCM lookup
            // before the traversal pass, so an app like com.garena.game.kgvn is
            // named even if its container's metadata plist is denied.
            for bid in ContainerStore.requiredAppIdentifiers where self.getCachedInfo(forBundleID: bid) == nil {
                var resolved = false
                var actErr: NSString?
                if let path = MCMActivateContainerPath(2, bid, false, &actErr)
                    ?? MCMContainerPathForIdentifier(2, bid, false, &actErr),
                   ContainerStore.isApplicationContainerPath(path) {
                    ContainerMetadataCache.shared.markBundleActivated(bid)
                    if let meta = ContainerStore.readContainerMetadata(containerPath: path),
                       ContainerStore.isValidAppBundleID(meta.bundleID) {
                        _ = self.registerResolvedApp(
                            bundleID: meta.bundleID,
                            containerPath: path,
                            preferredName: meta.displayName
                        )
                    } else {
                        _ = self.registerResolvedApp(
                            bundleID: bid,
                            containerPath: path
                        )
                    }
                    resolved = true
                }
                // Fallback: MCM direct lookup can return nil on iOS 26+ even
                // when the container is among the enumerated UUIDs. Search those
                // by metadata/content so the required app still shows up labeled.
                if !resolved {
                    for dir in containerManagerDirs {
                        guard let meta = ContainerStore.readContainerMetadata(containerPath: dir),
                              meta.bundleID == bid else { continue }
                        _ = self.registerResolvedApp(
                            bundleID: meta.bundleID,
                            containerPath: dir,
                            preferredName: meta.displayName
                        )
                        resolved = true
                        break
                    }
                }
            }

            if canReadRawUUIDContainers || !containerManagerDirs.isEmpty {
                // Prefer the container manager's list: it costs no grant and skips
                // the 2,000,000-inode `fsgetpath` walk that made this scan look
                // frozen. It is only preferred while it actually holds the
                // device's containers though — iOS 27.0.1 answered the query with
                // a single container for a device full of apps, and trusting that
                // left the browser empty, so a short list falls back to the
                // traversal listing instead of showing nothing.
                var dirs = containerManagerDirs
                if dirs.count < 5 {
                    let traversal = ContainerStore.enumerateDirectoriesWithTraversalGrant(
                        path: ContainerStore.appDataRoot
                    )
                    let known = Set(dirs)
                    dirs.append(contentsOf: traversal.filter { !known.contains($0) })
                    log("browser: MCM list short (\(containerManagerDirs.count)); " +
                        "traversal found \(dirs.count) containers")
                }
                let lsSet = Set(lsStoreCandidates)
                let stage3Started = Date()
                var stage3Inspected = 0
                for dirPath in dirs {
                    let udid = (dirPath as NSString).lastPathComponent
                    guard UUID(uuidString: udid) != nil else { continue }

                    // Each container costs one Tier-4 grant (symlink swap + daemon
                    // round-trip), so the iOS 27 pass over ~211 UUIDs takes a while.
                    // Publish what has been resolved so far instead of leaving the
                    // browser empty until the last container is done.
                    stage3Inspected += 1
                    if stage3Inspected.isMultiple(of: 25) {
                        let partial = self.buildSortedSnapshotFromCache()
                        let elapsed = String(format: "%.1f", Date().timeIntervalSince(stage3Started))
                        log("browser: inventory progress \(stage3Inspected)/\(dirs.count) " +
                            "elapsed=\(elapsed)s resolved=\(partial.count)")
                        if !partial.isEmpty {
                            await MainActor.run {
                                self.apps = partial
                                self.isLoading = false
                                NotificationCenter.default.post(name: .totoroxContainersDidUpdate, object: nil)
                            }
                        }
                    }
                    if self.getCachedInfo(forUDID: udid) != nil { continue }
                    if ContainerMetadataCache.shared.isUnresolved(uuid: udid) { continue }

                    if let meta = ContainerStore.readContainerMetadata(containerPath: dirPath),
                       ContainerStore.isValidAppBundleID(meta.bundleID, uuid: udid) {
                        _ = self.registerResolvedApp(
                            bundleID: meta.bundleID,
                            containerPath: dirPath,
                            preferredName: meta.displayName
                        )
                        continue
                    }

                    let fallback = InstalledApp(
                        bundleID: udid,
                        name: udid,
                        containerPath: dirPath,
                        version: "",
                        icon: nil
                    )
                    if !lsSet.isEmpty,
                       let inferred = ContainerStore.inferredApp(
                        for: fallback,
                        knownAppsByBundleID: [:],
                        launchServicesIdentifiers: lsSet
                    ),
                       ContainerStore.isValidAppBundleID(inferred.bundleID, uuid: udid) {
                        _ = self.registerResolvedApp(
                            bundleID: inferred.bundleID,
                            containerPath: dirPath,
                            preferredName: inferred.name,
                            preferredIcon: inferred.icon
                        )
                    } else {
                        // Still list the container when its metadata cannot be
                        // read. Dropping it is what made a pass that found 276
                        // containers show only 274 entries, and on a build whose
                        // tier hands out no token it emptied the browser even
                        // though the UUIDs had been enumerated.
                        ContainerMetadataCache.shared.markUnresolved(uuid: udid)
                        ContainerMetadataCache.shared.storeUnresolvedContainer(
                            uuid: udid,
                            containerPath: dirPath
                        )
                    }
                }
            }
            #endif

            log("browser: unresolved containers: " +
                ContainerMetadataCache.shared.unresolvedContainerUUIDList().sorted().joined(separator: ","))
            for bid in ContainerStore.requiredAppIdentifiers {
                if self.getCachedInfo(forBundleID: bid) == nil {
                    log("browser: REQUIRED \(bid) NOT resolved")
                } else {
                    log("browser: required \(bid) resolved")
                }
            }
            let finalSorted = self.buildSortedSnapshotFromCache()
            log("browser: inventory scan done apps=\(finalSorted.count) " +
                "unresolved=\(ContainerMetadataCache.shared.unresolvedContainerCount) " +
                "tier=\(SandboxGrantRouter.lastBackend?.rawValue ?? "none") " +
                "badQueryBlocked=\(SandboxGrantRouter.badQueryBlocked)")
            self.cacheLock.lock()
            self.hasCompletedFullScan = true
            self.activeScanTask = nil
            self.cacheLock.unlock()

            await MainActor.run {
                self.apps = finalSorted
                self.isLoading = false
                self.statusMessage = AppLanguage.current.text("scanner.found_apps", finalSorted.count)
                NotificationCenter.default.post(name: .totoroxContainersDidUpdate, object: nil)
            }
            return finalSorted
        }

        activeScanTask = task
        cacheLock.unlock()
        return await task.value
    }

    /// Resolves a container by Bundle ID strictly on a background thread (never blocking Main Thread).
    func resolveContainer(bundleID: String) async -> AppContainerInfo? {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ContainerStore.isValidAppBundleID(clean) else { return nil }

        if let cached = getCachedInfo(forBundleID: clean) {
            return cached
        }

        let directResolved = await Task.detached(priority: .userInitiated) { [weak self] () -> AppContainerInfo? in
            var lookupError: NSString?
            let resolvedPath = MCMActivateContainerPath(2, clean, false, &lookupError)
                ?? MCMContainerPathForIdentifier(2, clean, false, &lookupError)
                ?? ContainerStore.resolveAppContainerPath(bundleID: clean)

            guard let mcmPath = resolvedPath, !mcmPath.isEmpty else {
                return nil
            }

            ContainerMetadataCache.shared.markBundleActivated(clean)
            _ = ContainerStore.ensureContainerAccess(for: mcmPath)
            let meta = ContainerStore.readContainerMetadata(containerPath: mcmPath)
            let actualBundleID = (meta != nil && ContainerStore.isValidAppBundleID(meta!.bundleID))
                ? meta!.bundleID
                : clean
            return self?.registerResolvedApp(
                bundleID: actualBundleID,
                containerPath: mcmPath,
                preferredName: meta?.displayName
            )
        }.value

        if let directResolved {
            return directResolved
        }

        let list = await scanAllContainers(forceRefresh: false)
        return list.first { $0.bundleID.caseInsensitiveCompare(clean) == .orderedSame }
    }

    /// Scans available subdirectories inside a container on a background thread for destination selection.
    func scanContainerSubdirectories(for app: AppContainerInfo) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let root = ContainerStore.ensureContainerAccess(for: app.dataPath)
            let defaults = ["Documents", "Library", "Library/Caches", "Library/Preferences", "tmp"]
            var discovered = OrderedSubdirectorySet(defaults)

            let topEntries = ContainerStore.enumerateDirectoryNames(path: root)
            for entry in topEntries {
                let full = (root as NSString).appendingPathComponent(entry)
                var st = stat()
                if lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    discovered.append(entry)
                    let subEntries = ContainerStore.enumerateDirectoryNames(path: full)
                    for sub in subEntries.prefix(24) {
                        let subFull = (full as NSString).appendingPathComponent(sub)
                        var subSt = stat()
                        if lstat(subFull, &subSt) == 0, (subSt.st_mode & S_IFMT) == S_IFDIR {
                            discovered.append("\(entry)/\(sub)")
                        }
                    }
                }
            }
            return discovered.values
        }.value
    }
}

private struct OrderedSubdirectorySet {
    private var set = Set<String>()
    private(set) var values: [String] = []

    init(_ initial: [String]) {
        for item in initial {
            append(item)
        }
    }

    mutating func append(_ item: String) {
        let clean = item.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !clean.isEmpty, set.insert(clean).inserted else { return }
        values.append(clean)
    }
}
