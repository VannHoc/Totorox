import Foundation
import Darwin

public struct DirectorySizeResult: Sendable, Equatable {
    public let totalBytes: Int64
    public let fileCount: Int
    public let folderCount: Int

    public init(totalBytes: Int64 = 0, fileCount: Int = 0, folderCount: Int = 0) {
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
    }

    public var formattedText: String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let byteStr = nf.string(from: NSNumber(value: totalBytes)) ?? "\(totalBytes)"
        let humanSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(humanSize) (\(byteStr) bytes) • \(fileCount) tệp, \(folderCount) thư mục con"
    }
}

public enum DirectorySizeService {
    public static func calculateSize(at path: String) async -> DirectorySizeResult {
        await Task.detached(priority: .userInitiated) {
            calculateSizeSync(at: path)
        }.value
    }

    public static func calculateSizeSync(at path: String) -> DirectorySizeResult {
        var totalBytes: Int64 = 0
        var fileCount: Int = 0
        var folderCount: Int = 0

        var stack: [String] = [path]
        var visitedInodes = Set<UInt64>()

        while let currentPath = stack.popLast() {
            if Task.isCancelled { break }

            guard let dir = opendir(currentPath) else { continue }

            while let dp = readdir(dir) {
                if Task.isCancelled { break }

                let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }

                let itemPath = (currentPath as NSString).appendingPathComponent(name)
                var st = stat()
                guard lstat(itemPath, &st) == 0 else { continue }

                let inode = UInt64(st.st_ino)
                if !visitedInodes.insert(inode).inserted {
                    continue
                }

                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                let isLink = (st.st_mode & S_IFMT) == S_IFLNK

                if isDir {
                    folderCount += 1
                    stack.append(itemPath)
                } else if !isLink {
                    fileCount += 1
                    totalBytes += Int64(st.st_size)
                } else {
                    fileCount += 1
                }
            }
            closedir(dir)
        }

        return DirectorySizeResult(totalBytes: totalBytes, fileCount: fileCount, folderCount: folderCount)
    }

    public static func countImmediateChildren(at path: String) -> Int? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var count = 0
        while let dp = readdir(dir) {
            let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            count += 1
        }
        return count
    }
}
