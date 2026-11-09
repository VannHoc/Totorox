import Foundation

public enum FileIOConflictKind: Equatable, Sendable {
    case fileOverwritingFolder
    case folderOverwritingFile
}

public enum FileIOConflictResolution: Equatable, Sendable {
    case replace
    case skip
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

    /// Recursively copies and merges source items into destination according to strict business rules:
    /// 1. File overwriting file: destination overwritten without hash/diff comparison.
    /// 2. Folder into folder: recursive merge. Matching files overwritten, non-conflicting files/folders preserved.
    /// 3. File vs Folder conflict: MUST prompt user for Replace, Skip, or Cancel. Never delete destination silently.
    /// 4. Cancellation & Failure: Safely aborts and reports exact succeeded, failed, and skipped items.
    public func copyAndMerge(
        from sourceURL: URL,
        to destinationURL: URL,
        conflictResolver: FileIOConflictResolver
    ) async -> FileIOResult {
        var result = FileIOResult()
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
            result: &result,
            conflictResolver: conflictResolver
        )

        return result
    }

    private func processItem(
        source: URL,
        sourceIsDir: Bool,
        destination: URL,
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
            // Case A: Destination does not exist -> Create or copy directly
            if sourceIsDir {
                do {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    result.succeeded.append(destination)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                    return
                }

                await copyChildrenRecursively(
                    from: source,
                    to: destination,
                    result: &result,
                    conflictResolver: conflictResolver
                )
            } else {
                do {
                    let parentDir = destination.deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: parentDir.path) {
                        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    }
                    try fileManager.copyItem(at: source, to: destination)
                    result.succeeded.append(destination)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                }
            }
        } else {
            // Destination already exists -> check type alignment
            if !sourceIsDir && !destIsDir.boolValue {
                // Rule 1: File overwrites file. Direct overwrite without hash/diff check.
                do {
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.copyItem(at: source, to: destination)
                    result.succeeded.append(destination)
                } catch {
                    result.failed.append(FileIOFailureRecord(url: destination, reason: error.localizedDescription))
                }
            } else if sourceIsDir && destIsDir.boolValue {
                // Rule 2: Folder merges into folder recursively.
                // Destination folder remains intact.
                result.succeeded.append(destination)
                await copyChildrenRecursively(
                    from: source,
                    to: destination,
                    result: &result,
                    conflictResolver: conflictResolver
                )
            } else {
                // Rule 3: Type Conflict (File vs Folder or Folder vs File)
                let conflictKind: FileIOConflictKind = (!sourceIsDir && destIsDir.boolValue)
                    ? .fileOverwritingFolder
                    : .folderOverwritingFile

                let userChoice = await conflictResolver(source, destination, conflictKind)
                switch userChoice {
                case .replace:
                    // Remove conflicting destination and apply source
                    do {
                        try fileManager.removeItem(at: destination)
                        if sourceIsDir {
                            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                            result.succeeded.append(destination)
                            await copyChildrenRecursively(
                                from: source,
                                to: destination,
                                result: &result,
                                conflictResolver: conflictResolver
                            )
                        } else {
                            try fileManager.copyItem(at: source, to: destination)
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
                result: &result,
                conflictResolver: conflictResolver
            )

            if result.isCancelled {
                // Break out of directory iteration if cancelled
                break
            }
        }
    }
}
