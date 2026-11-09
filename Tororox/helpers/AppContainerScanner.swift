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
    
    /// Scans all application containers via LaunchServices, MCM, and Filesystem
    func scanAllContainers(forceRefresh: Bool = false) async -> [AppContainerInfo] {
        if !forceRefresh && hasScanned && !apps.isEmpty {
            return apps
        }
        
        isLoading = true
        statusMessage = "Đang quét ứng dụng..."
        
        let scanned = await Task.detached(priority: .userInitiated) { () -> [AppContainerInfo] in
            var results: [String: AppContainerInfo] = [:]
            
            // 0. Build comprehensive UUID -> Bundle ID map from system
            let uuidMap = containerUUIDToBundleIDMap() as? [String: String] ?? [:]
            
            // 1. Primary Source: LaunchServices & MobileInstallation
            let lsInfo = installedAppInfo() as? [String: [String: Any]] ?? [:]
            for (bundleID, info) in lsInfo {
                let name = info["name"] as? String ?? bundleID
                var dataPath = info["container"] as? String ?? ""
                let bundlePath = info["bundlePath"] as? String
                let icon = info["icon"] as? UIImage ?? iconForBundleID(bundleID)
                
                // If container is missing from LSApplicationProxy, query MCM Class 2
                if dataPath.isEmpty {
                    var lookupError: NSString?
                    if let mcmPath = MCMContainerPathForIdentifier(2, bundleID, false, &lookupError) ?? MCMActivateContainerPath(2, bundleID, false, &lookupError) {
                        dataPath = mcmPath
                    }
                }
                
                guard !dataPath.isEmpty else { continue }
                let udid = (dataPath as NSString).lastPathComponent
                
                let app = AppContainerInfo(
                    appName: name,
                    bundleID: bundleID,
                    udid: udid,
                    dataPath: dataPath,
                    bundlePath: bundlePath,
                    appIcon: icon
                )
                results[bundleID] = app
            }
            
            // 2. Secondary Source: Filesystem scan of /var/mobile/Containers/Data/Application
            let roots = [
                "/private/var/mobile/Containers/Data/Application",
                "/var/mobile/Containers/Data/Application"
            ]
            
            for root in roots {
                let handle = ContainerStore.grantContainerAccess(root)
                defer {
                    if handle >= 0 { bad_query_release(handle) }
                }
                
                let entries = ContainerStore.enumerateDirectories(path: root)
                for dir in entries {
                    let udid = (dir as NSString).lastPathComponent
                    guard UUID(uuidString: udid) != nil else { continue }
                    
                    // Check if already resolved
                    let alreadyFound = results.values.contains { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
                    if alreadyFound { continue }
                    
                    var bundleID: String = ""
                    var displayName: String = ""
                    
                    // A: Check UUID map
                    if let mappedBid = uuidMap[udid.uppercased()] ?? uuidMap[udid.lowercased()] ?? uuidMap[udid] {
                        bundleID = mappedBid
                    }
                    
                    // B: Check metadata plist
                    if bundleID.isEmpty {
                        let metadataPath = (dir as NSString).appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                        if let meta = ContainerStore.readContainerMetadata(containerPath: dir), !meta.bundleID.isEmpty {
                            bundleID = meta.bundleID
                            displayName = meta.displayName
                        } else if let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
                                  let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                            bundleID = plist["MCMMetadataIdentifier"] as? String ?? ""
                            if let info = plist["MCMMetadataInfo"] as? [String: Any] {
                                displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
                            }
                        }
                    }
                    
                    if !bundleID.isEmpty {
                        let appProxyInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                        let resolvedName = (appProxyInfo["name"] as? String) ?? (!displayName.isEmpty ? displayName : bundleID)
                        let icon = (appProxyInfo["icon"] as? UIImage) ?? iconForBundleID(bundleID)
                        let bundlePath = appProxyInfo["bundlePath"] as? String
                        
                        let app = AppContainerInfo(
                            appName: resolvedName,
                            bundleID: bundleID,
                            udid: udid,
                            dataPath: dir,
                            bundlePath: bundlePath,
                            appIcon: icon
                        )
                        results[bundleID] = app
                    }
                }
            }
            
            // Sort by app name alphabetically (User apps first)
            let sorted = Array(results.values).sorted { a, b in
                let aIsSystem = a.bundleID.hasPrefix("com.apple.")
                let bIsSystem = b.bundleID.hasPrefix("com.apple.")
                if aIsSystem != bIsSystem {
                    return !aIsSystem // Non-system user apps first
                }
                return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
            }
            return sorted
        }.value
        
        // Cache updates on MainActor
        self.apps = scanned
        for app in scanned {
            cacheByBundleID[app.bundleID] = app
            cacheByUDID[app.udid.uppercased()] = app
            cacheByUDID[app.udid.lowercased()] = app
            cacheByUDID[app.udid] = app
            
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
        
        hasScanned = true
        isLoading = false
        statusMessage = "Đã tìm thấy \(scanned.count) ứng dụng."
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
