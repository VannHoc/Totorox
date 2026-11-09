import Foundation
import Darwin
import UIKit

// MARK: - Models

struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let containerPath: String
    let version: String
    let icon: UIImage?

    var id: String { bundleID }
    var displayName: String {
        AppDisplayNamePolicy.resolve(bundleID: bundleID, candidates: [name])
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct FileEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let createdAt: Date?
    let isSymlink: Bool
    let posixPermissions: UInt16
    let childCount: Int?

    // App Container resolution fields
    let appName: String?
    let bundleID: String?
    let appIcon: UIImage?
    let isAppContainer: Bool
    let shortUUID: String?

    var id: String { path }

    static func == (lhs: FileEntry, rhs: FileEntry) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    var sizeText: String {
        guard size >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var extensionBadge: String {
        guard !isDirectory else { return "" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "" : ".\(ext.lowercased())"
    }

    var childCountText: String {
        if isDirectory {
            if let count = childCount {
                return count == 0 ? "Trống" : "\(count) mục"
            }
            return "Thư mục"
        }
        return sizeText
    }

    var formattedModifiedDate: String? {
        guard let d = modifiedAt else { return nil }
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: d)
    }

    var formattedCreatedDate: String? {
        guard let d = createdAt else { return nil }
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: d)
    }

    var octalPermissions: String {
        String(format: "%04o", posixPermissions & 0o7777)
    }

    var symbolicPermissions: String {
        let r1 = (posixPermissions & UInt16(S_IRUSR)) != 0 ? "r" : "-"
        let w1 = (posixPermissions & UInt16(S_IWUSR)) != 0 ? "w" : "-"
        let x1 = (posixPermissions & UInt16(S_IXUSR)) != 0 ? "x" : "-"
        let r2 = (posixPermissions & UInt16(S_IRGRP)) != 0 ? "r" : "-"
        let w2 = (posixPermissions & UInt16(S_IWGRP)) != 0 ? "w" : "-"
        let x2 = (posixPermissions & UInt16(S_IXGRP)) != 0 ? "x" : "-"
        let r3 = (posixPermissions & UInt16(S_IROTH)) != 0 ? "r" : "-"
        let w3 = (posixPermissions & UInt16(S_IWOTH)) != 0 ? "w" : "-"
        let x3 = (posixPermissions & UInt16(S_IXOTH)) != 0 ? "x" : "-"
        return "\(r1)\(w1)\(x1)\(r2)\(w2)\(x2)\(r3)\(w3)\(x3)"
    }

    var exactBytesText: String {
        if isDirectory { return "Thư mục" }
        guard size >= 0 else { return "—" }
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let formatted = nf.string(from: NSNumber(value: size)) ?? "\(size)"
        return "\(formatted) bytes (\(sizeText))"
    }

    var typeDescription: String {
        if isAppContainer {
            return "Thư mục Ứng dụng (App Container)"
        } else if isDirectory {
            return "Thư mục (Directory)"
        } else if isSymlink {
            return "Liên kết tượng trưng (Symbolic Link)"
        } else {
            return "Tệp tin (File)"
        }
    }

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date? = nil,
        createdAt: Date? = nil,
        isSymlink: Bool = false,
        posixPermissions: UInt16 = 0o644,
        childCount: Int? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        appIcon: UIImage? = nil,
        isAppContainer: Bool = false,
        shortUUID: String? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.isSymlink = isSymlink
        self.posixPermissions = posixPermissions
        self.childCount = childCount
        self.appName = appName
        self.bundleID = bundleID
        self.appIcon = appIcon
        self.isAppContainer = isAppContainer
        self.shortUUID = shortUUID
    }

    func withDirectorySummary(_ summary: FileBrowserDirectorySummary?) -> FileEntry {
        FileEntry(
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: summary?.byteCount ?? -2,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            isSymlink: isSymlink,
            posixPermissions: posixPermissions,
            childCount: summary?.childCount,
            appName: appName,
            bundleID: bundleID,
            appIcon: appIcon,
            isAppContainer: isAppContainer,
            shortUUID: shortUUID
        )
    }
}

// MARK: - Store

enum ContainerStore {
    static let appDataRoot = "/var/mobile/Containers/Data/Application"
    static let systemDataRoot = "/var/mobile/Containers/Data/System"
    private static var shouldUseBadQuery: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }
    private static let applicationBundleRoots: [(path: String, nested: Bool)] = [
        ("/var/containers/Bundle/Application", true),
        ("/Applications", false),
        ("/System/Applications", false)
    ]
    static let researchAppIdentifiers = [
        "com.apple.mobilesafari", "com.apple.mobilenotes", "com.apple.Maps",
        "com.apple.facetime", "com.apple.iBooks", "com.apple.podcasts",
        "com.apple.PosterBoard", "com.apple.mobilemail", "com.apple.weather",
        "com.apple.camera", "com.apple.Health", "com.apple.Fitness",
        "com.apple.tips", "com.apple.Passbook", "com.apple.reminders",
        "com.apple.stocks", "com.apple.news", "com.apple.Home", "com.apple.tv",
        "com.apple.shortcuts", "com.apple.freeform", "com.apple.calculator",
        "com.apple.MobileSMS", "com.apple.InCallService", "com.apple.Preferences",
        "com.apple.springboard", "com.apple.Photos", "com.apple.AppStore",
        "com.apple.Music", "com.apple.Bridge", "com.apple.Clock",
        "com.apple.VoiceMemos", "com.apple.Translate", "com.apple.measure",
        "com.apple.compass", "com.apple.Magnifier", "com.apple.DocumentsApp"
    ]

    static func resolveAppContainerPath(bundleID: String) -> String? {
        guard (try? PatchPathValidator.canonicalBundleIdentifier(bundleID)) == bundleID else {
            return nil
        }
        var lookupError: NSString?
        if let path = MCMActivateContainerPath(2, bundleID, false, &lookupError),
           isApplicationContainerPath(path) {
            log("patch: MHA-C2 resolved \(bundleID)")
            return path
        }
        let detail = lookupError.map(String.init) ?? "unavailable"
        log("patch: MHA-C2 could not resolve \(bundleID), detail=\(detail)")

        // Fallback for iOS builds where MCM refuses to hand out sandbox
        // tokens (e.g. iOS 18.1.x): scan the app-data root with the inode
        // walk and read each container's MCM metadata plist directly. The
        // raw reads only succeed when the sandbox escape is active.
        if let scanned = resolveAppContainerPathByMetadataScan(bundleID: bundleID) {
            log("patch: filesystem metadata scan resolved \(bundleID)")
            return scanned
        }
        return nil
    }

    static func resolveAppContainerPathByMetadataScan(bundleID: String) -> String? {
        // iOS < 26: kernel R/W is enough, no need to require full sandbox escape
        if KernelExploit.requiresSandboxEscape, !KernelExploit.hasSandboxAccess() {
            log("patch: metadata scan skipped — sandbox access not active")
            return nil
        }
        let dirs = enumerateDirectories(path: appDataRoot)
        guard !dirs.isEmpty else {
            log("patch: metadata scan unavailable — no containers enumerated")
            return nil
        }
        for dir in dirs {
            guard UUID(uuidString: (dir as NSString).lastPathComponent) != nil else { continue }
            guard let metadata = readContainerMetadata(containerPath: dir),
                  metadata.bundleID == bundleID else { continue }
            let canonical = ContainerDiscoveryMerger.canonicalPath(dir)
            guard isApplicationContainerPath(canonical) else { continue }
            return canonical
        }
        return nil
    }

    // MARK: Primary — MobileInstallation / LSApplicationWorkspace

    static func installedAppsFromAPI() -> [InstalledApp] {
        let raw = installedAppInfo() as? [String: [String: Any]] ?? [:]
        var apps: [InstalledApp] = []
        var missingContainer = 0
        for (bundleID, info) in raw {
            var containerPath = info["container"] as? String ?? ""
            if containerPath.isEmpty {
                var lookupError: NSString?
                if let resolved = MCMActivateContainerPath(2, bundleID, false, &lookupError),
                   isApplicationContainerPath(resolved) {
                    containerPath = resolved
                } else {
                    missingContainer += 1
                }
            }
            // Skip entries we cannot browse — empty path is dropped by mergers anyway.
            guard !containerPath.isEmpty else { continue }
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: info["name"] as? String ?? "",
                containerPath: containerPath,
                version: info["version"] as? String ?? "",
                icon: info["icon"] as? UIImage
            ))
        }
        log("browser: LS/API apps=\(apps.count) raw=\(raw.count) missingContainer=\(missingContainer)")
        return apps
    }

    static func applicationBundleMetadataCatalog() -> [String: ApplicationBundleMetadata] {
        var catalog: [String: ApplicationBundleMetadata] = [:]
        for root in applicationBundleRoots {
            for metadata in applicationBundleMetadata(at: root.path, nested: root.nested) {
                catalog[metadata.bundleID] = metadata
            }
        }
        log("browser: app-bundle metadata resolved \(catalog.count) names")
        return catalog
    }

    static func applyingBundleMetadata(
        to apps: [InstalledApp],
        catalog: [String: ApplicationBundleMetadata]
    ) -> [InstalledApp] {
        apps.map { app in
            guard let metadata = catalog[app.bundleID] else { return app }
            return InstalledApp(
                bundleID: app.bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: app.bundleID,
                    candidates: [metadata.displayName, app.name]
                ),
                containerPath: app.containerPath,
                version: app.version.isEmpty ? metadata.version : app.version,
                icon: app.icon
            )
        }
    }

    static func dynamicAppIdentifiers() -> [String] {
        var enumerationError: NSString?
        let identifiers = MCMEnumerateIdentifiersForClass(2, 1_024, &enumerationError)
        let enumerationDetail = enumerationError.map { String($0) } ?? "none"
        log("browser: MCM class-2 identifiers=\(identifiers.count) detail=\(enumerationDetail)")
        return identifiers
    }

    static func installedAppsFromMCM(
        identifiers: [String]? = nil,
        bundleMetadata: [String: ApplicationBundleMetadata] = [:]
    ) -> [InstalledApp] {
        let identifiers = identifiers ?? dynamicAppIdentifiers()

        var apps: [InstalledApp] = []
        for (index, bundleID) in identifiers.enumerated() {
            var lookupError: NSString?
            guard let containerPath = MCMActivateContainerPath(2, bundleID, false, &lookupError) else {
                let lookupDetail = lookupError.map { String($0) } ?? "no path"
                if index < 3 { log("mcm[\(index)]: \(bundleID) -> \(lookupDetail)") }
                continue
            }
            if index < 3 { log("mcm[\(index)]: \(bundleID) -> \(containerPath)") }

            let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
            let metadata = bundleMetadata[bundleID]
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: bundleID,
                    candidates: [metadata?.displayName, rawInfo["name"] as? String]
                ),
                containerPath: containerPath,
                version: rawInfo["version"] as? String ?? metadata?.version ?? "",
                icon: rawInfo["icon"] as? UIImage
            ))
        }
        log("browser: MCM resolved \(apps.count)/\(identifiers.count) app paths")
        return apps
    }

    // MARK: LaunchServices store discovery

    static func installedAppsFromMHACandidates(
        identifiers: [String],
        bundleMetadata: [String: ApplicationBundleMetadata] = [:],
        progress: (([InstalledApp]) -> Void)? = nil
    ) -> [InstalledApp] {
        guard !identifiers.isEmpty else {
            log("browser: MHA catalog returned no bundle candidates")
            return []
        }

        var apps: [InstalledApp] = []
        for (index, bundleID) in identifiers.enumerated() {
            var lookupError: NSString?
            guard let containerPath = MCMActivateContainerPath(
                2,
                bundleID,
                false,
                &lookupError
            ),
                  isApplicationContainerPath(containerPath) else {
                if index < 3 {
                    let detail = lookupError.map { String($0) } ?? "invalid app-data path"
                    log("mha-candidate[\(index)]: \(bundleID) -> \(detail)")
                }
                continue
            }

            let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
            let metadata = bundleMetadata[bundleID]
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: bundleID,
                    candidates: [metadata?.displayName, rawInfo["name"] as? String]
                ),
                containerPath: containerPath,
                version: rawInfo["version"] as? String ?? metadata?.version ?? "",
                icon: rawInfo["icon"] as? UIImage
            ))
            if apps.count <= 5 {
                log("browser: MHA-C2 resolved \(bundleID) -> \(containerPath)")
            }
            if apps.count.isMultiple(of: 8) {
                progress?(apps)
            }
        }

        progress?(apps)
        log("browser: MHA-C2 resolved \(apps.count)/\(identifiers.count) bundle candidates")
        return apps
    }

    private static func applicationBundleMetadata(
        at rootPath: String,
        nested: Bool
    ) -> [ApplicationBundleMetadata] {
        let handle = grantContainerAccess(rootPath)
        defer {
            if handle >= 0 { bad_query_release(handle) }
        }

        let fileManager = FileManager.default
        let rootEntries: [String]
        if let posixEntries = posixListDirectory(at: rootPath), !posixEntries.isEmpty {
            rootEntries = posixEntries.map { ($0.path as NSString).lastPathComponent }
        } else if let fmEntries = try? fileManager.contentsOfDirectory(atPath: rootPath) {
            rootEntries = fmEntries
        } else {
            log("browser: app-bundle metadata unavailable root=\(rootPath) grant=\(handle)")
            return []
        }

        let bundlePaths: [String]
        if nested {
            bundlePaths = rootEntries.prefix(2_048).flatMap { entry -> [String] in
                guard UUID(uuidString: entry) != nil else { return [] }
                let containerPath = (rootPath as NSString).appendingPathComponent(entry)
                let children = (try? fileManager.contentsOfDirectory(atPath: containerPath)) ?? []
                return children.prefix(16).compactMap { child in
                    guard child.hasSuffix(".app") else { return nil }
                    return (containerPath as NSString).appendingPathComponent(child)
                }
            }
        } else {
            bundlePaths = rootEntries.prefix(2_048).compactMap { entry in
                guard entry.hasSuffix(".app") else { return nil }
                return (rootPath as NSString).appendingPathComponent(entry)
            }
        }

        return bundlePaths.compactMap { bundlePath in
            let infoPath = (bundlePath as NSString).appendingPathComponent("Info.plist")
            let infoSize = (try? fileManager.attributesOfItem(atPath: infoPath)[.size] as? NSNumber)?
                .int64Value ?? 0
            guard infoSize > 0, infoSize <= 2 * 1_024 * 1_024 else { return nil }
            guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: infoPath)) else {
                return nil
            }
            return ApplicationBundleMetadataReader.metadata(
                from: plistData,
                localizedInfo: Bundle(path: bundlePath)?.localizedInfoDictionary
            )
        }
    }

    static func launchServicesStoreIdentifiers() -> [String] {
        var cachePaths: [String] = []
        var seenCachePaths = Set<String>()

        func addCachePath(_ rawPath: String) {
            let path = ContainerDiscoveryMerger.canonicalPath(rawPath)
            guard !path.isEmpty, seenCachePaths.insert(path).inserted else { return }
            cachePaths.append(path)
        }

        var leasedCachePaths = Set<String>()
        var serviceLookupError: NSString?
        if let servicePath = MCMActivateContainerPath(
            10,
            "com.apple.lsd",
            false,
            &serviceLookupError
        ) {
            let cachePath = (servicePath as NSString).appendingPathComponent("Library/Caches")
            addCachePath(cachePath)
            leasedCachePaths.insert(ContainerDiscoveryMerger.canonicalPath(cachePath))
        } else if shouldUseBadQuery {
            let detail = serviceLookupError.map { String($0) } ?? "no path"
            log("browser: MCM com.apple.lsd activation unavailable detail=\(detail)")
        }

        let traversedSystemDirectories = enumerateDirectoriesWithTraversalGrant(path: systemDataRoot)
        let systemDirectories = traversedSystemDirectories.isEmpty
            ? enumerateDirectories(path: systemDataRoot)
            : traversedSystemDirectories
        for directory in systemDirectories {
            // Attempt the raw metadata read even without a traversal grant:
            // it succeeds when the sandbox escape is active, which is the
            // only path left when MCM/bad_query grants are denied.
            guard readContainerMetadata(containerPath: directory)?.bundleID == "com.apple.lsd" else {
                continue
            }
            addCachePath((directory as NSString).appendingPathComponent("Library/Caches"))
        }

        // Older and Simulator layouts keep the same store outside the MCM
        // service-container layout. They are harmless fallbacks on device.
        addCachePath("/var/db/lsd")
        addCachePath("/var/mobile/Library/Caches")

        var identifiers: [String] = []
        var seenIdentifiers = Set<String>()
        let maximumCandidateCount = 65_536

        for cachePath in cachePaths where identifiers.count < maximumCandidateCount {
            let hasLease = leasedCachePaths.contains(
                ContainerDiscoveryMerger.canonicalPath(cachePath)
            )
            let handle: Int64
            if hasLease || !shouldUseBadQuery {
                handle = -1
            } else {
                handle = grantContainerAccess(cachePath)
                if handle < 0 {
                    log("browser: LaunchServices traversal grant failed \(cachePath) -> \(handle)")
                    continue
                }
            }
            defer {
                if handle >= 0 { bad_query_release(handle) }
            }

            let names = (try? FileManager.default.contentsOfDirectory(atPath: cachePath)) ?? []
            for name in names where identifiers.count < maximumCandidateCount {
                guard name.hasPrefix("com.apple.LaunchServices-"),
                      name.hasSuffix("-v2.csstore") else {
                    continue
                }
                let storePath = (cachePath as NSString).appendingPathComponent(name)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: storePath)[.size]) as? NSNumber,
                      size.uint64Value > 0,
                      size.uint64Value <= 64 * 1_024 * 1_024,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: storePath), options: .mappedIfSafe) else {
                    continue
                }
                let remaining = maximumCandidateCount - identifiers.count
                let extracted = LaunchServicesCandidateExtractor.identifiers(from: data, limit: remaining)
                for identifier in extracted where seenIdentifiers.insert(identifier).inserted {
                    identifiers.append(identifier)
                }
                log("browser: LaunchServices store \(name) bytes=\(data.count) candidates=\(identifiers.count)")
            }
        }

        log("browser: LaunchServices store total candidates=\(identifiers.count)")
        return identifiers
    }

    static func isApplicationContainerPath(_ path: String) -> Bool {
        let canonicalRoot = ContainerDiscoveryMerger.canonicalPath(appDataRoot)
        let canonicalPath = ContainerDiscoveryMerger.canonicalPath(path)
        guard canonicalPath.hasPrefix(canonicalRoot + "/") else { return false }
        return UUID(uuidString: (canonicalPath as NSString).lastPathComponent) != nil
    }

    // MARK: Filesystem discovery

    static func enumerateDirectories(path: String, maxInode: Int64 = 2_000_000) -> [String] {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard clean.hasPrefix("/") else { return [] }

        // 1. Try low-level POSIX opendir/readdir
        if let dir = opendir(clean) {
            defer { closedir(dir) }
            var subdirs: [String] = []
            while let dp = readdir(dir) {
                let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                let full = (clean as NSString).appendingPathComponent(name)
                var st = stat()
                if lstat(full, &st) == 0 {
                    if (st.st_mode & S_IFMT) == S_IFDIR {
                        subdirs.append(full)
                    }
                } else if dp.pointee.d_type == DT_DIR {
                    subdirs.append(full)
                }
            }
            if !subdirs.isEmpty {
                return subdirs
            }
        }

        // 2. Try standard FileManager
        if let names = try? FileManager.default.contentsOfDirectory(atPath: clean), !names.isEmpty {
            return names.map { (clean as NSString).appendingPathComponent($0) }
        }

        // 3. Fallback to bad_query inode enumeration
        var pathC = clean.utf8CString.map { Int8($0) }
        guard let result = bad_query_list(&pathC, maxInode) else {
            log("enumerate: NULL for \(clean)")
            return []
        }
        defer { free(result) }
        let list = String(cString: result).components(separatedBy: "\n").filter { !$0.isEmpty }
        if !list.isEmpty {
            log("enumerate: inode fallback for \(clean) -> \(list.count) entries")
        } else {
            log("enumerate: FileManager+inode unavailable for \(clean)")
        }
        return list
    }

    static func enumerateDirectoriesWithTraversalGrant(path: String) -> [String] {
        let handle = grantContainerAccess(path)
        if handle >= 0 {
            defer { bad_query_release(handle) }
            if let posixEntries = posixListDirectory(at: path), !posixEntries.isEmpty {
                return posixEntries.filter { $0.isDirectory }.map { $0.path }
            }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path), !names.isEmpty {
                return names.map { (path as NSString).appendingPathComponent($0) }
            }
        } else if !shouldUseBadQuery {
            if let posixEntries = posixListDirectory(at: path), !posixEntries.isEmpty {
                return posixEntries.filter { $0.isDirectory }.map { $0.path }
            }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path), !names.isEmpty {
                return names.map { (path as NSString).appendingPathComponent($0) }
            }
        } else {
            log("browser: root traversal grant failed \(path) -> \(handle)")
        }

        return enumerateDirectories(path: path)
    }

    static func readContainerMetadata(containerPath: String) -> ContainerMetadata? {
        let metadataPath = metadataPath(for: containerPath)

        var data: Data?
        if let fd = fopen(metadataPath, "r") {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var bytes: [UInt8] = []
            while true {
                let n = fread(&buffer, 1, buffer.count, fd)
                if n <= 0 { break }
                bytes.append(contentsOf: buffer[0..<n])
            }
            fclose(fd)
            if !bytes.isEmpty { data = Data(bytes) }
        }
        if data == nil { data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)) }

        guard let validData = data,
              let plist = try? PropertyListSerialization.propertyList(from: validData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let bundleID = plist["MCMMetadataIdentifier"] as? String ?? ""
        var displayName = ""
        if let info = plist["MCMMetadataInfo"] as? [String: Any] {
            displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
        }
        return ContainerMetadata(bundleID: bundleID, displayName: displayName)
    }

    static func metadataPath(for containerPath: String) -> String {
        (containerPath as NSString).appendingPathComponent(
            ".com.apple.mobile_container_manager.metadata.plist"
        )
    }

    static func grantContainerAccess(_ containerPath: String) -> Int64 {
        guard shouldUseBadQuery else { return -1 }
        let clean = containerPath.hasSuffix("/") ? String(containerPath.dropLast()) : containerPath
        var pathC = clean.utf8CString.map { Int8($0) }
        return bad_query(&pathC, true, nil, false)
    }

    static func containersFromFilesystem() -> [InstalledApp] {
        let grantedDirectories = enumerateDirectoriesWithTraversalGrant(path: appDataRoot)
        let dirs: [String]
        if grantedDirectories.isEmpty {
            dirs = enumerateDirectories(path: appDataRoot)
            log("browser: filesystem root=\(appDataRoot) inode fallback enumerated \(dirs.count) containers")
        } else {
            dirs = grantedDirectories
            log("browser: filesystem root=\(appDataRoot) traversal enumerated \(dirs.count) containers")
        }
        let apps = dirs.compactMap { dir -> InstalledApp? in
            let uuid = (dir as NSString).lastPathComponent
            guard UUID(uuidString: uuid) != nil else { return nil }
            let fallback = ContainerIdentityResolver.fallbackIdentity(containerPath: dir)
            return InstalledApp(
                bundleID: fallback.bundleID,
                name: fallback.displayName,
                containerPath: dir,
                version: "",
                icon: nil
            )
        }
        log("browser: filesystem accepted \(apps.count)/\(dirs.count) app containers")
        return apps
    }

    static func inferredApp(
        for fallback: InstalledApp,
        knownAppsByBundleID: [String: InstalledApp],
        launchServicesIdentifiers: Set<String>
    ) -> InstalledApp? {
        guard UUID(uuidString: fallback.bundleID) != nil else { return fallback }

        // Read the MCM metadata plist directly. With the sandbox escape
        // active the raw read succeeds even when every MCM/bad_query grant
        // is denied; without it the read simply fails and we fall through.
        if let metadata = readContainerMetadata(containerPath: fallback.containerPath) {
            let bundleID = metadata.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            if ContainerBundleCandidateResolver.isValidBundleIdentifier(bundleID),
               !bundleID.hasPrefix("systemgroup.") {
                let info = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                let resolvedName = metadata.displayName.isEmpty
                    ? (info["name"] as? String ?? bundleID)
                    : metadata.displayName
                return InstalledApp(
                    bundleID: bundleID,
                    name: resolvedName,
                    containerPath: fallback.containerPath,
                    version: info["version"] as? String ?? "",
                    icon: info["icon"] as? UIImage
                )
            }
        }

        let handle = grantContainerAccess(fallback.containerPath)
        defer {
            if handle >= 0 { bad_query_release(handle) }
        }

        let libraryPath = (fallback.containerPath as NSString).appendingPathComponent("Library")
        let savedStatePath = (libraryPath as NSString).appendingPathComponent("Saved Application State")
        let preferencesPath = (libraryPath as NSString).appendingPathComponent("Preferences")
        let savedStates = (try? FileManager.default.contentsOfDirectory(atPath: savedStatePath)) ?? []
        let preferences = (try? FileManager.default.contentsOfDirectory(atPath: preferencesPath)) ?? []
        let strongCandidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: savedStates,
            preferenceFileNames: []
        )
        let candidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: savedStates,
            preferenceFileNames: preferences
        )

        func resolvedApp(from candidates: [String], source: String) -> InstalledApp? {
            for bundleID in candidates {
                if let known = knownAppsByBundleID[bundleID] {
                    return InstalledApp(
                        bundleID: bundleID,
                        name: known.name,
                        containerPath: fallback.containerPath,
                        version: known.version,
                        icon: known.icon
                    )
                }

                let info = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                guard info["found"] as? Bool == true else { continue }
                return InstalledApp(
                    bundleID: bundleID,
                    name: info["name"] as? String ?? bundleID,
                    containerPath: fallback.containerPath,
                    version: info["version"] as? String ?? "",
                    icon: info["icon"] as? UIImage
                )
            }

            guard let bundleID = ContainerBundleCandidateResolver.confirmedCandidate(
                candidates: candidates,
                launchServicesIdentifiers: launchServicesIdentifiers
            ) else {
                return nil
            }
            let uuid = (fallback.containerPath as NSString).lastPathComponent
            log("browser: content+LaunchServices confirmed \(uuid) -> \(bundleID) source=\(source)")
            return InstalledApp(
                bundleID: bundleID,
                name: bundleID,
                containerPath: fallback.containerPath,
                version: "",
                icon: nil
            )
        }

        if let app = resolvedApp(from: candidates, source: "state/preferences") {
            return app
        }
        if let bundleID = strongCandidates.first {
            return InstalledApp(
                bundleID: bundleID,
                name: bundleID,
                containerPath: fallback.containerPath,
                version: "",
                icon: nil
            )
        }

        let artifactPaths = [
            (libraryPath as NSString).appendingPathComponent("SplashBoard/Snapshots"),
            (libraryPath as NSString).appendingPathComponent("Caches/Snapshots"),
            (libraryPath as NSString).appendingPathComponent("Cookies"),
            (libraryPath as NSString).appendingPathComponent("WebKit")
        ]
        let artifactNames = artifactPaths.flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }
        let artifactCandidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: [],
            preferenceFileNames: [],
            artifactNames: artifactNames
        )
        if let app = resolvedApp(from: artifactCandidates, source: "artifacts") {
            return app
        }

        let uuid = (fallback.containerPath as NSString).lastPathComponent
        let preview = (candidates + artifactCandidates).prefix(6).joined(separator: ",")
        log("browser: unresolved \(uuid) metadata=unavailable savedStates=\(savedStates.count) preferences=\(preferences.count) artifacts=\(artifactNames.count) candidates=[\(preview)]")
        return nil
    }

    static func inferUnidentifiedApps(
        in apps: [InstalledApp],
        knownApps: [InstalledApp],
        launchServicesIdentifiers: Set<String> = []
    ) -> [InstalledApp] {
        let knownByBundleID = Dictionary(knownApps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        var inferredCount = 0
        let result = apps.enumerated().map { index, app -> InstalledApp in
            guard UUID(uuidString: app.bundleID) != nil,
                  let inferred = autoreleasepool(invoking: {
                      inferredApp(
                        for: app,
                        knownAppsByBundleID: knownByBundleID,
                        launchServicesIdentifiers: launchServicesIdentifiers
                      )
                  }) else {
                return app
            }
            inferredCount += 1
            if inferredCount <= 5 {
                log("browser: inferred \((app.containerPath as NSString).lastPathComponent) -> \(inferred.bundleID)")
            }
            return inferred
        }
        let unresolvedCount = result.filter { UUID(uuidString: $0.bundleID) != nil }.count
        log("browser: inferred identities for \(inferredCount)/\(apps.count) merged containers; unresolved=\(unresolvedCount)")
        return result
    }

    // MARK: File browsing

    static func posixListDirectory(at path: String) -> [FileEntry]? {
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        guard let dir = opendir(clean) else {
            return nil
        }
        defer { closedir(dir) }

        let isAppContainerDirectory = clean.contains("Containers/Data/Application") || clean.contains("Bundle/Application")

        var entries: [FileEntry] = []
        while let dp = readdir(dir) {
            let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." || name.hasPrefix(".") {
                continue
            }

            let full = (clean as NSString).appendingPathComponent(name)
            var st = stat()
            let statRes = lstat(full, &st)

            let isDir: Bool
            let isSymlink: Bool
            let size: Int64
            let modDate: Date?
            let createDate: Date?
            let mode: UInt16

            if statRes == 0 {
                mode = UInt16(st.st_mode)
                isDir = (st.st_mode & S_IFMT) == S_IFDIR
                isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
                size = isDir ? -1 : Int64(st.st_size)
                modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                createDate = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
            } else {
                mode = 0
                isDir = (dp.pointee.d_type == DT_DIR)
                isSymlink = (dp.pointee.d_type == DT_LNK)
                size = isDir ? -1 : 0
                modDate = nil
                createDate = nil
            }

            var appName: String? = nil
            var bundleID: String? = nil
            var appIcon: UIImage? = nil
            var isAppContainer = false
            var shortUUID: String? = nil
            var childCount: Int? = nil

            if isDir && isAppContainerDirectory && UUID(uuidString: name) != nil {
                isAppContainer = true
                if let cached = ContainerMetadataCache.shared.cachedApp(forUUID: name) {
                    appName = cached.appName
                    bundleID = cached.bundleID
                    appIcon = cached.icon
                    shortUUID = cached.shortUUID
                } else if let meta = readContainerMetadata(containerPath: full), !meta.bundleID.isEmpty {
                    bundleID = meta.bundleID
                    let info = appInfoForBundleID(meta.bundleID)
                    let resolvedName = (info?["name"] as? String) ?? (meta.displayName.isEmpty ? meta.bundleID : meta.displayName)
                    appName = resolvedName
                    appIcon = iconForBundleID(meta.bundleID)
                    let containerMeta = AppContainerMetadata(
                        uuid: name,
                        containerPath: full,
                        bundleID: meta.bundleID,
                        appName: resolvedName,
                        icon: appIcon,
                        isUserApp: true,
                        modificationDate: modDate
                    )
                    ContainerMetadataCache.shared.store(app: containerMeta)
                    shortUUID = containerMeta.shortUUID
                } else {
                    shortUUID = name.count >= 8 ? "\(name.prefix(4))...\(name.suffix(4))" : name
                }
            } else if isDir {
                childCount = DirectorySizeService.countImmediateChildren(at: full)
            }

            entries.append(
                FileEntry(
                    name: name,
                    path: full,
                    isDirectory: isDir,
                    size: size,
                    modifiedAt: modDate,
                    createdAt: createDate,
                    isSymlink: isSymlink,
                    posixPermissions: mode,
                    childCount: childCount,
                    appName: appName,
                    bundleID: bundleID,
                    appIcon: appIcon,
                    isAppContainer: isAppContainer,
                    shortUUID: shortUUID
                )
            )
        }
        return entries
    }

    static func listFiles(at path: String) -> [FileEntry] {
        // 1. Try POSIX opendir/readdir first
        if let posixEntries = posixListDirectory(at: path), !posixEntries.isEmpty {
            return sortedEntries(posixEntries)
        }

        // 2. Try with bad_query traversal grant
        let handle = grantContainerAccess(path)
        if handle >= 0 {
            defer { bad_query_release(handle) }
            if let posixEntries = posixListDirectory(at: path), !posixEntries.isEmpty {
                return sortedEntries(posixEntries)
            }
            if let fmEntries = fileManagerListFiles(at: path), !fmEntries.isEmpty {
                return sortedEntries(fmEntries)
            }
        }

        // 3. Fallback for /var/mobile/Containers/Data/Application via inode walk
        let canonicalRoot = ContainerDiscoveryMerger.canonicalPath(appDataRoot)
        let canonicalPath = ContainerDiscoveryMerger.canonicalPath(path)
        if canonicalPath == canonicalRoot {
            let inodeDirs = enumerateDirectories(path: appDataRoot)
            if !inodeDirs.isEmpty {
                let entries = inodeDirs.compactMap { dir -> FileEntry? in
                    let uuid = (dir as NSString).lastPathComponent
                    guard UUID(uuidString: uuid) != nil else { return nil }

                    var appName: String? = nil
                    var bundleID: String? = nil
                    var appIcon: UIImage? = nil
                    let shortUUID = uuid.count >= 8 ? "\(uuid.prefix(4))...\(uuid.suffix(4))" : uuid

                    if let cached = ContainerMetadataCache.shared.cachedApp(forUUID: uuid) {
                        appName = cached.appName
                        bundleID = cached.bundleID
                        appIcon = cached.icon
                    } else if let meta = readContainerMetadata(containerPath: dir), !meta.bundleID.isEmpty {
                        bundleID = meta.bundleID
                        let info = appInfoForBundleID(meta.bundleID)
                        let resolvedName = (info?["name"] as? String) ?? (meta.displayName.isEmpty ? meta.bundleID : meta.displayName)
                        appName = resolvedName
                        appIcon = iconForBundleID(meta.bundleID)
                        let containerMeta = AppContainerMetadata(
                            uuid: uuid,
                            containerPath: dir,
                            bundleID: meta.bundleID,
                            appName: resolvedName,
                            icon: appIcon,
                            isUserApp: true,
                            modificationDate: nil
                        )
                        ContainerMetadataCache.shared.store(app: containerMeta)
                    }

                    return FileEntry(
                        name: uuid,
                        path: dir,
                        isDirectory: true,
                        size: -1,
                        modifiedAt: nil,
                        createdAt: nil,
                        isSymlink: false,
                        posixPermissions: 0o755,
                        childCount: nil,
                        appName: appName,
                        bundleID: bundleID,
                        appIcon: appIcon,
                        isAppContainer: true,
                        shortUUID: shortUUID
                    )
                }
                if !entries.isEmpty {
                    return sortedEntries(entries)
                }
            }
        }

        // 4. Default to FileManager
        if let fallback = fileManagerListFiles(at: path) {
            return sortedEntries(fallback)
        }

        log("listFiles: FAILED for \(path) errno=\(errno)")
        return []
    }

    public static func sortedEntries(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            // 1. User app containers first, sorted alphabetically by App Name
            let lhsIsUserApp = lhs.isAppContainer && lhs.appName != nil
            let rhsIsUserApp = rhs.isAppContainer && rhs.appName != nil
            if lhsIsUserApp != rhsIsUserApp {
                return lhsIsUserApp
            }
            if lhsIsUserApp && rhsIsUserApp {
                let name1 = lhs.appName ?? lhs.name
                let name2 = rhs.appName ?? rhs.name
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }

            // 2. Directories before regular files
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            // 3. Alphabetical by display name / filename
            let n1 = lhs.appName ?? lhs.name
            let n2 = rhs.appName ?? rhs.name
            return n1.localizedStandardCompare(n2) == .orderedAscending
        }
    }

    private static func fileManagerListFiles(at path: String) -> [FileEntry]? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else {
            return nil
        }
        let isAppContainerDirectory = path.contains("Containers/Data/Application") || path.contains("Bundle/Application")
        var entries: [FileEntry] = []
        for item in items {
            if item.hasPrefix(".") { continue }
            let full = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            let attributes = try? fm.attributesOfItem(atPath: full)
            let isDirectory = isDir.boolValue
            let size = isDirectory
                ? -1
                : (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let posixMode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let modDate = attributes?[.modificationDate] as? Date
            let createDate = attributes?[.creationDate] as? Date

            var appName: String? = nil
            var bundleID: String? = nil
            var appIcon: UIImage? = nil
            var isAppContainer = false
            var shortUUID: String? = nil
            var childCount: Int? = nil

            if isDirectory && isAppContainerDirectory && UUID(uuidString: item) != nil {
                isAppContainer = true
                if let cached = ContainerMetadataCache.shared.cachedApp(forUUID: item) {
                    appName = cached.appName
                    bundleID = cached.bundleID
                    appIcon = cached.icon
                    shortUUID = cached.shortUUID
                } else if let meta = readContainerMetadata(containerPath: full), !meta.bundleID.isEmpty {
                    bundleID = meta.bundleID
                    let info = appInfoForBundleID(meta.bundleID)
                    let resolvedName = (info?["name"] as? String) ?? (meta.displayName.isEmpty ? meta.bundleID : meta.displayName)
                    appName = resolvedName
                    appIcon = iconForBundleID(meta.bundleID)
                    let containerMeta = AppContainerMetadata(
                        uuid: item,
                        containerPath: full,
                        bundleID: meta.bundleID,
                        appName: resolvedName,
                        icon: appIcon,
                        isUserApp: true,
                        modificationDate: modDate
                    )
                    ContainerMetadataCache.shared.store(app: containerMeta)
                    shortUUID = containerMeta.shortUUID
                } else {
                    shortUUID = item.count >= 8 ? "\(item.prefix(4))...\(item.suffix(4))" : item
                }
            } else if isDirectory {
                childCount = DirectorySizeService.countImmediateChildren(at: full)
            }

            entries.append(
                FileEntry(
                    name: item,
                    path: full,
                    isDirectory: isDirectory,
                    size: size,
                    modifiedAt: modDate,
                    createdAt: createDate,
                    isSymlink: (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink,
                    posixPermissions: posixMode,
                    childCount: childCount,
                    appName: appName,
                    bundleID: bundleID,
                    appIcon: appIcon,
                    isAppContainer: isAppContainer,
                    shortUUID: shortUUID
                )
            )
        }
        return entries
    }

    static func readTextFile(at path: String, limit: Int = 200_000) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "Unable to read file."
        }
        let truncated = data.prefix(limit)
        if let text = String(data: truncated, encoding: .utf8) {
            return data.count > limit ? text + "\n… [truncated]" : text
        }
        if let text = String(data: truncated, encoding: .utf16) {
            return data.count > limit ? text + "\n… [truncated]" : text
        }
        return "Binary data (\(data.count) bytes) — not text."
    }
}
