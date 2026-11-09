import Foundation
import UIKit
import SwiftUI

// MARK: - App Container Info Model

public struct AppContainerInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let appName: String
    public let bundleID: String
    public let udid: String
    public let dataPath: String
    public let bundlePath: String?
    public let appIcon: UIImage?
    
    public init(
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
    
    public var shortUDID: String {
        if udid.count >= 16 {
            return "\(udid.prefix(8))-\(udid.dropFirst(8).prefix(4))-...\(udid.suffix(4))"
        }
        return udid
    }
    
    public var shortDataPath: String {
        let prefix = "/private/v..."
        if udid.count >= 12 {
            return "\(prefix)\(udid.suffix(16))/"
        }
        return dataPath
    }
    
    public var shortBundlePath: String? {
        guard let b = bundlePath, !b.isEmpty else { return nil }
        if b.count > 36 {
            let last = (b as NSString).lastPathComponent
            return "/.../\(last)"
        }
        return b
    }
    
    public var initialLetter: String {
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
    
    public static func == (lhs: AppContainerInfo, rhs: AppContainerInfo) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - App Icon Avatar View (Matches Original App UI)

public struct AppIconAvatarView: View {
    public let icon: UIImage?
    public let title: String
    public let bundleID: String
    public var size: CGFloat
    
    public init(info: AppContainerInfo, size: CGFloat = 48) {
        self.icon = info.appIcon
        self.title = info.appName
        self.bundleID = info.bundleID
        self.size = size
    }
    
    public init(icon: UIImage?, title: String, bundleID: String = "", size: CGFloat = 48) {
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
        // Deterministic vibrant gradient matching original app: Purple/Pink/Magenta
        let hash = abs(bundleID.isEmpty ? title.hashValue : bundleID.hashValue) % 4
        switch hash {
        case 0:
            return [
                Color(red: 0.58, green: 0.22, blue: 0.95), // Purple
                Color(red: 0.92, green: 0.22, blue: 0.72)  // Magenta pink
            ]
        case 1:
            return [
                Color(red: 0.22, green: 0.45, blue: 0.96), // Royal Blue
                Color(red: 0.58, green: 0.26, blue: 0.92)  // Purple
            ]
        case 2:
            return [
                Color(red: 0.98, green: 0.30, blue: 0.55), // Hot pink
                Color(red: 0.98, green: 0.55, blue: 0.25)  // Coral orange
            ]
        default:
            return [
                Color(red: 0.12, green: 0.65, blue: 0.92), // Cyan blue
                Color(red: 0.22, green: 0.85, blue: 0.68)  // Mint green
            ]
        }
    }
    
    public var body: some View {
        if let uiIcon = icon {
            Image(uiImage: uiIcon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1.5)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: gradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: gradientColors[0].opacity(0.25), radius: 4, x: 0, y: 2)
                
                Text(initialLetter)
                    .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 1)
            }
        }
    }
}

// MARK: - AppContainerScanner

@MainActor
public final class AppContainerScanner: ObservableObject {
    public static let shared = AppContainerScanner()
    
    @Published public private(set) var apps: [AppContainerInfo] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var statusMessage: String = ""
    
    private var cacheByBundleID: [String: AppContainerInfo] = [:]
    private var cacheByUDID: [String: AppContainerInfo] = [:]
    private var hasScanned: Bool = false
    
    private init() {}
    
    public func getCachedInfo(forUDID udid: String) -> AppContainerInfo? {
        return cacheByUDID[udid.uppercased()] ?? cacheByUDID[udid]
    }
    
    public func getCachedInfo(forBundleID bundleID: String) -> AppContainerInfo? {
        return cacheByBundleID[bundleID]
    }
    
    /// Scans all application containers via LaunchServices, MCM, and Filesystem
    public func scanAllContainers(forceRefresh: Bool = false) async -> [AppContainerInfo] {
        if !forceRefresh && hasScanned && !apps.isEmpty {
            return apps
        }
        
        isLoading = true
        statusMessage = "Đang quét ứng dụng qua LaunchServices & MCM..."
        
        let scanned = await Task.detached(priority: .userInitiated) { () -> [AppContainerInfo] in
            var results: [String: AppContainerInfo] = [:]
            
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
                    if let mcmPath = MCMActivateContainerPath(2, bundleID, false, &lookupError) {
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
                    
                    // Try reading metadata plist
                    let metadataPath = (dir as NSString).appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                    var bundleID: String = ""
                    var displayName: String = ""
                    
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
                    } else {
                        // Container without identifiable metadata
                        let short = udid.count >= 8 ? "\(udid.prefix(4))...\(udid.suffix(4))" : udid
                        let placeholder = AppContainerInfo(
                            appName: "Container (\(short))",
                            bundleID: udid,
                            udid: udid,
                            dataPath: dir,
                            bundlePath: nil,
                            appIcon: nil
                        )
                        results[udid] = placeholder
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
        statusMessage = "Đã quét \(scanned.count) ứng dụng."
        return scanned
    }
    
    /// Quickly resolves a container by Bundle ID (e.g. "com.garena.game.kgvn")
    public func resolveContainer(bundleID: String) async -> AppContainerInfo? {
        let clean = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        
        // 1. Check local cache
        if let cached = cacheByBundleID[clean] {
            return cached
        }
        
        // 2. Query MCM directly
        var lookupError: NSString?
        if let mcmPath = MCMActivateContainerPath(2, clean, false, &lookupError) {
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
            return info
        }
        
        // 3. Fallback: run scan
        let all = await scanAllContainers(forceRefresh: false)
        return all.first { $0.bundleID.caseInsensitiveCompare(clean) == .orderedSame }
    }
}
