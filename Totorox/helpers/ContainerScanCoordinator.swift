import Foundation
import Darwin

/// Port cơ chế scan dùng chung của WQFiles 0.9.19 (`WQAccess.m:2429-2516`,
/// `:2987-3104`, `:3125-3244`) vào luồng phát hiện container hiện có.
///
/// Hai trách nhiệm, đều là nền (không UI, không state song song với
/// `AppContainerScanner`):
///  1. Lưu danh sách container đã tìm được vào plist kèm `fsid` + inode probe,
///     tự full lại sau 7 ngày, verify từng path bằng `fsgetpath`.
///  2. Điều phối 2 slot scan (app/extension và daemon): TTL 600 s, generation
///     bị hỏng khi refresh, caller cùng chạy chờ worker đang chạy thay vì
///     mỗi người tự quét 2.000.000 inode.
struct ContainerScanSnapshot: Codable {
    let version: Int
    let fsid0: Int32
    let fsid1: Int32
    let probe: Int64
    let fullAt: TimeInterval
    /// absolute container path -> inode lúc ghi nhận
    let entries: [String: Int64]
}

@_silgen_name("fsgetpath")
private func wq_fsgetpath(_ buf: UnsafeMutablePointer<CChar>,
                          _ buflen: Int,
                          _ fsid: UnsafeMutableRawPointer,
                          _ objid: UInt64) -> Int

enum ContainerScanCoordinator {

    // MARK: - Constants

    private static let version = 1
    private static let fullScanInterval: TimeInterval = 7 * 24 * 3600
    private static let slotTTL: TimeInterval = 600
    private static let inodeMargin: Int64 = 100_000
    private static let minimumUsefulPaths = 2
    private static let cacheFileName = "totorox-container-scan.plist"

    // The shared scan slots were removed together with the brute-force inode
    // fallback: WQFiles only keeps a verified checkpoint here.

    // MARK: - Pure decisions (unit-testable)

    static func isFresh(fullAt: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - fullAt
        return age >= 0 && age < fullScanInterval
    }

    static func probeIsUsable(_ probe: Int64, current: Int64) -> Bool {
        probe > 0 && current > 0 && probe <= current
    }

    static func slotIsFresh(at: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - at
        return age >= 0 && age < slotTTL
    }

    // MARK: - Volume probe (dynamic inode bound)

    private struct VolumeInfo {
        let fsid0: Int32
        let fsid1: Int32
        let probe: Int64
        let maxInode: Int64
    }

    private static func volumeInfo() -> VolumeInfo? {
        let directories = [
            NSTemporaryDirectory(),
            (NSHomeDirectory() as NSString).appendingPathComponent("Documents"),
            NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? ""
        ]
        for directory in directories where !directory.isEmpty {
            let probePath = (directory as NSString).appendingPathComponent(
                "ttx-inode-\(arc4random())")
            let fd = probePath.withCString {
                open($0, O_CREAT | O_EXCL | O_WRONLY, 0600)
            }
            guard fd >= 0 else { continue }
            var st = stat()
            var sfs = statfs()
            let ok = fstat(fd, &st) == 0 && fstatfs(fd, &sfs) == 0
            close(fd)
            _ = probePath.withCString { unlink($0) }
            guard ok else { continue }
            guard st.st_ino > 0, st.st_ino < UInt64(Int64.max - inodeMargin) else { continue }
            return VolumeInfo(fsid0: sfs.f_fsid.val.0,
                              fsid1: sfs.f_fsid.val.1,
                              probe: Int64(st.st_ino),
                              maxInode: Int64(st.st_ino) + inodeMargin)
        }
        return nil
    }

    private static func cacheURL() -> URL? {
        guard let dir = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory, .userDomainMask, true).first else { return nil }
        return URL(fileURLWithPath: (dir as NSString).appendingPathComponent(cacheFileName))
    }

    // MARK: - Persistent checkpoint

    /// Trả danh sách path còn tồn tại từ lần quét trước, hoặc nil nếu cần quét lại.
    static func cachedPaths() -> [String]? {
        guard let url = cacheURL(),
              let data = try? Data(contentsOf: url),
              let saved = try? PropertyListDecoder().decode(ContainerScanSnapshot.self, from: data),
              saved.version == version,
              let volume = volumeInfo(),
              saved.fsid0 == volume.fsid0, saved.fsid1 == volume.fsid1,
              probeIsUsable(saved.probe, current: volume.probe),
              isFresh(fullAt: saved.fullAt, now: Date().timeIntervalSince1970) else {
            return nil
        }

        var fsid = fsid_t()
        fsid.val.0 = volume.fsid0
        fsid.val.1 = volume.fsid1
        var kept: [String] = []
        var dropped = 0
        for (path, inode) in saved.entries {
            var buf = [CChar](repeating: 0, count: 1200)
            let resolved: String? = withUnsafeMutablePointer(to: &fsid) { fsidPtr in
                buf.withUnsafeMutableBufferPointer { bufPtr in
                    let n = wq_fsgetpath(bufPtr.baseAddress!, bufPtr.count,
                                         UnsafeMutableRawPointer(fsidPtr), UInt64(bitPattern: inode))
                    guard n > 0, n < bufPtr.count else { return nil }
                    bufPtr.baseAddress![n] = 0  // fsgetpath không đảm bảo NUL khi lấp đầy buffer
                    return String(cString: bufPtr.baseAddress!)
                }
            }
            if resolved == path {
                kept.append(path)
            } else {
                dropped += 1
            }
        }
        if dropped > 0 {
            log("scan: checkpoint dropped \(dropped) stale container path(s)")
        }
        return kept.count >= minimumUsefulPaths ? kept : nil
    }

    /// Ghi nhận kết quả quét; gọi sau mỗi lần enumerate thành công.
    static func record(paths: [String]) {
        guard paths.count >= minimumUsefulPaths, let volume = volumeInfo(), let url = cacheURL() else { return }
        var entries: [String: Int64] = [:]
        for path in paths {
            var st = stat()
            if lstat(path, &st) == 0, st.st_ino > 0 {
                entries[path] = Int64(st.st_ino)
            }
        }
        guard entries.count >= minimumUsefulPaths else { return }
        let snapshot = ContainerScanSnapshot(version: version,
                                             fsid0: volume.fsid0,
                                             fsid1: volume.fsid1,
                                             probe: volume.probe,
                                             fullAt: Date().timeIntervalSince1970,
                                             entries: entries)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Refresh của người dùng: xoá checkpoint plist. RAM cache đã nằm trong
    /// ContainerMetadataCache và được invalidate ở luồng gọi khác.
    static func invalidate() {
        if let url = cacheURL() { try? FileManager.default.removeItem(at: url) }
        log("scan: checkpoint invalidated")
    }
}
