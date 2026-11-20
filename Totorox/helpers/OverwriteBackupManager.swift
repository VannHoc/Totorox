import Foundation
import Darwin

// MARK: - Models

public struct OverwriteBackupEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let destinationPath: String
    public let backupRelativePath: String?
    public let wasNewFile: Bool
    public let originalSize: Int64?
    public let writtenSize: Int64

    public init(
        id: UUID = UUID(),
        relativePath: String,
        destinationPath: String,
        backupRelativePath: String?,
        wasNewFile: Bool,
        originalSize: Int64?,
        writtenSize: Int64
    ) {
        self.id = id
        self.relativePath = relativePath
        self.destinationPath = destinationPath
        self.backupRelativePath = backupRelativePath
        self.wasNewFile = wasNewFile
        self.originalSize = originalSize
        self.writtenSize = writtenSize
    }

    public var fileName: String {
        (relativePath as NSString).lastPathComponent
    }
}

public struct OverwriteBackupSession: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let patchName: String
    public let bundleID: String
    public let appName: String
    public let targetSubfolder: String
    public let destinationRootPath: String
    public let createdAt: Date
    public var restoredAt: Date?
    public let entries: [OverwriteBackupEntry]
    public let totalBackupBytes: Int64

    public init(
        id: UUID = UUID(),
        patchName: String,
        bundleID: String,
        appName: String,
        targetSubfolder: String,
        destinationRootPath: String,
        createdAt: Date = Date(),
        restoredAt: Date? = nil,
        entries: [OverwriteBackupEntry],
        totalBackupBytes: Int64
    ) {
        self.id = id
        self.patchName = patchName
        self.bundleID = bundleID
        self.appName = appName
        self.targetSubfolder = targetSubfolder
        self.destinationRootPath = destinationRootPath
        self.createdAt = createdAt
        self.restoredAt = restoredAt
        self.entries = entries
        self.totalBackupBytes = totalBackupBytes
    }

    public var totalFilesCount: Int { entries.count }
    public var overwrittenCount: Int { entries.filter { !$0.wasNewFile }.count }
    public var addedCount: Int { entries.filter { $0.wasNewFile }.count }
    public var isRestored: Bool { restoredAt != nil }
}

public struct OverwriteRestoreResult: Sendable {
    public let restoredOriginalCount: Int
    public let deletedNewCount: Int
    public let failedItems: [FileIOFailureRecord]

    public var totalProcessed: Int {
        restoredOriginalCount + deletedNewCount
    }

    public var hasFailures: Bool {
        !failedItems.isEmpty
    }
}

// MARK: - Thread-safe Pre-Overwrite Recorder

public final class OverwriteSessionRecorder: @unchecked Sendable {
    public let sessionID: UUID
    public let sessionDirectory: URL
    private let filesDirectory: URL
    private let patchName: String
    private let bundleID: String
    private let appName: String
    private let targetSubfolder: String
    private let destinationRoot: URL
    private let destinationPrefix: String
    private let fileManager: FileManager
    private let lock = NSLock()

    private struct PendingRecord {
        let relativePath: String
        let destinationPath: String
        let backupRelativePath: String?
        let wasNewFile: Bool
        let originalSize: Int64?
    }

    private var recordsByPath: [String: PendingRecord] = [:]
    private var orderedPaths: [String] = []
    private var nextBackupIndex: Int = 0

    public init(
        sessionID: UUID = UUID(),
        backupsRoot: URL,
        patchName: String,
        bundleID: String,
        appName: String,
        targetSubfolder: String,
        destinationRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.sessionID = sessionID
        self.sessionDirectory = backupsRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        self.filesDirectory = self.sessionDirectory.appendingPathComponent("files", isDirectory: true)
        self.patchName = patchName
        self.bundleID = bundleID
        self.appName = appName
        self.targetSubfolder = targetSubfolder
        let stdDest = destinationRoot.standardizedFileURL
        self.destinationRoot = stdDest
        self.destinationPrefix = stdDest.path.hasSuffix("/") ? stdDest.path : stdDest.path + "/"
        self.fileManager = fileManager
    }

    /// Gọi NGAY TRƯỚC KHI ghi tệp xuống `destinationURL`.
    /// Nếu tệp đã tồn tại (`existedBefore == true`), sao lưu bản gốc vào thư mục snapshot trước khi bị ghi đè.
    /// Nếu tệp chưa tồn tại (`existedBefore == false`), đánh dấu là tệp mới thêm để khi khôi phục sẽ tự xóa bỏ.
    public func recordBeforeWrite(destinationURL: URL, existedBefore: Bool) {
        let stdDest = destinationURL.standardizedFileURL
        let destPath = stdDest.path

        lock.lock()
        if recordsByPath[destPath] != nil {
            // Đã chụp bản gốc trước đó trong cùng phiên ghi đè này — không ghi đè mất bản gốc đầu tiên.
            lock.unlock()
            return
        }
        let assignedIndex = nextBackupIndex
        nextBackupIndex += 1
        lock.unlock()

        let relativePath: String
        if destPath.hasPrefix(destinationPrefix) {
            relativePath = String(destPath.dropFirst(destinationPrefix.count))
        } else {
            relativePath = stdDest.lastPathComponent
        }

        var backupRelativePath: String? = nil
        var originalSize: Int64? = nil
        var effectiveWasNew = !existedBefore

        if existedBefore {
            var st = stat()
            if lstat(destPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                originalSize = Int64(st.st_size)
            } else if let attrs = try? fileManager.attributesOfItem(atPath: destPath),
                      let sz = attrs[.size] as? NSNumber {
                originalSize = sz.int64Value
            }

            let safeName = stdDest.lastPathComponent.replacingOccurrences(of: "/", with: "_")
            let backupFileName = String(format: "%05d_%@", assignedIndex, safeName)
            let backupURL = filesDirectory.appendingPathComponent(backupFileName, isDirectory: false)
            do {
                try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
                do {
                    try FileIOEngine.shared.copySingleFile(from: stdDest, to: backupURL)
                } catch {
                    try fileManager.copyItem(at: stdDest, to: backupURL)
                }
                backupRelativePath = "files/\(backupFileName)"
                if originalSize == nil,
                   let attrs = try? fileManager.attributesOfItem(atPath: backupURL.path),
                   let sz = attrs[.size] as? NSNumber {
                    originalSize = sz.int64Value
                }
            } catch {
                log("overwrite-backup: failed to snapshot \(relativePath): \(error.localizedDescription)")
                backupRelativePath = nil
            }
        } else {
            effectiveWasNew = true
        }

        let record = PendingRecord(
            relativePath: relativePath,
            destinationPath: destPath,
            backupRelativePath: backupRelativePath,
            wasNewFile: effectiveWasNew,
            originalSize: originalSize
        )

        lock.lock()
        if recordsByPath[destPath] == nil {
            recordsByPath[destPath] = record
            orderedPaths.append(destPath)
        }
        lock.unlock()
    }

    /// Hoàn tất phiên sau khi `applyMappedFiles` kết thúc: chỉ giữ những tệp thực sự ghi thành công,
    /// dọn bỏ bản sao lưu của các tệp bị bỏ qua/lỗi. Trả về `nil` nếu không có tệp nào được ghi.
    public func finalize(succeededURLs: [URL]) -> OverwriteBackupSession? {
        let succeededPaths = Set(succeededURLs.map { $0.standardizedFileURL.path })

        lock.lock()
        let snapshotOrder = orderedPaths
        let snapshotRecords = recordsByPath
        lock.unlock()

        var finalEntries: [OverwriteBackupEntry] = []
        var totalBackupBytes: Int64 = 0

        for path in snapshotOrder {
            guard let rec = snapshotRecords[path] else { continue }
            if !succeededPaths.contains(path) {
                if let rel = rec.backupRelativePath {
                    let unusedBackup = sessionDirectory.appendingPathComponent(rel)
                    try? fileManager.removeItem(at: unusedBackup)
                }
                continue
            }

            // Chỉ giữ các entry có thể khôi phục (tệp mới thêm hoặc tệp đè đã chụp được bản gốc)
            let writtenSize: Int64 = {
                var st = stat()
                if lstat(path, &st) == 0 {
                    return Int64(st.st_size)
                }
                if let attrs = try? fileManager.attributesOfItem(atPath: path),
                   let sz = attrs[.size] as? NSNumber {
                    return sz.int64Value
                }
                return 0
            }()

            if let rel = rec.backupRelativePath {
                let backupURL = sessionDirectory.appendingPathComponent(rel)
                if let attrs = try? fileManager.attributesOfItem(atPath: backupURL.path),
                   let sz = attrs[.size] as? NSNumber {
                    totalBackupBytes += sz.int64Value
                }
            }

            finalEntries.append(
                OverwriteBackupEntry(
                    relativePath: rec.relativePath,
                    destinationPath: rec.destinationPath,
                    backupRelativePath: rec.backupRelativePath,
                    wasNewFile: rec.wasNewFile,
                    originalSize: rec.originalSize,
                    writtenSize: writtenSize
                )
            )
        }

        guard !finalEntries.isEmpty else {
            try? fileManager.removeItem(at: sessionDirectory)
            return nil
        }

        // Loại trừ thư mục backup khỏi iCloud Backup để không chiếm dung lượng iCloud của người dùng.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = sessionDirectory
        try? mutableDir.setResourceValues(resourceValues)

        return OverwriteBackupSession(
            id: sessionID,
            patchName: patchName,
            bundleID: bundleID,
            appName: appName,
            targetSubfolder: targetSubfolder,
            destinationRootPath: destinationRoot.path,
            createdAt: Date(),
            restoredAt: nil,
            entries: finalEntries,
            totalBackupBytes: totalBackupBytes
        )
    }
}

// MARK: - OverwriteBackupManager

@MainActor
public final class OverwriteBackupManager: ObservableObject {
    public static let shared = OverwriteBackupManager()

    @Published public private(set) var sessions: [OverwriteBackupSession] = []

    public let backupsRoot: URL
    public let maxRetainedSessions: Int
    private let metadataURL: URL
    private let fileManager: FileManager

    public init(
        rootDirectory: URL? = nil,
        maxRetainedSessions: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.maxRetainedSessions = max(1, maxRetainedSessions)
        let resolvedRoot: URL
        if let rootDirectory {
            resolvedRoot = rootDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            resolvedRoot = appSupport.appendingPathComponent("TotoroxOverwriteBackups", isDirectory: true)
        }
        self.backupsRoot = resolvedRoot
        self.metadataURL = resolvedRoot.appendingPathComponent("sessions.json", isDirectory: false)
        try? fileManager.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        var mutableRoot = resolvedRoot
        try? mutableRoot.setResourceValues(rv)
        loadSessions()
    }

    public func createRecorder(
        patchName: String,
        bundleID: String,
        appName: String,
        targetSubfolder: String,
        destinationRoot: URL
    ) -> OverwriteSessionRecorder {
        try? fileManager.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        return OverwriteSessionRecorder(
            backupsRoot: backupsRoot,
            patchName: patchName,
            bundleID: bundleID,
            appName: appName,
            targetSubfolder: targetSubfolder,
            destinationRoot: destinationRoot,
            fileManager: fileManager
        )
    }

    public func saveSession(_ session: OverwriteBackupSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        if sessions.count > maxRetainedSessions {
            let overflow = sessions.suffix(from: maxRetainedSessions)
            for old in overflow {
                let oldDir = backupsRoot.appendingPathComponent(old.id.uuidString, isDirectory: true)
                try? fileManager.removeItem(at: oldDir)
            }
            sessions.removeLast(sessions.count - maxRetainedSessions)
        }
        persistSessions()
        pruneOrphanedBackupDirectories()
    }

    public func deleteSession(_ session: OverwriteBackupSession) {
        sessions.removeAll { $0.id == session.id }
        let dir = backupsRoot.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: dir)
        persistSessions()
    }

    public func clearAllSessions() {
        for s in sessions {
            let dir = backupsRoot.appendingPathComponent(s.id.uuidString, isDirectory: true)
            try? fileManager.removeItem(at: dir)
        }
        sessions.removeAll()
        persistSessions()
        pruneOrphanedBackupDirectories()
    }

    public var totalStoredBackupBytes: Int64 {
        sessions.reduce(0) { $0 + $1.totalBackupBytes }
    }

    /// Khôi phục dữ liệu ứng dụng về đúng trạng thái TRƯỚC KHI đè file:
    /// - Các tệp đã ghi đè lên file gốc -> chép trả lại bản gốc đã sao lưu.
    /// - Các tệp mới thêm vào -> xóa bỏ khỏi container và dọn thư mục rỗng mới phát sinh.
    public func restoreSession(
        _ session: OverwriteBackupSession,
        progressHandler: (@Sendable (_ completed: Int, _ total: Int, _ fileName: String) -> Void)? = nil
    ) async -> OverwriteRestoreResult {
        let rootDir = backupsRoot
        let sessionDir = rootDir.appendingPathComponent(session.id.uuidString, isDirectory: true)
        let fm = fileManager

        let outcome = await Task.detached(priority: .userInitiated) { () -> OverwriteRestoreResult in
            // 1. Kích hoạt lại quyền sandbox vào container đích (nếu có bundleID)
            let resolvedDestRoot: URL
            let cacheInvalidationPath: String
            if !session.bundleID.isEmpty {
                var actError: NSString? = nil
                let activatedPath = MCMActivateContainerPath(2, session.bundleID, false, &actError)
                if let liveRoot = activatedPath, !liveRoot.isEmpty {
                    _ = ContainerStore.ensureContainerAccess(for: liveRoot, requireWrite: true)
                    let baseURL = URL(fileURLWithPath: liveRoot).resolvingSymlinksInPath().standardizedFileURL
                    let sub = session.targetSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    resolvedDestRoot = sub.isEmpty
                        ? baseURL
                        : baseURL.appendingPathComponent(sub, isDirectory: true).standardizedFileURL
                    cacheInvalidationPath = liveRoot
                } else {
                    resolvedDestRoot = URL(fileURLWithPath: session.destinationRootPath).standardizedFileURL
                    cacheInvalidationPath = session.destinationRootPath
                }
            } else {
                resolvedDestRoot = URL(fileURLWithPath: session.destinationRootPath).standardizedFileURL
                cacheInvalidationPath = session.destinationRootPath
            }

            _ = ContainerStore.ensureContainerAccess(for: resolvedDestRoot.path, requireWrite: true)
            let destPrefix = resolvedDestRoot.path.hasSuffix("/")
                ? resolvedDestRoot.path
                : resolvedDestRoot.path + "/"

            var restoredOriginalCount = 0
            var deletedNewCount = 0
            var failedItems: [FileIOFailureRecord] = []
            var candidateEmptyDirs = Set<String>()

            let total = max(session.entries.count, 1)

            for (idx, entry) in session.entries.enumerated() {
                let relParts = entry.relativePath
                    .replacingOccurrences(of: "\\", with: "/")
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init)
                guard !relParts.isEmpty, !relParts.contains(".."), !relParts.contains(".") else {
                    failedItems.append(FileIOFailureRecord(
                        url: URL(fileURLWithPath: entry.destinationPath),
                        reason: FileIOEngineError.invalidDestination.localizedDescription
                    ))
                    progressHandler?(idx + 1, total, entry.fileName)
                    continue
                }

                let targetURL = relParts
                    .reduce(resolvedDestRoot) { $0.appendingPathComponent($1, isDirectory: false) }
                    .standardizedFileURL
                guard targetURL.path.hasPrefix(destPrefix) else {
                    failedItems.append(FileIOFailureRecord(
                        url: targetURL,
                        reason: FileIOEngineError.invalidDestination.localizedDescription
                    ))
                    progressHandler?(idx + 1, total, entry.fileName)
                    continue
                }

                if entry.wasNewFile {
                    // Xóa tệp mới được thêm vào trong lần đè file đó
                    var st = stat()
                    let exists = (lstat(targetURL.path, &st) == 0) || fm.fileExists(atPath: targetURL.path)
                    if exists {
                        do {
                            try await FileIOEngine.shared.deleteItem(at: targetURL)
                            deletedNewCount += 1
                            var parent = targetURL.deletingLastPathComponent().standardizedFileURL
                            while parent.path.hasPrefix(destPrefix) && parent.path != resolvedDestRoot.path {
                                candidateEmptyDirs.insert(parent.path)
                                parent = parent.deletingLastPathComponent().standardizedFileURL
                            }
                        } catch {
                            failedItems.append(FileIOFailureRecord(url: targetURL, reason: error.localizedDescription))
                        }
                    } else {
                        // Tệp mới thêm vốn đã không còn trên đĩa -> coi như đã sạch
                        deletedNewCount += 1
                    }
                } else if let backupRel = entry.backupRelativePath {
                    let backupURL = sessionDir.appendingPathComponent(backupRel, isDirectory: false)
                    guard fm.fileExists(atPath: backupURL.path) else {
                        failedItems.append(FileIOFailureRecord(
                            url: targetURL,
                            reason: AppLanguage.current.text("overwrite.backup.missing_snapshot")
                        ))
                        progressHandler?(idx + 1, total, entry.fileName)
                        continue
                    }
                    do {
                        try FileIOEngine.createDirectoryIfNeeded(at: targetURL.deletingLastPathComponent())
                        try FileIOEngine.shared.copySingleFile(from: backupURL, to: targetURL)
                        restoredOriginalCount += 1
                    } catch {
                        failedItems.append(FileIOFailureRecord(url: targetURL, reason: error.localizedDescription))
                    }
                } else {
                    failedItems.append(FileIOFailureRecord(
                        url: targetURL,
                        reason: AppLanguage.current.text("overwrite.backup.missing_snapshot")
                    ))
                }

                progressHandler?(idx + 1, total, entry.fileName)
            }

            // Dọn các thư mục con rỗng mới phát sinh (từ sâu nhất lên nông nhất, không bao giờ xóa resolvedDestRoot)
            let sortedEmptyDirs = candidateEmptyDirs.sorted { $0.count > $1.count }
            for dirPath in sortedEmptyDirs {
                if let contents = try? fm.contentsOfDirectory(atPath: dirPath), contents.isEmpty {
                    _ = rmdir(dirPath)
                }
            }

            ContainerMetadataCache.shared.invalidate(path: cacheInvalidationPath)
            return OverwriteRestoreResult(
                restoredOriginalCount: restoredOriginalCount,
                deletedNewCount: deletedNewCount,
                failedItems: failedItems
            )
        }.value

        if let idx = sessions.firstIndex(where: { $0.id == session.id }), !outcome.hasFailures {
            sessions[idx].restoredAt = Date()
            persistSessions()
        }

        return outcome
    }

    // MARK: - Persistence

    private func loadSessions() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([OverwriteBackupSession].self, from: data) else {
            sessions = []
            return
        }
        // Lọc các phiên vẫn còn dữ liệu hợp lệ (hoặc chỉ gồm tệp mới thêm không cần thư mục files/)
        sessions = decoded.filter { session in
            let dir = backupsRoot.appendingPathComponent(session.id.uuidString, isDirectory: true)
            if session.overwrittenCount == 0 {
                return true
            }
            return fileManager.fileExists(atPath: dir.path)
        }
        pruneOrphanedBackupDirectories()
    }

    private func persistSessions() {
        try? fileManager.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(sessions) {
            try? encoded.write(to: metadataURL, options: .atomic)
        }
    }

    private func pruneOrphanedBackupDirectories() {
        guard let children = try? fileManager.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let keptIDs = Set(sessions.map { $0.id.uuidString })
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            if !keptIDs.contains(child.lastPathComponent) {
                try? fileManager.removeItem(at: child)
            }
        }
    }
}
