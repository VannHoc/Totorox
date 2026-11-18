import CryptoKit
import Foundation

enum ModStoreCacheError: LocalizedError, Equatable {
    case invalidZipArchive
    case checksumMismatch

    var errorDescription: String? {
        let lang = AppLanguage.current
        switch self {
        case .invalidZipArchive:
            return lang.text("modstore.error.invalid_zip")
        case .checksumMismatch:
            return lang.text("modstore.error.checksum_mismatch")
        }
    }
}

/// Quản lý bộ nhớ đệm cục bộ cho các gói Mod `.zip` đã tải từ Kho Mod trực tuyến.
///
/// Mỗi gói mod sau khi tải và xác thực SHA-256 sẽ được lưu tại
/// `Caches/TotoroxModStoreCache/<id>_<sha12>/<fileName>`, giúp người dùng gửi lại sang
/// Đè file / Gộp file / Chia sẻ tức thì (0ms) mà không cần tải lại hay tốn thêm lượt.
final class ModStoreCache: @unchecked Sendable {
    static let shared = ModStoreCache()
    static let didChangeNotification = Notification.Name("totorox.modstore.cacheDidChange")

    let rootDirectory: URL
    private let lock = NSLock()

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDirectory = base.appendingPathComponent("TotoroxModStoreCache", isDirectory: true)
        }
    }

    /// Trả về đường dẫn tệp `.zip` đã lưu trên máy nếu tồn tại và khớp dung lượng.
    func cachedFileURL(for item: ModCatalogItem) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let targetURL = expectedFileURL(for: item)
        let fm = FileManager.default
        guard fm.fileExists(atPath: targetURL.path) else { return nil }

        if item.fileSize > 0 {
            let diskSize = Int64((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard diskSize == item.fileSize else { return nil }
        }
        return targetURL
    }

    func cachedModIDs(matching items: [ModCatalogItem]) -> Set<Int> {
        var ids = Set<Int>()
        for item in items where cachedFileURL(for: item) != nil {
            ids.insert(item.id)
        }
        return ids
    }

    /// Kiểm tra chữ ký ZIP + SHA-256 của tệp vừa tải rồi lưu nguyên tử vào bộ nhớ đệm.
    func storeDownloadedFile(from temporaryURL: URL, for item: ModCatalogItem) throws -> URL {
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: temporaryURL)
        }

        guard Self.hasValidZipSignature(at: temporaryURL) else {
            throw ModStoreCacheError.invalidZipArchive
        }

        let cleanExpectedHash = item.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanExpectedHash.count == 64 {
            guard let actualHash = Self.sha256Hex(forFileAt: temporaryURL),
                  actualHash == cleanExpectedHash else {
                throw ModStoreCacheError.checksumMismatch
            }
        }

        let destinationURL: URL = try {
            lock.lock()
            defer { lock.unlock() }

            try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let currentDir = entryDirectory(for: item)
            pruneStaleDirectoriesLocked(forModID: item.id, keeping: currentDir.lastPathComponent)

            try fm.createDirectory(at: currentDir, withIntermediateDirectories: true)
            let dest = expectedFileURL(for: item)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: temporaryURL, to: dest)
            return dest
        }()

        notifyCacheChanged()
        return destinationURL
    }

    func removeCachedFile(for modID: Int) {
        lock.lock()
        pruneStaleDirectoriesLocked(forModID: modID, keeping: nil)
        lock.unlock()
        notifyCacheChanged()
    }

    func clearAll() {
        lock.lock()
        try? FileManager.default.removeItem(at: rootDirectory)
        lock.unlock()
        notifyCacheChanged()
    }

    // MARK: - Private Helpers

    private func entryDirectory(for item: ModCatalogItem) -> URL {
        let hashPrefix = String(
            item.sha256
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .prefix(12)
        )
        let folderName = hashPrefix.isEmpty ? "\(item.id)_v1" : "\(item.id)_\(hashPrefix)"
        return rootDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    private func expectedFileURL(for item: ModCatalogItem) -> URL {
        let rawName = (item.fileName as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = rawName.isEmpty ? "mod_\(item.id).zip" : rawName
        let finalName = baseName.lowercased().hasSuffix(".zip") ? baseName : "\(baseName).zip"
        return entryDirectory(for: item).appendingPathComponent(finalName, isDirectory: false)
    }

    private func pruneStaleDirectoriesLocked(forModID modID: Int, keeping keepFolderName: String?) {
        let fm = FileManager.default
        let prefix = "\(modID)_"
        guard let children = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for child in children where child.lastPathComponent.hasPrefix(prefix) {
            if let keepFolderName, child.lastPathComponent == keepFolderName {
                continue
            }
            try? fm.removeItem(at: child)
        }
    }

    private func notifyCacheChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private static func hasValidZipSignature(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return magic == Data([0x50, 0x4B, 0x03, 0x04]) || magic == Data([0x50, 0x4B, 0x05, 0x06])
    }

    private static func sha256Hex(forFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            var done = false
            autoreleasepool {
                if let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    done = true
                }
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
