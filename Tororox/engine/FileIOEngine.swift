import Foundation
import Darwin

public enum FileIOConflictKind: Equatable, Sendable {
    case fileExists
    case fileOverwritingFolder
    case folderOverwritingFile
}

public enum FileIOConflictResolution: Equatable, Sendable {
    case replace
    case skip
    case replaceAll
    case cancel
}

public typealias FileIOConflictResolver = @Sendable (
    _ sourceURL: URL,
    _ destinationURL: URL,
    _ conflict: FileIOConflictKind
) async -> FileIOConflictResolution

public struct FileIOFailureRecord: Equatable, Sendable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct FileIOResult: Equatable, Sendable {
    public var succeeded: [URL]
    public var failed: [FileIOFailureRecord]
    public var skipped: [URL]
    public var isCancelled: Bool

    public init(
        succeeded: [URL] = [],
        failed: [FileIOFailureRecord] = [],
        skipped: [URL] = [],
        isCancelled: Bool = false
    ) {
        self.succeeded = succeeded
        self.failed = failed
        self.skipped = skipped
        self.isCancelled = isCancelled
    }
}

public final class FileIOEngine {
    public static let shared = FileIOEngine()
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Recursively copies and merges source items into destination according to Windows Merge rules:
    /// 1. Folder -> Folder: Recursive merge. Destination folder is never deleted; recurses inside.
    /// 2. File not existing at destination: Standard copy.
    /// 3. File already existing at destination:
    ///    - If isReplaceAll == true: Overwrites directly without prompting.
    ///    - If isReplaceAll == false: Pauses background execution (async/await) and invokes conflictResolver for prompt:
    ///      - Replace: Overwrite current file, continue.
    ///      - Skip: Do nothing for current file, continue.
    ///      - Replace All: Set isReplaceAll = true, overwrite current and all future colliding files without asking.
    public func copyAndMerge(
        from sourceURL: URL,
        to destinationURL: URL,
        conflictResolver: FileIOConflictResolver
    ) async -> FileIOResult {
        var result = FileIOResult()
        var isReplaceAll = false
        let standardizedSource = sourceURL.standardizedFileURL
        let standardizedDest = destinationURL.standardizedFileURL

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedSource.path, isDirectory: &isDir) else {
            result.failed.append(FileIOFailureRecord(url: standardizedSource, reason: "Source item does not exist."))
            return result
        }

        await processItem(
            source: standardizedSource,
            sourceIsDir: isDir.boolValue,
            destination: standardizedDest,
            isReplaceAll: &isReplaceAll,
            result: &result,
            conflictResolver: conflictResolver
        )

        return result
    }

    private func processItem(
        source: URL,
        sourceIsDir: Bool,
        destination: URL,
        isReplaceAll: inout Bool,
        result: inout FileIOResult,
        conflictResolver: FileIOConflictResolver
    ) async {
        if Task.isCancelled || result.isCancelled {
            result.isCancelled = true
            result.skipped.append(source)
            return
        }

        var destIsDir: ObjCBool = false
        let destExists = fileManager.fileExists(atPath: destination.path, isDirectory: &destIsDir)

        if !destExists {
            // Mục CHƯA tồn tại ở đích
            if sourceIsDir {
                do {
                    try Self.createDirectoryIfNeeded(at: destination)
                    result.succeeded.append(destination)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                    return
                }

                await copyChildrenRecursively(
                    from: source,
                    to: destination,
                    isReplaceAll: &isReplaceAll,
                    result: &result,
                    conflictResolver: conflictResolver
                )
            } else {
                do {
                    try copySingleFile(from: source, to: destination)
                    result.succeeded.append(destination)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                }
            }
        } else {
            // Mục ĐÃ tồn tại ở đích
            if sourceIsDir && destIsDir.boolValue {
                // 1. Thư mục gộp vào Thư mục: Xử lý Merge. Tuyệt đối không xóa thư mục đích. Đệ quy đi sâu vào bên trong
                result.succeeded.append(destination)
                await copyChildrenRecursively(
                    from: source,
                    to: destination,
                    isReplaceAll: &isReplaceAll,
                    result: &result,
                    conflictResolver: conflictResolver
                )
            } else if !sourceIsDir && !destIsDir.boolValue {
                // 2. File và ĐÃ tồn tại ở đích (File trùng tên)
                if isReplaceAll {
                    // Check if isReplaceAll == true: Ghi đè file mới (không hỏi)
                    do {
                        try copySingleFile(from: source, to: destination)
                        result.succeeded.append(destination)
                    } catch {
                        result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                    }
                } else {
                    // Check if isReplaceAll == false: Tạm dừng luồng xử lý nền (async/await) -> Gọi UI Prompt
                    let userChoice = await conflictResolver(source, destination, .fileExists)
                    switch userChoice {
                    case .replace:
                        do {
                            try copySingleFile(from: source, to: destination)
                            result.succeeded.append(destination)
                        } catch {
                            result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                        }
                    case .skip:
                        result.skipped.append(source)
                    case .replaceAll:
                        isReplaceAll = true
                        do {
                            try copySingleFile(from: source, to: destination)
                            result.succeeded.append(destination)
                        } catch {
                            result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                        }
                    case .cancel:
                        result.isCancelled = true
                        result.skipped.append(source)
                    }
                }
            } else {
                // 3. Xung đột kiểu (File vs Folder hoặc Folder vs File)
                let conflictKind: FileIOConflictKind = (!sourceIsDir && destIsDir.boolValue)
                    ? .fileOverwritingFolder
                    : .folderOverwritingFile

                let userChoice = await conflictResolver(source, destination, conflictKind)
                switch userChoice {
                case .replace, .replaceAll:
                    if userChoice == .replaceAll {
                        isReplaceAll = true
                    }
                    do {
                        try removeExistingItem(at: destination)
                        if sourceIsDir {
                            try Self.createDirectoryIfNeeded(at: destination)
                            result.succeeded.append(destination)
                            await copyChildrenRecursively(
                                from: source,
                                to: destination,
                                isReplaceAll: &isReplaceAll,
                                result: &result,
                                conflictResolver: conflictResolver
                            )
                        } else {
                            try copySingleFile(from: source, to: destination)
                            result.succeeded.append(destination)
                        }
                    } catch {
                        result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                    }
                case .skip:
                    result.skipped.append(source)
                case .cancel:
                    result.isCancelled = true
                    result.skipped.append(source)
                }
            }
        }
    }

    private func copyChildrenRecursively(
        from sourceDir: URL,
        to destinationDir: URL,
        isReplaceAll: inout Bool,
        result: inout FileIOResult,
        conflictResolver: FileIOConflictResolver
    ) async {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            result.failed.append(FileIOFailureRecord(url: sourceDir, reason: error.localizedDescription))
            return
        }

        for childSource in contents {
            if Task.isCancelled || result.isCancelled {
                result.isCancelled = true
                result.skipped.append(childSource)
                continue
            }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: childSource.path, isDirectory: &isDir) else {
                result.failed.append(FileIOFailureRecord(url: childSource, reason: "Source child inaccessible."))
                continue
            }

            let childDest = destinationDir.appendingPathComponent(childSource.lastPathComponent)
            await processItem(
                source: childSource,
                sourceIsDir: isDir.boolValue,
                destination: childDest,
                isReplaceAll: &isReplaceAll,
                result: &result,
                conflictResolver: conflictResolver
            )

            if result.isCancelled {
                // Break out of directory iteration if cancelled
                break
            }
        }
    }

    /// Safely copies a single file using atomic staging + rename and POSIX direct write fallback.
    /// This bypasses iOS container sandbox ACL/xattr inheritance failures that break standard `FileManager.copyItem`.
    public func copySingleFile(
        from source: URL,
        to destination: URL
    ) throws {
        let parentDir = destination.deletingLastPathComponent()
        try Self.createDirectoryIfNeeded(at: parentDir)

        let stagingURL = parentDir.appendingPathComponent(".totorox-\(UUID().uuidString).tmp")
        defer {
            _ = unlink(stagingURL.path)
            try? fileManager.removeItem(at: stagingURL)
        }

        var writeSuccess = false
        // 1. Stream from source to staging using FileHandle
        if let sourceHandle = try? FileHandle(forReadingFrom: source),
           fileManager.createFile(atPath: stagingURL.path, contents: nil, attributes: nil),
           let stagingHandle = try? FileHandle(forWritingTo: stagingURL) {
            defer {
                try? sourceHandle.close()
                try? stagingHandle.close()
            }
            let chunkSize = 1_024 * 1_024
            var ok = true
            while let chunk = try? sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty {
                do {
                    try stagingHandle.write(contentsOf: chunk)
                } catch {
                    ok = false
                    break
                }
            }
            try? stagingHandle.synchronize()
            writeSuccess = ok
        }

        // 2. Direct Data fallback
        if !writeSuccess {
            if let data = (try? Data(contentsOf: source)) ?? ContainerStore.readDataDirectly(atPath: source.path) {
                writeSuccess = posixWriteData(data, to: stagingURL.path)
            }
        }

        guard writeSuccess else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }

        // 3. Atomic commit via POSIX rename within the same directory
        if rename(stagingURL.path, destination.path) != 0 {
            // Rename failed, try POSIX write directly to destination
            if let data = (try? Data(contentsOf: source)) ?? ContainerStore.readDataDirectly(atPath: source.path) {
                if !posixWriteData(data, to: destination.path) {
                    if fileManager.fileExists(atPath: destination.path) {
                        _ = unlink(destination.path)
                        try? fileManager.removeItem(at: destination)
                    }
                    try fileManager.copyItem(at: source, to: destination)
                }
            } else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
        }
    }

    private func posixWriteData(_ data: Data, to path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var written = 0
            let total = buffer.count
            while written < total {
                let bytes = write(fd, baseAddress.advanced(by: written), total - written)
                if bytes <= 0 { return false }
                written += bytes
            }
            return true
        }
    }

    private func removeExistingItem(at url: URL) throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                try? fileManager.removeItem(at: url)
                if fileManager.fileExists(atPath: url.path) {
                    _ = rmdir(url.path)
                }
            } else {
                _ = unlink(url.path)
                try? fileManager.removeItem(at: url)
            }
        }
    }

    public static func createDirectoryIfNeeded(at url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return
        } catch {
            var currentPath = "/"
            for comp in url.pathComponents.filter({ $0 != "/" && !$0.isEmpty }) {
                currentPath += (currentPath == "/" ? "" : "/") + comp
                var st = stat()
                if stat(currentPath, &st) != 0 {
                    if mkdir(currentPath, 0o755) != 0 && errno != EEXIST {
                        throw error
                    }
                }
            }
        }
    }
}
