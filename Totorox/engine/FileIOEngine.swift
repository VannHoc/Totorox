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

private final class FileIOCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || Task.isCancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

public final class FileIOEngine: @unchecked Sendable {
    public static let shared = FileIOEngine()
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Recursively copies and merges source items into destination on a background thread
    /// according to Windows Merge rules:
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
        conflictResolver: @escaping FileIOConflictResolver
    ) async -> FileIOResult {
        let cancelState = FileIOCancellationState()
        if Task.isCancelled {
            cancelState.cancel()
        }

        let workerTask = Task.detached(priority: .userInitiated) { [self] () -> FileIOResult in
            var result = FileIOResult()
            var isReplaceAll = false
            let standardizedSource = sourceURL.standardizedFileURL
            let standardizedDest = destinationURL.standardizedFileURL

            _ = ContainerStore.ensureContainerAccess(for: standardizedSource.path)
            _ = ContainerStore.ensureContainerAccess(for: standardizedDest.path)

            var isDir: ObjCBool = false
            var st = stat()
            let exists: Bool
            if self.fileManager.fileExists(atPath: standardizedSource.path, isDirectory: &isDir) {
                exists = true
            } else if lstat(standardizedSource.path, &st) == 0 {
                exists = true
                isDir = ObjCBool((st.st_mode & S_IFMT) == S_IFDIR)
            } else {
                exists = false
            }

            guard exists else {
                result.failed.append(FileIOFailureRecord(url: standardizedSource, reason: "Source item does not exist."))
                return result
            }

            await self.processItem(
                source: standardizedSource,
                sourceIsDir: isDir.boolValue,
                destination: standardizedDest,
                isReplaceAll: &isReplaceAll,
                result: &result,
                cancelState: cancelState,
                conflictResolver: conflictResolver
            )

            return result
        }

        return await withTaskCancellationHandler {
            await workerTask.value
        } onCancel: {
            cancelState.cancel()
            workerTask.cancel()
        }
    }

    private func processItem(
        source: URL,
        sourceIsDir: Bool,
        destination: URL,
        isReplaceAll: inout Bool,
        result: inout FileIOResult,
        cancelState: FileIOCancellationState,
        conflictResolver: FileIOConflictResolver
    ) async {
        if cancelState.isCancelled || result.isCancelled {
            result.isCancelled = true
            result.skipped.append(source)
            return
        }

        _ = ContainerStore.ensureContainerAccess(for: destination.path)

        var destIsDir: ObjCBool = false
        var destStat = stat()
        let destExists: Bool
        if fileManager.fileExists(atPath: destination.path, isDirectory: &destIsDir) {
            destExists = true
        } else if lstat(destination.path, &destStat) == 0 {
            destExists = true
            destIsDir = ObjCBool((destStat.st_mode & S_IFMT) == S_IFDIR)
        } else {
            destExists = false
        }

        if !destExists {
            // Item does not exist at destination
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
                    cancelState: cancelState,
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
            // Item already exists at destination
            if sourceIsDir && destIsDir.boolValue {
                // 1. Folder -> Folder: Recursive merge without deleting destination directory
                result.succeeded.append(destination)
                await copyChildrenRecursively(
                    from: source,
                    to: destination,
                    isReplaceAll: &isReplaceAll,
                    result: &result,
                    cancelState: cancelState,
                    conflictResolver: conflictResolver
                )
            } else if !sourceIsDir && !destIsDir.boolValue {
                // 2. File -> File collision
                if isReplaceAll {
                    do {
                        try copySingleFile(from: source, to: destination)
                        result.succeeded.append(destination)
                    } catch {
                        result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                    }
                } else {
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
                // 3. Type conflict (File vs Folder or Folder vs File)
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
                                cancelState: cancelState,
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
        cancelState: FileIOCancellationState,
        conflictResolver: FileIOConflictResolver
    ) async {
        let contents: [URL]
        if let fmContents = try? fileManager.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            contents = fmContents
        } else if let posixDir = opendir(sourceDir.path) {
            defer { closedir(posixDir) }
            var urls: [URL] = []
            while let dp = readdir(posixDir) {
                let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                urls.append(sourceDir.appendingPathComponent(name))
            }
            contents = urls
        } else {
            result.failed.append(FileIOFailureRecord(url: sourceDir, reason: "Unable to read source directory contents."))
            return
        }

        for childSource in contents {
            if cancelState.isCancelled || result.isCancelled {
                result.isCancelled = true
                result.skipped.append(childSource)
                continue
            }

            var isDir: ObjCBool = false
            var st = stat()
            let childExists: Bool
            if fileManager.fileExists(atPath: childSource.path, isDirectory: &isDir) {
                childExists = true
            } else if lstat(childSource.path, &st) == 0 {
                childExists = true
                isDir = ObjCBool((st.st_mode & S_IFMT) == S_IFDIR)
            } else {
                childExists = false
            }

            guard childExists else {
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
                cancelState: cancelState,
                conflictResolver: conflictResolver
            )

            if result.isCancelled {
                break
            }
        }
    }

    /// Copies a single file using the 3105 & FilzaSlop POSIX atomic replacement pipeline:
    /// 1. Activates container sandbox lease (`ContainerStore.ensureContainerAccess`).
    /// 2. Preserves existing POSIX file permissions and protection attributes when overwriting.
    /// 3. Streams via low-level POSIX `open`/`read`/`write`/`fsync` into an atomic staging file and commits with `rename`,
    ///    falling back to `FileReplacementService.replace` and direct POSIX overwrite if the container disallows sibling temp files.
    public func copySingleFile(
        from source: URL,
        to destination: URL
    ) throws {
        let parentDir = destination.deletingLastPathComponent()
        _ = ContainerStore.ensureContainerAccess(for: source.path)
        _ = ContainerStore.ensureContainerAccess(for: destination.path)
        _ = ContainerStore.ensureContainerAccess(for: parentDir.path)
        try Self.createDirectoryIfNeeded(at: parentDir)

        var preservedMode: mode_t = 0o644
        var targetStat = stat()
        if lstat(destination.path, &targetStat) == 0 {
            let existingPerms = targetStat.st_mode & 0o7777
            if existingPerms != 0 {
                preservedMode = existingPerms | mode_t(S_IWUSR)
            }
        } else if lstat(source.path, &targetStat) == 0 {
            let sourcePerms = targetStat.st_mode & 0o7777
            if sourcePerms != 0 {
                preservedMode = sourcePerms | mode_t(S_IWUSR)
            }
        }
        let existingAttrs = try? fileManager.attributesOfItem(atPath: destination.path)
        let protection = existingAttrs?[.protectionKey] as? FileProtectionType

        let stagingURL = parentDir.appendingPathComponent(".totorox-\(UUID().uuidString).tmp")
        defer {
            _ = unlink(stagingURL.path)
            try? fileManager.removeItem(at: stagingURL)
        }

        // 1. Low-level POSIX stream to sibling staging file + atomic rename
        if posixCopyStream(from: source.path, to: stagingURL.path, mode: preservedMode) {
            _ = chmod(stagingURL.path, preservedMode)
            if let protection {
                try? fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: stagingURL.path)
            }
            if rename(stagingURL.path, destination.path) == 0 {
                return
            }
        }

        // 2. Original 3105 FileReplacementService engine
        if (try? FileReplacementService.replace(target: destination, with: source)) != nil {
            return
        }

        // 3. Direct POSIX stream in-place to destination (handles containers that block temp sibling creation)
        _ = chmod(destination.path, preservedMode | mode_t(S_IWUSR))
        if posixCopyStream(from: source.path, to: destination.path, mode: preservedMode) {
            _ = chmod(destination.path, preservedMode)
            if let protection {
                try? fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: destination.path)
            }
            return
        }

        // 4. Direct Data read + POSIX write fallback
        if let data = ContainerStore.readDataDirectly(atPath: source.path) ?? (try? Data(contentsOf: source)) {
            if posixWriteData(data, to: stagingURL.path, mode: preservedMode),
               rename(stagingURL.path, destination.path) == 0 {
                return
            }
            _ = unlink(destination.path)
            if posixWriteData(data, to: destination.path, mode: preservedMode) {
                return
            }
        }

        // 5. Final Foundation fallback
        if fileManager.fileExists(atPath: destination.path) {
            _ = unlink(destination.path)
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func posixCopyStream(from sourcePath: String, to destinationPath: String, mode: mode_t = 0o644) -> Bool {
        let srcFD = open(sourcePath, O_RDONLY | O_CLOEXEC)
        guard srcFD >= 0 else { return false }
        defer { close(srcFD) }

        let dstFD = open(destinationPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
        guard dstFD >= 0 else { return false }
        defer { close(dstFD) }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = read(srcFD, buffer, bufferSize)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return false
            }
            if bytesRead == 0 {
                break
            }
            var offset = 0
            while offset < bytesRead {
                let bytesWritten = write(dstFD, buffer.advanced(by: offset), bytesRead - offset)
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if bytesWritten == 0 {
                    return false
                }
                offset += bytesWritten
            }
        }
        _ = fsync(dstFD)
        return true
    }

    private func posixWriteData(_ data: Data, to path: String, mode: mode_t = 0o644) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var written = 0
            let total = buffer.count
            while written < total {
                let bytes = write(fd, baseAddress.advanced(by: written), total - written)
                if bytes < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if bytes == 0 { return false }
                written += bytes
            }
            return true
        }
        if ok {
            _ = fsync(fd)
        }
        return ok
    }

    private func removeExistingItem(at url: URL) throws {
        _ = ContainerStore.ensureContainerAccess(for: url.path)
        var isDir: ObjCBool = false
        var st = stat()
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir) || (lstat(url.path, &st) == 0)
        if !fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && exists {
            isDir = ObjCBool((st.st_mode & S_IFMT) == S_IFDIR)
        }
        guard exists else { return }

        if isDir.boolValue {
            try? fileManager.removeItem(at: url)
            if fileManager.fileExists(atPath: url.path) || lstat(url.path, &st) == 0 {
                posixRemoveDirectoryTree(at: url.path)
            }
        } else {
            _ = unlink(url.path)
            try? fileManager.removeItem(at: url)
        }
    }

    private func posixRemoveDirectoryTree(at path: String) {
        if let dir = opendir(path) {
            while let dp = readdir(dir) {
                let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                let childPath = (path as NSString).appendingPathComponent(name)
                var st = stat()
                if lstat(childPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
                    posixRemoveDirectoryTree(at: childPath)
                } else {
                    _ = unlink(childPath)
                }
            }
            closedir(dir)
        }
        _ = rmdir(path)
    }

    public static func createDirectoryIfNeeded(at url: URL) throws {
        let fm = FileManager.default
        _ = ContainerStore.ensureContainerAccess(for: url.path)
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

    // MARK: - Async Background Single-Item Operations (Avoids Main-Thread Blocking)

    public func createFolder(at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = ContainerStore.ensureContainerAccess(for: url.deletingLastPathComponent().path)
            try Self.createDirectoryIfNeeded(at: url)
        }.value
    }

    public func renameItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            _ = ContainerStore.ensureContainerAccess(for: sourceURL.path)
            _ = ContainerStore.ensureContainerAccess(for: destinationURL.deletingLastPathComponent().path)
            if Darwin.rename(sourceURL.path, destinationURL.path) == 0 {
                return
            }
            try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
        }.value
    }

    public func deleteItem(at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.removeExistingItem(at: url)
            var st = stat()
            if self.fileManager.fileExists(atPath: url.path) || lstat(url.path, &st) == 0 {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        }.value
    }

    /// Unwraps a patch zip payload directory if it contains `patch.json` + `payload/<bundleID>/...`,
    /// or stages a `.3105` package into a clean directory structure ready for container merge.
    public func unwrapExtractedPayloadRoot(at extractedDir: URL, preferredBundleID: String? = nil) -> (rootURL: URL, usesContainerRootRelativePaths: Bool) {
        let patchJSON = extractedDir.appendingPathComponent("patch.json")
        let payloadDir = extractedDir.appendingPathComponent("payload")
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: patchJSON.path),
           fileManager.fileExists(atPath: payloadDir.path, isDirectory: &isDir),
           isDir.boolValue {
            if let bid = preferredBundleID, !bid.isEmpty {
                let candidate = payloadDir.appendingPathComponent(bid)
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    return (candidate, true)
                }
            }
            if let children = try? fileManager.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]),
               let firstDir = children.first(where: {
                   var childIsDir: ObjCBool = false
                   return fileManager.fileExists(atPath: $0.path, isDirectory: &childIsDir) && childIsDir.boolValue
               }) {
                return (firstDir, true)
            }
            return (payloadDir, true)
        }
        return (extractedDir, false)
    }
}
