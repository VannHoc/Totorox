import Foundation
import CryptoKit

// MARK: - Models & Errors

public struct AovModSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let fileName: String
    public let fileSize: Int64
    public let heroID: Int?
    public let skinID: Int?
    public let heroIDs: [Int]
    public let skinIDs: [Int]
    public let resourceVersion: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        fileSize: Int64,
        heroID: Int?,
        skinID: Int?,
        resourceVersion: String?,
        heroIDs: [Int]? = nil,
        skinIDs: [Int]? = nil
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileSize = fileSize
        let resolvedHeroes = heroIDs ?? (heroID.map { [$0] } ?? [])
        let resolvedSkins = skinIDs ?? (skinID.map { [$0] } ?? [])
        self.heroIDs = resolvedHeroes
        self.skinIDs = resolvedSkins
        self.heroID = heroID ?? resolvedHeroes.first
        self.skinID = skinID ?? resolvedSkins.first
        self.resourceVersion = resourceVersion
    }

    public var heroBadgeText: String {
        let lang = AppLanguage.current
        if heroIDs.count > 1 {
            let preview = heroIDs.prefix(4).map { "#\($0)" }.joined(separator: ", ")
            let suffix = heroIDs.count > 4 ? "…" : ""
            return lang.text("merge.badge.heroes", heroIDs.count, "\(preview)\(suffix)")
        } else if let h = heroID, let s = skinID {
            return lang.text("merge.badge.hero_skin", h, s)
        } else if let h = heroID {
            return lang.text("merge.badge.hero", h)
        } else {
            return lang.text("merge.badge.generic")
        }
    }
}

public struct AovMergeResult: Equatable, Sendable {
    public let outputZipURL: URL
    public let outputFileSize: Int64
    public let resourceVersion: String
    public let mergedMods: [AovModSummary]
    public let totalFilesWritten: Int
    public let smartMergedConflicts: Int
    public let logs: [String]
}

public enum AovModMergerError: LocalizedError {
    case insufficientInputMods
    case invalidArchive(String)
    case missingResourceStructure(String)
    case cryptoFailed(String)
    case assetBundleMergeFailed(String)
    case msesParseFailed(String)
    case ifixPatchFailed(String)
    case zipCreationFailed(String)
    case sizeLimitExceeded

    public var errorDescription: String? {
        let lang = AppLanguage.current
        switch self {
        case .insufficientInputMods:
            return lang.text("merge.error.insufficient_mods")
        case .invalidArchive(let name):
            return lang.text("merge.error.invalid_archive", name)
        case .missingResourceStructure(let name):
            return lang.text("merge.error.missing_resources", name)
        case .cryptoFailed(let detail):
            return lang.text("merge.error.crypto", detail)
        case .assetBundleMergeFailed(let detail):
            return lang.text("merge.error.asset_bundle", detail)
        case .msesParseFailed(let detail):
            return lang.text("merge.error.mses", detail)
        case .ifixPatchFailed(let detail):
            return lang.text("merge.error.ifix", detail)
        case .zipCreationFailed(let detail):
            return lang.text("merge.error.zip_creation", detail)
        case .sizeLimitExceeded:
            return lang.text("merge.error.size_limit")
        }
    }
}

// MARK: - Thin server merger client

/// Client mỏng cho tính năng "Gộp File Mod": toàn bộ pipeline gộp
/// (UnityFS/RP/RV/CommonActions/MSES/HeroSkin) chạy trên `/api/v1/merge-plan`.
/// App chỉ upload gói `.zip` gốc và ghi lại `result.zip` do server trả về.
public final class AovModMergerEngine: @unchecked Sendable {
    public static let shared = AovModMergerEngine()

    private init() {}

    /// Đọc và xác thực chặt chẽ gói mod `.zip` trước khi cho phép thêm vào danh sách gộp.
    private static func validatedHeadersAndSummary(at url: URL) throws -> (summary: AovModSummary, headers: [String: PatchZipConverter.ZipArchiveEntryHeader]) {
        guard url.pathExtension.lowercased() != "3105" else {
            throw AovModMergerError.invalidArchive(
                AppLanguage.current.text("merge.error.only_zip_entry", url.lastPathComponent)
            )
        }

        let hasSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurity { url.stopAccessingSecurityScopedResource() }
        }

        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard !PatchPackageLimits.exceedsExpandedLimit(fileSize) else {
            throw AovModMergerError.sizeLimitExceeded
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AovModMergerError.invalidArchive(
                AppLanguage.current.text("merge.error.open_source_mod", url.lastPathComponent)
            )
        }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        try? handle.close()
        let isLocalZipMagic = magic.count == 4 && magic == Data([0x50, 0x4B, 0x03, 0x04])
        let isEmptyZipMagic = magic.count == 4 && magic == Data([0x50, 0x4B, 0x05, 0x06])
        guard isLocalZipMagic || isEmptyZipMagic else {
            throw AovModMergerError.invalidArchive(
                AppLanguage.current.text("merge.error.not_valid_zip_entry", url.lastPathComponent)
            )
        }

        let headers: [String: PatchZipConverter.ZipArchiveEntryHeader]
        do {
            headers = try PatchZipConverter.shared.readZipArchiveHeaders(from: url)
        } catch let err as PatchZipConverterError where err == .sizeLimitExceeded {
            throw AovModMergerError.sizeLimitExceeded
        } catch {
            throw AovModMergerError.invalidArchive(
                AppLanguage.current.text("merge.error.not_valid_zip_entry", url.lastPathComponent)
            )
        }

        guard !headers.isEmpty else {
            throw AovModMergerError.invalidArchive(
                AppLanguage.current.text("merge.error.empty_zip", url.lastPathComponent)
            )
        }
        if headers.values.contains(where: { $0.isEncrypted }) {
            throw AovModMergerError.invalidArchive(
                AppLanguage.current.text("merge.error.encrypted_zip", url.lastPathComponent)
            )
        }
        if headers.values.contains(where: { $0.compressionMethod != 0 && $0.compressionMethod != 8 }) {
            throw AovModMergerError.invalidArchive(
                AppLanguage.current.text("merge.error.not_valid_zip_entry", url.lastPathComponent)
            )
        }

        let summary = Self.summary(
            url: url,
            fileSize: fileSize,
            entryNames: Array(headers.keys)
        )
        let fallbackVersion = summary.resourceVersion ?? "0.0.0"
        let hasValidAovStructure = headers.keys.contains {
            Self.normalizeAovPath($0, fallbackVersion: fallbackVersion) != nil
        }
        guard hasValidAovStructure else {
            throw AovModMergerError.missingResourceStructure(url.lastPathComponent)
        }
        return (summary, headers)
    }

    /// Đọc metadata nhẹ (số tướng, phiên bản Resources) để hiển thị trong danh sách chọn mod.
    public func inspectModArchive(at url: URL) throws -> AovModSummary {
        try Self.validatedHeadersAndSummary(at: url).summary
    }

    /// Dựng `AovModSummary` từ danh sách đường dẫn đã có sẵn, tránh đọc lại gói mod
    /// (mỗi gói có thể 150 MB nên đọc hai lần là lãng phí I/O và bộ nhớ).
    static func summary(url: URL, fileSize: Int64, entryNames: [String]) -> AovModSummary {
        var primaryHeroIDs = Set<Int>()
        var fallbackHeroIDs = Set<Int>()
        var skinIDs = Set<Int>()
        var resourceVersion: String?

        for name in entryNames {
            if let versioned = Self.normalizeAovPath(name) {
                let parts = versioned.split(separator: "/")
                if resourceVersion == nil,
                   parts.count >= 2,
                   parts[0].caseInsensitiveCompare("Resources") == .orderedSame,
                   Self.isVersionComponent(String(parts[1])) {
                    resourceVersion = String(parts[1])
                }
            }
            guard let normalized = Self.normalizeAovPath(name, fallbackVersion: resourceVersion ?? "0.0.0") else {
                continue
            }
            for id in Self.primaryHeroIDs(inPath: normalized) {
                primaryHeroIDs.insert(id)
            }
            for id in Self.fallbackHeroIDs(inPath: normalized) {
                fallbackHeroIDs.insert(id)
            }
            if normalized.lowercased().contains("/skin") {
                for id in Self.heroIDs(inPath: normalized) {
                    skinIDs.insert(id)
                }
            }
        }

        let sortedHeroes = (primaryHeroIDs.isEmpty ? fallbackHeroIDs : primaryHeroIDs).sorted()
        let sortedSkins = skinIDs.sorted()
        return AovModSummary(
            url: url,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            heroID: sortedHeroes.first,
            skinID: sortedSkins.first,
            resourceVersion: resourceVersion,
            heroIDs: sortedHeroes,
            skinIDs: sortedSkins
        )
    }

    /// Gộp nhiều gói mod `.zip` theo mô hình tối ưu siêu tốc (Zero-Decompression Streaming).
    ///
    /// - Nhóm toàn bộ entry từ các gói mod theo đường dẫn chuẩn hóa (Resources/<targetVersion>/...).
    /// - Phát hiện Path Collision: Chỉ upload những file cấu hình (XML, MSES, HeroSkin, RP/RV)
    ///   thực sự xuất hiện ở >= 2 gói mod. File cấu hình không đè lên nhau được giữ nguyên ở local.
    /// - Đóng gói kết quả siêu tốc: ghi file đã merge từ server, các file còn lại (cấu hình
    ///   local và toàn bộ assetbundle nặng) được copy thẳng luồng byte đã nén (Deflate/STORE)
    ///   trực tiếp từ file mod gốc sang file zip kết quả mà KHÔNG cần giải nén hay nén lại.
    public func mergeModArchives(
        inputURLs: [URL],
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> AovMergeResult {
        guard inputURLs.count >= 2 else {
            throw AovModMergerError.insufficientInputMods
        }

        // BƯỚC 1: Đọc nhanh danh mục Central Directory của tất cả các gói mod (< 5ms mỗi gói)
        progress(AppLanguage.current.text("merge.progress.reading_catalog"), 0.05)

        let modMetas: [ModMetadata] = try await Task.detached(priority: .userInitiated) { () -> [ModMetadata] in
            var items: [ModMetadata] = []
            for url in inputURLs {
                let inspected = try Self.validatedHeadersAndSummary(at: url)
                items.append(ModMetadata(summary: inspected.summary, headers: inspected.headers))
            }
            return items
        }.value

        let summaries = modMetas.map(\.summary)
        let logs = summaries.map { AppLanguage.current.text("merge.log.read_archive", $0.fileName, $0.fileSize) }

        let targetVersion = Self.resolveTargetVersion(summaries)

        // Xác định các gói mod có thư mục Thanos (HeroSkin_1..4) để luôn đồng bộ IFix và MD5 .pkg.bytes
        var hasThanosFile = false
        for modMeta in modMetas {
            for origPath in modMeta.headers.keys {
                let lower = origPath.replacingOccurrences(of: "\\", with: "/").lowercased()
                if lower.contains("/thanos/") || lower.hasPrefix("thanos/") || lower.hasSuffix("heroskin_1.bytes") {
                    hasThanosFile = true
                    break
                }
            }
            if hasThanosFile { break }
        }

        // BƯỚC 2: Nhóm toàn bộ entry theo đường dẫn chuẩn hóa (Resources/<targetVersion>/...)
        var pathGroups: [String: [ModHeaderRef]] = [:]
        for (modIdx, modMeta) in modMetas.enumerated() {
            let sourceVersion = modMeta.summary.resourceVersion
            for (origPath, header) in modMeta.headers {
                guard let canonical = Self.normalizeAovPath(origPath, fallbackVersion: targetVersion) else {
                    continue
                }
                let remapped = Self.remapResourceVersion(
                    path: canonical,
                    from: sourceVersion,
                    to: targetVersion
                )
                let normalizedKey = remapped.lowercased()

                // Loại bỏ các file Databin rác/watermark (< 32 byte, ví dụ 9 byte chữ ký tác giả)
                // gây crash GameDataMgr và đứng game ở 88%
                if normalizedKey.contains("/databin/") && normalizedKey.hasSuffix(".bytes")
                    && header.uncompressedSize > 0 && header.uncompressedSize < 32 {
                    continue
                }

                let entryRef = ModHeaderRef(
                    modIndex: modIdx,
                    originalPath: origPath,
                    remappedPath: remapped,
                    header: header
                )
                pathGroups[normalizedKey, default: []].append(entryRef)
            }
        }
        guard !pathGroups.isEmpty else {
            throw AovModMergerError.missingResourceStructure(summaries.map(\.fileName).joined(separator: ", "))
        }

        // BƯỚC 3: Chọn lọc file cấu hình cần gửi lên máy chủ để chạy pipeline merge đầy đủ:
        // - Luôn gửi metadata build/version (version.txt, ResourcePackerInfoSetAll, ResourceVerificationInfoSetAll)
        //   để server phát hiện chính xác build version cho từng mod khi so khớp xung đột.
        // - Luôn gửi /Thanos/ (HeroSkin_1..4) và Lua pkg lõi (KernelLua, HeroInfoLua, StableSystems_*)
        //   cộng với .pkg.bytes khi có Thanos để server giải mã/cập nhật IFix + MD5 + STORE method=0.
        // - Các file cấu hình còn lại (CommonActions, Databin, XML, MSES, languageMap, ...) chỉ gửi
        //   khi có >= 2 mod chạm cùng đường dẫn với nội dung khác nhau.
        var collidingRefs: [ModHeaderRef] = []
        var detectedConflicts = 0

        for (normalizedKey, refs) in pathGroups {
            guard let first = refs.first else { continue }
            guard Self.isServerConfigPath(first.remappedPath) else { continue }

            let distinctMods = Set(refs.map(\.modIndex))
            let uniqueVariants = Set(refs.map { "\($0.header.crc32):\($0.header.uncompressedSize)" })

            let isBuildMetadata = normalizedKey.hasSuffix("/version.txt")
                || normalizedKey == "version.txt"
                || normalizedKey.hasSuffix("resourcepackerinfosetall.assetbundle")
                || normalizedKey.hasSuffix("resourceverificationinfosetall.assetbundle")
            let isCorePkg = normalizedKey.hasSuffix("kernellua.pkg.bytes")
                || normalizedKey.hasSuffix("heroinfolua.pkg.bytes")
                || (normalizedKey.contains("stablesystems_") && normalizedKey.hasSuffix(".pkg.bytes"))
            let isThanosConfig = normalizedKey.contains("/thanos/")
            let isPkgWithThanos = hasThanosFile && normalizedKey.hasSuffix(".pkg.bytes")

            if isBuildMetadata || isCorePkg || isThanosConfig || isPkgWithThanos {
                if distinctMods.count >= 2 && uniqueVariants.count >= 2 {
                    detectedConflicts += 1
                } else if isThanosConfig || isCorePkg {
                    detectedConflicts += 1
                }
                collidingRefs.append(contentsOf: refs)
                continue
            }

            guard distinctMods.count >= 2 else { continue }
            guard uniqueVariants.count >= 2 else { continue }

            detectedConflicts += 1
            collidingRefs.append(contentsOf: refs)
        }

        // BƯỚC 4: Chuẩn bị config_bundle.zip gửi lên máy chủ (khử trùng lặp blob bằng blob_aliases)
        var configBundleEntries: [(path: String, data: Data)] = []
        var blobAliases: [[String: Any]] = []
        var firstBlobSourceBySignature: [String: (modIndex: Int, path: String)] = [:]
        if !collidingRefs.isEmpty {
            progress(AppLanguage.current.text("merge.progress.extracting_configs", detectedConflicts), 0.2)
            for ref in collidingRefs {
                let sourceVer = modMetas[ref.modIndex].summary.resourceVersion
                let canonical = Self.normalizeAovPath(ref.originalPath, fallbackVersion: targetVersion) ?? ref.originalPath
                let normalizedForServer = Self.remapResourceVersion(
                    path: canonical,
                    from: sourceVer,
                    to: targetVersion
                )
                let signature = "\(ref.header.crc32):\(ref.header.uncompressedSize)"
                if ref.header.uncompressedSize > 0, let existing = firstBlobSourceBySignature[signature] {
                    if !(existing.modIndex == ref.modIndex && existing.path == normalizedForServer) {
                        blobAliases.append([
                            "source_mod_index": existing.modIndex,
                            "source_path": existing.path,
                            "target_mod_index": ref.modIndex,
                            "target_path": normalizedForServer,
                        ])
                    }
                    continue
                }
                let modURL = inputURLs[ref.modIndex]
                let fileData = try PatchZipConverter.shared.extractZipEntry(header: ref.header, from: modURL)
                firstBlobSourceBySignature[signature] = (modIndex: ref.modIndex, path: normalizedForServer)
                configBundleEntries.append((path: "mod_\(ref.modIndex)/\(normalizedForServer)", data: fileData))
            }
        }

        // Nén Deflate riêng cho gói vận chuyển `config_bundle.zip` gửi lên server
        // (file mod thành phẩm & `.pkg.bytes` đầu ra ở Bước 6 vẫn giữ nguyên STORE method 0).
        let configBundleData = try PatchZipConverter.shared.buildZipArchive(
            entries: configBundleEntries,
            compress: true
        )
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TotoroxMerge_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let configBundleURL = workDir.appendingPathComponent("config_bundle.zip")
        try configBundleData.write(to: configBundleURL, options: .atomic)

        let modPayloads: [[String: Any]] = summaries.map { s in
            var dict: [String: Any] = [
                "name": s.fileName,
                "heroIDs": s.heroIDs,
                "skinIDs": s.skinIDs,
            ]
            if let explicitVersion = s.resourceVersion, !explicitVersion.isEmpty {
                dict["explicitVersion"] = explicitVersion
            }
            return dict
        }
        var configObject: [String: Any] = [
            "mods": modPayloads,
            "output": ["resourcesVersion": targetVersion],
        ]
        if !blobAliases.isEmpty {
            configObject["blob_aliases"] = blobAliases
        }
        guard let configData = try? JSONSerialization.data(withJSONObject: configObject, options: [.sortedKeys]),
              let configJSON = String(data: configData, encoding: .utf8) else {
            throw AovModMergerError.zipCreationFailed(AppLanguage.current.text("merge.error.build_config"))
        }

        progress(AppLanguage.current.text("merge.progress.uploading_server"), 0.5)

        let planResult = await APIService.shared.mergePlanWithQueue(
            fileURL: configBundleURL,
            configJSON: configJSON,
            token: LicenseManager.shared.authToken,
            hwid: LicenseManager.shared.deviceIdentifier
        ) { stage in
            switch stage {
            case .queued(let position, _):
                progress(AppLanguage.current.text("merge.progress.queued", position), 0.54)
            case .processing:
                progress(AppLanguage.current.text("merge.progress.processing"), 0.62)
            case .downloadingResult:
                progress(AppLanguage.current.text("merge.progress.downloading_result"), 0.70)
            }
        }

        let plan: MergePlanResponse
        let downloadedBundleData: Data?
        switch planResult {
        case .success(let executionResult):
            plan = executionResult.response
            downloadedBundleData = executionResult.resultBundleData
        case .failure(let error):
            throw AovModMergerError.invalidArchive(AppLanguage.current.text("merge.error.server_prefix", error.localizedDescription))
        }
        guard plan.ok else {
            throw AovModMergerError.invalidArchive(AppLanguage.current.text("merge.error.invalid_server_response"))
        }

        progress(AppLanguage.current.text("merge.progress.packing_zip"), 0.75)

        // BƯỚC 5: Nhận và giải nén các file server đã merge (nếu có)
        var serverMergedEntries: [String: Data] = [:]
        let resolvedBundleData: Data? = {
            if let downloadedBundleData, !downloadedBundleData.isEmpty {
                return downloadedBundleData
            }
            if let encoded = plan.zipBytesB64, let decoded = Data(base64Encoded: encoded), !decoded.isEmpty {
                return decoded
            }
            return nil
        }()
        if let bundle = resolvedBundleData {
            let outerEntries = (try? PatchZipConverter.shared.parseZipArchive(bundle)) ?? [:]
            let rawMergedEntries: [String: Data]
            if let innerResultData = outerEntries["result.zip"]
                ?? outerEntries.first(where: { ($0.key as NSString).lastPathComponent.lowercased() == "result.zip" })?.value,
               !innerResultData.isEmpty,
               let parsedInner = try? PatchZipConverter.shared.parseZipArchive(innerResultData) {
                rawMergedEntries = parsedInner
            } else {
                rawMergedEntries = outerEntries
            }

            for (rawKey, rawData) in rawMergedEntries {
                guard let normalized = Self.normalizeAovPath(rawKey, fallbackVersion: targetVersion) else {
                    continue
                }
                let parts = normalized.split(separator: "/").map(String.init)
                let srcVer = (parts.count >= 2 && parts[0].caseInsensitiveCompare("Resources") == .orderedSame && Self.isVersionComponent(parts[1]))
                    ? parts[1]
                    : nil
                let remapped = Self.remapResourceVersion(
                    path: normalized,
                    from: srcVer,
                    to: targetVersion
                )
                serverMergedEntries[remapped] = rawData
            }
        }
        let serverMergedKeys = Set(serverMergedEntries.keys.map { $0.lowercased() })

        // Xây dựng bảng build version cho từng mod theo dữ liệu server (nếu có) hoặc version.txt/summary local
        let buildVersions = plan.mergePlan?.bundleVersions ?? []
        var buildInfoByModIndex: [Int: (tuple: [Int], build: Int)] = [:]
        for modIdx in 0..<modMetas.count {
            let fallbackTuple = Self.parseVersionTupleComponents(summaries[modIdx].resourceVersion ?? "")
            var resolved: (tuple: [Int], build: Int) = (fallbackTuple, 0)
            if modIdx < buildVersions.count, buildVersions[modIdx].modName == summaries[modIdx].fileName {
                let bv = buildVersions[modIdx]
                resolved = (bv.versionTuple ?? fallbackTuple, bv.buildNumber ?? 0)
            } else if let matched = buildVersions.first(where: { $0.modName == summaries[modIdx].fileName }) {
                resolved = (matched.versionTuple ?? fallbackTuple, matched.buildNumber ?? 0)
            }
            buildInfoByModIndex[modIdx] = resolved
        }

        // BƯỚC 6: Tạo file .zip kết quả với tốc độ cao (Streaming Copy)
        let fileManager = FileManager.default
        let outDir = fileManager.temporaryDirectory
            .appendingPathComponent("TotoroxMergedMods", isDirectory: true)
        try fileManager.createDirectory(at: outDir, withIntermediateDirectories: true)

        let serverOutName = plan.mergePlan?.outputFilename.flatMap { raw -> String? in
            let sanitized = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return (!sanitized.isEmpty && sanitized.lowercased().hasSuffix(".zip")) ? sanitized : nil
        }
        let outName = serverOutName ?? Self.makeMergedOutputFilename(
            loadedModsWithHeroes: summaries.map { (heroIDs: $0.heroIDs, fileName: $0.fileName) },
            fileExtension: "zip"
        )
        let outURL = Self.uniqueOutputURL(in: outDir, preferredName: outName, fileManager: fileManager)

        var modHandles: [FileHandle?] = []
        for url in inputURLs {
            _ = url.startAccessingSecurityScopedResource()
            let handle = try? FileHandle(forReadingFrom: url)
            modHandles.append(handle)
        }
        defer {
            for (idx, handle) in modHandles.enumerated() {
                try? handle?.close()
                inputURLs[idx].stopAccessingSecurityScopedResource()
            }
        }

        do {
            let writer = try PatchZipConverter.ZipArchiveWriter(destinationURL: outURL)
            defer { writer.cancel() }

            // 1. Ghi các file cấu hình server đã merge
            for path in serverMergedEntries.keys.sorted() {
                guard let data = serverMergedEntries[path] else { continue }
                try writer.add(path: path, data: data)
            }

            // 2. Ghi toàn bộ các file còn lại (cấu hình không xung đột + tài nguyên nặng)
            // Khi trùng đường dẫn ở local, ưu tiên mod có build version cao hơn rồi mới tới kích thước/thứ tự.
            for normalizedKey in pathGroups.keys.sorted() {
                guard !serverMergedKeys.contains(normalizedKey) else { continue }
                guard let refs = pathGroups[normalizedKey],
                      let winner = Self.selectWinningLocalRef(refs, buildInfoByModIndex: buildInfoByModIndex) else {
                    continue
                }
                guard let sourceHandle = modHandles[winner.modIndex] else {
                    throw AovModMergerError.invalidArchive(
                        AppLanguage.current.text("merge.error.open_source_mod", inputURLs[winner.modIndex].lastPathComponent)
                    )
                }

                // Các gói .pkg.bytes phải luôn đóng gói ở chế độ STORE (method 0) cả lớp ngoài lẫn entry bên trong
                // để CFileManager của AOV đọc trực tiếp không bị kẹt 88%
                if normalizedKey.hasSuffix(".pkg.bytes") {
                    let rawPkgData = try PatchZipConverter.shared.extractZipEntry(
                        header: winner.header,
                        from: inputURLs[winner.modIndex]
                    )
                    let normalizedPkgData = Self.ensurePkgArchiveStored(rawPkgData)
                    if winner.header.compressionMethod != 0 || normalizedPkgData != rawPkgData {
                        try writer.add(path: winner.remappedPath, data: normalizedPkgData)
                        continue
                    }
                }

                try writer.copyRawEntry(
                    destinationPath: winner.remappedPath,
                    from: sourceHandle,
                    payloadOffset: winner.header.payloadOffset,
                    compressedSize: winner.header.compressedSize,
                    uncompressedSize: winner.header.uncompressedSize,
                    compressionMethod: winner.header.compressionMethod,
                    crc32: winner.header.crc32
                )
            }

            try writer.finish()

            let outputSize = Int64((try? outURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let totalFiles = writer.totalEntriesWritten
            let mergedConflicts = plan.mergePlan?.conflicts ?? detectedConflicts
            let serverFilesCount = serverMergedEntries.count

            let finalLogs = logs + [AppLanguage.current.text("merge.log.server_merged", serverFilesCount, mergedConflicts)]
            progress(AppLanguage.current.text("merge.progress.done"), 1.0)

            return AovMergeResult(
                outputZipURL: outURL,
                outputFileSize: outputSize,
                resourceVersion: targetVersion,
                mergedMods: summaries,
                totalFilesWritten: totalFiles,
                smartMergedConflicts: mergedConflicts,
                logs: finalLogs
            )
        } catch {
            try? fileManager.removeItem(at: outURL)
            throw AovModMergerError.zipCreationFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private struct ModHeaderRef: Sendable {
        let modIndex: Int
        let originalPath: String
        let remappedPath: String
        let header: PatchZipConverter.ZipArchiveEntryHeader
    }

    private struct ModMetadata: Sendable {
        let summary: AovModSummary
        let headers: [String: PatchZipConverter.ZipArchiveEntryHeader]
    }

    /// Đảm bảo mọi entry bên trong gói `.pkg.bytes` dùng compression method 0 (`STORE`)
    /// để `CFileManager` của AOV đọc trực tiếp không bị treo ở màn hình tải 88%.
    static func ensurePkgArchiveStored(_ rawPkgData: Data) -> Data {
        guard let innerHeaders = try? PatchZipConverter.shared.readZipArchiveHeaders(from: rawPkgData),
              innerHeaders.values.contains(where: { $0.compressionMethod != 0 }) else {
            return rawPkgData
        }
        guard let parsed = try? PatchZipConverter.shared.parseZipArchive(rawPkgData),
              !parsed.isEmpty else {
            return rawPkgData
        }
        let sortedEntries = parsed.keys.sorted().compactMap { key -> (path: String, data: Data)? in
            guard let data = parsed[key] else { return nil }
            return (path: key, data: data)
        }
        return (try? PatchZipConverter.shared.buildZipArchive(entries: sortedEntries)) ?? rawPkgData
    }

    /// Đường dẫn cấu hình mà server thật sự chạy pipeline merge:
    /// `CommonActions` (XML), `Databin` (MSES), `Thanos` (HeroSkin_1/2) và hai assetbundle
    /// metadata `ResourcePackerInfoSetAll` / `ResourceVerificationInfoSetAll` (thêm entry
    /// cho asset mới). Mọi file khác do client giữ nguyên và ghép local.
    private static let aovKnownRootDirectories: Set<String> = [
        "ages", "assetrefs", "databin", "assetbundle", "sound",
        "thanos", "prefab_characters", "behaviac", "lua_signed", "languages"
    ]

    private static let aovKnownRootFiles: Set<String> = [
        "version.txt", "heroinfolua.pkg.bytes", "kernellua.pkg.bytes", "stablesystems_3.pkg.bytes"
    ]

    /// Chuẩn hóa đường dẫn entry trong gói mod AOV về dạng `Resources/<version>/...`.
    /// Trả về `nil` nếu đây là tệp rác hệ thống (`__MACOSX`, `.DS_Store`, `._*`),
    /// metadata wrapper (`patch.json`, `config.json`, `merge_plan.json`, `result.zip`, `*.3105`)
    /// hoặc tệp ngoài cây tài nguyên AOV.
    public static func normalizeAovPath(_ rawPath: String, fallbackVersion: String? = nil) -> String? {
        var cleaned = rawPath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("./") {
            cleaned.removeFirst(2)
        }
        while cleaned.hasPrefix("/") {
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty, !cleaned.hasSuffix("/") else { return nil }

        let parts = cleaned
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        guard !parts.isEmpty else { return nil }

        let lowerParts = parts.map { $0.lowercased() }
        let fileNameLower = lowerParts.last ?? ""
        if lowerParts.contains("__macosx") || fileNameLower.hasPrefix("._") || fileNameLower == ".ds_store" {
            return nil
        }
        let metadataFiles: Set<String> = [
            "patch.json", "manifest.json", "config.json", "merge_plan.json", "result.zip", "payload.3105"
        ]
        if metadataFiles.contains(fileNameLower) || fileNameLower.hasSuffix(".3105") {
            return nil
        }

        // 1. Đường dẫn có thành phần "Resources" rõ ràng (vd: "Pack/com.garena.game.kgvn/Documents/Resources/1.64.1/...")
        if let resIdx = lowerParts.firstIndex(of: "resources") {
            let tail = Array(parts[(resIdx + 1)...])
            guard !tail.isEmpty else { return nil }
            return (["Resources"] + tail).joined(separator: "/")
        }

        // 2. Bắt đầu ngay bằng số phiên bản (vd: "1.64.1/Ages/...")
        if parts.count >= 2, Self.isVersionComponent(parts[0]) {
            return (["Resources"] + parts).joined(separator: "/")
        }

        // 3. Lồng trong thư mục wrapper/Documents trước số phiên bản (vd: "ModPack/1.64.1/Ages/...")
        if parts.count >= 3 {
            for idx in 1..<(parts.count - 1) {
                let nextLower = lowerParts[idx + 1]
                if Self.isVersionComponent(parts[idx]),
                   Self.aovKnownRootDirectories.contains(nextLower) || Self.aovKnownRootFiles.contains(nextLower) {
                    return (["Resources"] + Array(parts[idx...])).joined(separator: "/")
                }
            }
        }

        // 4. Đường dẫn không có số phiên bản nhưng bắt đầu bằng thư mục/tệp gốc AOV hợp lệ
        if let fallback = fallbackVersion, !fallback.isEmpty {
            var trimmed = parts
            if lowerParts.first == "documents", parts.count >= 2 {
                trimmed = Array(parts.dropFirst())
            } else if lowerParts.first == "payload", parts.count >= 3 {
                trimmed = Array(parts.dropFirst())
                if let firstLower = trimmed.first?.lowercased(), firstLower.hasPrefix("com."), trimmed.count >= 2 {
                    trimmed.removeFirst()
                }
            }
            if let firstLower = trimmed.first?.lowercased() {
                if (Self.aovKnownRootDirectories.contains(firstLower) && trimmed.count >= 2)
                    || (trimmed.count == 1 && Self.aovKnownRootFiles.contains(firstLower)) {
                    return (["Resources", fallback] + trimmed).joined(separator: "/")
                }
            }
        }

        return nil
    }

    private static func isVersionComponent(_ component: String) -> Bool {
        guard component.contains(".") else { return false }
        let parts = component.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.count <= 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func parseVersionTupleComponents(_ version: String) -> [Int] {
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        return cleaned.split(separator: ".").map { part -> Int in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }

    private static func compareBuildVersion(
        _ lhs: (tuple: [Int], build: Int),
        _ rhs: (tuple: [Int], build: Int)
    ) -> Int {
        let maxCount = max(lhs.tuple.count, rhs.tuple.count)
        for idx in 0..<maxCount {
            let l = idx < lhs.tuple.count ? lhs.tuple[idx] : 0
            let r = idx < rhs.tuple.count ? rhs.tuple[idx] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        if lhs.build != rhs.build {
            return lhs.build < rhs.build ? -1 : 1
        }
        return 0
    }

    private static func selectWinningLocalRef(
        _ refs: [ModHeaderRef],
        buildInfoByModIndex: [Int: (tuple: [Int], build: Int)]
    ) -> ModHeaderRef? {
        return refs.max { lhs, rhs in
            let lBuild = buildInfoByModIndex[lhs.modIndex] ?? ([], 0)
            let rBuild = buildInfoByModIndex[rhs.modIndex] ?? ([], 0)
            let cmp = Self.compareBuildVersion(lBuild, rBuild)
            if cmp != 0 {
                return cmp < 0
            }
            let lNonEmpty = lhs.header.uncompressedSize > 0
            let rNonEmpty = rhs.header.uncompressedSize > 0
            if lNonEmpty != rNonEmpty {
                return !lNonEmpty
            }
            return lhs.modIndex < rhs.modIndex
        }
    }

    public static func isServerConfigPath(_ relativePath: String) -> Bool {
        let lower = relativePath.replacingOccurrences(of: "\\", with: "/").lowercased()
        return lower.contains("commonactions")
            || lower.contains("databin")
            || lower.contains("thanos")
            || lower.hasSuffix(".xml")
            || lower.hasSuffix(".mses")
            || lower.hasSuffix(".pkg.bytes")
            || lower.hasSuffix("/version.txt")
            || lower == "version.txt"
            || lower.hasSuffix("/languagemap.txt")
            || lower == "languagemap.txt"
            || lower.hasSuffix("resourcepackerinfosetall.assetbundle")
            || lower.hasSuffix("resourceverificationinfosetall.assetbundle")
    }

    /// Version Resources đích: lấy bản cao nhất trong các mod, fallback `1.64.1`
    /// (mặc định của server khi client không chỉ định).
    static func resolveTargetVersion(_ summaries: [AovModSummary]) -> String {
        summaries
            .compactMap(\.resourceVersion)
            .max { compareVersion($0, $1) < 0 }
            ?? "1.64.1"
    }

    /// So sánh version dạng `1.64.10` theo từng thành phần số (không so chuỗi thô).
    private static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// Đổi tiền tố `Resources/<ver>/` sang version đích, giống `run_merge` phía server.
    /// Chỉ đổi khi mod có version riêng và khác version đích.
    static func remapResourceVersion(
        path: String,
        from sourceVersion: String?,
        to targetVersion: String
    ) -> String {
        guard let sourceVersion,
              !sourceVersion.isEmpty,
              sourceVersion != targetVersion else {
            return path
        }
        let sourcePrefix = "Resources/\(sourceVersion)/"
        guard path.lowercased().hasPrefix(sourcePrefix.lowercased()) else {
            return path
        }
        return "Resources/\(targetVersion)/" + path.dropFirst(sourcePrefix.count)
    }

    /// Đọc lại entry của một gói mod. Chỉ dùng ở lượt ghép để RAM đỉnh ~1 gói.
    private static func readZipEntries(at url: URL) throws -> [String: Data] {
        let hasSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurity { url.stopAccessingSecurityScopedResource() }
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AovModMergerError.invalidArchive(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        do {
            return try PatchZipConverter.shared.parseZipArchive(data)
        } catch {
            throw AovModMergerError.invalidArchive(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    static func primaryHeroIDs(inPath path: String) -> [Int] {
        let unified = path.replacingOccurrences(of: "\\", with: "/")
        let fileName = (unified as NSString).lastPathComponent
        var found: [Int] = []
        var seen = Set<Int>()

        if fileName.lowercased().hasPrefix("actor_") {
            let parts = fileName.split(separator: "_")
            if parts.count >= 2, let hid = Int(parts[1]), (100...9999).contains(hid), seen.insert(hid).inserted {
                found.append(hid)
            }
        }
        if fileName.lowercased().hasSuffix("_assetref.bytes") {
            let prefix = String(fileName.dropLast("_AssetRef.bytes".count))
            if let hid = Int(prefix), (100...9999).contains(hid), seen.insert(hid).inserted {
                found.append(hid)
            }
        }
        return found
    }

    static func fallbackHeroIDs(inPath path: String) -> [Int] {
        let lower = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        let patterns = [
            "(?:^|/)hero/(\\d{3,4})(?:_|/|\\.|$)",
            "(?:^|/)commercializenotify_(?:blue|red)_(\\d{3,4})(?:_|\\.|$)",
            "(?:^|/)hero[_\\-](\\d{3,4})(?:_|\\.|$)"
        ]
        var found: [Int] = []
        var seen = Set<Int>()
        let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            for match in regex.matches(in: lower, options: [], range: nsRange) {
                guard match.numberOfRanges > 1,
                      let idRange = Range(match.range(at: 1), in: lower),
                      let id = Int(lower[idRange]),
                      (100...9999).contains(id),
                      seen.insert(id).inserted else { continue }
                found.append(id)
            }
        }
        return found
    }

    static func heroIDs(inPath path: String) -> [Int] {
        let primary = Self.primaryHeroIDs(inPath: path)
        return primary.isEmpty ? Self.fallbackHeroIDs(inPath: path) : primary
    }

    // MARK: - Output Filename Helper (Short Hash, Max Length Protected)

    /// Tạo tên file ngắn gọn dùng Short Hash (4-6 ký tự) để chống tràn giới hạn 255 ký tự trên APFS:
    /// Format: `AOV_Mod_[Count]Heroes_[ShortHash].zip` (hoặc .3105 tùy loại file)
    /// Ví dụ: `AOV_Mod_6Heroes_a8f2.zip`
    public static func makeMergedOutputFilename(
        loadedMods: [(heroID: Int?, fileName: String)],
        fileExtension: String = "zip"
    ) -> String {
        return makeMergedOutputFilename(
            loadedModsWithHeroes: loadedMods.map { (heroIDs: $0.heroID.map { [$0] } ?? [], fileName: $0.fileName) },
            fileExtension: fileExtension
        )
    }

    public static func makeMergedOutputFilename(
        loadedModsWithHeroes: [(heroIDs: [Int], fileName: String)],
        fileExtension: String = "zip"
    ) -> String {
        var uniqueHeroes = Set<Int>()
        for mod in loadedModsWithHeroes {
            uniqueHeroes.formUnion(mod.heroIDs)
        }

        let countLabel: String
        if !uniqueHeroes.isEmpty {
            let heroCount = max(uniqueHeroes.count, loadedModsWithHeroes.count)
            countLabel = "\(heroCount)Heroes"
        } else {
            countLabel = "\(loadedModsWithHeroes.count)Mods"
        }

        let hashInput = loadedModsWithHeroes.map { mod -> String in
            let heroesPart = mod.heroIDs.isEmpty ? "x" : mod.heroIDs.sorted().map(String.init).joined(separator: ",")
            return "\(heroesPart)_\(mod.fileName)"
        }.joined(separator: "|")
        let digest = Insecure.MD5.hash(data: Data(hashInput.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let shortHash = String(hex.prefix(4)).lowercased()

        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "AOV_Mod_\(countLabel)_\(shortHash).\(ext)"
    }

    static func uniqueOutputURL(
        in directory: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let candidate = directory.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let nsName = preferredName as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        for index in 2...999 {
            let suffixedName = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
            let nextCandidate = directory.appendingPathComponent(suffixedName)
            if !fileManager.fileExists(atPath: nextCandidate.path) {
                return nextCandidate
            }
        }
        let fallbackName = ext.isEmpty
            ? "\(stem)_\(UUID().uuidString.prefix(6))"
            : "\(stem)_\(UUID().uuidString.prefix(6)).\(ext)"
        return directory.appendingPathComponent(fallbackName)
    }
}
