import Foundation
import UIKit

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
    private var directoryListCache: [String: [FileEntry]] = [:]
    private var directorySizes: [String: DirectorySizeResult] = [:]
    private let iconCache = NSCache<NSString, UIImage>()

    private init() {
        iconCache.countLimit = 300
    }

    func cachedApp(forUUID uuid: String) -> AppContainerMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return appMetadataCache[uuid] ?? appMetadataCache[uuid.uppercased()] ?? appMetadataCache[uuid.lowercased()]
    }

    func bundleID(forUUID uuid: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return (appMetadataCache[uuid] ?? appMetadataCache[uuid.uppercased()] ?? appMetadataCache[uuid.lowercased()])?.bundleID
    }

    func store(app: AppContainerMetadata) {
        lock.lock()
        defer { lock.unlock() }
        appMetadataCache[app.uuid] = app
        appMetadataCache[app.uuid.uppercased()] = app
        appMetadataCache[app.uuid.lowercased()] = app
        if let icon = app.icon {
            iconCache.setObject(icon, forKey: app.bundleID as NSString)
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
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        return directoryListCache[clean]
    }

    func storeList(_ entries: [FileEntry], for path: String) {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        directoryListCache[clean] = entries
    }

    func cachedDirectorySize(for path: String) -> DirectorySizeResult? {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        return directorySizes[clean]
    }

    func storeDirectorySize(_ size: DirectorySizeResult, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        directorySizes[clean] = size
    }

    func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        directoryListCache.removeValue(forKey: clean)
        directorySizes.removeValue(forKey: clean)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        appMetadataCache.removeAll()
        directoryListCache.removeAll()
        directorySizes.removeAll()
        iconCache.removeAllObjects()
    }
}
