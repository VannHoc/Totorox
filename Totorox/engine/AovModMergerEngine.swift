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
        if heroIDs.count > 1 {
            let preview = heroIDs.prefix(4).map { "#\($0)" }.joined(separator: ", ")
            let suffix = heroIDs.count > 4 ? "…" : ""
            return "\(heroIDs.count) Tướng (\(preview)\(suffix))"
        } else if let h = heroID, let s = skinID {
            return "Hero #\(h) • Skin #\(s)"
        } else if let h = heroID {
            return "Hero #\(h)"
        } else {
            return "Gói Mod AOV"
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
        switch self {
        case .insufficientInputMods:
            return "Cần chọn ít nhất 2 tệp .zip mod Liên Quân để thực hiện gộp."
        case .invalidArchive(let name):
            return "Không thể đọc cấu trúc tệp nén: \(name)"
        case .missingResourceStructure(let name):
            return "Không tìm thấy cấu trúc Resources/<phiên_bản> hợp lệ trong tệp: \(name)"
        case .cryptoFailed(let detail):
            return "Lỗi máy chủ khi giải mã gói mod: \(detail)"
        case .assetBundleMergeFailed(let detail):
            return "Lỗi máy chủ khi hợp nhất AssetBundle: \(detail)"
        case .msesParseFailed(let detail):
            return "Lỗi máy chủ khi hợp nhất bảng dữ liệu Databin MSES: \(detail)"
        case .ifixPatchFailed(let detail):
            return "Lỗi máy chủ khi hợp nhất Thanos IFix Bytecode: \(detail)"
        case .zipCreationFailed(let detail):
            return "Lỗi đóng gói tệp .zip đầu ra: \(detail)"
        case .sizeLimitExceeded:
            return "Tệp vượt quá giới hạn 3.6 GB."
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

    /// Đọc metadata nhẹ (số tướng, phiên bản Resources) để hiển thị trong danh sách chọn mod.
    public func inspectModArchive(at url: URL) throws -> AovModSummary {
        guard url.pathExtension.lowercased() != "3105" else {
            throw AovModMergerError.invalidArchive(
                "\(url.lastPathComponent) (Chức năng gộp chỉ hỗ trợ tệp .zip)"
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
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2),
              magic.count == 2, magic[0] == 0x50, magic[1] == 0x4B else {
            throw AovModMergerError.invalidArchive("\(url.lastPathComponent) (Không phải tệp .zip hợp lệ)")
        }
        try? handle.close()

        if let data = try? Data(contentsOf: url),
           let entries = try? PatchZipConverter.shared.parseZipArchive(data) {
            return Self.summary(
                url: url,
                fileSize: fileSize,
                entryNames: Array(entries.keys)
            )
        }

        return Self.summary(url: url, fileSize: fileSize, entryNames: [])
    }

    /// Dựng `AovModSummary` từ danh sách đường dẫn đã có sẵn, tránh đọc lại gói mod
    /// (mỗi gói có thể 150 MB nên đọc hai lần là lãng phí I/O và bộ nhớ).
    static func summary(url: URL, fileSize: Int64, entryNames: [String]) -> AovModSummary {
        var heroIDs = Set<Int>()
        var skinIDs = Set<Int>()
        var resourceVersion: String?

        for name in entryNames {
            let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            if resourceVersion == nil,
               parts.count >= 2,
               parts[0].caseInsensitiveCompare("Resources") == .orderedSame {
                resourceVersion = String(parts[1])
            }
            for id in Self.heroIDs(inPath: name) {
                heroIDs.insert(id)
            }
            if name.lowercased().contains("/skin") {
                for id in Self.heroIDs(inPath: name) {
                    skinIDs.insert(id)
                }
            }
        }

        let sortedHeroes = heroIDs.sorted()
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

    /// Gộp nhiều gói mod `.zip` theo mô hình hybrid.
    ///
    /// - Lượt 1: chỉ trích các file cấu hình mà server thật sự merge
    ///   (`CommonActions` / `Databin` / `Thanos` / RP-RV metadata), đóng gói thành
    ///   `config_bundle.zip` vài trăm KB rồi gửi `/api/v1/merge-plan`.
    /// - Lượt 2: đọc lại từng gói mod một, ghép asset nặng vào `outURL` bằng writer
    ///   streaming. Không gói mod nào (có thể 150 MB) bị upload, và RAM đỉnh chỉ ~1 gói.
    public func mergeModArchives(
        inputURLs: [URL],
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> AovMergeResult {
        guard inputURLs.count >= 2 else {
            throw AovModMergerError.insufficientInputMods
        }

        struct PreparedMod: Sendable {
            let summary: AovModSummary
            let lightEntries: [(path: String, data: Data)]
        }

        let prepared = try await Task.detached(priority: .userInitiated) { () -> [PreparedMod] in
            var items: [PreparedMod] = []
            for (idx, url) in inputURLs.enumerated() {
                guard url.pathExtension.lowercased() != "3105" else {
                    throw AovModMergerError.invalidArchive(
                        "\(url.lastPathComponent) (Chức năng gộp chỉ hỗ trợ tệp .zip)"
                    )
                }

                progress(
                    "Đang đọc gói mod (\(idx + 1)/\(inputURLs.count)): \(url.lastPathComponent)...",
                    Double(idx) / Double(inputURLs.count) * 0.2
                )

                let hasSecurity = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurity { url.stopAccessingSecurityScopedResource() }
                }

                let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard !PatchPackageLimits.exceedsExpandedLimit(fileSize) else {
                    throw AovModMergerError.sizeLimitExceeded
                }

                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    throw AovModMergerError.invalidArchive(
                        "\(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
                guard data.count >= 4, data.prefix(2) == Data([0x50, 0x4B]) else {
                    throw AovModMergerError.invalidArchive("\(url.lastPathComponent) (Không phải tệp .zip hợp lệ)")
                }

                let entries = try PatchZipConverter.shared.parseZipArchive(data)
                var light: [(path: String, data: Data)] = []
                for path in entries.keys.sorted() {
                    guard let fileData = entries[path] else { continue }
                    if Self.isServerConfigPath(path) {
                        light.append((path: path, data: fileData))
                    }
                }

                let summary = Self.summary(
                    url: url,
                    fileSize: fileSize,
                    entryNames: Array(entries.keys)
                )
                items.append(PreparedMod(summary: summary, lightEntries: light))
                // `data` và `entries` được giải phóng khi vòng lặp sang mod kế tiếp.
            }
            return items
        }.value

        let summaries = prepared.map(\.summary)
        let logs = summaries.map { "Đã đọc \($0.fileName) (\($0.fileSize) byte)." }

        // Đóng gói config nhẹ thành config_bundle.zip theo layout mod_<idx>/...
        var configBundleEntries: [(path: String, data: Data)] = []
        for (idx, mod) in prepared.enumerated() {
            for entry in mod.lightEntries {
                configBundleEntries.append((path: "mod_\(idx)/\(entry.path)", data: entry.data))
            }
        }
        let configBundleData = try PatchZipConverter.shared.buildZipArchive(entries: configBundleEntries)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TotoroxMerge_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let configBundleURL = workDir.appendingPathComponent("config_bundle.zip")
        try configBundleData.write(to: configBundleURL, options: .atomic)

        let modPayloads: [[String: Any]] = prepared.map { mod in
            [
                "name": mod.summary.fileName,
                "heroIDs": mod.summary.heroIDs,
                "skinIDs": mod.summary.skinIDs,
            ]
        }
        // Server remap mọi `Resources/<ver>/...` về `target_version`. Client phải dùng
        // cùng version đó khi ghép asset nặng, nếu không asset sẽ rơi vào thư mục
        // version cũ và game bỏ qua.
        let targetVersion = Self.resolveTargetVersion(summaries)
        let configObject: [String: Any] = [
            "mods": modPayloads,
            "output": ["resourcesVersion": targetVersion],
        ]
        guard let configData = try? JSONSerialization.data(withJSONObject: configObject, options: [.sortedKeys]),
              let configJSON = String(data: configData, encoding: .utf8) else {
            throw AovModMergerError.zipCreationFailed("Không dựng được cấu hình gửi máy chủ.")
        }

        progress("Đang gửi config nhẹ lên máy chủ để gộp...", 0.35)

        let planResult = await APIService.shared.mergePlan(
            fileURL: configBundleURL,
            configJSON: configJSON,
            licenseKey: LicenseManager.shared.licenseKey,
            hwid: LicenseManager.shared.deviceIdentifier
        )

        let plan: MergePlanResponse
        switch planResult {
        case .success(let response):
            plan = response
        case .failure(let error):
            throw AovModMergerError.invalidArchive("Máy chủ merge-plan: \(error.localizedDescription)")
        }
        guard plan.ok else {
            throw AovModMergerError.invalidArchive("Máy chủ trả về merge-plan không hợp lệ.")
        }

        progress("Đang nhận kết quả gộp từ máy chủ...", 0.8)

        guard let encoded = plan.zipBytesB64,
              let bundle = Data(base64Encoded: encoded),
              let entries = try? PatchZipConverter.shared.parseZipArchive(bundle) else {
            throw AovModMergerError.zipCreationFailed(
                plan.note ?? "Máy chủ không trả gói kết quả (.zip)."
            )
        }

        // Hybrid: ghép file cấu hình đã merge (server) với tài nguyên nặng từ mod gốc (client).
        let mergedPaths = Set(entries.keys.map { $0.lowercased() })

        let fileManager = FileManager.default
        let outDir = fileManager.temporaryDirectory
            .appendingPathComponent("TotoroxMergedMods", isDirectory: true)
        try fileManager.createDirectory(at: outDir, withIntermediateDirectories: true)

        let outName = Self.makeMergedOutputFilename(
            loadedModsWithHeroes: summaries.map { (heroIDs: $0.heroIDs, fileName: $0.fileName) },
            fileExtension: "zip"
        )
        let outURL = outDir.appendingPathComponent(outName)
        try? fileManager.removeItem(at: outURL)

        // Hai lượt: upload chỉ cần config nhẹ; lượt ghép đọc lại từng gói mod một
        // và ghi thẳng xuống đĩa. Nhờ vậy RAM đỉnh ~1 gói thay vì cả 4 gói mod.
        do {
            let writer = try PatchZipConverter.ZipArchiveWriter(destinationURL: outURL)
            defer { writer.cancel() }
            var writtenPaths = Set<String>()

            for mod in prepared {
                progress("Đang ghép tài nguyên nặng: \(mod.summary.fileName)...", 0.85)
                let entriesOfMod = try Self.readZipEntries(at: mod.summary.url)
                for path in entriesOfMod.keys.sorted() {
                    guard let fileData = entriesOfMod[path] else { continue }
                    guard !Self.isServerConfigPath(path) else { continue }
                    let remapped = Self.remapResourceVersion(
                        path: path,
                        from: mod.summary.resourceVersion,
                        to: targetVersion
                    )
                    guard !mergedPaths.contains(remapped.lowercased()) else { continue }
                    guard writtenPaths.insert(remapped.lowercased()).inserted else { continue }
                    try writer.add(path: remapped, data: fileData)
                }
            }

            for path in entries.keys.sorted() {
                guard let data = entries[path] else { continue }
                try writer.add(path: path, data: data)
            }

            try writer.finish()
        } catch {
            try? fileManager.removeItem(at: outURL)
            throw AovModMergerError.zipCreationFailed(error.localizedDescription)
        }

        let outputSize = Int64((try? outURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        let finalLogs = logs + ["Máy chủ trả \(plan.mergePlan?.fileCount ?? 0) file đã gộp."]
        progress("Hoàn tất", 1.0)

        return AovMergeResult(
            outputZipURL: outURL,
            outputFileSize: outputSize,
            resourceVersion: targetVersion,
            mergedMods: summaries,
            totalFilesWritten: plan.mergePlan?.fileCount ?? 0,
            smartMergedConflicts: 0,
            logs: finalLogs
        )
    }

    // MARK: - Helpers

    /// Đường dẫn cấu hình mà server thật sự chạy pipeline merge:
    /// `CommonActions` (XML), `Databin` (MSES), `Thanos` (HeroSkin_1/2) và hai assetbundle
    /// metadata `ResourcePackerInfoSetAll` / `ResourceVerificationInfoSetAll` (thêm entry
    /// cho asset mới). Mọi file khác do client giữ nguyên và ghép local.
    static func isServerConfigPath(_ relativePath: String) -> Bool {
        let lower = relativePath.lowercased()
        return lower.contains("commonactions")
            || lower.contains("/databin/")
            || lower.contains("/thanos/")
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

    private static func heroIDs(inPath path: String) -> [Int] {
        let lower = path.lowercased()
        guard let regex = try? NSRegularExpression(pattern: "hero[_\\-]?(\\d{3,4})", options: []) else {
            return []
        }
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        return regex.matches(in: lower, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let idRange = Range(match.range(at: 1), in: lower) else { return nil }
            return Int(lower[idRange])
        }
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
}
