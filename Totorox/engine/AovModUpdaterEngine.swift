import Foundation
import CryptoKit

// MARK: - Domain Models

public struct CachedResourcesSnapshot: Codable, Equatable, Sendable {
    public let sha256: String
    public let gameVersion: String
    public let versionTxt: String
    public let sourceLabel: String
    public let snapshotBytes: Int64
    public let totalSourceEntries: Int
    public let cachedAt: Date
    public let snapshotFileName: String

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: snapshotBytes, countStyle: .file)
    }
}

public struct UpdatedModOutput: Equatable, Sendable {
    public let outputURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let targetGameVersion: String
    public let engineTier: String
    public let preservedBundleCount: Int
    let inspection: ModUpdaterInspectionResponse?

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

public enum AovModUpdaterError: LocalizedError {
    case notAuthenticated
    case gameContainerNotFound
    case invalidResourcesSource(String)
    case invalidOldModArchive(String)
    case serverFailure(String)

    public var errorDescription: String? {
        let lang = AppLanguage.current
        switch self {
        case .notAuthenticated:
            return lang.text("modupdater.error.not_authenticated")
        case .gameContainerNotFound:
            return lang.text("modupdater.error.game_not_found")
        case .invalidResourcesSource(let detail):
            return detail
        case .invalidOldModArchive(let detail):
            return detail
        case .serverFailure(let detail):
            return detail
        }
    }
}

// MARK: - Smart Thin-Client Engine + Persistent Local/Server SHA-256 Cache

/// Quản lý trích xuất thông minh `Resources gốc` (hỗ trợ cả file ZIP64 > 8 GB mà không tốn RAM),
/// lưu bộ đệm vĩnh viễn theo phiên bản trên máy (~18 MB), đồng bộ chống trùng lặp SHA-256
/// với máy chủ và ghép luồng không giải nén cho `.assetbundle` / `.bnk` nặng của bản mod cũ.
public final class AovModUpdaterEngine: @unchecked Sendable {
    public static let shared = AovModUpdaterEngine()

    public static let virtualPathsManifestName = "__totorox_virtual_paths.txt"
    public static let oldModBundlesManifestName = "__totorox_old_mod_bundles.json"
    private static let cacheMetaFileName = "snapshot_meta_v1.json"
    private static let maxRetainedOutputs = 5

    private init() {}

    // MARK: - Directories & Persistent Snapshot Cache

    private func cacheDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("TotoroxResourcesCache", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func outputDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("TotoroxUpdatedMods", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public func loadCachedSnapshot() -> (meta: CachedResourcesSnapshot, fileURL: URL)? {
        guard let dir = try? cacheDirectoryURL() else { return nil }
        let metaURL = dir.appendingPathComponent(Self.cacheMetaFileName)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CachedResourcesSnapshot.self, from: data) else {
            return nil
        }
        let snapURL = dir.appendingPathComponent(meta.snapshotFileName)
        guard FileManager.default.fileExists(atPath: snapURL.path) else {
            return nil
        }
        return (meta, snapURL)
    }

    public func clearCache() {
        guard let dir = try? cacheDirectoryURL() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private func persistSnapshot(
        stagedZipURL: URL,
        gameVersion: String,
        versionTxt: String,
        sourceLabel: String,
        totalSourceEntries: Int
    ) throws -> (meta: CachedResourcesSnapshot, fileURL: URL) {
        let fm = FileManager.default
        let sha256 = try Self.computeFileSHA256(at: stagedZipURL)
        let dir = try cacheDirectoryURL()
        let finalFileName = "resources_\(sha256.prefix(16)).zip"
        let finalURL = dir.appendingPathComponent(finalFileName)

        // Dọn dẹp toàn bộ bản snapshot cũ để bộ nhớ máy luôn chỉ giữ đúng 1 bản mới nhất (~18-22 MB)
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent != finalFileName {
                try? fm.removeItem(at: item)
            }
        }
        if fm.fileExists(atPath: finalURL.path) {
            try? fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: stagedZipURL, to: finalURL)

        let snapSize = Int64((try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let meta = CachedResourcesSnapshot(
            sha256: sha256,
            gameVersion: gameVersion,
            versionTxt: versionTxt.isEmpty ? gameVersion : versionTxt,
            sourceLabel: sourceLabel,
            snapshotBytes: snapSize,
            totalSourceEntries: totalSourceEntries,
            cachedAt: Date(),
            snapshotFileName: finalFileName
        )
        let metaData = try JSONEncoder().encode(meta)
        try metaData.write(to: dir.appendingPathComponent(Self.cacheMetaFileName), options: .atomic)
        return (meta, finalURL)
    }

    // MARK: - Config Path Classification

    /// Chỉ giữ các bảng cấu hình nhẹ (~18-24 MB) cần thiết cho Server biên dịch Mod,
    /// bỏ qua hàng chục nghìn file 3D/Sound nặng hàng GB.
    public static func isResourcesSnapshotConfigRel(_ relLower: String) -> Bool {
        if relLower == "version.txt" { return true }
        if relLower == "kernellua.pkg.bytes" || relLower == "stablesystems_3.pkg.bytes" { return true }
        if relLower.hasPrefix("databin/") || relLower.hasPrefix("thanos/") || relLower.hasPrefix("assetrefs/") {
            return true
        }
        if relLower.hasPrefix("languages/vn_garena_vn/") || relLower.hasPrefix("languages/en_garena_vn/") {
            return true
        }
        if relLower.hasPrefix("ages/prefab_characters/") || relLower.hasPrefix("prefab_characters/") {
            return relLower.hasSuffix(".pkg.bytes") || relLower.hasSuffix(".bytes")
        }
        if relLower == "assetbundle/resourcepackerinfosetall.assetbundle"
            || relLower == "assetbundle/resourceverificationinfosetall.assetbundle" {
            return true
        }
        return false
    }

    public static func isHeavyBinaryAssetInOldMod(_ relLower: String) -> Bool {
        if relLower.hasSuffix(".bnk") { return true }
        guard relLower.hasSuffix(".assetbundle") else { return false }
        if relLower.hasSuffix("resourcepackerinfosetall.assetbundle")
            || relLower.hasSuffix("resourceverificationinfosetall.assetbundle") {
            return false
        }
        if relLower.contains("loadingnotice") || relLower.contains("allshared") {
            return false
        }
        if relLower.hasPrefix("vanhoc_milo/")
            || relLower.hasPrefix("totorox_mod/")
            || relLower.hasPrefix("vannhoc_mod/")
            || relLower.contains("kpm_mod_") {
            return false
        }
        return true
    }

    // MARK: - 1. Build Compact Snapshot from File / Folder / Installed Game

    public func prepareResourcesSnapshot(
        from sourceURL: URL,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> (meta: CachedResourcesSnapshot, fileURL: URL) {
        try await Task.detached(priority: .userInitiated) {
            let hasScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasScope { sourceURL.stopAccessingSecurityScopedResource() }
            }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
                throw AovModUpdaterError.invalidResourcesSource(
                    AppLanguage.current.text("modupdater.error.invalid_resources")
                )
            }

            if isDir.boolValue {
                return try self.buildSnapshotFromDirectory(
                    rootURL: sourceURL,
                    sourceLabel: sourceURL.lastPathComponent,
                    progress: progress
                )
            } else {
                return try self.buildSnapshotFromLargeZip(
                    zipURL: sourceURL,
                    sourceLabel: sourceURL.lastPathComponent,
                    progress: progress
                )
            }
        }.value
    }

    public func prepareResourcesSnapshotFromInstalledGame(
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> (meta: CachedResourcesSnapshot, fileURL: URL) {
        try await Task.detached(priority: .userInitiated) {
            progress(AppLanguage.current.text("modupdater.progress.locating_game"), 0.08)

            let candidates = CatalogGameID.aov.bundleCandidates
            var resolvedContainer: String?
            for bid in candidates {
                if let path = ContainerStore.resolveAppContainerPath(bundleID: bid)
                    ?? ContainerStore.launchServicesExistingContainerPath(for: bid) {
                    _ = ContainerStore.grantContainerAccess(path, requireWrite: false)
                    let docsRes = (path as NSString).appendingPathComponent("Documents/Resources")
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: docsRes, isDirectory: &isDir), isDir.boolValue {
                        resolvedContainer = docsRes
                        break
                    }
                }
            }

            guard let resourcesDirPath = resolvedContainer else {
                throw AovModUpdaterError.gameContainerNotFound
            }

            return try self.buildSnapshotFromDirectory(
                rootURL: URL(fileURLWithPath: resourcesDirPath, isDirectory: true),
                sourceLabel: "Liên Quân Mobile (Trên máy)",
                progress: progress
            )
        }.value
    }

    // MARK: - Streaming ZIP64 Central Directory Reader (Supports > 8 GB with < 5 MB RAM)

    private struct LargeZipCDEntry {
        let filename: String
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let bitFlags: UInt16
    }

    private func readLargeZipCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> [LargeZipCDEntry] {
        guard fileSize >= 22 else {
            throw AovModUpdaterError.invalidResourcesSource(AppLanguage.current.text("modupdater.error.invalid_resources"))
        }
        let tailLen = Int(min(fileSize, 131_072))
        let tailStart = fileSize - UInt64(tailLen)
        try handle.seek(toOffset: tailStart)
        guard let tail = try handle.read(upToCount: tailLen), tail.count >= 22 else {
            throw AovModUpdaterError.invalidResourcesSource(AppLanguage.current.text("modupdater.error.invalid_resources"))
        }

        var eocdPos: Int?
        for idx in stride(from: tail.count - 22, through: 0, by: -1) {
            if Self.readU32LE(tail, idx) == 0x0605_4b50 {
                eocdPos = idx
                break
            }
        }
        guard let eocdIdx = eocdPos else {
            throw AovModUpdaterError.invalidResourcesSource(AppLanguage.current.text("modupdater.error.invalid_resources"))
        }

        var totalEntries = UInt64(Self.readU16LE(tail, eocdIdx + 10))
        var cdSize = UInt64(Self.readU32LE(tail, eocdIdx + 12))
        var cdOffset = UInt64(Self.readU32LE(tail, eocdIdx + 16))

        // Hỗ trợ đầy đủ ZIP64 EOCD Locator (0x07064b50) & ZIP64 EOCD Record (0x06064b50) cho Resources > 4 GB
        if eocdIdx >= 20, Self.readU32LE(tail, eocdIdx - 20) == 0x0706_4b50 {
            let zip64EOCDOffset = Self.readU64LE(tail, eocdIdx - 12)
            if zip64EOCDOffset + 56 <= fileSize {
                try handle.seek(toOffset: zip64EOCDOffset)
                if let z64 = try handle.read(upToCount: 56),
                   z64.count >= 56,
                   Self.readU32LE(z64, 0) == 0x0606_4b50 {
                    totalEntries = Self.readU64LE(z64, 32)
                    cdSize = Self.readU64LE(z64, 40)
                    cdOffset = Self.readU64LE(z64, 48)
                }
            }
        }

        guard cdSize > 0, cdSize <= 64 * 1024 * 1024, cdOffset + cdSize <= fileSize else {
            throw AovModUpdaterError.invalidResourcesSource(AppLanguage.current.text("modupdater.error.invalid_resources"))
        }

        try handle.seek(toOffset: cdOffset)
        guard let cdData = try handle.read(upToCount: Int(cdSize)), cdData.count == Int(cdSize) else {
            throw AovModUpdaterError.invalidResourcesSource(AppLanguage.current.text("modupdater.error.invalid_resources"))
        }

        var entries: [LargeZipCDEntry] = []
        entries.reserveCapacity(Int(min(totalEntries, 80_000)))
        var pos = 0
        while pos + 46 <= cdData.count {
            guard Self.readU32LE(cdData, pos) == 0x0201_4b50 else { break }
            let bitFlags = Self.readU16LE(cdData, pos + 8)
            let method = Self.readU16LE(cdData, pos + 10)
            let crc = Self.readU32LE(cdData, pos + 16)
            var compSz = UInt64(Self.readU32LE(cdData, pos + 20))
            var uncompSz = UInt64(Self.readU32LE(cdData, pos + 24))
            let nameLen = Int(Self.readU16LE(cdData, pos + 28))
            let extraLen = Int(Self.readU16LE(cdData, pos + 30))
            let commentLen = Int(Self.readU16LE(cdData, pos + 32))
            var localOff = UInt64(Self.readU32LE(cdData, pos + 42))

            let nameStart = pos + 46
            let extraStart = nameStart + nameLen
            let nextPos = extraStart + extraLen + commentLen
            guard nextPos <= cdData.count else { break }

            let nameSlice = cdData.subdata(in: nameStart..<extraStart)
            let filename = String(data: nameSlice, encoding: .utf8)
                ?? String(data: nameSlice, encoding: .isoLatin1)
                ?? ""

            if uncompSz == 0xFFFF_FFFF || compSz == 0xFFFF_FFFF || localOff == 0xFFFF_FFFF {
                var eCursor = extraStart
                let eEnd = extraStart + extraLen
                while eCursor + 4 <= eEnd {
                    let tag = Self.readU16LE(cdData, eCursor)
                    let bSize = Int(Self.readU16LE(cdData, eCursor + 2))
                    var bCur = eCursor + 4
                    let bEnd = min(bCur + bSize, eEnd)
                    if tag == 0x0001 {
                        if uncompSz == 0xFFFF_FFFF && bCur + 8 <= bEnd {
                            uncompSz = Self.readU64LE(cdData, bCur)
                            bCur += 8
                        }
                        if compSz == 0xFFFF_FFFF && bCur + 8 <= bEnd {
                            compSz = Self.readU64LE(cdData, bCur)
                            bCur += 8
                        }
                        if localOff == 0xFFFF_FFFF && bCur + 8 <= bEnd {
                            localOff = Self.readU64LE(cdData, bCur)
                        }
                        break
                    }
                    eCursor += 4 + bSize
                }
            }

            pos = nextPos
            if !filename.isEmpty && !filename.hasSuffix("/") {
                entries.append(
                    LargeZipCDEntry(
                        filename: filename,
                        compressionMethod: method,
                        crc32: crc,
                        compressedSize: compSz,
                        uncompressedSize: uncompSz,
                        localHeaderOffset: localOff,
                        bitFlags: bitFlags
                    )
                )
            }
        }
        return entries
    }

    private func buildSnapshotFromLargeZip(
        zipURL: URL,
        sourceLabel: String,
        progress: @escaping @Sendable (String, Double) -> Void
    ) throws -> (meta: CachedResourcesSnapshot, fileURL: URL) {
        try Task.checkCancellation()
        progress(AppLanguage.current.text("modupdater.progress.indexing_resources"), 0.12)

        let fileSize = UInt64((try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }

        let cdEntries = try readLargeZipCentralDirectory(handle: handle, fileSize: fileSize)
        guard !cdEntries.isEmpty else {
            throw AovModUpdaterError.invalidResourcesSource(AppLanguage.current.text("modupdater.error.invalid_resources"))
        }

        // Phát hiện số phiên bản game (VD: 1.64.1)
        var detectedVersion: String?
        for entry in cdEntries {
            if let norm = AovModMergerEngine.normalizeAovPath(entry.filename) {
                let parts = norm.split(separator: "/")
                if parts.count >= 3, parts[0].caseInsensitiveCompare("Resources") == .orderedSame {
                    detectedVersion = String(parts[1])
                    break
                }
            }
        }
        let fallbackVer = detectedVersion ?? "1.64.1"

        var configEntries: [(rel: String, entry: LargeZipCDEntry)] = []
        var virtualLines: [String] = []
        virtualLines.reserveCapacity(cdEntries.count)
        var hasHeroSkinBytes = false

        for entry in cdEntries {
            guard (entry.bitFlags & 0x0001) == 0 else { continue }
            guard let norm = AovModMergerEngine.normalizeAovPath(entry.filename, fallbackVersion: fallbackVer) else {
                continue
            }
            let parts = norm.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let rel = String(parts[2])
            let relLow = rel.lowercased()

            if Self.isResourcesSnapshotConfigRel(relLow),
               entry.compressedSize <= UInt64(UInt32.max),
               entry.uncompressedSize <= UInt64(UInt32.max) {
                if relLow == "databin/client/actor/heroskin.bytes" {
                    hasHeroSkinBytes = true
                }
                configEntries.append((rel: rel, entry: entry))
            } else {
                virtualLines.append("\(rel)\t\(entry.uncompressedSize)\t\(entry.crc32)")
            }
        }

        guard hasHeroSkinBytes, !configEntries.isEmpty else {
            throw AovModUpdaterError.invalidResourcesSource(
                AppLanguage.current.text("modupdater.error.missing_heroskin_table")
            )
        }

        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("totorox_res_snap_\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let writer = try PatchZipConverter.ZipArchiveWriter(destinationURL: stagingURL)
        defer { writer.cancel() }

        var versionTxtContent = ""
        let totalCfg = max(configEntries.count, 1)

        for (idx, item) in configEntries.enumerated() {
            try Task.checkCancellation()
            let e = item.entry
            try handle.seek(toOffset: e.localHeaderOffset)
            guard let lh = try handle.read(upToCount: 30),
                  lh.count == 30,
                  Self.readU32LE(lh, 0) == 0x0403_4b50 else {
                continue
            }
            let lNameLen = UInt64(Self.readU16LE(lh, 26))
            let lExtraLen = UInt64(Self.readU16LE(lh, 28))
            let payloadOff = e.localHeaderOffset + 30 + lNameLen + lExtraLen

            if item.rel.lowercased() == "version.txt", e.uncompressedSize <= 4096 {
                try handle.seek(toOffset: payloadOff)
                if let rawV = try handle.read(upToCount: Int(e.compressedSize)) {
                    let fakeHeader = PatchZipConverter.ZipArchiveEntryHeader(
                        path: e.filename,
                        compressionMethod: e.compressionMethod,
                        crc32: e.crc32,
                        compressedSize: UInt32(e.compressedSize),
                        uncompressedSize: UInt32(e.uncompressedSize),
                        localHeaderOffset: 0,
                        payloadOffset: 0
                    )
                    if e.compressionMethod == 0 {
                        versionTxtContent = String(data: rawV, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    } else if let dec = try? PatchZipConverter.shared.extractZipEntry(header: fakeHeader, from: zipURL) {
                        versionTxtContent = String(data: dec, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                }
            }

            try writer.copyRawEntry(
                destinationPath: "Resources/\(fallbackVer)/\(item.rel)",
                from: handle,
                payloadOffset: payloadOff,
                compressedSize: UInt32(e.compressedSize),
                uncompressedSize: UInt32(e.uncompressedSize),
                compressionMethod: e.compressionMethod,
                crc32: e.crc32
            )

            if idx % 40 == 0 || idx + 1 == totalCfg {
                let frac = 0.15 + 0.78 * (Double(idx + 1) / Double(totalCfg))
                progress(
                    AppLanguage.current.text("modupdater.progress.extracting_snapshot", idx + 1, totalCfg),
                    frac
                )
            }
        }

        let manifestText = virtualLines.joined(separator: "\n") + "\n"
        try writer.add(path: Self.virtualPathsManifestName, data: Data(manifestText.utf8))
        try writer.finish()

        progress(AppLanguage.current.text("modupdater.progress.saving_cache"), 0.96)
        let finalVer = Self.extractShortGameVersion(from: versionTxtContent) ?? fallbackVer
        return try persistSnapshot(
            stagedZipURL: stagingURL,
            gameVersion: finalVer,
            versionTxt: versionTxtContent,
            sourceLabel: sourceLabel,
            totalSourceEntries: cdEntries.count
        )
    }

    private func buildSnapshotFromDirectory(
        rootURL: URL,
        sourceLabel: String,
        progress: @escaping @Sendable (String, Double) -> Void
    ) throws -> (meta: CachedResourcesSnapshot, fileURL: URL) {
        try Task.checkCancellation()
        progress(AppLanguage.current.text("modupdater.progress.indexing_resources"), 0.12)

        let fm = FileManager.default
        var scanRoot = rootURL
        var detectedVersion = "1.64.1"

        // Nếu thư mục chọn là `Resources/` chứa các thư mục con `1.64.1`, chọn bản cao nhất
        let resCandidate = fm.fileExists(atPath: rootURL.appendingPathComponent("Resources").path)
            ? rootURL.appendingPathComponent("Resources", isDirectory: true)
            : rootURL

        if let subItems = try? fm.contentsOfDirectory(at: resCandidate, includingPropertiesForKeys: [.isDirectoryKey]) {
            let verDirs = subItems.filter { url in
                let isD = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = url.lastPathComponent
                return isD && name.contains(".") && name.first?.isNumber == true
            }
            if let highest = verDirs.max(by: { Self.compareVersionStrings($0.lastPathComponent, $1.lastPathComponent) < 0 }) {
                scanRoot = highest
                detectedVersion = highest.lastPathComponent
            }
        }

        guard let enumerator = fm.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AovModUpdaterError.invalidResourcesSource(AppLanguage.current.text("modupdater.error.invalid_resources"))
        }

        var configFiles: [(rel: String, url: URL)] = []
        var virtualLines: [String] = []
        var totalEntries = 0
        var hasHeroSkin = false
        let basePrefix = scanRoot.standardizedFileURL.path

        while let fileURL = enumerator.nextObject() as? URL {
            let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard vals?.isRegularFile == true else { continue }
            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(basePrefix) else { continue }
            var rel = String(fullPath.dropFirst(basePrefix.count)).replacingOccurrences(of: "\\", with: "/")
            while rel.hasPrefix("/") { rel.removeFirst() }
            if let norm = AovModMergerEngine.normalizeAovPath(rel, fallbackVersion: detectedVersion) {
                let parts = norm.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count == 3 {
                    detectedVersion = String(parts[1])
                    rel = String(parts[2])
                }
            }
            guard !rel.isEmpty else { continue }
            totalEntries += 1
            let relLow = rel.lowercased()
            if Self.isResourcesSnapshotConfigRel(relLow) {
                if relLow == "databin/client/actor/heroskin.bytes" { hasHeroSkin = true }
                configFiles.append((rel: rel, url: fileURL))
            } else {
                let sz = vals?.fileSize ?? -1
                virtualLines.append("\(rel)\t\(sz)\t0")
            }
        }

        guard hasHeroSkin, !configFiles.isEmpty else {
            throw AovModUpdaterError.invalidResourcesSource(
                AppLanguage.current.text("modupdater.error.missing_heroskin_table")
            )
        }

        let stagingURL = fm.temporaryDirectory.appendingPathComponent("totorox_dir_snap_\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: stagingURL) }

        let writer = try PatchZipConverter.ZipArchiveWriter(destinationURL: stagingURL)
        defer { writer.cancel() }

        var versionTxt = ""
        let totalCfg = max(configFiles.count, 1)
        for (idx, item) in configFiles.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let data = try Data(contentsOf: item.url)
                if item.rel.lowercased() == "version.txt" {
                    versionTxt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                try writer.add(path: "Resources/\(detectedVersion)/\(item.rel)", data: data)
            }
            if idx % 30 == 0 || idx + 1 == totalCfg {
                let frac = 0.15 + 0.78 * (Double(idx + 1) / Double(totalCfg))
                progress(
                    AppLanguage.current.text("modupdater.progress.extracting_snapshot", idx + 1, totalCfg),
                    frac
                )
            }
        }

        let manifestText = virtualLines.joined(separator: "\n") + "\n"
        try writer.add(path: Self.virtualPathsManifestName, data: Data(manifestText.utf8))
        try writer.finish()

        let finalVer = Self.extractShortGameVersion(from: versionTxt) ?? detectedVersion
        return try persistSnapshot(
            stagedZipURL: stagingURL,
            gameVersion: finalVer,
            versionTxt: versionTxt,
            sourceLabel: sourceLabel,
            totalSourceEntries: totalEntries
        )
    }

    // MARK: - 2. Server Sync + Thin Old-Mod Slicing + Zero-Decompression Repack

    private func ensureSnapshotSyncedOnServer(
        snapshot: (meta: CachedResourcesSnapshot, fileURL: URL),
        token: String,
        hwid: String,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws {
        progress(AppLanguage.current.text("modupdater.progress.checking_server_cache"), 0.18)
        let statusRes = await APIService.shared.checkModUpdaterResourcesStatus(
            sha256: snapshot.meta.sha256,
            token: token,
            hwid: hwid
        )
        if case .success(let st) = statusRes, st.cached {
            return
        }

        progress(AppLanguage.current.text("modupdater.progress.uploading_resources"), 0.24)
        let uploadRes = await APIService.shared.uploadModUpdaterResourcesSnapshot(
            fileURL: snapshot.fileURL,
            sha256: snapshot.meta.sha256,
            token: token,
            hwid: hwid
        ) { idx, total in
            let frac = 0.24 + 0.24 * (Double(idx) / Double(max(total, 1)))
            progress(AppLanguage.current.text("merge.progress.uploading_chunk", idx, total), frac)
        }
        if case .failure(let err) = uploadRes {
            throw AovModUpdaterError.serverFailure(err.localizedDescription)
        }
    }

    private struct PreparedOldModSlice {
        let uploadFileURL: URL
        let unwrappedZipURL: URL?
        let isTemporaryUploadFile: Bool
        let localHeavyHeadersByRelLower: [String: PatchZipConverter.ZipArchiveEntryHeader]
    }

    /// Nếu gói mod cũ là `.zip` nặng chứa `.assetbundle` / `.bnk` 3D, chỉ rút cấu hình nhẹ gửi lên Server
    /// và giữ danh sách header `.assetbundle` / `.bnk` để ghép luồng trực tiếp tại máy sau khi Server trả kết quả.
    private func prepareOldModUploadSlice(
        oldModURL: URL,
        workDir: URL
    ) throws -> PreparedOldModSlice {
        let hasScope = oldModURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { oldModURL.stopAccessingSecurityScopedResource() }
        }

        let handle = try FileHandle(forReadingFrom: oldModURL)
        let magic = (try? handle.read(upToCount: 10)) ?? Data()
        try? handle.close()

        // Gói `.3105` mã hóa -> gửi nguyên tệp lên Server giải mã
        if magic.starts(with: Data("3105PATCH\0".utf8)) || oldModURL.pathExtension.lowercased() == "3105" {
            let copied = workDir.appendingPathComponent(oldModURL.lastPathComponent)
            try FileManager.default.copyItem(at: oldModURL, to: copied)
            return PreparedOldModSlice(
                uploadFileURL: copied,
                unwrappedZipURL: nil,
                isTemporaryUploadFile: true,
                localHeavyHeadersByRelLower: [:]
            )
        }

        // Bóc tự động nếu là `.zip` bọc ngoài (chứa `Resources.zip` bên trong)
        let effectiveZipURL = try AovModMergerEngine.unwrapNestedModArchiveIfNeeded(at: oldModURL, into: workDir)
        let headers = try PatchZipConverter.shared.readZipArchiveHeaders(from: effectiveZipURL)
        guard !headers.isEmpty else {
            throw AovModUpdaterError.invalidOldModArchive(
                AppLanguage.current.text("merge.error.empty_zip", oldModURL.lastPathComponent)
            )
        }

        let srcHandle = try FileHandle(forReadingFrom: effectiveZipURL)
        defer { try? srcHandle.close() }

        let thinURL = workDir.appendingPathComponent("thin_old_mod.zip")
        let writer = try PatchZipConverter.ZipArchiveWriter(destinationURL: thinURL)
        defer { writer.cancel() }

        var manifestObjects: [[String: Any]] = []
        var heavyMap: [String: PatchZipConverter.ZipArchiveEntryHeader] = [:]

        for rawPath in headers.keys.sorted() {
            guard let hdr = headers[rawPath], !hdr.isEncrypted else { continue }
            guard let norm = AovModMergerEngine.normalizeAovPath(rawPath, fallbackVersion: "1.64.1") else {
                continue
            }
            let parts = norm.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let rel = String(parts[2])
            let relLow = rel.lowercased()

            if Self.isHeavyBinaryAssetInOldMod(relLow) {
                manifestObjects.append([
                    "rel": rel,
                    "size": Int(hdr.uncompressedSize),
                    "crc32": UInt(hdr.crc32),
                ])
                heavyMap[relLow] = hdr
            } else {
                try writer.copyRawEntry(
                    destinationPath: norm,
                    from: srcHandle,
                    payloadOffset: hdr.payloadOffset,
                    compressedSize: hdr.compressedSize,
                    uncompressedSize: hdr.uncompressedSize,
                    compressionMethod: hdr.compressionMethod,
                    crc32: hdr.crc32
                )
            }
        }

        if !manifestObjects.isEmpty {
            let jsonData = try JSONSerialization.data(withJSONObject: manifestObjects, options: [])
            try writer.add(path: Self.oldModBundlesManifestName, data: jsonData)
        }
        try writer.finish()

        return PreparedOldModSlice(
            uploadFileURL: thinURL,
            unwrappedZipURL: effectiveZipURL,
            isTemporaryUploadFile: true,
            localHeavyHeadersByRelLower: heavyMap
        )
    }

    func inspectOldMod(
        snapshot: (meta: CachedResourcesSnapshot, fileURL: URL),
        oldModURL: URL,
        inputPassword: String?,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> ModUpdaterInspectionResponse {
        let token = await LicenseManager.shared.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AovModUpdaterError.notAuthenticated }
        let hwid = await LicenseManager.shared.deviceIdentifier

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TotoroxUpdInspect_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        try await ensureSnapshotSyncedOnServer(snapshot: snapshot, token: token, hwid: hwid, progress: progress)
        try Task.checkCancellation()

        progress(AppLanguage.current.text("modupdater.progress.preparing_old_mod"), 0.52)
        let slice = try await Task.detached(priority: .userInitiated) {
            try self.prepareOldModUploadSlice(oldModURL: oldModURL, workDir: workDir)
        }.value

        progress(AppLanguage.current.text("modupdater.progress.inspecting_server"), 0.75)
        let res = await APIService.shared.inspectOldModOnServer(
            resourcesSHA256: snapshot.meta.sha256,
            fileURL: slice.uploadFileURL,
            fileName: oldModURL.lastPathComponent,
            inputPassword: inputPassword,
            token: token,
            hwid: hwid
        )
        switch res {
        case .success(let insp):
            progress(AppLanguage.current.text("merge.progress.done"), 1.0)
            return insp
        case .failure(let err):
            throw AovModUpdaterError.serverFailure(err.localizedDescription)
        }
    }

    func updateOldMod(
        snapshot: (meta: CachedResourcesSnapshot, fileURL: URL),
        oldModURL: URL,
        inputPassword: String?,
        upgradeMissingFeatures: Bool,
        gateID: String? = nil,
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> UpdatedModOutput {
        let token = await LicenseManager.shared.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AovModUpdaterError.notAuthenticated }
        let hwid = await LicenseManager.shared.deviceIdentifier

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TotoroxUpdRun_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        try await ensureSnapshotSyncedOnServer(snapshot: snapshot, token: token, hwid: hwid, progress: progress)
        try Task.checkCancellation()

        progress(AppLanguage.current.text("modupdater.progress.preparing_old_mod"), 0.50)
        let slice = try await Task.detached(priority: .userInitiated) {
            try self.prepareOldModUploadSlice(oldModURL: oldModURL, workDir: workDir)
        }.value

        var optsDict: [String: Any] = [
            "upgrade_missing_features": upgradeMissingFeatures,
            "preserve_custom_assetbundles": true,
            "output_format": "zip",
        ]
        if let pw = inputPassword?.trimmingCharacters(in: .whitespacesAndNewlines), !pw.isEmpty {
            optsDict["input_password"] = pw
        }
        let optsData = try JSONSerialization.data(withJSONObject: optsDict, options: [])
        let optsJSON = String(data: optsData, encoding: .utf8) ?? "{}"

        let serverZipURL = workDir.appendingPathComponent("server_compiled.zip")
        progress(AppLanguage.current.text("modupdater.progress.updating_on_server"), 0.62)

        let updRes = await APIService.shared.updateOldModOnServer(
            resourcesSHA256: snapshot.meta.sha256,
            fileURL: slice.uploadFileURL,
            fileName: oldModURL.lastPathComponent,
            optionsJSON: optsJSON,
            destinationURL: serverZipURL,
            token: token,
            hwid: hwid,
            gateID: gateID
        ) { idx, total in
            let frac = 0.54 + 0.12 * (Double(idx) / Double(max(total, 1)))
            progress(AppLanguage.current.text("merge.progress.uploading_chunk", idx, total), frac)
        }

        let response: ModUpdaterUpdateResponse
        switch updRes {
        case .success(let resp):
            response = resp
        case .failure(let err):
            throw AovModUpdaterError.serverFailure(err.localizedDescription)
        }

        try Task.checkCancellation()
        progress(AppLanguage.current.text("modupdater.progress.repacking_output"), 0.88)

        let outDir = try outputDirectoryURL()
        Self.pruneOldOutputs(in: outDir)

        let safeName = (response.filename as NSString).lastPathComponent
        let finalURL = outDir.appendingPathComponent(safeName.isEmpty ? "Updated_Mod.zip" : safeName)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
        }

        let repackRels = response.clientRepackBundlePaths ?? []
        let targetVer = response.targetGameVersion ?? snapshot.meta.gameVersion

        if !repackRels.isEmpty,
           let localZipURL = slice.unwrappedZipURL,
           !slice.localHeavyHeadersByRelLower.isEmpty {
            // Ghép luồng không giải nén: toàn bộ entry từ `serverZipURL` + các `.assetbundle`/`.bnk` tùy biến trên máy
            try await Task.detached(priority: .userInitiated) {
                let hasScope = oldModURL.startAccessingSecurityScopedResource()
                defer {
                    if hasScope { oldModURL.stopAccessingSecurityScopedResource() }
                }

                let serverHeaders = try PatchZipConverter.shared.readZipArchiveHeaders(from: serverZipURL)
                let serverHandle = try FileHandle(forReadingFrom: serverZipURL)
                defer { try? serverHandle.close() }

                let localHandle = try FileHandle(forReadingFrom: localZipURL)
                defer { try? localHandle.close() }

                let writer = try PatchZipConverter.ZipArchiveWriter(destinationURL: finalURL)
                defer { writer.cancel() }

                var writtenLower = Set<String>()
                for sPath in serverHeaders.keys.sorted() {
                    guard let sh = serverHeaders[sPath] else { continue }
                    writtenLower.insert(sPath.lowercased())
                    try writer.copyRawEntry(
                        destinationPath: sPath,
                        from: serverHandle,
                        payloadOffset: sh.payloadOffset,
                        compressedSize: sh.compressedSize,
                        uncompressedSize: sh.uncompressedSize,
                        compressionMethod: sh.compressionMethod,
                        crc32: sh.crc32
                    )
                }

                for rel in repackRels {
                    let cleanRel = rel.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let destArc = "Resources/\(targetVer)/\(cleanRel)"
                    guard !writtenLower.contains(destArc.lowercased()),
                          let lh = slice.localHeavyHeadersByRelLower[cleanRel.lowercased()] else {
                        continue
                    }
                    writtenLower.insert(destArc.lowercased())
                    try writer.copyRawEntry(
                        destinationPath: destArc,
                        from: localHandle,
                        payloadOffset: lh.payloadOffset,
                        compressedSize: lh.compressedSize,
                        uncompressedSize: lh.uncompressedSize,
                        compressionMethod: lh.compressionMethod,
                        crc32: lh.crc32
                    )
                }

                try writer.finish()
            }.value
        } else {
            try FileManager.default.moveItem(at: serverZipURL, to: finalURL)
        }

        let finalSize = Int64((try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        progress(AppLanguage.current.text("merge.progress.done"), 1.0)

        return UpdatedModOutput(
            outputURL: finalURL,
            fileName: finalURL.lastPathComponent,
            fileSize: finalSize,
            targetGameVersion: targetVer,
            engineTier: response.engineTier ?? "native_rebuild",
            preservedBundleCount: response.inspection?.customAssetbundleCount ?? repackRels.count,
            inspection: response.inspection
        )
    }

    // MARK: - Low-Level Byte & File Helpers

    private static func pruneOldOutputs(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), items.count >= maxRetainedOutputs else {
            return
        }
        let sorted = items.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for old in sorted.dropFirst(maxRetainedOutputs - 1) {
            try? fm.removeItem(at: old)
        }
    }

    public static func computeFileSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extractShortGameVersion(from rawVersionTxt: String) -> String? {
        let trimmed = rawVersionTxt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let left = trimmed.split(separator: "|", maxSplits: 1).first.map(String.init) ?? trimmed
        let comps = left.split(separator: ".").map(String.init)
        if comps.count >= 3, comps.prefix(3).allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return comps.prefix(3).joined(separator: ".")
        }
        return nil
    }

    private static func compareVersionStrings(_ lhs: String, _ rhs: String) -> Int {
        let la = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let ra = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for idx in 0..<max(la.count, ra.count) {
            let lv = idx < la.count ? la[idx] : 0
            let rv = idx < ra.count ? ra[idx] : 0
            if lv != rv { return lv < rv ? -1 : 1 }
        }
        return 0
    }

    private static func readU16LE(_ data: Data, _ offset: Int) -> UInt16 {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
        }
    }

    private static func readU32LE(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return UInt32(base[offset])
                | (UInt32(base[offset + 1]) << 8)
                | (UInt32(base[offset + 2]) << 16)
                | (UInt32(base[offset + 3]) << 24)
        }
    }

    private static func readU64LE(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readU32LE(data, offset)) | (UInt64(readU32LE(data, offset + 4)) << 32)
    }
}
