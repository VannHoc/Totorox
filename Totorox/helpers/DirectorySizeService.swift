import Foundation
import Darwin

struct DirectorySizeResult: Sendable, Equatable {
    let totalBytes: Int64
    let fileCount: Int
    let folderCount: Int

    private static let formatterLock = NSLock()
    private static let sharedNumberFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf
    }()

    init(totalBytes: Int64 = 0, fileCount: Int = 0, folderCount: Int = 0) {
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
    }

    var formattedText: String {
        Self.formatterLock.lock()
        let byteStr = Self.sharedNumberFormatter.string(from: NSNumber(value: totalBytes)) ?? "\(totalBytes)"
        Self.formatterLock.unlock()
        let humanSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return AppLanguage.current.text("dirsize.formatted", humanSize, byteStr, fileCount, folderCount)
    }
}

enum DirectorySizeService {
    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: UInt64
    }

    static func calculateSize(at path: String) async -> DirectorySizeResult {
        await Task.detached(priority: .userInitiated) {
            calculateSizeSync(at: path)
        }.value
    }

    static func calculateSizeSync(at path: String) -> DirectorySizeResult {
        var totalBytes: Int64 = 0
        var fileCount: Int = 0
        var folderCount: Int = 0

        var stack: [String] = [path]
        var visited = Set<FileIdentity>()

        while let currentPath = stack.popLast() {
            if Task.isCancelled { break }

            guard let dir = opendir(currentPath) else { continue }

            while let dp = readdir(dir) {
                if Task.isCancelled { break }

                let firstByte = dp.pointee.d_name.0
                if firstByte == 46 { // '.'
                    let secondByte = dp.pointee.d_name.1
                    if secondByte == 0 || (secondByte == 46 && dp.pointee.d_name.2 == 0) {
                        continue
                    }
                }

                let name = withUnsafePointer(to: &dp.pointee.d_name) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }

                let itemPath = currentPath.hasSuffix("/")
                    ? currentPath + name
                    : currentPath + "/" + name
                var st = stat()
                guard lstat(itemPath, &st) == 0 else { continue }

                let identity = FileIdentity(device: st.st_dev, inode: UInt64(st.st_ino))
                if !visited.insert(identity).inserted {
                    continue
                }

                let fileType = st.st_mode & S_IFMT
                if fileType == S_IFDIR {
                    folderCount += 1
                    stack.append(itemPath)
                } else if fileType != S_IFLNK {
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

    static func countImmediateChildren(at path: String) -> Int? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var count = 0
        while let dp = readdir(dir) {
            let firstByte = dp.pointee.d_name.0
            if firstByte == 46 { // '.'
                let secondByte = dp.pointee.d_name.1
                if secondByte == 0 || (secondByte == 46 && dp.pointee.d_name.2 == 0) {
                    continue
                }
            }
            count += 1
        }
        return count
    }
}
