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

    private let cacheLock = NSLock()
    private var cacheByBundleID: [String: AppContainerInfo] = [:]
    private var cacheByUDID: [String: AppContainerInfo] = [:]
    private var _cachedAppsSnapshot: [AppContainerInfo] = []
    private var hasScanned: Bool = false

    private init() {}

    func getCachedInfo(forUDID udid: String) -> AppContainerInfo? {
        let clean = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let found = cacheByUDID[clean.uppercased()] ?? cacheByUDID[clean.lowercased()] ?? cacheByUDID[clean] else {
            return nil
        }
        guard !found.bundleID.isEmpty,
              UUID(uuidString: found.bundleID) == nil,
              found.bundleID.caseInsensitiveCompare(clean) != .orderedSame else {
            return nil
        }
        return found
    }

    func getCachedInfo(forBundleID bundleID: String) -> AppContainerInfo? {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, UUID(uuidString: clean) == nil else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cacheByBundleID[clean] ?? cacheByBundleID[clean.lowercased()]
    }

    func allCachedApps() -> [AppContainerInfo] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return _cachedAppsSnapshot
    }

    private func storeInCache(_ app: AppContainerInfo) {
        guard !app.bundleID.isEmpty,
              UUID(uuidString: app.bundleID) == nil,
              app.bundleID.caseInsensitiveCompare(app.udid) != .orderedSame else {
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

    private func readScanSnapshot() -> (alreadyScanned: Bool, existing: [AppContainerInfo]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (hasScanned && !_cachedAppsSnapshot.isEmpty, _cachedAppsSnapshot)
    }

    private func writeScanSnapshot(_ scanned: [AppContainerInfo]) {
        cacheLock.lock()
        _cachedAppsSnapshot = scanned
        hasScanned = true
        cacheLock.unlock()
    }

    /// Scans all application containers on a background thread by parsing
    /// `.com.apple.mobile_container_manager.metadata.plist` (`MCMMetadataIdentifier`)
    /// directly in each container, combined with MCM & LaunchServices discovery.
    func scanAllContainers(forceRefresh: Bool = false) async -> [AppContainerInfo] {
        let snapshot = readScanSnapshot()
        let alreadyScanned = snapshot.alreadyScanned
        let existing = snapshot.existing

        if !forceRefresh && alreadyScanned {
            await MainActor.run {
                if self.apps.isEmpty {
                    self.apps = existing
                }
            }
            return existing
        }

        await MainActor.run {
            self.isLoading = true
            self.statusMessage = "Đang quét danh sách ứng dụng..."
        }

        let scanned = await Task.detached(priority: .userInitiated) { [weak self] () -> [AppContainerInfo] in
            var resultsByBundleID: [String: AppContainerInfo] = [:]
            var resolvedUDIDs = Set<String>()

            let bundleCatalog = ContainerStore.applicationBundleMetadataCatalog()

            func registerApp(
                bundleID: String,
                containerPath: String,
                preferredName: String? = nil,
                preferredBundlePath: String? = nil,
                preferredIcon: UIImage? = nil
            ) {
                let cleanBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanBundleID.isEmpty,
                      UUID(uuidString: cleanBundleID) == nil,
                      !cleanBundleID.hasPrefix("systemgroup.") else {
                    return
                }
                let canonicalPath = ContainerDiscoveryMerger.canonicalPath(containerPath)
                let finalPath = canonicalPath.isEmpty ? containerPath : canonicalPath
                guard !finalPath.isEmpty else { return }

                let udid = (finalPath as NSString).lastPathComponent
                guard UUID(uuidString: udid) == nil || cleanBundleID.caseInsensitiveCompare(udid) != .orderedSame else {
                    return
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
                resultsByBundleID[cleanBundleID] = info
                if UUID(uuidString: udid) != nil {
                    resolvedUDIDs.insert(udid.uppercased())
                }
                self?.storeInCache(info)
            }

            // 1. PRIMARY SOURCE: Direct Filesystem Scan of /var/mobile/Containers/Data/Application
            // Parsing .com.apple.mobile_container_manager.metadata.plist (MCMMetadataIdentifier)
            let containerRoots = [
                "/var/mobile/Containers/Data/Application",
                "/private/var/mobile/Containers/Data/Application"
            ]
            var discoveredContainerDirs: [String] = []
            var seenDirs = Set<String>()

            for root in containerRoots {
                let grantedDirs = ContainerStore.enumerateDirectoriesWithTraversalGrant(path: root)
                let dirs = grantedDirs.isEmpty ? ContainerStore.enumerateDirectories(path: root) : grantedDirs
                for dir in dirs {
                    let udid = (dir as NSString).lastPathComponent
                    guard UUID(uuidString: udid) != nil else { continue }
                    let key = udid.uppercased()
                    if seenDirs.insert(key).inserted {
                        discoveredContainerDirs.append(dir)
                    }
                }
            }

            var unresolvedContainerDirs: [String] = []
            for dirPath in discoveredContainerDirs {
                if let meta = ContainerStore.readContainerMetadata(containerPath: dirPath),
                   !meta.bundleID.isEmpty,
                   UUID(uuidString: meta.bundleID) == nil {
                    registerApp(
                        bundleID: meta.bundleID,
                        containerPath: dirPath,
                        preferredName: meta.displayName
                    )
                } else {
                    unresolvedContainerDirs.append(dirPath)
                }
            }

            // 2. SECONDARY SOURCE: MCM Class-2 Enumeration & Lease Activation
            var mcmError: NSString? = nil
            let mcmIDs = MCMEnumerateIdentifiersForClass(2, 2048, &mcmError)
            for bundleID in mcmIDs where !bundleID.isEmpty && UUID(uuidString: bundleID) == nil {
                if resultsByBundleID[bundleID] != nil { continue }
                var actError: NSString? = nil
                if let path = MCMActivateContainerPath(2, bundleID, false, &actError)
                    ?? MCMContainerPathForIdentifier(2, bundleID, false, &actError),
                   !path.isEmpty {
                    let meta = ContainerStore.readContainerMetadata(containerPath: path)
                    let actualBundleID = (meta != nil && !meta!.bundleID.isEmpty && UUID(uuidString: meta!.bundleID) == nil)
                        ? meta!.bundleID
                        : bundleID
                    registerApp(
                        bundleID: actualBundleID,
                        containerPath: path,
                        preferredName: meta?.displayName
                    )
                }
            }

            // 3. TERTIARY SOURCE: LaunchServices / MobileInstallation API
            let lsInfo = installedAppInfo() as? [String: [String: Any]] ?? [:]
            for (bundleID, info) in lsInfo where !bundleID.isEmpty && UUID(uuidString: bundleID) == nil {
                if resultsByBundleID[bundleID] != nil { continue }
                var dataPath = info["container"] as? String ?? ""
                if dataPath.isEmpty {
                    var lookupError: NSString?
                    if let mcmPath = MCMActivateContainerPath(2, bundleID, false, &lookupError)
                        ?? MCMContainerPathForIdentifier(2, bundleID, false, &lookupError) {
                        dataPath = mcmPath
                    }
                }
                guard !dataPath.isEmpty else { continue }
                let meta = ContainerStore.readContainerMetadata(containerPath: dataPath)
                registerApp(
                    bundleID: meta?.bundleID ?? bundleID,
                    containerPath: dataPath,
                    preferredName: meta?.displayName ?? (info["name"] as? String),
                    preferredBundlePath: info["bundlePath"] as? String,
                    preferredIcon: info["icon"] as? UIImage
                )
            }

            // 4. QUATERNARY SOURCE: LaunchServices Store (.csstore) + Bundle Catalog Candidates via MCM
            let lsStoreCandidates = ContainerStore.launchServicesStoreIdentifiers()
            var mhaCandidates: [String] = []
            var seenCandidates = Set<String>()
            for sourceList in [
                lsStoreCandidates,
                Array(lsInfo.keys),
                mcmIDs,
                Array(bundleCatalog.keys),
                ContainerStore.researchAppIdentifiers
            ] {
                for id in sourceList {
                    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else { continue }
                    if seenCandidates.insert(trimmed).inserted {
                        mhaCandidates.append(trimmed)
                    }
                }
            }
            for candidateID in mhaCandidates where resultsByBundleID[candidateID] == nil {
                var actError: NSString? = nil
                if let path = MCMActivateContainerPath(2, candidateID, false, &actError),
                   ContainerStore.isApplicationContainerPath(path) {
                    let meta = ContainerStore.readContainerMetadata(containerPath: path)
                    registerApp(
                        bundleID: meta?.bundleID ?? candidateID,
                        containerPath: path,
                        preferredName: meta?.displayName
                    )
                }
            }

            // 5. FINAL PASS: Re-check any unresolved container directories via metadata plist or content inference
            let lsSet = Set(lsStoreCandidates)
            let knownInstalledApps = resultsByBundleID.values.map {
                InstalledApp(
                    bundleID: $0.bundleID,
                    name: $0.appName,
                    containerPath: $0.dataPath,
                    version: "",
                    icon: $0.appIcon
                )
            }
            let knownByBundleID = Dictionary(
                knownInstalledApps.map { ($0.bundleID, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for dirPath in unresolvedContainerDirs {
                let udid = (dirPath as NSString).lastPathComponent
                if resolvedUDIDs.contains(udid.uppercased()) { continue }

                if let meta = ContainerStore.readContainerMetadata(containerPath: dirPath),
                   !meta.bundleID.isEmpty,
                   UUID(uuidString: meta.bundleID) == nil {
                    registerApp(
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
                if let inferred = ContainerStore.inferredApp(
                    for: fallback,
                    knownAppsByBundleID: knownByBundleID,
                    launchServicesIdentifiers: lsSet
                ),
                   UUID(uuidString: inferred.bundleID) == nil {
                    registerApp(
                        bundleID: inferred.bundleID,
                        containerPath: dirPath,
                        preferredName: inferred.name,
                        preferredIcon: inferred.icon
                    )
                }
            }

            // Sort: non-system (user) apps first, then alphabetical by appName / bundleID
            let sorted = Array(resultsByBundleID.values).sorted { a, b in
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
            return sorted
        }.value

        writeScanSnapshot(scanned)

        await MainActor.run {
            self.apps = scanned
            self.isLoading = false
            self.statusMessage = "Đã tìm thấy \(scanned.count) ứng dụng."
        }
        return scanned
    }

    /// Resolves a container by Bundle ID strictly on a background thread (never blocking Main Thread).
    func resolveContainer(bundleID: String) async -> AppContainerInfo? {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, UUID(uuidString: clean) == nil else { return nil }

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

            _ = ContainerStore.ensureContainerAccess(for: mcmPath)
            let meta = ContainerStore.readContainerMetadata(containerPath: mcmPath)
            let actualBundleID = (meta != nil && !meta!.bundleID.isEmpty && UUID(uuidString: meta!.bundleID) == nil)
                ? meta!.bundleID
                : clean
            let udid = (mcmPath as NSString).lastPathComponent
            let proxyInfo = appInfoForBundleID(actualBundleID) as? [String: Any] ?? [:]
            let name = AppDisplayNamePolicy.resolve(
                bundleID: actualBundleID,
                candidates: [meta?.displayName, proxyInfo["name"] as? String]
            )
            let icon = (proxyInfo["icon"] as? UIImage) ?? iconForBundleID(actualBundleID)
            let bPath = proxyInfo["bundlePath"] as? String

            let info = AppContainerInfo(
                appName: name,
                bundleID: actualBundleID,
                udid: udid,
                dataPath: mcmPath,
                bundlePath: bPath,
                appIcon: icon
            )
            self?.storeInCache(info)
            return info
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
