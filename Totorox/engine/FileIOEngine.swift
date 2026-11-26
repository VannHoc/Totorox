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

public enum FileIOEngineError: Error, Equatable, LocalizedError {
    case symbolicLinkUnsupported
    case invalidDestination

    public var errorDescription: String? {
        switch self {
        case .symbolicLinkUnsupported: return AppLanguage.current.text("error.filemanager.symlink_unsupported")
        case .invalidDestination: return AppLanguage.current.text("error.fileio.invalid_destination")
        }
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

private final class FileIOConflictSession: @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldReplaceAllConflicts = false

    var shouldReplaceAllConflicts: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _shouldReplaceAllConflicts
    }

    func enableReplaceAll() {
        lock.lock()
        _shouldReplaceAllConflicts = true
        lock.unlock()
    }
}

private final class FileIOBatchContext {
    let bufferSize: Int = 1_024 * 1_024
    let buffer: UnsafeMutablePointer<UInt8>
    let syncEachFile: Bool
    var createdDirectories = Set<String>()
    var verifiedSafeAncestors = Set<String>()
    var verifiedReadPaths = Set<String>()
    var verifiedWritePaths = Set<String>()

    init(syncEachFile: Bool = false) {
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024 * 1_024)
        self.syncEachFile = syncEachFile
    }

    deinit {
        buffer.deallocate()
    }
}

public typealias FileIOByteProgressHandler = @Sendable (
    _ bytesCopied: Int64,
    _ totalBytes: Int64,
    _ currentItemName: String
) -> Void

public final class FileIOEngine: @unchecked Sendable {
    public static let shared = FileIOEngine()
    private let fileManager: FileManager
    private let replaceAllLock = NSLock()
    private var _shouldReplaceAllConflicts: Bool = false

    /// Reset to `false` at the beginning of each `copyAndMerge` operation and flipped to `true`
    /// as soon as the user selects `.replaceAll` on any conflict.
    public var shouldReplaceAllConflicts: Bool {
        get {
            replaceAllLock.lock()
            defer { replaceAllLock.unlock() }
            return _shouldReplaceAllConflicts
        }
        set {
            replaceAllLock.lock()
            _shouldReplaceAllConflicts = newValue
            replaceAllLock.unlock()
        }
    }

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Recursively copies and merges source items into destination on a background thread
    /// according to Windows Merge rules:
    /// 1. Folder -> Folder: Recursive merge. Destination folder is never deleted; recurses inside.
    /// 2. File not existing at destination: Standard copy.
    /// 3. Exact destination file/item already existing on disk:
    ///    - If `shouldReplaceAllConflicts == true`: Overwrites directly without prompting.
    ///    - If `shouldReplaceAllConflicts == false`: Pauses background execution (async/await) and invokes `conflictResolver`:
    ///      - Replace: Overwrite current file, continue.
    ///      - Skip: Do nothing for current item, continue.
    ///      - Replace All: Set `shouldReplaceAllConflicts = true`, overwrite current and all future colliding items without asking.
    public func copyAndMerge(
        from sourceURL: URL,
        to destinationURL: URL,
        progressHandler: (@Sendable (_ completedCount: Int, _ currentItemName: String) -> Void)? = nil,
        byteProgressHandler: FileIOByteProgressHandler? = nil,
        conflictResolver: @escaping FileIOConflictResolver
    ) async -> FileIOResult {
        let cancelState = FileIOCancellationState()
        let conflictSession = FileIOConflictSession()
        self.shouldReplaceAllConflicts = false

        if Task.isCancelled {
            cancelState.cancel()
        }

        let workerTask = Task.detached(priority: .userInitiated) { [self] () -> FileIOResult in
            var result = FileIOResult()
            let batchContext = FileIOBatchContext(syncEachFile: false)
            let standardizedSource = sourceURL.standardizedFileURL
            let initialDest = destinationURL.standardizedFileURL

            _ = ContainerStore.ensureContainerAccess(for: standardizedSource.path, requireWrite: false)
            batchContext.verifiedReadPaths.insert(standardizedSource.path)
            _ = ContainerStore.ensureContainerAccess(for: initialDest.path, requireWrite: true)
            batchContext.verifiedWritePaths.insert(initialDest.path)

            var isDir: ObjCBool = false
            var st = stat()
            let exists: Bool
            if lstat(standardizedSource.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    result.failed.append(FileIOFailureRecord(
                        url: standardizedSource,
                        reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
                    ))
                    return result
                }
                exists = true
                isDir = ObjCBool((st.st_mode & S_IFMT) == S_IFDIR)
            } else if self.fileManager.fileExists(atPath: standardizedSource.path, isDirectory: &isDir) {
                if Self.isSymbolicLink(at: standardizedSource) {
                    result.failed.append(FileIOFailureRecord(
                        url: standardizedSource,
                        reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
                    ))
                    return result
                }
                exists = true
            } else {
                exists = false
            }

            guard exists else {
                result.failed.append(FileIOFailureRecord(url: standardizedSource, reason: "Source item does not exist."))
                return result
            }

            // Guard against copying a single file into a parent directory path without appending the filename.
            // Only treat it as a type collision (.fileOverwritingFolder) if the names genuinely collide or
            // destination is NOT a different-named parent directory.
            var resolvedDest = initialDest
            if !isDir.boolValue {
                var destSt = stat()
                var destIsDir = false
                if lstat(initialDest.path, &destSt) == 0 {
                    destIsDir = (destSt.st_mode & S_IFMT) == S_IFDIR
                } else {
                    var fmDir: ObjCBool = false
                    if self.fileManager.fileExists(atPath: initialDest.path, isDirectory: &fmDir) {
                        destIsDir = fmDir.boolValue
                    }
                }
                if destIsDir, initialDest.lastPathComponent != standardizedSource.lastPathComponent {
                    resolvedDest = initialDest.appendingPathComponent(standardizedSource.lastPathComponent)
                }
            }

            if standardizedSource == resolvedDest {
                // Copying/moving an item onto itself is a no-op. Never report success here:
                // callers performing a "cut" delete the source when the result looks successful.
                result.skipped.append(standardizedSource)
                return result
            }

            if isDir.boolValue {
                let sourcePath = standardizedSource.path
                let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
                if resolvedDest.standardizedFileURL.path.hasPrefix(sourcePrefix) {
                    result.failed.append(FileIOFailureRecord(
                        url: resolvedDest,
                        reason: "A folder cannot be copied or moved into itself."
                    ))
                    return result
                }
            }

            if Self.isSymbolicLink(at: resolvedDest)
                || Self.isSymbolicLink(at: resolvedDest.deletingLastPathComponent()) {
                result.failed.append(FileIOFailureRecord(
                    url: resolvedDest,
                    reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
                ))
                return result
            }

            await self.processItem(
                source: standardizedSource,
                sourceIsDir: isDir.boolValue,
                destination: resolvedDest,
                conflictSession: conflictSession,
                result: &result,
                cancelState: cancelState,
                progressHandler: progressHandler,
                byteProgressHandler: byteProgressHandler,
                conflictResolver: conflictResolver,
                batchContext: batchContext
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
        conflictSession: FileIOConflictSession,
        result: inout FileIOResult,
        cancelState: FileIOCancellationState,
        progressHandler: (@Sendable (_ completedCount: Int, _ currentItemName: String) -> Void)?,
        byteProgressHandler: FileIOByteProgressHandler? = nil,
        conflictResolver: FileIOConflictResolver,
        batchContext: FileIOBatchContext? = nil,
        beforeWriteFile: (@Sendable (_ destinationURL: URL, _ existedBefore: Bool) -> Void)? = nil
    ) async {
        await Task.yield()
        defer {
            let totalDone = result.succeeded.count + result.skipped.count + result.failed.count
            progressHandler?(totalDone, source.lastPathComponent)
        }
        if cancelState.isCancelled || result.isCancelled {
            result.isCancelled = true
            result.skipped.append(source)
            return
        }

        if Self.isSymbolicLink(at: source.standardizedFileURL) {
            result.failed.append(FileIOFailureRecord(
                url: source,
                reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
            ))
            return
        }

        let exactDestination = destination.standardizedFileURL
        if let ctx = batchContext {
            let parentPath = exactDestination.deletingLastPathComponent().path
            if !ctx.verifiedWritePaths.contains(parentPath) {
                _ = ContainerStore.ensureContainerAccess(for: exactDestination.path, requireWrite: true)
                ctx.verifiedWritePaths.insert(parentPath)
            }
        } else {
            _ = ContainerStore.ensureContainerAccess(for: exactDestination.path, requireWrite: true)
        }

        var destIsDir = false
        var destExists = false
        var destStat = stat()
        if lstat(exactDestination.path, &destStat) == 0 {
            if (destStat.st_mode & S_IFMT) == S_IFLNK {
                result.failed.append(FileIOFailureRecord(
                    url: exactDestination,
                    reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
                ))
                return
            }
            destExists = true
            destIsDir = (destStat.st_mode & S_IFMT) == S_IFDIR
        } else {
            var fmDir: ObjCBool = false
            if fileManager.fileExists(atPath: exactDestination.path, isDirectory: &fmDir) {
                if Self.isSymbolicLink(at: exactDestination) {
                    result.failed.append(FileIOFailureRecord(
                        url: exactDestination,
                        reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
                    ))
                    return
                }
                destExists = true
                destIsDir = fmDir.boolValue
            }
        }

        let destParent = exactDestination.deletingLastPathComponent()
        if !(batchContext?.verifiedSafeAncestors.contains(destParent.path) ?? false) {
            if Self.isSymbolicLink(at: destParent) {
                result.failed.append(FileIOFailureRecord(
                    url: exactDestination,
                    reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
                ))
                return
            }
        }

        if !destExists {
            // Final destination path does NOT exist on disk -> copy/create directly without any conflict prompt
            if sourceIsDir {
                do {
                    try Self.createDirectoryIfNeeded(at: exactDestination, batchContext: batchContext)
                    result.succeeded.append(exactDestination)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: exactDestination, reason: error.localizedDescription))
                    return
                }

                await copyChildrenRecursively(
                    from: source,
                    to: exactDestination,
                    conflictSession: conflictSession,
                    result: &result,
                    cancelState: cancelState,
                    progressHandler: progressHandler,
                    byteProgressHandler: byteProgressHandler,
                    conflictResolver: conflictResolver,
                    batchContext: batchContext,
                    beforeWriteFile: beforeWriteFile
                )
            } else {
                do {
                    beforeWriteFile?(exactDestination, false)
                    try copySingleFile(
                        from: source,
                        to: exactDestination,
                        batchContext: batchContext,
                        cancelCheck: { cancelState.isCancelled },
                        byteProgressHandler: byteProgressHandler
                    )
                    if cancelState.isCancelled {
                        result.isCancelled = true
                        result.skipped.append(source)
                    } else {
                        result.succeeded.append(exactDestination)
                    }
                } catch is CancellationError {
                    result.isCancelled = true
                    result.skipped.append(source)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: exactDestination, reason: error.localizedDescription))
                }
            }
            return
        }

        // Exact destination path EXISTS on disk:
        if sourceIsDir && destIsDir {
            // 1. Folder -> Folder: Automatically merge recursively (NEVER prompt for conflict)
            result.succeeded.append(exactDestination)
            await copyChildrenRecursively(
                from: source,
                to: exactDestination,
                conflictSession: conflictSession,
                result: &result,
                cancelState: cancelState,
                progressHandler: progressHandler,
                byteProgressHandler: byteProgressHandler,
                conflictResolver: conflictResolver,
                batchContext: batchContext,
                beforeWriteFile: beforeWriteFile
            )
            return
        }

        if !sourceIsDir && !destIsDir {
            // 2. File -> File collision
            if conflictSession.shouldReplaceAllConflicts {
                do {
                    beforeWriteFile?(exactDestination, true)
                    try copySingleFile(
                        from: source,
                        to: exactDestination,
                        batchContext: batchContext,
                        cancelCheck: { cancelState.isCancelled },
                        byteProgressHandler: byteProgressHandler
                    )
                    if cancelState.isCancelled {
                        result.isCancelled = true
                        result.skipped.append(source)
                    } else {
                        result.succeeded.append(exactDestination)
                    }
                } catch is CancellationError {
                    result.isCancelled = true
                    result.skipped.append(source)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: exactDestination, reason: error.localizedDescription))
                }
                return
            }

            let userChoice = await conflictResolver(source, exactDestination, .fileExists)
            switch userChoice {
            case .replace:
                do {
                    beforeWriteFile?(exactDestination, true)
                    try copySingleFile(
                        from: source,
                        to: exactDestination,
                        batchContext: batchContext,
                        cancelCheck: { cancelState.isCancelled },
                        byteProgressHandler: byteProgressHandler
                    )
                    if cancelState.isCancelled {
                        result.isCancelled = true
                        result.skipped.append(source)
                    } else {
                        result.succeeded.append(exactDestination)
                    }
                } catch is CancellationError {
                    result.isCancelled = true
                    result.skipped.append(source)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: exactDestination, reason: error.localizedDescription))
                }
            case .replaceAll:
                conflictSession.enableReplaceAll()
                self.shouldReplaceAllConflicts = true
                do {
                    beforeWriteFile?(exactDestination, true)
                    try copySingleFile(
                        from: source,
                        to: exactDestination,
                        batchContext: batchContext,
                        cancelCheck: { cancelState.isCancelled },
                        byteProgressHandler: byteProgressHandler
                    )
                    if cancelState.isCancelled {
                        result.isCancelled = true
                        result.skipped.append(source)
                    } else {
                        result.succeeded.append(exactDestination)
                    }
                } catch is CancellationError {
                    result.isCancelled = true
                    result.skipped.append(source)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: exactDestination, reason: error.localizedDescription))
                }
            case .skip:
                result.skipped.append(source)
            case .cancel:
                result.isCancelled = true
                result.skipped.append(source)
            }
            return
        }

        // 3. Type conflict (File -> Folder or Folder -> File)
        if conflictSession.shouldReplaceAllConflicts {
            do {
                try removeExistingItem(at: exactDestination)
                if sourceIsDir {
                    try Self.createDirectoryIfNeeded(at: exactDestination, batchContext: batchContext)
                    result.succeeded.append(exactDestination)
                    await copyChildrenRecursively(
                        from: source,
                        to: exactDestination,
                        conflictSession: conflictSession,
                        result: &result,
                        cancelState: cancelState,
                        progressHandler: progressHandler,
                        byteProgressHandler: byteProgressHandler,
                        conflictResolver: conflictResolver,
                        batchContext: batchContext,
                        beforeWriteFile: beforeWriteFile
                    )
                } else {
                    try copySingleFile(
                        from: source,
                        to: exactDestination,
                        batchContext: batchContext,
                        cancelCheck: { cancelState.isCancelled },
                        byteProgressHandler: byteProgressHandler
                    )
                    result.succeeded.append(exactDestination)
                }
            } catch is CancellationError {
                result.isCancelled = true
                result.skipped.append(source)
            } catch {
                result.failed.append(FileIOFailureRecord(url: exactDestination, reason: error.localizedDescription))
            }
            return
        }

        let conflictKind: FileIOConflictKind = (!sourceIsDir && destIsDir)
            ? .fileOverwritingFolder
            : .folderOverwritingFile

        let userChoice = await conflictResolver(source, exactDestination, conflictKind)
        switch userChoice {
        case .replace, .replaceAll:
            if userChoice == .replaceAll {
                conflictSession.enableReplaceAll()
                self.shouldReplaceAllConflicts = true
            }
            do {
                try removeExistingItem(at: exactDestination)
                if sourceIsDir {
                    try Self.createDirectoryIfNeeded(at: exactDestination, batchContext: batchContext)
                    result.succeeded.append(exactDestination)
                    await copyChildrenRecursively(
                        from: source,
                        to: exactDestination,
                        conflictSession: conflictSession,
                        result: &result,
                        cancelState: cancelState,
                        progressHandler: progressHandler,
                        byteProgressHandler: byteProgressHandler,
                        conflictResolver: conflictResolver,
                        batchContext: batchContext,
                        beforeWriteFile: beforeWriteFile
                    )
                } else {
                    try copySingleFile(
                        from: source,
                        to: exactDestination,
                        batchContext: batchContext,
                        cancelCheck: { cancelState.isCancelled },
                        byteProgressHandler: byteProgressHandler
                    )
                    result.succeeded.append(exactDestination)
                }
            } catch is CancellationError {
                result.isCancelled = true
                result.skipped.append(source)
            } catch {
                result.failed.append(FileIOFailureRecord(url: exactDestination, reason: error.localizedDescription))
            }
        case .skip:
            result.skipped.append(source)
        case .cancel:
            result.isCancelled = true
            result.skipped.append(source)
        }
    }

    private func copyChildrenRecursively(
        from sourceDir: URL,
        to destinationDir: URL,
        conflictSession: FileIOConflictSession,
        result: inout FileIOResult,
        cancelState: FileIOCancellationState,
        progressHandler: (@Sendable (_ completedCount: Int, _ currentItemName: String) -> Void)?,
        byteProgressHandler: FileIOByteProgressHandler? = nil,
        conflictResolver: FileIOConflictResolver,
        batchContext: FileIOBatchContext? = nil,
        beforeWriteFile: (@Sendable (_ destinationURL: URL, _ existedBefore: Bool) -> Void)? = nil
    ) async {
        // Fast POSIX opendir/readdir yields child names and d_type in one pass without Foundation URL allocation per attribute.
        var children: [(url: URL, isDir: Bool, isSymlink: Bool)] = []
        if let posixDir = opendir(sourceDir.path) {
            defer { closedir(posixDir) }
            while let dp = readdir(posixDir) {
                let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                let childURL = sourceDir.appendingPathComponent(name)
                let dtype = Int32(dp.pointee.d_type)
                if dtype == Int32(DT_LNK) {
                    children.append((childURL, false, true))
                } else if dtype == Int32(DT_DIR) {
                    children.append((childURL, true, false))
                } else if dtype == Int32(DT_REG) {
                    children.append((childURL, false, false))
                } else {
                    var st = stat()
                    if lstat(childURL.path, &st) == 0 {
                        let ftype = st.st_mode & S_IFMT
                        children.append((childURL, ftype == S_IFDIR, ftype == S_IFLNK))
                    } else {
                        var isDirObj: ObjCBool = false
                        if fileManager.fileExists(atPath: childURL.path, isDirectory: &isDirObj) {
                            children.append((childURL, isDirObj.boolValue, Self.isSymbolicLink(at: childURL)))
                        } else {
                            result.failed.append(FileIOFailureRecord(url: childURL, reason: "Source child inaccessible."))
                        }
                    }
                }
            }
        } else if let fmContents = try? fileManager.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            for childURL in fmContents {
                let rv = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isLink = rv?.isSymbolicLink ?? Self.isSymbolicLink(at: childURL)
                let isDir = rv?.isDirectory ?? false
                children.append((childURL, isDir, isLink))
            }
        } else {
            result.failed.append(FileIOFailureRecord(url: sourceDir, reason: "Unable to read source directory contents."))
            return
        }

        for child in children {
            if cancelState.isCancelled || result.isCancelled {
                result.isCancelled = true
                result.skipped.append(child.url)
                continue
            }

            if child.isSymlink {
                result.failed.append(FileIOFailureRecord(
                    url: child.url,
                    reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
                ))
                continue
            }

            let childDest = destinationDir.appendingPathComponent(child.url.lastPathComponent)
            await processItem(
                source: child.url,
                sourceIsDir: child.isDir,
                destination: childDest,
                conflictSession: conflictSession,
                result: &result,
                cancelState: cancelState,
                progressHandler: progressHandler,
                byteProgressHandler: byteProgressHandler,
                conflictResolver: conflictResolver,
                batchContext: batchContext,
                beforeWriteFile: beforeWriteFile
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
        to destination: URL,
        syncAfterWrite: Bool = true,
        cancelCheck: (() -> Bool)? = nil,
        byteProgressHandler: FileIOByteProgressHandler? = nil
    ) throws {
        try copySingleFile(
            from: source,
            to: destination,
            batchContext: nil,
            syncAfterWrite: syncAfterWrite,
            cancelCheck: cancelCheck,
            byteProgressHandler: byteProgressHandler
        )
    }

    private func copySingleFile(
        from source: URL,
        to destination: URL,
        batchContext: FileIOBatchContext?,
        syncAfterWrite: Bool = true,
        cancelCheck: (() -> Bool)? = nil,
        byteProgressHandler: FileIOByteProgressHandler? = nil
    ) throws {
        // A copy onto itself must never truncate the source through the staging/overwrite fallbacks.
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }

        let parentDir = destination.deletingLastPathComponent()
        if let ctx = batchContext {
            let srcParentPath = source.deletingLastPathComponent().path
            if !ctx.verifiedReadPaths.contains(srcParentPath) {
                _ = ContainerStore.ensureContainerAccess(for: source.path, requireWrite: false)
                ctx.verifiedReadPaths.insert(srcParentPath)
            }
            if !ctx.verifiedWritePaths.contains(parentDir.path) {
                _ = ContainerStore.ensureContainerAccess(for: destination.path, requireWrite: true)
                _ = ContainerStore.ensureContainerAccess(for: parentDir.path, requireWrite: true)
                ctx.verifiedWritePaths.insert(parentDir.path)
            }
        } else {
            _ = ContainerStore.ensureContainerAccess(for: source.path, requireWrite: false)
            _ = ContainerStore.ensureContainerAccess(for: destination.path, requireWrite: true)
            _ = ContainerStore.ensureContainerAccess(for: parentDir.path, requireWrite: true)
        }

        try Self.validateNoSymbolicLinks(at: source, includeParent: true, batchContext: batchContext)
        try Self.validateNoSymbolicLinks(at: destination, includeParent: true, batchContext: batchContext)
        try Self.createDirectoryIfNeeded(at: parentDir, batchContext: batchContext)

        var preservedMode: mode_t = 0o644
        var targetStat = stat()
        let targetExisted = (lstat(destination.path, &targetStat) == 0)
        if targetExisted {
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
        let protection: FileProtectionType? = targetExisted
            ? (try? fileManager.attributesOfItem(atPath: destination.path))?[.protectionKey] as? FileProtectionType
            : nil

        let stagingURL = parentDir.appendingPathComponent(".totorox-\(UUID().uuidString).tmp")
        var stagingCommitted = false
        defer {
            if !stagingCommitted {
                _ = unlink(stagingURL.path)
            }
        }

        // 1. Low-level POSIX stream to sibling staging file + atomic rename
        let itemName = source.lastPathComponent
        if try posixCopyStream(
            from: source.path,
            to: stagingURL.path,
            mode: preservedMode,
            batchContext: batchContext,
            syncAfterWrite: syncAfterWrite,
            cancelCheck: cancelCheck,
            itemName: itemName,
            byteProgressHandler: byteProgressHandler
        ) {
            if let protection {
                try? fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: stagingURL.path)
            }
            if rename(stagingURL.path, destination.path) == 0 {
                stagingCommitted = true
                return
            }
        }

        // 2. Original 3105 FileReplacementService engine
        if (try? FileReplacementService.replace(target: destination, with: source)) != nil {
            return
        }

        // 3. Direct POSIX stream in-place to destination (handles directories that block temp sibling creation).
        //    Keep the rollback backup in `temporaryDirectory` so it succeeds even when `parentDir` forbids sibling temps.
        let inPlaceBackupURL = fileManager.temporaryDirectory
            .appendingPathComponent(".totorox-backup-\(UUID().uuidString).tmp")
        defer {
            _ = unlink(inPlaceBackupURL.path)
            try? fileManager.removeItem(at: inPlaceBackupURL)
        }
        var destinationStat = stat()
        let destinationExisted = targetExisted
            || fileManager.fileExists(atPath: destination.path)
            || lstat(destination.path, &destinationStat) == 0
        let hasInPlaceBackup = destinationExisted
            && ((try? posixCopyStream(from: destination.path, to: inPlaceBackupURL.path, mode: preservedMode, batchContext: batchContext, syncAfterWrite: false)) ?? false)
        _ = chmod(destination.path, preservedMode | mode_t(S_IWUSR))
        if try posixCopyStream(
            from: source.path,
            to: destination.path,
            mode: preservedMode,
            batchContext: batchContext,
            syncAfterWrite: syncAfterWrite,
            cancelCheck: cancelCheck,
            itemName: itemName,
            byteProgressHandler: byteProgressHandler
        ) {
            _ = chmod(destination.path, preservedMode)
            if let protection {
                try? fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: destination.path)
            }
            return
        }
        if hasInPlaceBackup {
            _ = try? posixCopyStream(from: inPlaceBackupURL.path, to: destination.path, mode: preservedMode, batchContext: batchContext, syncAfterWrite: false)
        }

        // 4. Direct Data read + POSIX write fallback (never deletes the destination first)
        if let data = ContainerStore.readDataDirectly(atPath: source.path) ?? (try? Data(contentsOf: source)) {
            if posixWriteData(data, to: stagingURL.path, mode: preservedMode),
               rename(stagingURL.path, destination.path) == 0 {
                stagingCommitted = true
                return
            }
            var fallbackStat = stat()
            let fallbackExisted = destinationExisted
                || fileManager.fileExists(atPath: destination.path)
                || lstat(destination.path, &fallbackStat) == 0
            let hasFallbackBackup = fallbackExisted
                && ((try? posixCopyStream(from: destination.path, to: inPlaceBackupURL.path, mode: preservedMode, batchContext: batchContext, syncAfterWrite: false)) ?? false)
            if posixWriteData(data, to: destination.path, mode: preservedMode) {
                _ = chmod(destination.path, preservedMode)
                if let protection {
                    try? fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: destination.path)
                }
                return
            }
            if hasFallbackBackup {
                _ = try? posixCopyStream(from: inPlaceBackupURL.path, to: destination.path, mode: preservedMode, batchContext: batchContext, syncAfterWrite: false)
            }
        }

        // 5. Final Foundation fallback: copy to staging first, then swap without unlinking the destination.
        let foundationStagingURL = parentDir.appendingPathComponent(".totorox-\(UUID().uuidString).tmp")
        defer {
            _ = unlink(foundationStagingURL.path)
            try? fileManager.removeItem(at: foundationStagingURL)
        }
        try fileManager.copyItem(at: source, to: foundationStagingURL)
        if rename(foundationStagingURL.path, destination.path) == 0 {
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            let backupURL = parentDir.appendingPathComponent(".totorox-backup-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: backupURL) }
            try fileManager.moveItem(at: destination, to: backupURL)
            do {
                try fileManager.moveItem(at: foundationStagingURL, to: destination)
                try? fileManager.removeItem(at: backupURL)
            } catch {
                try? fileManager.moveItem(at: backupURL, to: destination)
                throw error
            }
            return
        }
        try fileManager.moveItem(at: foundationStagingURL, to: destination)
    }

    private func posixCopyStream(
        from sourcePath: String,
        to destinationPath: String,
        mode: mode_t = 0o644,
        batchContext: FileIOBatchContext? = nil,
        syncAfterWrite: Bool = true,
        cancelCheck: (() -> Bool)? = nil,
        itemName: String = "",
        byteProgressHandler: FileIOByteProgressHandler? = nil
    ) throws -> Bool {
        let srcFD = open(sourcePath, O_RDONLY | O_CLOEXEC)
        guard srcFD >= 0 else { return false }
        defer { close(srcFD) }

        var srcStat = stat()
        let totalBytes: Int64 = (fstat(srcFD, &srcStat) == 0 && srcStat.st_size > 0)
            ? Int64(srcStat.st_size)
            : 0

        let dstFD = open(destinationPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
        guard dstFD >= 0 else { return false }
        defer { close(dstFD) }

        let bufferSize: Int
        let buffer: UnsafeMutablePointer<UInt8>
        let ownsBuffer: Bool
        if let ctx = batchContext {
            bufferSize = ctx.bufferSize
            buffer = ctx.buffer
            ownsBuffer = false
        } else {
            bufferSize = 512 * 1024
            buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            ownsBuffer = true
        }
        defer {
            if ownsBuffer {
                buffer.deallocate()
            }
        }

        var copiedBytes: Int64 = 0
        var lastReportedTime = CFAbsoluteTimeGetCurrent()
        // Report initial 0-byte state for large files (>= 4 MB) so the UI immediately shows byte progress.
        if let byteProgressHandler, totalBytes >= 4 * 1_024 * 1_024 {
            byteProgressHandler(0, totalBytes, itemName)
        }

        while true {
            if cancelCheck?() == true || Task.isCancelled {
                throw CancellationError()
            }
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
            copiedBytes += Int64(bytesRead)
            if let byteProgressHandler, totalBytes > 0 {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastReportedTime >= 0.1 || copiedBytes >= totalBytes {
                    lastReportedTime = now
                    byteProgressHandler(copiedBytes, totalBytes, itemName)
                }
            }
        }
        _ = fchmod(dstFD, mode)
        if batchContext?.syncEachFile ?? syncAfterWrite {
            _ = fsync(dstFD)
        }
        return true
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Rejects symlinks so a write can never be redirected outside the intended item.
    /// The immediate parent is checked as well, since a symlinked directory would
    /// silently relocate the destination.
    private static func validateNoSymbolicLinks(
        at url: URL,
        includeParent: Bool,
        batchContext: FileIOBatchContext? = nil
    ) throws {
        if isSymbolicLink(at: url) {
            throw FileIOEngineError.symbolicLinkUnsupported
        }
        let parent = url.deletingLastPathComponent()
        if batchContext?.verifiedSafeAncestors.contains(parent.path) == true {
            return
        }
        if includeParent, isSymbolicLink(at: parent) {
            throw FileIOEngineError.symbolicLinkUnsupported
        }
        try validateContainerAncestors(of: url, batchContext: batchContext)
    }

    /// Walks every path component from the app-container root down to `url` and rejects any
    /// symlink found on the way. Checking only the item and its immediate parent is not enough:
    /// a link placed deeper in the path (e.g. `Documents/a/b` where `Documents/a` is a symlink)
    /// would still redirect the write outside the container.
    ///
    /// Components *above* the container root are deliberately skipped — `/var` is a symlink to
    /// `/private/var` on stock iOS, so inspecting them would reject every container path.
    private static func validateContainerAncestors(of url: URL, batchContext: FileIOBatchContext? = nil) throws {
        let components = url.standardizedFileURL.pathComponents
        guard let applicationIndex = components.firstIndex(of: "Application"),
              applicationIndex >= 2,
              components[applicationIndex - 1] == "Data",
              components[applicationIndex - 2] == "Containers",
              applicationIndex + 1 < components.count else {
            return
        }

        var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() where component != "/" {
            currentURL.appendPathComponent(component)
            guard index >= applicationIndex + 1 else { continue }
            if isSymbolicLink(at: currentURL) {
                throw FileIOEngineError.symbolicLinkUnsupported
            }
        }
        batchContext?.verifiedSafeAncestors.insert(url.deletingLastPathComponent().path)
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
        _ = ContainerStore.ensureContainerAccess(for: url.path, requireWrite: true)
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
        try createDirectoryIfNeeded(at: url, batchContext: nil)
    }

    private static func createDirectoryIfNeeded(
        at url: URL,
        batchContext: FileIOBatchContext?
    ) throws {
        let path = url.path
        if let ctx = batchContext, ctx.createdDirectories.contains(path) {
            return
        }

        if let ctx = batchContext {
            if !ctx.verifiedWritePaths.contains(path) {
                _ = ContainerStore.ensureContainerAccess(for: path, requireWrite: true)
                ctx.verifiedWritePaths.insert(path)
            }
        } else {
            _ = ContainerStore.ensureContainerAccess(for: path, requireWrite: true)
        }

        var st = stat()
        if stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
            batchContext?.createdDirectories.insert(path)
            return
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            batchContext?.createdDirectories.insert(path)
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
            batchContext?.createdDirectories.insert(path)
        }
    }

    // MARK: - Async Background Single-Item Operations (Avoids Main-Thread Blocking)

    public func createFolder(at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let parent = url.deletingLastPathComponent()
            _ = ContainerStore.ensureContainerAccess(for: parent.path, requireWrite: true)
            try Self.validateNoSymbolicLinks(at: parent, includeParent: false)
            try Self.createDirectoryIfNeeded(at: url)
        }.value
    }

    /// Returns `true` only when every item from a cut operation reached the destination.
    /// A cut must never delete its source when the engine skipped/failed an item, when the
    /// operation was cancelled, or when the source and destination are the same location.
    public func canDeleteCutSource(
        sourceURL: URL,
        destinationURL: URL,
        result: FileIOResult
    ) -> Bool {
        guard !result.isCancelled,
              result.failed.isEmpty,
              result.skipped.isEmpty,
              !result.succeeded.isEmpty else {
            return false
        }

        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        if source == destination {
            return false
        }

        let sourcePath = source.path
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        if destination.path.hasPrefix(sourcePrefix) {
            return false
        }

        return true
    }

    public func renameItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            _ = ContainerStore.ensureContainerAccess(for: sourceURL.path, requireWrite: true)
            _ = ContainerStore.ensureContainerAccess(for: sourceURL.deletingLastPathComponent().path, requireWrite: true)
            _ = ContainerStore.ensureContainerAccess(for: destinationURL.deletingLastPathComponent().path, requireWrite: true)

            let source = sourceURL.standardizedFileURL
            let destination = destinationURL.standardizedFileURL
            if source == destination {
                return
            }

            try Self.validateNoSymbolicLinks(at: source, includeParent: true)
            try Self.validateNoSymbolicLinks(at: destination, includeParent: true)

            // `rename(2)` silently replaces an existing file on POSIX. Refuse that here so a
            // rename can never destroy an unrelated item; callers must pick a different name.
            var destinationStat = stat()
            if self.fileManager.fileExists(atPath: destination.path)
                || lstat(destination.path, &destinationStat) == 0 {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }

            if Darwin.rename(source.path, destination.path) == 0 {
                return
            }
            try self.fileManager.moveItem(at: source, to: destination)
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

    /// Thực hiện copy/ghi đè từng tệp theo danh sách ánh xạ `(source, destination)` từ `/api/v1/overwrite-plan`.
    public func applyMappedFiles(
        _ mappings: [(source: String, destination: String)],
        from sourceRoot: URL,
        to destinationRoot: URL,
        progressHandler: (@Sendable (_ completedCount: Int, _ currentItemName: String) -> Void)? = nil,
        byteProgressHandler: FileIOByteProgressHandler? = nil,
        beforeWriteFile: (@Sendable (_ destinationURL: URL, _ existedBefore: Bool) -> Void)? = nil,
        conflictResolver: @escaping FileIOConflictResolver
    ) async -> FileIOResult {
        let cancelState = FileIOCancellationState()
        let conflictSession = FileIOConflictSession()
        self.shouldReplaceAllConflicts = false

        if Task.isCancelled {
            cancelState.cancel()
        }

        let workerTask = Task.detached(priority: .userInitiated) { [self] () -> FileIOResult in
            var result = FileIOResult()
            let batchContext = FileIOBatchContext(syncEachFile: false)
            let srcBase = sourceRoot.standardizedFileURL
            let dstBase = destinationRoot.standardizedFileURL
            let srcPrefix = srcBase.path.hasSuffix("/") ? srcBase.path : srcBase.path + "/"
            let dstPrefix = dstBase.path.hasSuffix("/") ? dstBase.path : dstBase.path + "/"

            _ = ContainerStore.ensureContainerAccess(for: srcBase.path, requireWrite: false)
            batchContext.verifiedReadPaths.insert(srcBase.path)
            _ = ContainerStore.ensureContainerAccess(for: dstBase.path, requireWrite: true)
            batchContext.verifiedWritePaths.insert(dstBase.path)

            for mapping in mappings {
                if cancelState.isCancelled || result.isCancelled || Task.isCancelled {
                    result.isCancelled = true
                    break
                }

                let relSrc = mapping.source.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let relDst = mapping.destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let srcParts = relSrc.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                let dstParts = relDst.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                guard !srcParts.isEmpty, !dstParts.isEmpty else {
                    continue
                }
                if srcParts.contains("..") || dstParts.contains("..") ||
                    srcParts.contains(".") || dstParts.contains(".") {
                    result.failed.append(FileIOFailureRecord(
                        url: dstBase.appendingPathComponent(relDst),
                        reason: FileIOEngineError.invalidDestination.localizedDescription
                    ))
                    continue
                }

                let sourceFile = srcParts.reduce(srcBase) { $0.appendingPathComponent($1, isDirectory: false) }.standardizedFileURL
                let destFile = dstParts.reduce(dstBase) { $0.appendingPathComponent($1, isDirectory: false) }.standardizedFileURL
                guard sourceFile.path.hasPrefix(srcPrefix),
                      destFile.path.hasPrefix(dstPrefix) else {
                    result.failed.append(FileIOFailureRecord(
                        url: destFile,
                        reason: FileIOEngineError.invalidDestination.localizedDescription
                    ))
                    continue
                }

                var srcSt = stat()
                var srcIsRegular = false
                if lstat(sourceFile.path, &srcSt) == 0 {
                    if (srcSt.st_mode & S_IFMT) == S_IFLNK {
                        result.failed.append(FileIOFailureRecord(
                            url: sourceFile,
                            reason: FileIOEngineError.symbolicLinkUnsupported.localizedDescription
                        ))
                        continue
                    }
                    srcIsRegular = (srcSt.st_mode & S_IFMT) != S_IFDIR
                } else {
                    var isSrcDir: ObjCBool = false
                    srcIsRegular = self.fileManager.fileExists(atPath: sourceFile.path, isDirectory: &isSrcDir)
                        && !isSrcDir.boolValue
                }
                guard srcIsRegular else {
                    continue
                }

                do {
                    try Self.createDirectoryIfNeeded(
                        at: destFile.deletingLastPathComponent(),
                        batchContext: batchContext
                    )
                } catch {
                    result.failed.append(FileIOFailureRecord(
                        url: destFile,
                        reason: error.localizedDescription
                    ))
                    continue
                }

                await self.processItem(
                    source: sourceFile,
                    sourceIsDir: false,
                    destination: destFile,
                    conflictSession: conflictSession,
                    result: &result,
                    cancelState: cancelState,
                    progressHandler: progressHandler,
                    byteProgressHandler: byteProgressHandler,
                    conflictResolver: conflictResolver,
                    batchContext: batchContext,
                    beforeWriteFile: beforeWriteFile
                )
            }

            return result
        }

        return await withTaskCancellationHandler {
            await workerTask.value
        } onCancel: {
            cancelState.cancel()
            workerTask.cancel()
        }
    }
}
