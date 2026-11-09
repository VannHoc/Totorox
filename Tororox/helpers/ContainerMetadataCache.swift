import Foundation
import UIKit

public struct AppContainerMetadata {
    public let uuid: String
    public let containerPath: String
    public let bundleID: String
    public let appName: String
    public let icon: UIImage?
    public let isUserApp: Bool
    public let modificationDate: Date?
    public let shortUUID: String

    public init(
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

public final class ContainerMetadataCache: @unchecked Sendable {
    public static let shared = ContainerMetadataCache()

    private let lock = NSRecursiveLock()
    private var appMetadataCache: [String: AppContainerMetadata] = [:]
    private var directoryListCache: [String: [FileEntry]] = [:]
    private var directorySizes: [String: DirectorySizeResult] = [:]
    private let iconCache = NSCache<NSString, UIImage>()

    private init() {
        iconCache.countLimit = 300
    }

    public func cachedApp(forUUID uuid: String) -> AppContainerMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return appMetadataCache[uuid]
    }

    public func store(app: AppContainerMetadata) {
        lock.lock()
        defer { lock.unlock() }
        appMetadataCache[app.uuid] = app
        if let icon = app.icon {
            iconCache.setObject(icon, forKey: app.bundleID as NSString)
        }
    }

    public func cachedIcon(for bundleID: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return iconCache.object(forKey: bundleID as NSString)
    }

    public func storeIcon(_ icon: UIImage, for bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        iconCache.setObject(icon, forKey: bundleID as NSString)
    }

    public func cachedList(for path: String) -> [FileEntry]? {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        return directoryListCache[clean]
    }

    public func storeList(_ entries: [FileEntry], for path: String) {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        directoryListCache[clean] = entries
    }

    public func cachedSize(for path: String) -> DirectorySizeResult? {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        return directorySizes[clean]
    }

    public func storeSize(_ size: DirectorySizeResult, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        directorySizes[clean] = size
    }

    public func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let clean = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        directoryListCache.removeValue(forKey: clean)
        directorySizes.removeValue(forKey: clean)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        appMetadataCache.removeAll()
        directoryListCache.removeAll()
        directorySizes.removeAll()
        iconCache.removeAllObjects()
    }
}
