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
            [Color(red: 0.58, green: 0.28, blue: 0.96), Color(red: 0.78, green: 0.35, blue: 0.95)], // Purple/Violet
            [Color(red: 0.12, green: 0.58, blue: 0.95), Color(red: 0.25, green: 0.75, blue: 0.98)], // Azure Blue
            [Color(red: 0.95, green: 0.32, blue: 0.55), Color(red: 0.98, green: 0.52, blue: 0.68)], // Magenta/Pink
            [Color(red: 0.96, green: 0.52, blue: 0.22), Color(red: 0.98, green: 0.68, blue: 0.32)], // Orange Amber
            [Color(red: 0.18, green: 0.72, blue: 0.62), Color(red: 0.35, green: 0.85, blue: 0.75)], // Mint Teal
            [Color(red: 0.20, green: 0.45, blue: 0.95), Color(red: 0.42, green: 0.62, blue: 0.98)]  // Indigo Blue
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

final class AppContainerScanner: ObservableObject {
    static let shared = AppContainerScanner()
    
    @Published private(set) var apps: [AppContainerInfo] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var statusMessage: String = ""
    
    private var cacheByBundleID: [String: AppContainerInfo] = [:]
    private var cacheByUDID: [String: AppContainerInfo] = [:]
    private var hasScanned: Bool = false
    
    private init() {}
    
    func getCachedInfo(forUDID udid: String) -> AppContainerInfo? {
        return cacheByUDID[udid.uppercased()] ?? cacheByUDID[udid.lowercased()] ?? cacheByUDID[udid]
    }
    
    func getCachedInfo(forBundleID bundleID: String) -> AppContainerInfo? {
        return cacheByBundleID[bundleID]
    }
    
    /// Scans all application containers via Filesystem metadata and LaunchServices
    func scanAllContainers(forceRefresh: Bool = false) async -> [AppContainerInfo] {
        if !forceRefresh && hasScanned && !apps.isEmpty {
            return apps
        }
        
        await MainActor.run {
            self.isLoading = true
            self.statusMessage = "Đang quét danh sách ứng dụng..."
        }
        
        let scanned = await Task.detached(priority: .userInitiated) { () -> [AppContainerInfo] in
            var results: [String: AppContainerInfo] = [:]
            
            // 1. PRIMARY SOURCE: Scan /var/mobile/Containers/Data/Application directly
            let roots = [
                "/var/mobile/Containers/Data/Application",
                "/private/var/mobile/Containers/Data/Application"
            ]
            
            for root in roots {
                let dirNames = ContainerStore.enumerateDirectoryNames(path: root)
                for dirName in dirNames {
                    guard UUID(uuidString: dirName) != nil else { continue }
                    let dirPath = (root as NSString).appendingPathComponent(dirName)
                    
                    guard let meta = ContainerStore.readContainerMetadata(containerPath: dirPath),
                          !meta.bundleID.isEmpty else {
                        continue
                    }
                    
                    let bundleID = meta.bundleID
                    if results[bundleID] != nil { continue }
                    
                    // Query LSApplicationProxy for localizedName & icon
                    let proxyInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                    let lsName = proxyInfo["name"] as? String
                    let resolvedName: String
                    if let lsName = lsName, !lsName.isEmpty, lsName != bundleID {
                        resolvedName = lsName
                    } else if !meta.displayName.isEmpty {
                        resolvedName = meta.displayName
                    } else {
                        resolvedName = bundleID
                    }
                    
                    let icon = (proxyInfo["icon"] as? UIImage) ?? iconForBundleID(bundleID)
                    let bPath = proxyInfo["bundlePath"] as? String
                    
                    let app = AppContainerInfo(
                        appName: resolvedName,
                        bundleID: bundleID,
                        udid: dirName,
                        dataPath: dirPath,
                        bundlePath: bPath,
                        appIcon: icon
                    )
                    results[bundleID] = app
                }
            }
            
            // 2. SUPPLEMENTARY SOURCE: Add any LaunchServices apps with containers not yet found
            let lsInfo = installedAppInfo() as? [String: [String: Any]] ?? [:]
            for (bundleID, info) in lsInfo {
                if results[bundleID] != nil { continue }
                var dataPath = info["container"] as? String ?? ""
                if dataPath.isEmpty {
                    var lookupError: NSString?
                    if let mcmPath = MCMContainerPathForIdentifier(2, bundleID, false, &lookupError) ?? MCMActivateContainerPath(2, bundleID, false, &lookupError) {
                        dataPath = mcmPath
                    }
                }
                guard !dataPath.isEmpty else { continue }
                let udid = (dataPath as NSString).lastPathComponent
                let name = info["name"] as? String ?? bundleID
                let icon = info["icon"] as? UIImage ?? iconForBundleID(bundleID)
                let bPath = info["bundlePath"] as? String
                
                results[bundleID] = AppContainerInfo(
                    appName: name,
                    bundleID: bundleID,
                    udid: udid,
                    dataPath: dataPath,
                    bundlePath: bPath,
                    appIcon: icon
                )
            }
            
            // Sort: non-system (user) apps first, then alphabetical by appName
            let sorted = Array(results.values).sorted { a, b in
                let aIsSystem = a.bundleID.hasPrefix("com.apple.")
                let bIsSystem = b.bundleID.hasPrefix("com.apple.")
                if aIsSystem != bIsSystem {
                    return !aIsSystem
                }
                return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
            }
            return sorted
        }.value
        
        await MainActor.run {
            self.apps = scanned
            for app in scanned {
                self.cacheByBundleID[app.bundleID] = app
                self.cacheByUDID[app.udid.uppercased()] = app
                self.cacheByUDID[app.udid.lowercased()] = app
                self.cacheByUDID[app.udid] = app
                
                // Sync with ContainerMetadataCache
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
            }
            self.hasScanned = true
            self.isLoading = false
            self.statusMessage = "Đã tìm thấy \(scanned.count) ứng dụng."
        }
        return scanned
    }
    
    /// Quickly resolves a container by Bundle ID (e.g. "com.garena.game.kgvn")
    func resolveContainer(bundleID: String) async -> AppContainerInfo? {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        
        // 1. Check local cache
        if let cached = cacheByBundleID[clean] {
            return cached
        }
        
        // 2. Query MCM directly
        var lookupError: NSString?
        if let mcmPath = MCMContainerPathForIdentifier(2, clean, false, &lookupError) ?? MCMActivateContainerPath(2, clean, false, &lookupError) {
            let udid = (mcmPath as NSString).lastPathComponent
            let proxyInfo = appInfoForBundleID(clean) as? [String: Any] ?? [:]
            let name = (proxyInfo["name"] as? String) ?? clean
            let icon = (proxyInfo["icon"] as? UIImage) ?? iconForBundleID(clean)
            let bPath = proxyInfo["bundlePath"] as? String
            
            let info = AppContainerInfo(
                appName: name,
                bundleID: clean,
                udid: udid,
                dataPath: mcmPath,
                bundlePath: bPath,
                appIcon: icon
            )
            cacheByBundleID[clean] = info
            cacheByUDID[udid.uppercased()] = info
            cacheByUDID[udid.lowercased()] = info
            cacheByUDID[udid] = info
            return info
        }
        
        // 3. Scan if needed
        let list = await scanAllContainers(forceRefresh: false)
        return list.first { $0.bundleID.caseInsensitiveCompare(clean) == .orderedSame }
    }
}
