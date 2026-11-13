import Foundation
import Compression
import CommonCrypto
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
            return "Lỗi giải mã/mã hóa JG AES-128-CBC: \(detail)"
        case .assetBundleMergeFailed(let detail):
            return "Lỗi hợp nhất AssetBundle: \(detail)"
        case .msesParseFailed(let detail):
            return "Lỗi hợp nhất bảng dữ liệu Databin MSES: \(detail)"
        case .ifixPatchFailed(let detail):
            return "Lỗi hợp nhất Thanos IFix Bytecode: \(detail)"
        case .zipCreationFailed(let detail):
            return "Lỗi đóng gói tệp .zip đầu ra: \(detail)"
        case .sizeLimitExceeded:
            return "Tệp vượt quá giới hạn 3.6 GB."
        }
    }
}

// MARK: - Main Smart Merger Engine

public final class AovModMergerEngine: @unchecked Sendable {
    public static let shared = AovModMergerEngine()

    private init() {}

    // MARK: - Quick Inspection when user picks a ZIP

    public func inspectModArchive(at url: URL) throws -> AovModSummary {
        guard url.pathExtension.lowercased() != "3105" else {
            throw AovModMergerError.invalidArchive("\(url.lastPathComponent) (Chức năng gộp chỉ hỗ trợ tệp .zip)")
        }

        let hasSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurity { url.stopAccessingSecurityScopedResource() }
        }

        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard !PatchPackageLimits.exceedsExpandedLimit(fileSize) else {
            throw AovModMergerError.sizeLimitExceeded
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let magic = try? handle.read(upToCount: 2)
        guard let magic, magic.count == 2, magic[0] == 0x50, magic[1] == 0x4B else {
            throw AovModMergerError.invalidArchive("\(url.lastPathComponent) (Không phải tệp .zip hợp lệ)")
        }
        try handle.seek(toOffset: 0)

        let centralEntries: [CentralDirEntry]
        if let cd = try? readZipCentralDirectory(handle: handle, archiveSize: UInt64(max(0, fileSize))) {
            centralEntries = cd
        } else {
            centralEntries = []
        }

        var detectedHeroIDs = Set<Int>()
        var detectedSkinIDs = Set<Int>()
        var detectedVersion: String? = nil
        var normalizedPaths: [String] = []

        for entry in centralEntries where !entry.isDirectory {
            let normOpt = normalizeAovRelativePath(entry.name)
                ?? (isUnversionedAovRelativePath(entry.name) ? normalizeAovRelativePath(entry.name, fallbackVersion: "1.64.1") : nil)
            guard let norm = normOpt else { continue }
            normalizedPaths.append(norm)
            if detectedVersion == nil {
                let parts = norm.split(separator: "/")
                if parts.count >= 2 && parts[0] == "Resources" && !isUnversionedAovRelativePath(entry.name) {
                    detectedVersion = String(parts[1])
                }
            }
            for hid in extractHeroIDsFromPath(norm) {
                detectedHeroIDs.insert(hid)
            }
            let normLower = norm.lowercased()
            if normLower.hasSuffix("/thanos/heroskin_1.bytes"),
               let rawBytes = try? extractSingleEntryData(handle: handle, entry: entry),
               let dec = try? jgDecrypt(rawBytes, stem: "HeroSkin_1") {
                for pair in extractAllHeroAndSkinsFromHeroSkin1(dec) {
                    detectedHeroIDs.insert(pair.heroID)
                    detectedSkinIDs.insert(pair.skinID)
                }
            }
            if normLower.hasSuffix("/thanos/heroskin_2.bytes"),
               let rawBytes = try? extractSingleEntryData(handle: handle, entry: entry),
               let dec = try? jgDecrypt(rawBytes, stem: "HeroSkin_2") {
                for p in extractAllParamsFromHeroSkin2(dec) {
                    detectedHeroIDs.insert(p.heroID)
                }
            }
        }

        if detectedHeroIDs.isEmpty {
            for norm in normalizedPaths {
                for hid in extractFallbackHeroIDsFromAssetPath(norm) {
                    detectedHeroIDs.insert(hid)
                }
            }
        }

        let sortedHeroes = detectedHeroIDs.sorted()
        let sortedSkins = detectedSkinIDs.sorted()
        return AovModSummary(
            url: url,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            heroID: sortedHeroes.first,
            skinID: sortedSkins.first,
            resourceVersion: detectedVersion,
            heroIDs: sortedHeroes,
            skinIDs: sortedSkins
        )
    }

    // MARK: - Full Multi-Mod Smart Merge Pipeline

    public func mergeModArchives(
        inputURLs: [URL],
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> AovMergeResult {
        guard inputURLs.count >= 2 else {
            throw AovModMergerError.insufficientInputMods
        }

        return try await Task.detached(priority: .userInitiated) {
            var logs: [String] = []
            func appendLog(_ msg: String) {
                logs.append(msg)
            }

            let fm = FileManager.default
            let workDir = fm.temporaryDirectory.appendingPathComponent("AovSmartMerge_\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(at: workDir)
            }

            struct StagedMod {
                let url: URL
                let fileName: String
                let fileSize: Int64
                let extractRoot: URL
                let rawFiles: [(relRaw: String, fileURL: URL)]
                let explicitVersion: String?
            }

            var stagedMods: [StagedMod] = []
            for (idx, url) in inputURLs.enumerated() {
                guard url.pathExtension.lowercased() != "3105" else {
                    throw AovModMergerError.invalidArchive("\(url.lastPathComponent) (Chức năng gộp chỉ hỗ trợ tệp .zip)")
                }

                let stepBase = Double(idx) / Double(inputURLs.count) * 0.35
                progress("Đang giải nén gói mod (\(idx + 1)/\(inputURLs.count)): \(url.lastPathComponent)...", stepBase)

                let hasSecurity = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurity { url.stopAccessingSecurityScopedResource() }
                }

                let modRawDir = workDir.appendingPathComponent("mod_\(idx)", isDirectory: true)
                try fm.createDirectory(at: modRawDir, withIntermediateDirectories: true)

                do {
                    _ = try ZIPArchiveExtractor.extractFlatContents(archiveURL: url, into: modRawDir, fileManager: fm)
                } catch {
                    // Fallback: pure-Swift in-memory parser (handles ZIP64 / ISO-Latin-1 filenames)
                    do {
                        let archiveFileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(archiveFileSize)) else {
                            throw AovModMergerError.sizeLimitExceeded
                        }
                        let archiveData = try Data(contentsOf: url)
                        let parsed = try self.parseInMemoryZip(archiveData)
                        guard !parsed.isEmpty else {
                            throw AovModMergerError.invalidArchive(url.lastPathComponent)
                        }
                        for entry in parsed {
                            let cleanRel = entry.name.replacingOccurrences(of: "\\", with: "/")
                                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            guard !cleanRel.isEmpty else { continue }
                            let dest = modRawDir.appendingPathComponent(cleanRel)
                            let standardizedDest = dest.standardizedFileURL
                            guard standardizedDest.path.hasPrefix(modRawDir.standardizedFileURL.path + "/") else { continue }
                            try fm.createDirectory(at: standardizedDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try entry.data.write(to: standardizedDest)
                        }
                    } catch let err as AovModMergerError {
                        throw err
                    } catch {
                        throw AovModMergerError.invalidArchive(url.lastPathComponent)
                    }
                }

                var rawFiles: [(relRaw: String, fileURL: URL)] = []
                var detectedVersion: String? = nil

                if let enumerator = fm.enumerator(
                    at: modRawDir,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                        guard vals?.isRegularFile == true, vals?.isDirectory != true else { continue }
                        let relRaw = fileURL.path.replacingOccurrences(of: modRawDir.path, with: "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
                        rawFiles.append((relRaw: relRaw, fileURL: fileURL))
                        if detectedVersion == nil, let norm = self.normalizeAovRelativePath(relRaw) {
                            let parts = norm.split(separator: "/")
                            if parts.count >= 2 && parts[0] == "Resources" {
                                detectedVersion = String(parts[1])
                            }
                        }
                    }
                }

                let fsize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                stagedMods.append(StagedMod(
                    url: url,
                    fileName: url.lastPathComponent,
                    fileSize: fsize,
                    extractRoot: modRawDir,
                    rawFiles: rawFiles,
                    explicitVersion: detectedVersion
                ))
            }

            let explicitVersions = stagedMods.compactMap(\.explicitVersion)
            let targetVersion = explicitVersions.max { self.compareVersionStrings($0, $1) == .orderedAscending } ?? "1.64.1"

            struct LoadedMod {
                let summary: AovModSummary
                let extractRoot: URL
                let filesByRelPath: [String: URL]
                let heroIDs: Set<Int>
                let skinIDs: Set<Int>
                let heroSkinPairs: [(heroID: Int, skinID: Int)]
                let heroSkin2Params: [(heroID: Int, bcastID: Int, pbtnID: Int)]
                let buildVersion: AovGameBuildVersion
                let version: String
            }

            var loadedMods: [LoadedMod] = []
            for staged in stagedMods {
                let ver = staged.explicitVersion ?? targetVersion
                var map: [String: URL] = [:]
                var detectedHeroIDs = Set<Int>()
                var detectedSkinIDs = Set<Int>()

                for item in staged.rawFiles {
                    let normOpt: String?
                    if staged.explicitVersion != nil {
                        normOpt = self.normalizeAovRelativePath(item.relRaw)
                    } else {
                        normOpt = self.normalizeAovRelativePath(item.relRaw, fallbackVersion: ver)
                    }
                    guard let norm = normOpt else { continue }
                    map[norm] = item.fileURL
                    for hid in self.extractHeroIDsFromPath(norm) {
                        detectedHeroIDs.insert(hid)
                    }
                }

                guard !map.isEmpty else {
                    throw AovModMergerError.missingResourceStructure(staged.fileName)
                }

                var heroSkinPairs: [(heroID: Int, skinID: Int)] = []
                if let hs1URL = map.first(where: { $0.key.lowercased().hasSuffix("/thanos/heroskin_1.bytes") })?.value,
                   let raw1 = try? Data(contentsOf: hs1URL),
                   let dec1 = try? self.jgDecrypt(raw1, stem: "HeroSkin_1") {
                    heroSkinPairs = self.extractAllHeroAndSkinsFromHeroSkin1(dec1)
                    for pair in heroSkinPairs {
                        detectedHeroIDs.insert(pair.heroID)
                        detectedSkinIDs.insert(pair.skinID)
                    }
                }

                var heroSkin2Params: [(heroID: Int, bcastID: Int, pbtnID: Int)] = []
                if let hs2URL = map.first(where: { $0.key.lowercased().hasSuffix("/thanos/heroskin_2.bytes") })?.value,
                   let raw2 = try? Data(contentsOf: hs2URL),
                   let dec2 = try? self.jgDecrypt(raw2, stem: "HeroSkin_2") {
                    heroSkin2Params = self.extractAllParamsFromHeroSkin2(dec2)
                    for p in heroSkin2Params {
                        detectedHeroIDs.insert(p.heroID)
                    }
                }

                if detectedHeroIDs.isEmpty {
                    for norm in map.keys {
                        for hid in self.extractFallbackHeroIDsFromAssetPath(norm) {
                            detectedHeroIDs.insert(hid)
                        }
                    }
                }

                let buildVer = self.detectGameBuildVersion(filesByRelPath: map, resourceVersion: ver)
                let sortedHeroes = detectedHeroIDs.sorted()
                let sortedSkins = detectedSkinIDs.sorted()
                let summary = AovModSummary(
                    url: staged.url,
                    fileName: staged.fileName,
                    fileSize: staged.fileSize,
                    heroID: sortedHeroes.first,
                    skinID: sortedSkins.first,
                    resourceVersion: ver,
                    heroIDs: sortedHeroes,
                    skinIDs: sortedSkins
                )
                loadedMods.append(LoadedMod(
                    summary: summary,
                    extractRoot: staged.extractRoot,
                    filesByRelPath: map,
                    heroIDs: detectedHeroIDs,
                    skinIDs: detectedSkinIDs,
                    heroSkinPairs: heroSkinPairs,
                    heroSkin2Params: heroSkin2Params,
                    buildVersion: buildVer,
                    version: ver
                ))
                let heroDesc = sortedHeroes.isEmpty ? "?" : sortedHeroes.map(String.init).joined(separator: ",")
                let skinDesc = sortedSkins.isEmpty ? "?" : sortedSkins.map(String.init).joined(separator: ",")
                appendLog("Đã nạp \(staged.fileName): Hero=\(heroDesc), Skin=\(skinDesc), Build=\(buildVer.description), Version=\(ver), Files=\(map.count)")
            }

            let outputStagingRoot = workDir.appendingPathComponent("merged_root", isDirectory: true)
            try fm.createDirectory(at: outputStagingRoot, withIntermediateDirectories: true)

            // Collect union of all normalized relative paths (harmonizing version folder and grouping case-insensitively)
            var canonicalPathByLower: [String: (buildVersion: AovGameBuildVersion, path: String)] = [:]
            var remappedModFiles: [[String: URL]] = []
            for mod in loadedMods {
                var remapped: [String: URL] = [:]
                let prefixOrig = "Resources/\(mod.version)/"
                let prefixTarget = "Resources/\(targetVersion)/"
                for (path, fileURL) in mod.filesByRelPath {
                    let canonicalPath: String
                    if path.hasPrefix(prefixOrig) && mod.version != targetVersion {
                        canonicalPath = prefixTarget + String(path.dropFirst(prefixOrig.count))
                    } else {
                        canonicalPath = path
                    }
                    let lowerKey = canonicalPath.lowercased()
                    remapped[lowerKey] = fileURL
                    if let existing = canonicalPathByLower[lowerKey] {
                        if mod.buildVersion > existing.buildVersion {
                            canonicalPathByLower[lowerKey] = (mod.buildVersion, canonicalPath)
                        }
                    } else {
                        canonicalPathByLower[lowerKey] = (mod.buildVersion, canonicalPath)
                    }
                }
                remappedModFiles.append(remapped)
            }

            let sortedLowerKeys = canonicalPathByLower.keys.sorted()
            var totalWritten = 0
            var smartMergedCount = 0

            // Track merged KernelLua & StableSystems_3 MD5 hashes so Thanos/HeroSkin_1..2 can be updated
            var mergedPkgMD5s: [String: String] = [:]

            // Separate Thanos/HeroSkin_*.bytes to process last (after KernelLua & StableSystems_3 MD5s are computed)
            let nonThanosKeys = sortedLowerKeys.filter { !$0.contains("/thanos/heroskin_") }
            let thanosKeys = sortedLowerKeys.filter { $0.contains("/thanos/heroskin_") }

            for (pIdx, lowerKey) in nonThanosKeys.enumerated() {
                let relPath = canonicalPathByLower[lowerKey]!.path
                if pIdx % 12 == 0 {
                    let ratio = 0.35 + (Double(pIdx) / Double(max(1, sortedLowerKeys.count))) * 0.50
                    let shortName = (relPath as NSString).lastPathComponent
                    progress("Đang hợp nhất: \(shortName)...", ratio)
                }

                // Collect mods that have this file (case-insensitive path match)
                var contributors: [(modIndex: Int, mod: LoadedMod, url: URL)] = []
                let isDatabinBytes = lowerKey.contains("/databin/") && lowerKey.hasSuffix(".bytes")
                for (mIdx, mod) in loadedMods.enumerated() {
                    if let u = remappedModFiles[mIdx][lowerKey] {
                        if isDatabinBytes {
                            let fsize = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                            if fsize > 0 && fsize < 32 {
                                // Skip 9-byte watermark/placeholder files (e.g. ResAwakenBattleEffect.bytes)
                                continue
                            }
                        }
                        contributors.append((mIdx, mod, u))
                    }
                }
                guard let first = contributors.first else { continue }

                let destURL = outputStagingRoot.appendingPathComponent(relPath)
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                if contributors.count == 1 {
                    try fm.copyItem(at: first.url, to: destURL)
                    totalWritten += 1
                    if lowerKey.hasSuffix(".pkg.bytes"),
                       let singleData = try? Data(contentsOf: first.url) {
                        let fileName = (relPath as NSString).lastPathComponent
                        mergedPkgMD5s[fileName] = self.md5Hex(singleData)
                    }
                    continue
                }

                // Multiple mods have this file — check if bytes are identical
                let firstData = try Data(contentsOf: first.url)
                var allIdentical = true
                var otherDatas: [(mod: LoadedMod, data: Data)] = [(first.mod, firstData)]

                for item in contributors.dropFirst() {
                    let d = try Data(contentsOf: item.url)
                    if d != firstData {
                        allIdentical = false
                    }
                    otherDatas.append((item.mod, d))
                }

                if allIdentical {
                    try firstData.write(to: destURL)
                    totalWritten += 1
                    if lowerKey.hasSuffix(".pkg.bytes") {
                        let fileName = (relPath as NSString).lastPathComponent
                        mergedPkgMD5s[fileName] = self.md5Hex(firstData)
                    }
                    continue
                }

                // Smart Binary Merge based on file type!
                let mergedData: Data
                if lowerKey.hasSuffix("resourcepackerinfosetall.assetbundle") {
                    mergedData = try self.mergeResourcePackerAssetBundle(otherDatas.map(\.data))
                    smartMergedCount += 1
                    appendLog("Gộp thông minh UnityFS LZ4: \(relPath) (\(mergedData.count) bytes)")
                } else if lowerKey.hasSuffix("resourceverificationinfosetall.assetbundle") {
                    mergedData = self.mergeResourceVerificationAssetBundle(otherDatas.map(\.data))
                    smartMergedCount += 1
                    appendLog("Gộp ResourceVerificationInfoSetAll (\(mergedData.count) bytes)")
                } else if lowerKey.hasSuffix("commonactions.pkg.bytes") {
                    let inputs = otherDatas.map { (heroIDs: $0.mod.heroIDs, buildVersion: $0.mod.buildVersion, data: $0.data) }
                    mergedData = try self.mergeCommonActionsPkg(inputs: inputs, logs: &logs)
                    smartMergedCount += 1
                    appendLog("Gộp thông minh XML Zstd: \(relPath) (\(mergedData.count) bytes)")
                } else if lowerKey.hasSuffix(".pkg.bytes") {
                    let inputs = otherDatas.map { (buildVersion: $0.mod.buildVersion, data: $0.data) }
                    let merged = try self.mergeGenericPkgZipPreferModified(inputs)
                    mergedData = merged
                    smartMergedCount += 1
                    let fileName = (relPath as NSString).lastPathComponent
                    mergedPkgMD5s[fileName] = self.md5Hex(merged)
                    appendLog("Gộp gói ZIP \(fileName): MD5=\(mergedPkgMD5s[fileName] ?? "")")
                } else if isDatabinBytes {
                    let stem = ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension
                    let inputs = otherDatas.map { (heroIDs: $0.mod.heroIDs, buildVersion: $0.mod.buildVersion, data: $0.data) }
                    mergedData = try self.mergeDatabinMsesFile(stem: stem, inputs: inputs)
                    smartMergedCount += 1
                    appendLog("Gộp bảng Databin MSES: \(stem).bytes")
                } else {
                    // Default fallback for unknown colliding file: prefer higher game build version, then latest mod
                    let bestItem = otherDatas.max { a, b in
                        a.mod.buildVersion < b.mod.buildVersion
                    } ?? otherDatas.last!
                    mergedData = bestItem.data
                }

                try mergedData.write(to: destURL)
                totalWritten += 1
            }

            // Now process Thanos/HeroSkin_1.bytes & HeroSkin_2.bytes
            progress("Đang hợp nhất bytecode Thanos IFix & cập nhật MD5...", 0.88)
            for lowerKey in thanosKeys {
                let relPath = canonicalPathByLower[lowerKey]!.path
                var contributors: [(mod: LoadedMod, data: Data)] = []
                for (mIdx, mod) in loadedMods.enumerated() {
                    if let u = remappedModFiles[mIdx][lowerKey],
                       let d = try? Data(contentsOf: u) {
                        contributors.append((mod, d))
                    }
                }
                guard !contributors.isEmpty else { continue }
                let destURL = outputStagingRoot.appendingPathComponent(relPath)
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let fileName = (relPath as NSString).lastPathComponent
                let stem = (fileName as NSString).deletingPathExtension
                let stemLower = stem.lowercased()

                if stemLower == "heroskin_1" {
                    let merged = try self.mergeThanosHeroSkin1(
                        contributors: contributors.map {
                            (heroID: $0.mod.summary.heroID, skinID: $0.mod.summary.skinID, buildVersion: $0.mod.buildVersion, encrypted: $0.data)
                        },
                        pkgMD5s: mergedPkgMD5s
                    )
                    if !merged.isEmpty {
                        try merged.write(to: destURL)
                        totalWritten += 1
                        smartMergedCount += 1
                        appendLog("Gộp IFix Bytecode: Thanos/HeroSkin_1.bytes (\(contributors.count) nguồn)")
                    }
                } else if stemLower == "heroskin_2" {
                    let merged = try self.mergeThanosHeroSkin2(
                        contributors: contributors.map {
                            (
                                heroID: $0.mod.summary.heroID,
                                bcastID: $0.mod.heroSkin2Params.first?.bcastID,
                                pbtnID: $0.mod.heroSkin2Params.first?.pbtnID,
                                buildVersion: $0.mod.buildVersion,
                                encrypted: $0.data
                            )
                        },
                        pkgMD5s: mergedPkgMD5s
                    )
                    if !merged.isEmpty {
                        try merged.write(to: destURL)
                        totalWritten += 1
                        smartMergedCount += 1
                        appendLog("Gộp IFix Bytecode: Thanos/HeroSkin_2.bytes (\(contributors.count) nguồn)")
                    }
                } else {
                    let bestItem = contributors.max { a, b in
                        if a.mod.buildVersion != b.mod.buildVersion { return a.mod.buildVersion < b.mod.buildVersion }
                        return a.data.count < b.data.count
                    } ?? contributors.last!
                    if var dec = try? self.jgDecrypt(bestItem.data, stem: stem), !mergedPkgMD5s.isEmpty {
                        let before = dec
                        self.updateEmbeddedPkgMD5s(in: &dec, pkgMD5s: mergedPkgMD5s)
                        if dec != before, let reEnc = try? self.jgEncrypt(dec, stem: stem) {
                            try reEnc.write(to: destURL)
                            totalWritten += 1
                            continue
                        }
                    }
                    try bestItem.data.write(to: destURL)
                    totalWritten += 1
                }
            }

            // Package output .zip with Resources/<version>/... at root
            progress("Đang đóng gói tệp .zip đầu ra...", 0.94)
            let resourcesFolderURL = outputStagingRoot.appendingPathComponent("Resources", isDirectory: true)
            guard fm.fileExists(atPath: resourcesFolderURL.path) else {
                throw AovModMergerError.zipCreationFailed("Không tìm thấy thư mục Resources sau khi hợp nhất.")
            }

            let outZipName = Self.makeMergedOutputFilename(
                loadedModsWithHeroes: loadedMods.map { (heroIDs: $0.summary.heroIDs, fileName: $0.summary.fileName) },
                fileExtension: "zip"
            )
            let outDir = fm.temporaryDirectory.appendingPathComponent("TotoroxMergedMods", isDirectory: true)
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            let outZipURL = outDir.appendingPathComponent(outZipName)
            if fm.fileExists(atPath: outZipURL.path) {
                try? fm.removeItem(at: outZipURL)
            }

            do {
                _ = try ZIPArchiveWriter.write(items: [resourcesFolderURL], to: outZipURL, fileManager: fm)
            } catch {
                throw AovModMergerError.zipCreationFailed(error.localizedDescription)
            }

            let finalSize = Int64((try? outZipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            progress("Hoàn tất gộp file mod!", 1.0)

            return AovMergeResult(
                outputZipURL: outZipURL,
                outputFileSize: finalSize,
                resourceVersion: targetVersion,
                mergedMods: loadedMods.map(\.summary),
                totalFilesWritten: totalWritten,
                smartMergedConflicts: smartMergedCount,
                logs: logs
            )
        }.value
    }

    // MARK: - Path Normalization & Hero ID Detection

    private static let aovKnownRootDirectories: Set<String> = [
        "ages", "assetrefs", "databin", "assetbundle", "sound",
        "thanos", "prefab_characters", "behaviac", "lua_signed"
    ]

    private static let aovKnownRootFiles: Set<String> = [
        "version.txt", "heroinfolua.pkg.bytes", "kernellua.pkg.bytes", "stablesystems_3.pkg.bytes"
    ]

    private func isUnversionedAovRelativePath(_ rawPath: String) -> Bool {
        let unified = rawPath.replacingOccurrences(of: "\\", with: "/")
        let components = unified
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        guard !components.isEmpty, !components.contains("__MACOSX") else { return false }
        if let last = components.last, last == ".DS_Store" || last.hasPrefix("._") {
            return false
        }
        let firstLower = components[0].lowercased()
        if Self.aovKnownRootDirectories.contains(firstLower) {
            return components.count >= 2
        }
        if components.count == 1 && Self.aovKnownRootFiles.contains(firstLower) {
            return true
        }
        return false
    }

    public func normalizeAovRelativePath(_ rawPath: String) -> String? {
        return normalizeAovRelativePath(rawPath, fallbackVersion: nil)
    }

    public func normalizeAovRelativePath(_ rawPath: String, fallbackVersion: String?) -> String? {
        let unified = rawPath.replacingOccurrences(of: "\\", with: "/")
        let components = unified
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }

        guard !components.isEmpty else { return nil }
        if components.contains("__MACOSX") { return nil }
        if let last = components.last, last == ".DS_Store" || last.hasPrefix("._") {
            return nil
        }

        // Look for "Resources" component (case-insensitive)
        if let resIdx = components.firstIndex(where: { $0.lowercased() == "resources" }) {
            let tail = components.suffix(from: resIdx + 1)
            guard !tail.isEmpty else { return nil }
            return (["Resources"] + tail).joined(separator: "/")
        }

        // Check if path starts with a version directory like "1.64.1/Ages/..."
        if components.count >= 2,
           components[0].range(of: #"^\d+\.\d+(\.\d+)*$"#, options: .regularExpression) != nil {
            return (["Resources"] + components).joined(separator: "/")
        }

        // Check nested version directory like "ModPack/1.64.1/Ages/..." followed by an AoV resource dir/file
        if components.count >= 3 {
            for idx in 1..<(components.count - 1) {
                let comp = components[idx]
                let nextLower = components[idx + 1].lowercased()
                if comp.range(of: #"^\d+\.\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil,
                   Self.aovKnownRootDirectories.contains(nextLower) || Self.aovKnownRootFiles.contains(nextLower) {
                    return (["Resources"] + Array(components[idx...])).joined(separator: "/")
                }
            }
        }

        // Optional fallback for versionless mod archives rooted directly at Ages/, Databin/, Sound/, Thanos/, etc.
        if let fallbackVer = fallbackVersion, !fallbackVer.isEmpty {
            let firstLower = components[0].lowercased()
            if (Self.aovKnownRootDirectories.contains(firstLower) && components.count >= 2) ||
                (components.count == 1 && Self.aovKnownRootFiles.contains(firstLower)) {
                return (["Resources", fallbackVer] + components).joined(separator: "/")
            }
        }

        return nil
    }

    private func extractHeroIDsFromPath(_ normPath: String) -> [Int] {
        let fileName = (normPath as NSString).lastPathComponent
        var found: [Int] = []
        // Pattern 1: Actor_131_Actions.pkg.bytes or Actor_131_Infos.pkg.bytes
        if fileName.hasPrefix("Actor_") {
            let parts = fileName.split(separator: "_")
            if parts.count >= 2, let hid = Int(parts[1]), hid >= 100 && hid <= 9999 {
                found.append(hid)
            }
        }
        // Pattern 2: 131_AssetRef.bytes
        if fileName.hasSuffix("_AssetRef.bytes") {
            let prefix = fileName.replacingOccurrences(of: "_AssetRef.bytes", with: "")
            if let hid = Int(prefix), hid >= 100 && hid <= 9999 {
                found.append(hid)
            }
        }
        return found
    }

    private func extractHeroIDFromPath(_ normPath: String) -> Int? {
        return extractHeroIDsFromPath(normPath).first
    }

    private func extractFallbackHeroIDsFromAssetPath(_ normPath: String) -> [Int] {
        let lowerParts = normPath.lowercased().split(separator: "/")
        guard lowerParts.count >= 2 else { return [] }
        for i in 0..<(lowerParts.count - 1) where lowerParts[i] == "hero" {
            let candidate = lowerParts[i + 1]
            let digits = candidate.prefix { $0.isNumber }
            if digits.count == 3 || digits.count == 4,
               let nextIdx = candidate.index(candidate.startIndex, offsetBy: digits.count, limitedBy: candidate.endIndex),
               nextIdx == candidate.endIndex || candidate[nextIdx] == "_" || candidate[nextIdx] == ".",
               let hid = Int(digits), hid >= 100 && hid <= 9999 {
                return [hid]
            }
        }
        return []
    }

    // MARK: - Build Version Detection & Semantic Comparison

    private struct AovGameBuildVersion: Comparable, Hashable {
        let versionTuple: [Int]
        let buildNumber: Int
        let versionText: String

        static let zero = AovGameBuildVersion(versionTuple: [], buildNumber: 0, versionText: "0")

        var description: String {
            let ver = versionText.isEmpty ? "unknown" : versionText
            return buildNumber > 0 ? "\(ver) (\(buildNumber))" : ver
        }

        static func < (lhs: AovGameBuildVersion, rhs: AovGameBuildVersion) -> Bool {
            let maxLen = max(lhs.versionTuple.count, rhs.versionTuple.count)
            for i in 0..<maxLen {
                let lv = i < lhs.versionTuple.count ? lhs.versionTuple[i] : 0
                let rv = i < rhs.versionTuple.count ? rhs.versionTuple[i] : 0
                if lv != rv { return lv < rv }
            }
            return lhs.buildNumber < rhs.buildNumber
        }
    }

    private func parseVersionTuple(_ version: String) -> [Int] {
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        return cleaned.split(separator: ".").map { part -> Int in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }

    private func compareVersionStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lParts = parseVersionTuple(lhs)
        let rParts = parseVersionTuple(rhs)
        let count = max(lParts.count, rParts.count)
        for i in 0..<count {
            let lVal = i < lParts.count ? lParts[i] : 0
            let rVal = i < rParts.count ? rParts[i] : 0
            if lVal < rVal { return .orderedAscending }
            if lVal > rVal { return .orderedDescending }
        }
        return .orderedSame
    }

    private func parseVersionAndBuild(after marker: [UInt8], in payload: [UInt8], extraPaddingBytes: Int = 0) -> AovGameBuildVersion? {
        guard let idx = findSubsliceBytes(payload, marker, from: 0) else { return nil }
        let pos = idx + marker.count + extraPaddingBytes
        return parseVersionAndBuildAt(offset: pos, in: payload)
    }

    private func parseVersionAndBuildAt(offset start: Int, in bytes: [UInt8]) -> AovGameBuildVersion? {
        var pos = start
        guard pos + 4 <= bytes.count else { return nil }
        let verLen = Int(readU32LE(bytes, pos))
        pos += 4
        guard verLen > 0, verLen <= 32, pos + ((verLen + 3) & ~3) + 4 <= bytes.count else { return nil }
        let verStr = String(decoding: bytes[pos..<(pos + verLen)], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let verTuple = parseVersionTuple(verStr)
        guard !verTuple.isEmpty else { return nil }
        pos += (verLen + 3) & ~3

        let buildLen = Int(readU32LE(bytes, pos))
        pos += 4
        var buildNum = 0
        if buildLen > 0, buildLen <= 32, pos + buildLen <= bytes.count {
            let buildStr = String(decoding: bytes[pos..<(pos + buildLen)], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            buildNum = Int(buildStr) ?? 0
        }
        return AovGameBuildVersion(versionTuple: verTuple, buildNumber: buildNum, versionText: verStr)
    }

    private func detectGameBuildVersion(filesByRelPath: [String: URL], resourceVersion: String) -> AovGameBuildVersion {
        var candidates: [AovGameBuildVersion] = []

        if let rvEntry = filesByRelPath.first(where: { $0.key.lowercased().hasSuffix("resourceverificationinfosetall.assetbundle") }),
           let rvData = try? Data(contentsOf: rvEntry.value),
           let unpacked = try? unpackUnityFS(rvData) {
            let rvMarker: [UInt8] = [0x1E, 0x00, 0x00, 0x00] + Array("ResourceVerificationInfoSetXML".utf8)
            if let v = parseVersionAndBuild(after: rvMarker, in: unpacked.payload, extraPaddingBytes: 2)
                ?? parseVersionAndBuild(after: rvMarker, in: unpacked.payload, extraPaddingBytes: 0) {
                candidates.append(v)
            }
        }

        if let rpEntry = filesByRelPath.first(where: { $0.key.lowercased().hasSuffix("resourcepackerinfosetall.assetbundle") }),
           let rpData = try? Data(contentsOf: rpEntry.value),
           let unpacked = try? unpackUnityFS(rpData) {
            let rpMarker: [UInt8] = [0x18, 0x00, 0x00, 0x00] + Array("ResourcePackerInfoSetXML".utf8)
            if let v = parseVersionAndBuild(after: rpMarker, in: unpacked.payload, extraPaddingBytes: 0) {
                candidates.append(v)
            }
        }

        if let verEntry = filesByRelPath.first(where: { $0.key.lowercased().hasSuffix("/version.txt") || $0.key.lowercased() == "version.txt" }),
           let verData = try? Data(contentsOf: verEntry.value),
           let verRaw = String(data: verData, encoding: .utf8) {
            let parts = verRaw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "|", omittingEmptySubsequences: true)
            if let verPart = parts.first {
                let verStr = String(verPart).trimmingCharacters(in: .whitespacesAndNewlines)
                let tuple = parseVersionTuple(verStr)
                if !tuple.isEmpty {
                    let buildNum = parts.count >= 2 ? (Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : 0
                    candidates.append(AovGameBuildVersion(versionTuple: tuple, buildNumber: buildNum, versionText: verStr))
                }
            }
        }

        // If a mod accidentally bundles a spoofed higher version.txt / ResourcePacker while its actual ResourceVerification & tables are older (e.g. Amily 1.63.1.14), min() reflects its true base build.
        if let effective = candidates.min() {
            return effective
        }

        let fallbackTuple = parseVersionTuple(resourceVersion)
        return AovGameBuildVersion(versionTuple: fallbackTuple, buildNumber: 0, versionText: resourceVersion)
    }

    private func readU32LE(_ bytes: [UInt8], _ off: Int) -> UInt32 {
        return UInt32(bytes[off])
            | (UInt32(bytes[off + 1]) << 8)
            | (UInt32(bytes[off + 2]) << 16)
            | (UInt32(bytes[off + 3]) << 24)
    }

    private func findSubsliceBytes(_ haystack: [UInt8], _ needle: [UInt8], from startOffset: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count + startOffset else { return nil }
        let firstByte = needle[0]
        let nLen = needle.count
        let limit = haystack.count - nLen
        var i = startOffset
        while i <= limit {
            if haystack[i] == firstByte {
                var matched = true
                for j in 1..<nLen {
                    if haystack[i + j] != needle[j] {
                        matched = false
                        break
                    }
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Format 1: UnityFS v8 LZ4 AssetBundle Helpers & Mergers

    private struct UnpackedUnityFS {
        let sizeFieldOffset: Int
        let headerEnd: Int
        let header: Data
        let infoRaw: Data
        let tailInfo: Data
        let uncompressedSize: Int
        let payload: [UInt8]
    }

    private func unpackUnityFS(_ data: Data) throws -> UnpackedUnityFS {
        guard data.count > 133,
              String(data: data.subdata(in: 0..<7), encoding: .ascii) == "UnityFS" else {
            throw AovModMergerError.assetBundleMergeFailed("Header không phải UnityFS hợp lệ.")
        }

        // Skip "UnityFS\0" (8B) + version (4B) = 12, then skip 2 null-terminated version strings ("5.x.x\0", "2022.3.5f1\0")
        var pos = 12
        for _ in 0..<2 {
            while pos < data.count && data[data.startIndex + pos] != 0 {
                pos += 1
            }
            pos += 1 // skip null terminator
        }
        guard pos + 20 <= data.count else {
            throw AovModMergerError.assetBundleMergeFailed("Header UnityFS bị cắt cụt tại offset \(pos).")
        }

        let flags = readUInt32BE(data, pos + 16)
        let compInfoSize = Int(readUInt32BE(data, pos + 8))
        let uncompInfoSize = Int(readUInt32BE(data, pos + 12))
        let baseHeaderEnd = ((pos + 20) + 15) & ~15
        var dataStart = baseHeaderEnd

        guard compInfoSize > 0, uncompInfoSize >= 32 else {
            throw AovModMergerError.assetBundleMergeFailed("Kích thước BlocksInfo không hợp lệ (comp=\(compInfoSize), uncomp=\(uncompInfoSize)).")
        }

        let infoAtEnd = (flags & 0x80) != 0
        let compType = flags & 0x3F

        let infoComp: Data
        if infoAtEnd {
            guard compInfoSize < data.count - baseHeaderEnd else {
                throw AovModMergerError.assetBundleMergeFailed("Kích thước BlocksInfo đuôi vượt quá giới hạn file.")
            }
            infoComp = data.subdata(in: (data.count - compInfoSize)..<data.count)
        } else {
            guard baseHeaderEnd + compInfoSize <= data.count else {
                throw AovModMergerError.assetBundleMergeFailed("BlocksInfo đầu vượt quá giới hạn file.")
            }
            infoComp = data.subdata(in: baseHeaderEnd..<(baseHeaderEnd + compInfoSize))
            dataStart = ((baseHeaderEnd + compInfoSize) + 15) & ~15
        }

        let infoRaw = (compType == 2 || compType == 3)
            ? try lz4DecompressBlock(infoComp, uncompressedSize: uncompInfoSize)
            : infoComp

        let blockCompType = infoRaw.count >= 22 ? Int(readUInt16BE(infoRaw, 20)) & 0x3F : 2
        let compBlockSize = infoRaw.count >= 28 ? Int(readUInt32BE(infoRaw, 24)) : (data.count - dataStart)
        let u28 = infoRaw.count >= 32 ? Int(readUInt32BE(infoRaw, 28)) : compBlockSize
        let uncompBlockSize = (u28 > 0 && u28 < 50_000_000) ? u28 : compBlockSize

        guard uncompBlockSize > 0 && uncompBlockSize < 50_000_000 else {
            throw AovModMergerError.assetBundleMergeFailed("Kích thước payload giải nén không hợp lệ: \(uncompBlockSize)")
        }

        let compBlockData: Data
        if infoAtEnd {
            let availEnd = data.count - compInfoSize
            let blockEnd = min(availEnd, dataStart + compBlockSize)
            compBlockData = data.subdata(in: dataStart..<max(dataStart, blockEnd))
        } else {
            let blockEnd = min(data.count, dataStart + compBlockSize)
            compBlockData = data.subdata(in: dataStart..<max(dataStart, blockEnd))
        }

        let payloadData: Data
        if blockCompType == 2 || blockCompType == 3 {
            payloadData = try lz4DecompressBlock(compBlockData, uncompressedSize: uncompBlockSize)
        } else {
            payloadData = compBlockData.prefix(uncompBlockSize)
        }

        return UnpackedUnityFS(
            sizeFieldOffset: pos,
            headerEnd: baseHeaderEnd,
            header: data.subdata(in: 0..<baseHeaderEnd),
            infoRaw: infoRaw,
            tailInfo: infoAtEnd ? infoComp : Data(),
            uncompressedSize: uncompBlockSize,
            payload: [UInt8](payloadData)
        )
    }

    private func mergeResourceVerificationAssetBundle(_ bundles: [Data]) -> Data {
        guard let first = bundles.first else { return Data() }
        let rvMarker: [UInt8] = [0x1E, 0x00, 0x00, 0x00] + Array("ResourceVerificationInfoSetXML".utf8)

        var bestRaw = first
        var bestBuild = AovGameBuildVersion.zero
        var bestPayloadCount = -1

        for raw in bundles {
            if let unpacked = try? unpackUnityFS(raw) {
                let parsedBuild = parseVersionAndBuild(after: rvMarker, in: unpacked.payload, extraPaddingBytes: 2)
                    ?? parseVersionAndBuild(after: rvMarker, in: unpacked.payload, extraPaddingBytes: 0)
                    ?? AovGameBuildVersion.zero
                let pCount = unpacked.payload.count

                let isBetter: Bool
                if bestPayloadCount < 0 {
                    isBetter = true
                } else if parsedBuild != bestBuild {
                    isBetter = parsedBuild > bestBuild
                } else if pCount != bestPayloadCount {
                    isBetter = pCount > bestPayloadCount
                } else {
                    isBetter = raw.count > bestRaw.count
                }

                if isBetter {
                    bestRaw = raw
                    bestBuild = parsedBuild
                    bestPayloadCount = pCount
                }
            } else if bestPayloadCount < 0 && raw.count > bestRaw.count {
                bestRaw = raw
            }
        }
        return bestRaw
    }

    private func mergeResourcePackerAssetBundle(_ bundles: [Data]) throws -> Data {
        guard !bundles.isEmpty else {
            throw AovModMergerError.assetBundleMergeFailed("Dữ liệu AssetBundle rỗng.")
        }

        struct RPackRecordRange {
            let hashesStart: Int
            let hashesEnd: Int
        }

        struct ParsedRPackBundle {
            let unpacked: UnpackedUnityFS
            let idx1: Int
            let idx2: Int
            let verBlock: [UInt8]
            let parsedVersion: AovGameBuildVersion
            let recCount: Int
            let records: [String: RPackRecordRange]
        }

        let rpackMarker: [UInt8] = [0x18, 0x00, 0x00, 0x00] + Array("ResourcePackerInfoSetXML".utf8)
        let kianaMarker: [UInt8] = [0x4B, 0x69, 0x61, 0x6E, 0x61, 0x4D, 0x6F, 0x64] // "KianaMod"

        func parseRPackRecords(_ unpacked: UnpackedUnityFS) -> ParsedRPackBundle? {
            let p = unpacked.payload
            guard let idx1 = findSubsliceBytes(p, rpackMarker, from: 0),
                  let idx2 = findSubsliceBytes(p, rpackMarker, from: idx1 + rpackMarker.count),
                  idx2 + 32 <= p.count else {
                return nil
            }
            let verBlock = Array(p[(idx1 + rpackMarker.count)..<idx2])
            let parsedVer = parseVersionAndBuildAt(offset: idx1 + rpackMarker.count, in: p) ?? AovGameBuildVersion.zero
            let recCount = Int(readU32LE(p, idx2 + 28))
            guard recCount > 0 && recCount < 200_000 else { return nil }

            var pos = idx2 + 32
            var records: [String: RPackRecordRange] = [:]
            records.reserveCapacity(recCount)

            for _ in 0..<recCount {
                guard pos + 4 <= p.count else { return nil }
                let pathLen = Int(readU32LE(p, pos))
                pos += 4
                guard pathLen >= 0, pos + ((pathLen + 3) & ~3) + 16 <= p.count else { return nil }
                let path = String(decoding: p[pos..<(pos + pathLen)], as: UTF8.self)
                pos += (pathLen + 3) & ~3
                pos += 12 // 3 * UInt32LE (pkgType, crcXor, flags)

                let tagLen = Int(readU32LE(p, pos))
                pos += 4
                guard tagLen >= 0, pos + ((tagLen + 3) & ~3) + 8 <= p.count else { return nil }
                pos += (tagLen + 3) & ~3
                pos += 4 // 1 * UInt32LE

                let hcnt = Int(readU32LE(p, pos))
                pos += 4
                guard hcnt >= 0 && hcnt < 10_000 else { return nil }
                let hashesStart = pos
                for _ in 0..<hcnt {
                    guard pos + 12 <= p.count else { return nil }
                    pos += 8 // 8-byte HashCode
                    let extLen = Int(readU32LE(p, pos))
                    pos += 4
                    guard extLen >= 0, pos + ((extLen + 3) & ~3) <= p.count else { return nil }
                    pos += (extLen + 3) & ~3
                }
                let hashesEnd = pos
                records[path] = RPackRecordRange(hashesStart: hashesStart, hashesEnd: hashesEnd)
            }

            return ParsedRPackBundle(
                unpacked: unpacked,
                idx1: idx1,
                idx2: idx2,
                verBlock: verBlock,
                parsedVersion: parsedVer,
                recCount: recCount,
                records: records
            )
        }

        let unpackedBundles = try bundles.map { try unpackUnityFS($0) }
        let parsedBundles = unpackedBundles.compactMap { parseRPackRecords($0) }

        let baseUnpacked: UnpackedUnityFS
        var mergedBytes: [UInt8]

        if parsedBundles.count == unpackedBundles.count, !parsedBundles.isEmpty {
            // Choose the bundle with the highest record count (e.g. Edras with 22,301 records) as base
            var baseIdx = 0
            for i in 1..<parsedBundles.count {
                let cand = parsedBundles[i]
                let cur = parsedBundles[baseIdx]
                if cand.recCount > cur.recCount ||
                   (cand.recCount == cur.recCount && cand.parsedVersion > cur.parsedVersion) ||
                   (cand.recCount == cur.recCount && cand.parsedVersion == cur.parsedVersion && cand.unpacked.payload.count > cur.unpacked.payload.count) {
                    baseIdx = i
                }
            }

            let baseParsed = parsedBundles[baseIdx]
            baseUnpacked = baseParsed.unpacked
            mergedBytes = baseUnpacked.payload
            let baseBytes = baseUnpacked.payload

            // Find the newest semantic version/build block with matching length (so serialized offsets never shift)
            var newestVerBlock = baseParsed.verBlock
            var newestVer = baseParsed.parsedVersion
            for pb in parsedBundles {
                if pb.verBlock.count == baseParsed.verBlock.count && pb.parsedVersion > newestVer {
                    newestVer = pb.parsedVersion
                    newestVerBlock = pb.verBlock
                }
            }

            if newestVerBlock != baseParsed.verBlock && newestVerBlock.count == baseParsed.verBlock.count && !newestVerBlock.isEmpty {
                var searchFrom = 0
                while let pos = findSubsliceBytes(mergedBytes, baseParsed.verBlock, from: searchFrom) {
                    for k in 0..<newestVerBlock.count {
                        mergedBytes[pos + k] = newestVerBlock[k]
                    }
                    searchFrom = pos + newestVerBlock.count
                }
            }

            // Merge records by PathInIFS key so record offset differences never corrupt string lengths!
            for (idx, otherParsed) in parsedBundles.enumerated() where idx != baseIdx {
                let otherBytes = otherParsed.unpacked.payload
                let otherIsNewer = (otherParsed.parsedVersion > baseParsed.parsedVersion)
                    || (otherParsed.parsedVersion == baseParsed.parsedVersion && otherParsed.verBlock == newestVerBlock)

                for (path, oRec) in otherParsed.records {
                    guard let bRec = baseParsed.records[path] else { continue }
                    let bLen = bRec.hashesEnd - bRec.hashesStart
                    let oLen = oRec.hashesEnd - oRec.hashesStart
                    guard bLen == oLen, bLen >= 12 else { continue }

                    var copiedKiana = false
                    var k = 0
                    while k <= oLen - 12 {
                        let oPos = oRec.hashesStart + k
                        if otherBytes[oPos] == 0x4B &&
                            otherBytes[oPos + 1] == 0x69 &&
                            Array(otherBytes[oPos..<(oPos + 8)]) == kianaMarker {
                            let bPos = bRec.hashesStart + k
                            for byteIdx in 0..<12 {
                                mergedBytes[bPos + byteIdx] = otherBytes[oPos + byteIdx]
                            }
                            copiedKiana = true
                            k += 12
                        } else {
                            k += 1
                        }
                    }

                    if !copiedKiana && otherIsNewer {
                        var otherDiffersFromBase = false
                        for byteIdx in 0..<bLen {
                            if otherBytes[oRec.hashesStart + byteIdx] != baseBytes[bRec.hashesStart + byteIdx] {
                                otherDiffersFromBase = true
                                break
                            }
                        }
                        if otherDiffersFromBase {
                            var mergedAlreadyHasKiana = false
                            var mCheck = 0
                            while mCheck <= bLen - 8 {
                                let bPos = bRec.hashesStart + mCheck
                                if mergedBytes[bPos] == 0x4B && Array(mergedBytes[bPos..<(bPos + 8)]) == kianaMarker {
                                    mergedAlreadyHasKiana = true
                                    break
                                }
                                mCheck += 1
                            }
                            if !mergedAlreadyHasKiana {
                                for byteIdx in 0..<bLen {
                                    mergedBytes[bRec.hashesStart + byteIdx] = otherBytes[oRec.hashesStart + byteIdx]
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // Fallback for synthetic test payloads without ResourcePackerInfoSetXML schema
            baseUnpacked = unpackedBundles[0]
            mergedBytes = baseUnpacked.payload
            let baseBytes = baseUnpacked.payload

            for otherUnpacked in unpackedBundles.dropFirst() {
                let otherBytes = otherUnpacked.payload
                let limit = min(mergedBytes.count, otherBytes.count)

                if limit >= 12 {
                    var i = 0
                    while i <= limit - 12 {
                        if otherBytes[i] == 0x4B &&
                            otherBytes[i + 1] == 0x69 &&
                            Array(otherBytes[i..<(i + 8)]) == kianaMarker {
                            for k in 0..<12 {
                                mergedBytes[i + k] = otherBytes[i + k]
                            }
                            i += 12
                        } else {
                            i += 1
                        }
                    }
                }

                var idx = 0
                while idx < limit {
                    if otherBytes[idx] != baseBytes[idx] {
                        let checkStart = max(0, idx - 11)
                        let checkEnd = min(limit - 8, idx)
                        var baseHasKiana = false
                        if checkStart <= checkEnd {
                            for pos in checkStart...checkEnd {
                                if baseBytes[pos] == 0x4B && Array(baseBytes[pos..<(pos + 8)]) == kianaMarker {
                                    baseHasKiana = true
                                    break
                                }
                            }
                        }
                        if !baseHasKiana {
                            mergedBytes[idx] = otherBytes[idx]
                        }
                    }
                    idx += 1
                }
            }
        }

        // Re-compress mergedBytes using Apple's COMPRESSION_LZ4_RAW
        let mergedData = Data(mergedBytes)
        let compressedPayload = try lz4CompressBlock(mergedData)
        let newCompSize = UInt32(compressedPayload.count)
        let newUncompSize = UInt32(mergedBytes.count)

        var newHeader = baseUnpacked.header
        var newTailInfo = baseUnpacked.tailInfo
        let sizeFieldPos = baseUnpacked.sizeFieldOffset

        if baseUnpacked.infoRaw.count == 93 && newCompSize < 0x0100_0000 && newUncompSize < 0x0100_0000 {
            // Exact 69-byte Garena UnityFS LZ4 BlocksInfo tail with CAB directory node & updated sizes
            var tail = Data(capacity: 69)
            tail.append(contentsOf: [0x1E, 0x00, 0x01, 0x00, 0xD1, 0x01, 0x00, 0x02, 0x00, 0x00])
            var compBE = Data(count: 4)
            writeUInt32BE(&compBE, offset: 0, value: newCompSize)
            tail.append(compBE)
            var uncompBE = Data(count: 4)
            writeUInt32BE(&uncompBE, offset: 0, value: newUncompSize)
            tail.append(uncompBE)
            tail.append(contentsOf: [0x10, 0x00, 0x00, 0x01, 0x00, 0x02, 0x0C, 0x00, 0x04, 0x24, 0x00, 0xF0, 0x17])
            tail.append(baseUnpacked.infoRaw.subdata(in: 55..<93))
            newTailInfo = tail
            writeUInt32BE(&newHeader, offset: sizeFieldPos + 8, value: 69)
            writeUInt32BE(&newHeader, offset: sizeFieldPos + 12, value: 93)
            writeUInt32BE(&newHeader, offset: sizeFieldPos + 16, value: 0x00C2)
        } else {
            var infoRaw = baseUnpacked.infoRaw
            if infoRaw.count >= 32 {
                writeUInt16BE(&infoRaw, offset: 20, value: 2)
                writeUInt32BE(&infoRaw, offset: 24, value: newCompSize)
                writeUInt32BE(&infoRaw, offset: 28, value: newUncompSize)
            }
            if infoRaw.count >= 44 {
                writeUInt32BE(&infoRaw, offset: 40, value: newUncompSize)
            }
            if infoRaw.count >= 15 && infoRaw.count < 270 {
                var litBlock = Data([0xF0, UInt8(infoRaw.count - 15)])
                litBlock.append(infoRaw)
                newTailInfo = litBlock
                writeUInt32BE(&newHeader, offset: sizeFieldPos + 8, value: UInt32(newTailInfo.count))
                writeUInt32BE(&newHeader, offset: sizeFieldPos + 12, value: UInt32(infoRaw.count))
                writeUInt32BE(&newHeader, offset: sizeFieldPos + 16, value: 0x00C2)
            } else {
                let compInfo = try lz4CompressBlock(infoRaw)
                newTailInfo = compInfo
                writeUInt32BE(&newHeader, offset: sizeFieldPos + 8, value: UInt32(newTailInfo.count))
                writeUInt32BE(&newHeader, offset: sizeFieldPos + 12, value: UInt32(infoRaw.count))
                writeUInt32BE(&newHeader, offset: sizeFieldPos + 16, value: 0x00C2)
            }
        }

        let newTotalFileSize = UInt64(newHeader.count + compressedPayload.count + newTailInfo.count)
        writeUInt64BE(&newHeader, offset: sizeFieldPos, value: newTotalFileSize)

        var finalBundle = Data(capacity: Int(newTotalFileSize))
        finalBundle.append(newHeader)
        finalBundle.append(compressedPayload)
        finalBundle.append(newTailInfo)
        return finalBundle
    }

    private func lz4DecompressBlock(_ src: Data, uncompressedSize: Int) throws -> Data {
        // Pure-Swift standard LZ4 raw block decompressor (100% deterministic for all LZ4 blocks including tiny 69B BlocksInfo)
        var dst = [UInt8]()
        dst.reserveCapacity(uncompressedSize)
        let bytes = [UInt8](src)
        var pos = 0
        let srcLen = bytes.count

        while pos < srcLen {
            let token = Int(bytes[pos])
            pos += 1

            var litLen = token >> 4
            if litLen == 15 {
                while pos < srcLen {
                    let b = Int(bytes[pos])
                    pos += 1
                    litLen += b
                    if b != 255 { break }
                }
            }

            guard pos + litLen <= srcLen else {
                throw AovModMergerError.assetBundleMergeFailed("LZ4 literal vượt quá giới hạn khối.")
            }
            if litLen > 0 {
                dst.append(contentsOf: bytes[pos..<(pos + litLen)])
                pos += litLen
            }

            if pos >= srcLen {
                break
            }

            guard pos + 2 <= srcLen else {
                throw AovModMergerError.assetBundleMergeFailed("LZ4 thiếu match offset.")
            }
            let offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
            pos += 2
            guard offset > 0, offset <= dst.count else {
                throw AovModMergerError.assetBundleMergeFailed("LZ4 match offset không hợp lệ: \(offset)")
            }

            var matchLen = (token & 0x0F) + 4
            if (token & 0x0F) == 15 {
                while pos < srcLen {
                    let b = Int(bytes[pos])
                    pos += 1
                    matchLen += b
                    if b != 255 { break }
                }
            }

            let matchPos = dst.count - offset
            for i in 0..<matchLen {
                dst.append(dst[matchPos + i])
            }
        }

        return Data(dst)
    }

    private func lz4CompressBlock(_ src: Data) throws -> Data {
        let dstCapacity = src.count + (src.count / 255) + 64
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }

        let compressedSize = src.withUnsafeBytes { rawBuffer -> Int in
            guard let basePtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                dstBuffer,
                dstCapacity,
                basePtr,
                src.count,
                nil,
                COMPRESSION_LZ4_RAW
            )
        }

        guard compressedSize > 0 else {
            throw AovModMergerError.assetBundleMergeFailed("Không thể nén khối LZ4_RAW.")
        }
        return Data(bytes: dstBuffer, count: compressedSize)
    }

    // MARK: - Format 2A: Generic `.pkg.bytes` ZIP Merger (`KernelLua.pkg.bytes`, `StableSystems_3.pkg.bytes`)

    private func mergeGenericPkgZipPreferModified(_ inputs: [(buildVersion: AovGameBuildVersion, data: Data)]) throws -> Data {
        guard let first = inputs.first else { return Data() }
        struct RankedEntry {
            var entry: InMemoryZipEntry
            var isModified: Bool
            var dosTimestamp: UInt32
            var buildVersion: AovGameBuildVersion
        }

        func makeRanked(_ entry: InMemoryZipEntry, buildVersion: AovGameBuildVersion) -> RankedEntry {
            let isMod = !(entry.modifiedDate == 0x0021 && entry.modifiedTime == 0x0000)
            let dosTS = (UInt32(entry.modifiedDate) << 16) | UInt32(entry.modifiedTime)
            return RankedEntry(entry: entry, isModified: isMod, dosTimestamp: dosTS, buildVersion: buildVersion)
        }

        func outranks(_ cand: RankedEntry, _ cur: RankedEntry) -> Bool {
            if cand.isModified != cur.isModified {
                return cand.isModified && !cur.isModified
            }
            if cand.buildVersion != cur.buildVersion {
                return cand.buildVersion > cur.buildVersion
            }
            if cand.dosTimestamp != cur.dosTimestamp {
                return cand.dosTimestamp > cur.dosTimestamp
            }
            return cand.entry.data != cur.entry.data
        }

        let firstParsed = try parseInMemoryZip(first.data)
        var rankedEntries: [RankedEntry] = firstParsed.map { makeRanked($0, buildVersion: first.buildVersion) }
        var indexByName: [String: Int] = [:]
        for (i, r) in rankedEntries.enumerated() {
            indexByName[r.entry.name] = i
        }

        for otherInput in inputs.dropFirst() {
            let otherEntries = try parseInMemoryZip(otherInput.data)
            for oe in otherEntries {
                let cand = makeRanked(oe, buildVersion: otherInput.buildVersion)
                if let existingIdx = indexByName[oe.name] {
                    if outranks(cand, rankedEntries[existingIdx]) {
                        rankedEntries[existingIdx] = cand
                    }
                } else {
                    indexByName[oe.name] = rankedEntries.count
                    rankedEntries.append(cand)
                }
            }
        }

        return try buildInMemoryStoreZip(rankedEntries.map(\.entry))
    }

    // MARK: - Format 2B: `CommonActions.pkg.bytes` XML + Zstd Dict Merger

    private func mergeCommonActionsPkg(
        inputs: [(heroIDs: Set<Int>, buildVersion: AovGameBuildVersion, data: Data)],
        logs: inout [String]
    ) throws -> Data {
        guard !inputs.isEmpty else { return Data() }

        struct ParsedPkgInput {
            let heroIDs: Set<Int>
            let buildVersion: AovGameBuildVersion
            let byteCount: Int
            let entriesByName: [String: InMemoryZipEntry]
            let orderedNames: [String]
        }

        var parsedInputs: [ParsedPkgInput] = []
        for inp in inputs {
            let entries = try parseInMemoryZip(inp.data)
            var dict: [String: InMemoryZipEntry] = [:]
            var names: [String] = []
            dict.reserveCapacity(entries.count)
            names.reserveCapacity(entries.count)
            for e in entries {
                if dict[e.name] == nil {
                    names.append(e.name)
                }
                dict[e.name] = e
            }
            parsedInputs.append(ParsedPkgInput(
                heroIDs: inp.heroIDs,
                buildVersion: inp.buildVersion,
                byteCount: inp.data.count,
                entriesByName: dict,
                orderedNames: names
            ))
        }

        // Preserve canonical entry order from the highest-build / largest CommonActions archive
        let masterIdx = parsedInputs.enumerated().max { a, b in
            if a.element.buildVersion != b.element.buildVersion {
                return a.element.buildVersion < b.element.buildVersion
            }
            if a.element.orderedNames.count != b.element.orderedNames.count {
                return a.element.orderedNames.count < b.element.orderedNames.count
            }
            return a.element.byteCount < b.element.byteCount
        }?.offset ?? 0

        var allNames: [String] = parsedInputs[masterIdx].orderedNames
        var seenNames = Set(allNames)
        for p in parsedInputs {
            for name in p.orderedNames where !seenNames.contains(name) {
                seenNames.insert(name)
                allNames.append(name)
            }
        }

        func countOccurrences(of needle: String, in haystack: String) -> Int {
            var count = 0
            var searchStart = haystack.startIndex
            while let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
                count += 1
                searchStart = r.upperBound
            }
            return count
        }

        func normalizeXmlText(_ raw: String) -> String {
            var s = raw
            if s.hasPrefix("\u{FEFF}") {
                s.removeFirst()
            }
            return s.replacingOccurrences(of: "\r\n", with: "\n")
        }

        struct DecodedXmlCandidate {
            let inputIdx: Int
            let heroIDs: Set<Int>
            let buildVersion: AovGameBuildVersion
            let entry: InMemoryZipEntry
            let xmlText: String
            let hasGuidTracks: Bool
            let trackCount: Int
            let skinTagCount: Int
        }

        var mergedEntries: [InMemoryZipEntry] = []
        mergedEntries.reserveCapacity(allNames.count)

        for entryName in allNames {
            var contributors: [(inputIdx: Int, heroIDs: Set<Int>, buildVersion: AovGameBuildVersion, entry: InMemoryZipEntry)] = []
            for (idx, p) in parsedInputs.enumerated() {
                if let e = p.entriesByName[entryName] {
                    contributors.append((idx, p.heroIDs, p.buildVersion, e))
                }
            }
            guard let first = contributors.first else { continue }

            // Fast path: single contributor or byte-for-byte identical compressed/encrypted payloads
            if contributors.count == 1 || contributors.dropFirst().allSatisfy({ $0.entry.data == first.entry.data }) {
                mergedEntries.append(first.entry)
                continue
            }

            // Decode only colliding entries whose raw bytes differ
            var candidates: [DecodedXmlCandidate] = []
            var nonXmlFallback: (buildVersion: AovGameBuildVersion, entry: InMemoryZipEntry)? = nil

            for item in contributors {
                let decodedData = (try? decodeAovXmlEntryIfNeeded(item.entry.data, entryPath: entryName)) ?? item.entry.data
                if let rawStr = String(data: decodedData, encoding: .utf8) {
                    let normXml = normalizeXmlText(rawStr)
                    if normXml.contains("<Track") {
                        let hasGuid = normXml.contains("guid=\"")
                        let trackCnt = countOccurrences(of: "<Track", in: normXml)
                        let skinCnt = countOccurrences(of: "<SkinOrAvatarList", in: normXml)
                        candidates.append(DecodedXmlCandidate(
                            inputIdx: item.inputIdx,
                            heroIDs: item.heroIDs,
                            buildVersion: item.buildVersion,
                            entry: item.entry,
                            xmlText: normXml,
                            hasGuidTracks: hasGuid,
                            trackCount: trackCnt,
                            skinTagCount: skinCnt
                        ))
                        continue
                    }
                }
                if let cur = nonXmlFallback {
                    if item.buildVersion > cur.buildVersion ||
                       (item.buildVersion == cur.buildVersion && item.entry.data.count > cur.entry.data.count) {
                        nonXmlFallback = (item.buildVersion, item.entry)
                    }
                } else {
                    nonXmlFallback = (item.buildVersion, item.entry)
                }
            }

            guard !candidates.isEmpty else {
                mergedEntries.append(nonXmlFallback?.entry ?? first.entry)
                continue
            }

            // Pick richest per-entry base: (hasGuidTracks > buildVersion > trackCount > skinTagCount > xmlSize)
            let baseCandIdx = candidates.enumerated().max { a, b in
                let x = a.element
                let y = b.element
                if x.hasGuidTracks != y.hasGuidTracks { return !x.hasGuidTracks && y.hasGuidTracks }
                if x.buildVersion != y.buildVersion { return x.buildVersion < y.buildVersion }
                if x.trackCount != y.trackCount { return x.trackCount < y.trackCount }
                if x.skinTagCount != y.skinTagCount { return x.skinTagCount < y.skinTagCount }
                return x.xmlText.utf8.count < y.xmlText.utf8.count
            }?.offset ?? 0

            let baseCand = candidates[baseCandIdx]
            let allDecodedEqual = candidates.dropFirst().allSatisfy { $0.xmlText == candidates[0].xmlText }
            if allDecodedEqual {
                // Only encoding differed (e.g. encrypted vs Zstd vs plain XML for exact same file)
                mergedEntries.append(baseCand.entry)
                continue
            }

            var accumulatedXml = baseCand.xmlText
            var mergedHeroLabels: [String] = []
            for (cIdx, cand) in candidates.enumerated() where cIdx != baseCandIdx {
                guard cand.xmlText != accumulatedXml else { continue }
                accumulatedXml = mergeAovActionXmlTracks(
                    baseXml: accumulatedXml,
                    incomingXml: cand.xmlText,
                    incomingHeroIDs: cand.heroIDs
                )
                let hLabel = cand.heroIDs.sorted().map(String.init).joined(separator: ",")
                if !hLabel.isEmpty { mergedHeroLabels.append(hLabel) }
            }

            if let mergedXmlBytes = accumulatedXml.data(using: .utf8) {
                var bestTime = baseCand.entry.modifiedTime
                var bestDate = baseCand.entry.modifiedDate
                for cand in candidates {
                    if !(cand.entry.modifiedDate == 0x0021 && cand.entry.modifiedTime == 0x0000) {
                        bestTime = cand.entry.modifiedTime
                        bestDate = cand.entry.modifiedDate
                    }
                }
                mergedEntries.append(InMemoryZipEntry(
                    name: entryName,
                    modifiedTime: bestTime,
                    modifiedDate: bestDate,
                    data: mergedXmlBytes
                ))
                let heroDesc = mergedHeroLabels.isEmpty ? "?" : mergedHeroLabels.joined(separator: "+")
                logs.append("  + Đã gộp Track XML: \(entryName) (Hero \(heroDesc))")
            } else {
                mergedEntries.append(baseCand.entry)
            }
        }

        return try buildInMemoryStoreZip(mergedEntries)
    }

    public func decodeAovXmlEntryIfNeeded(_ raw: Data, entryPath: String = "") throws -> Data {
        guard raw.count > 8 else { return raw }
        let b0 = raw[raw.startIndex]
        let b1 = raw[raw.startIndex + 1]
        let b2 = raw[raw.startIndex + 2]
        let b3 = raw[raw.startIndex + 3]

        guard b0 == 0x22 && b1 == 0x4A else { return raw }

        if b2 == 0x00 && b3 == 0xEF {
            return try jgDecrypt(raw, stem: "commonresource")
        }

        if b2 == 0x67 && (b3 == 0xEF || b3 == 0x00) {
            var candidateStems: [String] = []
            func addStem(_ s: String) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !candidateStems.contains(t) {
                    candidateStems.append(t)
                }
            }

            if !entryPath.isEmpty {
                let normalized = entryPath.replacingOccurrences(of: "\\", with: "/")
                let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                if let fileName = parts.last {
                    if let lastDot = fileName.lastIndex(of: ".") {
                        addStem(String(fileName[..<lastDot]))
                    }
                    if let firstDot = fileName.firstIndex(of: ".") {
                        addStem(String(fileName[..<firstDot]))
                    }
                    addStem(fileName)
                }
                if parts.count >= 2 {
                    addStem(parts[parts.count - 2])
                }
            }
            addStem("commonresource")

            for stem in candidateStems {
                if let dec = try? jgDecrypt(raw, stem: stem),
                   let str = String(data: dec, encoding: .utf8),
                   str.contains("<Project") || str.contains("<Track") || str.contains("<?xml") || str.contains("<Action") {
                    return dec
                }
            }
        }

        return raw
    }

    private func mergeAovActionXmlTracks(
        baseXml: String,
        incomingXml: String,
        incomingHeroIDs: Set<Int>
    ) -> String {
        struct XmlCondition {
            let id: Int?
            let guid: String
            let status: String
        }

        struct XmlTrackObjRef {
            let id: Int?
            let guid: String
        }

        struct ParsedTrack {
            let origIndex: Int
            let guid: String
            let trackName: String
            let strippedTrackName: String
            let eventType: String
            let filterType: String?
            let skel: String
            let skins: [String]
            let skinIdIntParam: String?
            let conditions: [XmlCondition]
            let trackObjects: [XmlTrackObjRef]
            let resourceNames: [String]
            let rawText: String
        }

        func stripNumericTrackPrefix(_ name: String) -> String {
            guard let underIdx = name.firstIndex(of: "_"),
                  underIdx != name.startIndex else {
                return name
            }
            let prefix = name[..<underIdx]
            let rest = name[name.index(after: underIdx)...]
            if !rest.isEmpty && prefix.allSatisfy({ $0.isNumber }) {
                return String(rest)
            }
            return name
        }

        func parseTagAttributes(_ inner: String) -> (tagName: String, attrs: [(key: String, value: String)]) {
            var idx = inner.startIndex
            while idx < inner.endIndex && !inner[idx].isWhitespace {
                idx = inner.index(after: idx)
            }
            let tagName = String(inner[..<idx])
            var attrs: [(String, String)] = []
            while idx < inner.endIndex {
                while idx < inner.endIndex && inner[idx].isWhitespace {
                    idx = inner.index(after: idx)
                }
                guard idx < inner.endIndex else { break }
                let keyStart = idx
                while idx < inner.endIndex && inner[idx] != "=" && !inner[idx].isWhitespace {
                    idx = inner.index(after: idx)
                }
                let key = String(inner[keyStart..<idx])
                while idx < inner.endIndex && inner[idx].isWhitespace {
                    idx = inner.index(after: idx)
                }
                guard idx < inner.endIndex, inner[idx] == "=" else {
                    break
                }
                idx = inner.index(after: idx)
                while idx < inner.endIndex && inner[idx].isWhitespace {
                    idx = inner.index(after: idx)
                }
                guard idx < inner.endIndex else { break }
                let quote = inner[idx]
                if quote == "\"" || quote == "'" {
                    idx = inner.index(after: idx)
                    let valStart = idx
                    while idx < inner.endIndex && inner[idx] != quote {
                        idx = inner.index(after: idx)
                    }
                    let val = String(inner[valStart..<idx])
                    if idx < inner.endIndex { idx = inner.index(after: idx) }
                    if !key.isEmpty { attrs.append((key, val)) }
                }
            }
            return (tagName, attrs)
        }

        func parseTrack(rawTrack: String, origIndex: Int) -> ParsedTrack {
            var trackGuid = ""
            var trackName = ""
            var eventType = ""
            var filterType: String? = nil
            var skins: [String] = []
            var skinIdIntParam: String? = nil
            var conditions: [XmlCondition] = []
            var trackObjects: [XmlTrackObjRef] = []
            var resourceNames: [String] = []
            var canonicalParts: [String] = []

            var pos = rawTrack.startIndex
            while let lt = rawTrack.range(of: "<", range: pos..<rawTrack.endIndex),
                  let gt = rawTrack.range(of: ">", range: lt.upperBound..<rawTrack.endIndex) {
                let rawInner = String(rawTrack[lt.upperBound..<gt.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                pos = gt.upperBound
                guard !rawInner.isEmpty else { continue }

                if rawInner.hasPrefix("/") {
                    canonicalParts.append("<\(rawInner)>")
                    continue
                }

                let selfClose = rawInner.hasSuffix("/")
                let trimmedInner = selfClose ? String(rawInner.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : rawInner
                let (tagName, rawAttrs) = parseTagAttributes(trimmedInner)
                var attrDict: [String: String] = [:]
                for (k, v) in rawAttrs { attrDict[k] = v }

                if tagName == "Track" {
                    trackGuid = attrDict["guid"] ?? ""
                    trackName = attrDict["trackName"] ?? ""
                    eventType = attrDict["eventType"] ?? ""
                    filterType = attrDict["SkinAvatarFilterType"]
                } else if tagName == "SkinOrAvatarList" {
                    if let sid = attrDict["id"] { skins.append(sid) }
                    continue
                } else if tagName == "Condition" {
                    let cid = attrDict["id"].flatMap(Int.init)
                    let cguid = attrDict["guid"] ?? ""
                    let cstatus = attrDict["status"] ?? "true"
                    conditions.append(XmlCondition(id: cid, guid: cguid, status: cstatus))
                    continue
                } else if tagName == "TrackObject" {
                    let oid = attrDict["id"].flatMap(Int.init)
                    let oguid = attrDict["guid"] ?? ""
                    trackObjects.append(XmlTrackObjRef(id: oid, guid: oguid))
                } else if tagName == "int" && attrDict["name"] == "skinId" {
                    skinIdIntParam = attrDict["value"]
                } else if tagName == "String" && attrDict["name"] == "resourceName",
                          let rval = attrDict["value"], !rval.isEmpty {
                    resourceNames.append(rval)
                }

                // Canonicalize attributes for GUID-free structural comparison
                attrDict.removeValue(forKey: "guid")
                if attrDict["useRefParam"] == "false" { attrDict.removeValue(forKey: "useRefParam") }
                if attrDict["refParamName"] == "" { attrDict.removeValue(forKey: "refParamName") }
                if attrDict["r"] == "0.000" && attrDict["g"] == "0.000" && attrDict["b"] == "0.000" {
                    attrDict.removeValue(forKey: "r")
                    attrDict.removeValue(forKey: "g")
                    attrDict.removeValue(forKey: "b")
                }
                if attrDict["stopAfterLastEvent"] == "true" { attrDict.removeValue(forKey: "stopAfterLastEvent") }
                if tagName == "Track" {
                    attrDict.removeValue(forKey: "SkinAvatarFilterType")
                    attrDict.removeValue(forKey: "trackName")
                }
                if tagName == "TrackObject" {
                    attrDict.removeValue(forKey: "id")
                }
                if tagName == "String",
                   attrDict["value"] == "",
                   attrDict["useRefParam"] != "true",
                   let sName = attrDict["name"],
                   sName == "syncAnimationName" || sName == "customTagName" || sName == "resourceName" || sName == "outSoundEventParamName" {
                    continue
                }

                let sortedAttrStr = attrDict.keys.sorted().map { "\($0)=\"\(attrDict[$0]!)\"" }.joined(separator: " ")
                if sortedAttrStr.isEmpty {
                    canonicalParts.append(selfClose ? "<\(tagName)/>" : "<\(tagName)>")
                } else {
                    canonicalParts.append(selfClose ? "<\(tagName) \(sortedAttrStr)/>" : "<\(tagName) \(sortedAttrStr)>")
                }
            }

            return ParsedTrack(
                origIndex: origIndex,
                guid: trackGuid,
                trackName: trackName,
                strippedTrackName: stripNumericTrackPrefix(trackName),
                eventType: eventType,
                filterType: filterType,
                skel: canonicalParts.joined(),
                skins: skins,
                skinIdIntParam: skinIdIntParam,
                conditions: conditions,
                trackObjects: trackObjects,
                resourceNames: resourceNames,
                rawText: rawTrack
            )
        }

        func splitXmlIntoTracks(_ xml: String) -> (header: String, tracks: [ParsedTrack], footer: String)? {
            guard let firstTrackRange = xml.range(of: "<Track"),
                  let lastTrackEndRange = xml.range(of: "</Track>", options: .backwards) else {
                return nil
            }
            let header = String(xml[..<firstTrackRange.lowerBound])
            let footer = String(xml[lastTrackEndRange.upperBound...])
            let body = String(xml[firstTrackRange.lowerBound..<lastTrackEndRange.upperBound])

            var tracks: [ParsedTrack] = []
            var searchStart = body.startIndex
            while let openRange = body.range(of: "<Track", range: searchStart..<body.endIndex),
                  let closeRange = body.range(of: "</Track>", range: openRange.lowerBound..<body.endIndex) {
                let rawTrack = String(body[openRange.lowerBound..<closeRange.upperBound])
                tracks.append(parseTrack(rawTrack: rawTrack, origIndex: tracks.count))
                searchStart = closeRange.upperBound
            }
            return (header, tracks, footer)
        }

        func skinMatchesAnyHero(_ value: String, heroPrefixes: [String]) -> Bool {
            guard value.count >= 5 else { return false }
            return heroPrefixes.contains { value.hasPrefix($0) }
        }

        func stringContainsHeroMarker(_ text: String, heroPrefixes: [String]) -> Bool {
            guard !text.isEmpty else { return false }
            for hp in heroPrefixes {
                if text.hasPrefix("\(hp)_") || text.contains("/\(hp)_") {
                    return true
                }
                // Check contiguous digit runs of length 5..6 starting with heroID (e.g. Amily19309RecallReceiver -> 19309)
                var currentDigits = ""
                for ch in text {
                    if ch.isNumber {
                        currentDigits.append(ch)
                    } else {
                        if currentDigits.count >= 5 && currentDigits.count <= 6 && currentDigits.hasPrefix(hp) {
                            return true
                        }
                        currentDigits.removeAll(keepingCapacity: true)
                    }
                }
                if currentDigits.count >= 5 && currentDigits.count <= 6 && currentDigits.hasPrefix(hp) {
                    return true
                }
            }
            return false
        }

        func replaceSkinTags(in trackText: String, with newIds: [String], filterTypeIfMissing: String? = nil) -> String {
            var working = trackText
            if let ft = filterTypeIfMissing, !ft.isEmpty,
               let firstTagEnd = working.range(of: ">"),
               !working[..<firstTagEnd.lowerBound].contains("SkinAvatarFilterType=") {
                working.insert(contentsOf: " SkinAvatarFilterType=\"\(ft)\"", at: firstTagEnd.lowerBound)
            }

            guard !newIds.isEmpty else {
                // Remove any existing SkinOrAvatarList tags cleanly if newIds is empty
                var stripped = ""
                stripped.reserveCapacity(working.count)
                var searchStart = working.startIndex
                while let tagStart = working.range(of: "<SkinOrAvatarList", range: searchStart..<working.endIndex),
                      let tagEnd = working.range(of: "/>", range: tagStart.lowerBound..<working.endIndex) {
                    stripped.append(contentsOf: working[searchStart..<tagStart.lowerBound])
                    searchStart = tagEnd.upperBound
                }
                stripped.append(contentsOf: working[searchStart..<working.endIndex])
                return stripped
            }

            let isMultiline = working.contains("\n")
            let separator = isMultiline ? "\n      " : ""
            let newSkinsBlock = newIds.map { "<SkinOrAvatarList id=\"\($0)\" />" }.joined(separator: separator)

            if working.contains("<SkinOrAvatarList") {
                var result = ""
                result.reserveCapacity(working.count + newSkinsBlock.count)
                var searchStart = working.startIndex
                var inserted = false
                while let tagStart = working.range(of: "<SkinOrAvatarList", range: searchStart..<working.endIndex),
                      let tagEnd = working.range(of: "/>", range: tagStart.lowerBound..<working.endIndex) {
                    if !inserted {
                        result.append(contentsOf: working[searchStart..<tagStart.lowerBound])
                        result.append(newSkinsBlock)
                        inserted = true
                    } else {
                        let between = working[searchStart..<tagStart.lowerBound]
                        if !between.allSatisfy({ $0.isWhitespace }) {
                            result.append(contentsOf: between)
                        }
                    }
                    searchStart = tagEnd.upperBound
                }
                result.append(contentsOf: working[searchStart..<working.endIndex])
                return result
            } else if let closeTrack = working.range(of: "</Track>", options: .backwards) {
                var result = working
                let insertStr = isMultiline ? "      \(newSkinsBlock)\n    " : newSkinsBlock
                result.insert(contentsOf: insertStr, at: closeTrack.lowerBound)
                return result
            }
            return working
        }

        func insertConditions(_ condTags: [String], into trackText: String) -> String {
            guard !condTags.isEmpty else { return trackText }
            let isMultiline = trackText.contains("\n")
            let block = condTags.joined(separator: isMultiline ? "\n      " : "")
            if let eventRange = trackText.range(of: "<Event") {
                var result = trackText
                if isMultiline {
                    // Preserve indentation of `<Event`
                    var lineStart = eventRange.lowerBound
                    while lineStart > result.startIndex {
                        let prev = result.index(before: lineStart)
                        if result[prev] == "\n" { break }
                        lineStart = prev
                    }
                    let indent = String(result[lineStart..<eventRange.lowerBound])
                    let formatted = condTags.map { "\(indent)\($0)\n" }.joined()
                    result.insert(contentsOf: formatted, at: lineStart)
                } else {
                    result.insert(contentsOf: block, at: eventRange.lowerBound)
                }
                return result
            } else if let firstTagEnd = trackText.range(of: ">") {
                var result = trackText
                result.insert(contentsOf: isMultiline ? "\n      \(block)" : block, at: firstTagEnd.upperBound)
                return result
            }
            return trackText
        }

        guard let baseParsed = splitXmlIntoTracks(baseXml),
              let incParsed = splitXmlIntoTracks(incomingXml) else {
            return baseXml
        }

        let baseTracks = baseParsed.tracks
        let incTracks = incParsed.tracks
        let heroPrefixes = incomingHeroIDs.sorted().map(String.init)

        // 1-to-1 track assignment between incoming and base
        var incToBaseMatch: [Int: Int] = [:]
        var usedBaseIndices = Set<Int>()
        var usedIncIndices = Set<Int>()

        struct MatchPair {
            let incIdx: Int
            let baseIdx: Int
            let score: Int
            let indexDelta: Int
        }

        func pairScore(ii: Int, bi: Int) -> Int {
            let it = incTracks[ii]
            let bt = baseTracks[bi]
            var score = 0
            if it.filterType == bt.filterType {
                score += 2000
            }
            if !it.strippedTrackName.isEmpty && it.strippedTrackName == bt.strippedTrackName {
                if it.strippedTrackName.allSatisfy(\.isNumber) {
                    score += 500
                } else {
                    score += 10_000
                }
            }
            if it.skins.isEmpty == bt.skins.isEmpty {
                score += 1500
            }
            if !it.skins.isEmpty && !bt.skins.isEmpty {
                let bSet = Set(bt.skins)
                let iSet = Set(it.skins)
                if !bSet.isDisjoint(with: iSet) {
                    score += 3000
                }
                if bt.skins == it.skins {
                    score += 1000
                }
            }
            if it.conditions.count == bt.conditions.count {
                score += 1500
                if it.conditions.map(\.status) == bt.conditions.map(\.status) {
                    score += 1500
                }
            }
            let posDiff = abs(Double(ii) / Double(max(1, incTracks.count)) - Double(bi) / Double(max(1, baseTracks.count)))
            score += Int((1.0 - posDiff) * 100.0)
            return score
        }

        func applyGreedyPairs(_ pairs: [MatchPair]) {
            let sorted = pairs.sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.indexDelta != b.indexDelta { return a.indexDelta < b.indexDelta }
                return a.baseIdx < b.baseIdx
            }
            for p in sorted {
                if !usedIncIndices.contains(p.incIdx) && !usedBaseIndices.contains(p.baseIdx) {
                    usedIncIndices.insert(p.incIdx)
                    usedBaseIndices.insert(p.baseIdx)
                    incToBaseMatch[p.incIdx] = p.baseIdx
                }
            }
        }

        // Tier 1A: Exact GUID + Canonical Skeleton (handles duplicate GUIDs like Murad 13118 & Tamyn #91 safely)
        var baseByGuid: [String: [Int]] = [:]
        for bt in baseTracks where !bt.guid.isEmpty {
            baseByGuid[bt.guid, default: []].append(bt.origIndex)
        }
        var tier1APairs: [MatchPair] = []
        for it in incTracks where !it.guid.isEmpty {
            for bi in baseByGuid[it.guid] ?? [] where baseTracks[bi].skel == it.skel {
                tier1APairs.append(MatchPair(
                    incIdx: it.origIndex,
                    baseIdx: bi,
                    score: 100_000 + pairScore(ii: it.origIndex, bi: bi),
                    indexDelta: abs(it.origIndex - bi)
                ))
            }
        }
        applyGreedyPairs(tier1APairs)

        // Tier 1B: Same GUID + EventType + SkinAvatarFilterType (if a stock GUID track's parameters were modified)
        var tier1BPairs: [MatchPair] = []
        for it in incTracks where !usedIncIndices.contains(it.origIndex) && !it.guid.isEmpty {
            for bi in baseByGuid[it.guid] ?? [] where !usedBaseIndices.contains(bi) {
                let bt = baseTracks[bi]
                if it.eventType == bt.eventType && it.filterType == bt.filterType {
                    tier1BPairs.append(MatchPair(
                        incIdx: it.origIndex,
                        baseIdx: bi,
                        score: 50_000 + pairScore(ii: it.origIndex, bi: bi),
                        indexDelta: abs(it.origIndex - bi)
                    ))
                }
            }
        }
        applyGreedyPairs(tier1BPairs)

        // Tier 2: Canonical Skeleton matching for GUID-stripped mods (e.g. Edras) or regenerated-GUID mods
        var baseBySkel: [String: [Int]] = [:]
        for bt in baseTracks where !usedBaseIndices.contains(bt.origIndex) {
            baseBySkel[bt.skel, default: []].append(bt.origIndex)
        }
        var tier2Pairs: [MatchPair] = []
        for it in incTracks where !usedIncIndices.contains(it.origIndex) {
            for bi in baseBySkel[it.skel] ?? [] where !usedBaseIndices.contains(bi) {
                let bt = baseTracks[bi]
                // Never merge two unrelated single-hero custom tracks from different heroes
                if !heroPrefixes.isEmpty,
                   !bt.skins.isEmpty,
                   !it.skins.isEmpty,
                   Set(bt.skins).isDisjoint(with: Set(it.skins)),
                   it.skins.allSatisfy({ skinMatchesAnyHero($0, heroPrefixes: heroPrefixes) }),
                   !bt.skins.contains(where: { skinMatchesAnyHero($0, heroPrefixes: heroPrefixes) }) {
                    continue
                }
                tier2Pairs.append(MatchPair(
                    incIdx: it.origIndex,
                    baseIdx: bi,
                    score: pairScore(ii: it.origIndex, bi: bi),
                    indexDelta: abs(it.origIndex - bi)
                ))
            }
        }
        applyGreedyPairs(tier2Pairs)

        // Invert mapping: baseIdx -> incIdx
        var baseToIncMatch: [Int: Int] = [:]
        for (ii, bi) in incToBaseMatch {
            baseToIncMatch[bi] = ii
        }

        // Resolve internal incoming dependency graph (Conditions + TrackObjects)
        var incByGuid: [String: [Int]] = [:]
        for it in incTracks where !it.guid.isEmpty {
            incByGuid[it.guid, default: []].append(it.origIndex)
        }

        func resolveIncomingTarget(id: Int?, guid: String, fromIndex: Int) -> Int? {
            if let i = id, i >= 0, i < incTracks.count {
                if guid.isEmpty || incTracks[i].guid == guid || incTracks[i].guid.isEmpty {
                    return i
                }
            }
            if !guid.isEmpty, let candidates = incByGuid[guid], !candidates.isEmpty {
                return candidates.min(by: { abs($0 - fromIndex) < abs($1 - fromIndex) })
            }
            if let i = id, i >= 0, i < incTracks.count {
                return i
            }
            return nil
        }

        var forwardEdges: [Int: [Int]] = [:]
        var reverseEdges: [Int: [Int]] = [:]
        for it in incTracks {
            var targets: [Int] = []
            for c in it.conditions {
                if let t = resolveIncomingTarget(id: c.id, guid: c.guid, fromIndex: it.origIndex) {
                    targets.append(t)
                }
            }
            for obj in it.trackObjects {
                if let t = resolveIncomingTarget(id: obj.id, guid: obj.guid, fromIndex: it.origIndex) {
                    targets.append(t)
                }
            }
            if !targets.isEmpty {
                forwardEdges[it.origIndex] = targets
                for t in targets {
                    reverseEdges[t, default: []].append(it.origIndex)
                }
            }
        }

        func isCustomIncomingSeed(_ it: ParsedTrack) -> Bool {
            if heroPrefixes.isEmpty {
                return true
            }
            if it.skins.contains(where: { skinMatchesAnyHero($0, heroPrefixes: heroPrefixes) }) {
                return true
            }
            if let sp = it.skinIdIntParam, skinMatchesAnyHero(sp, heroPrefixes: heroPrefixes) {
                return true
            }
            if stringContainsHeroMarker(it.guid, heroPrefixes: heroPrefixes)
                || stringContainsHeroMarker(it.trackName, heroPrefixes: heroPrefixes) {
                return true
            }
            for r in it.resourceNames where stringContainsHeroMarker(r, heroPrefixes: heroPrefixes) {
                return true
            }
            return false
        }

        var keptIncomingIndices = Set<Int>()
        var bfsQueue: [Int] = []
        for it in incTracks where incToBaseMatch[it.origIndex] == nil {
            if isCustomIncomingSeed(it) {
                keptIncomingIndices.insert(it.origIndex)
                bfsQueue.append(it.origIndex)
            }
        }

        var qIdx = 0
        while qIdx < bfsQueue.count {
            let curr = bfsQueue[qIdx]
            qIdx += 1
            for next in (forwardEdges[curr] ?? []) where incToBaseMatch[next] == nil {
                if !keptIncomingIndices.contains(next) {
                    keptIncomingIndices.insert(next)
                    bfsQueue.append(next)
                }
            }
            for dep in (reverseEdges[curr] ?? []) where incToBaseMatch[dep] == nil {
                if !keptIncomingIndices.contains(dep) {
                    keptIncomingIndices.insert(dep)
                    bfsQueue.append(dep)
                }
            }
        }

        // Build un-remapped output sequence and map original indices -> final indices
        enum TrackOrigin {
            case base(origIdx: Int)
            case incoming(origIdx: Int)
        }
        struct PendingOutputTrack {
            let origin: TrackOrigin
            let guid: String
            var rawText: String
            let injectedIncConds: [(targetIncIdx: Int, status: String)]
        }

        var pendingTracks: [PendingOutputTrack] = []
        var baseOrigToFinalIdx: [Int: Int] = [:]
        var incOrigToFinalIdx: [Int: Int] = [:]

        for bt in baseTracks {
            var updatedRaw = bt.rawText
            var injectedConds: [(targetIncIdx: Int, status: String)] = []

            if let ii = baseToIncMatch[bt.origIndex] {
                let it = incTracks[ii]

                // 1) Merge SkinOrAvatarList entries
                if bt.skins != it.skins {
                    if !heroPrefixes.isEmpty {
                        var mergedSkins = bt.skins.filter { !skinMatchesAnyHero($0, heroPrefixes: heroPrefixes) }
                        mergedSkins.append(contentsOf: it.skins.filter { skinMatchesAnyHero($0, heroPrefixes: heroPrefixes) })
                        if !mergedSkins.isEmpty || bt.skins.isEmpty {
                            let needFilter = (bt.filterType == nil && !mergedSkins.isEmpty) ? it.filterType : nil
                            if mergedSkins != bt.skins {
                                updatedRaw = replaceSkinTags(in: updatedRaw, with: mergedSkins, filterTypeIfMissing: needFilter)
                            }
                        } else {
                            // Incoming mod removed all skins on this hero-specific base track
                            continue
                        }
                    } else {
                        var seen = Set(bt.skins)
                        var mergedSkins = bt.skins
                        for s in it.skins where !seen.contains(s) {
                            seen.insert(s)
                            mergedSkins.append(s)
                        }
                        if mergedSkins != bt.skins {
                            let needFilter = (bt.filterType == nil && !mergedSkins.isEmpty) ? it.filterType : nil
                            updatedRaw = replaceSkinTags(in: updatedRaw, with: mergedSkins, filterTypeIfMissing: needFilter)
                        }
                    }
                }

                // 2) Merge extra <Condition .../> pointing to kept custom incoming tracks (e.g. Amily19309RecallReceiver)
                let existingCondGuids = Set(bt.conditions.map(\.guid).filter { !$0.isEmpty })
                for cond in it.conditions {
                    if let targetInc = resolveIncomingTarget(id: cond.id, guid: cond.guid, fromIndex: it.origIndex),
                       keptIncomingIndices.contains(targetInc) {
                        let tGuid = incTracks[targetInc].guid
                        let alreadyPresent = !tGuid.isEmpty && existingCondGuids.contains(tGuid)
                        if !alreadyPresent && !injectedConds.contains(where: { $0.targetIncIdx == targetInc && $0.status == cond.status }) {
                            injectedConds.append((targetIncIdx: targetInc, status: cond.status))
                        }
                    }
                }

                let finalIdx = pendingTracks.count
                baseOrigToFinalIdx[bt.origIndex] = finalIdx
                incOrigToFinalIdx[it.origIndex] = finalIdx
                pendingTracks.append(PendingOutputTrack(
                    origin: .base(origIdx: bt.origIndex),
                    guid: bt.guid,
                    rawText: updatedRaw,
                    injectedIncConds: injectedConds
                ))
            } else {
                // Track exists in base only (removed or absent in incoming)
                if !heroPrefixes.isEmpty, bt.skins.contains(where: { skinMatchesAnyHero($0, heroPrefixes: heroPrefixes) }) {
                    let remainingSkins = bt.skins.filter { !skinMatchesAnyHero($0, heroPrefixes: heroPrefixes) }
                    if !remainingSkins.isEmpty {
                        updatedRaw = replaceSkinTags(in: updatedRaw, with: remainingSkins)
                    } else {
                        continue
                    }
                }
                let finalIdx = pendingTracks.count
                baseOrigToFinalIdx[bt.origIndex] = finalIdx
                pendingTracks.append(PendingOutputTrack(
                    origin: .base(origIdx: bt.origIndex),
                    guid: bt.guid,
                    rawText: updatedRaw,
                    injectedIncConds: []
                ))
            }
        }

        // Append kept custom tracks from incoming in original order
        for it in incTracks where keptIncomingIndices.contains(it.origIndex) {
            var trackText = it.rawText
            if !heroPrefixes.isEmpty {
                let heroSkins = it.skins.filter { skinMatchesAnyHero($0, heroPrefixes: heroPrefixes) }
                if !heroSkins.isEmpty && heroSkins.count != it.skins.count {
                    trackText = replaceSkinTags(in: trackText, with: heroSkins)
                }
            }
            let finalIdx = pendingTracks.count
            incOrigToFinalIdx[it.origIndex] = finalIdx
            pendingTracks.append(PendingOutputTrack(
                origin: .incoming(origIdx: it.origIndex),
                guid: it.guid,
                rawText: trackText,
                injectedIncConds: []
            ))
        }

        // Build final GUID -> [finalIdx] map for Condition / TrackObject index remapping
        var guidToFinalIndices: [String: [Int]] = [:]
        for (idx, p) in pendingTracks.enumerated() where !p.guid.isEmpty {
            guidToFinalIndices[p.guid, default: []].append(idx)
        }

        func rewriteReferenceIds(in trackText: String, origin: TrackOrigin, currentFinalIdx: Int) -> String {
            var out = ""
            out.reserveCapacity(trackText.count + 32)
            var cursor = trackText.startIndex

            while let lt = trackText.range(of: "<", range: cursor..<trackText.endIndex),
                  let gt = trackText.range(of: ">", range: lt.upperBound..<trackText.endIndex) {
                out.append(contentsOf: trackText[cursor..<lt.lowerBound])
                let tagFull = String(trackText[lt.lowerBound..<gt.upperBound])
                cursor = gt.upperBound

                if tagFull.hasPrefix("<Condition ") || tagFull.hasPrefix("<TrackObject ") {
                    let inner = String(tagFull.dropFirst().dropLast())
                    let selfClose = inner.hasSuffix("/")
                    let trimmed = selfClose ? String(inner.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : inner
                    let (tagName, attrs) = parseTagAttributes(trimmed)
                    var attrDict: [String: String] = [:]
                    for (k, v) in attrs { attrDict[k] = v }

                    let refGuid = attrDict["guid"] ?? ""
                    let origId = attrDict["id"].flatMap(Int.init)
                    var resolvedIdx: Int? = nil

                    switch origin {
                    case .base:
                        if let oi = origId, let mapped = baseOrigToFinalIdx[oi] {
                            let mGuid = pendingTracks[mapped].guid
                            if refGuid.isEmpty || mGuid.isEmpty || mGuid == refGuid {
                                resolvedIdx = mapped
                            }
                        }
                        if resolvedIdx == nil, !refGuid.isEmpty, let cands = guidToFinalIndices[refGuid], !cands.isEmpty {
                            resolvedIdx = cands.min(by: { abs($0 - currentFinalIdx) < abs($1 - currentFinalIdx) })
                        }
                    case .incoming:
                        if let oi = origId, let mapped = incOrigToFinalIdx[oi] {
                            let mGuid = pendingTracks[mapped].guid
                            if refGuid.isEmpty || mGuid.isEmpty || mGuid == refGuid {
                                resolvedIdx = mapped
                            }
                        }
                        if resolvedIdx == nil, !refGuid.isEmpty, let cands = guidToFinalIndices[refGuid], !cands.isEmpty {
                            resolvedIdx = cands.min(by: { abs($0 - currentFinalIdx) < abs($1 - currentFinalIdx) })
                        }
                    }

                    if let finalRef = resolvedIdx, let curId = origId, finalRef != curId {
                        // Rewrite just the standalone `id="old"` attribute value without touching `guid="..."` or other attributes
                        var replacedTag = tagFull
                        if let idRange = replacedTag.range(
                            of: "(?<=\\s)id=\"\(curId)\"",
                            options: .regularExpression
                        ) {
                            replacedTag.replaceSubrange(idRange, with: "id=\"\(finalRef)\"")
                        }
                        out.append(replacedTag)
                        continue
                    } else if resolvedIdx == nil {
                        _ = tagName // keep unchanged
                    }
                }
                out.append(tagFull)
            }
            out.append(contentsOf: trackText[cursor..<trackText.endIndex])
            return out
        }

        // Emit final tracks with remapped Condition / TrackObject indices and injected cross-track conditions
        var finalRawTracks: [String] = []
        finalRawTracks.reserveCapacity(pendingTracks.count)

        for (finalIdx, item) in pendingTracks.enumerated() {
            var finalText = rewriteReferenceIds(in: item.rawText, origin: item.origin, currentFinalIdx: finalIdx)
            if !item.injectedIncConds.isEmpty {
                var newCondTags: [String] = []
                for inj in item.injectedIncConds {
                    guard let targetFinalIdx = incOrigToFinalIdx[inj.targetIncIdx] else { continue }
                    let targetGuid = pendingTracks[targetFinalIdx].guid
                    if targetGuid.isEmpty {
                        newCondTags.append("<Condition id=\"\(targetFinalIdx)\" status=\"\(inj.status)\" />")
                    } else {
                        newCondTags.append("<Condition guid=\"\(targetGuid)\" id=\"\(targetFinalIdx)\" status=\"\(inj.status)\" />")
                    }
                }
                finalText = insertConditions(newCondTags, into: finalText)
            }
            finalRawTracks.append(finalText)
        }

        let joinedTracks = finalRawTracks.joined(separator: "\n    ")
        return baseParsed.header + joinedTracks + baseParsed.footer
    }

    // MARK: - Format 3: `JG` AES-128-CBC Crypto & `Databin/Client/**/*.bytes` MSES Table Merger

    public func deriveJgKey(stem: String) -> [UInt8] {
        var h: UInt32 = 0
        for b in stem.utf8 {
            let c: UInt32 = (b >= 97 && b <= 122) ? UInt32(b - 32) : UInt32(b)
            h = h &* 31 &+ c
        }
        let baseKey: [UInt8] = [
            0x99, 0x64, 0xB1, 0xB0, 0x6B, 0x03, 0x8D, 0x7F,
            0xB7, 0x7D, 0xB6, 0xA7, 0x54, 0x90, 0x8B, 0x73
        ]
        let hBytes: [UInt8] = [
            UInt8(h & 0xFF),
            UInt8((h >> 8) & 0xFF),
            UInt8((h >> 16) & 0xFF),
            UInt8((h >> 24) & 0xFF)
        ]
        var key = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            key[i] = baseKey[i] ^ hBytes[i & 3]
        }
        return key
    }

    public func decompressAovZstd(_ zstdFrame: Data, expectedUncompressedSize: Int) -> Data? {
        let capacity = max(expectedUncompressedSize + 1024, zstdFrame.count * 12, 65_536)
        var dst = Data(count: capacity)
        let decompressedBytes: Int64 = zstdFrame.withUnsafeBytes { srcBuf in
            dst.withUnsafeMutableBytes { dstBuf in
                guard let srcPtr = srcBuf.bindMemory(to: UInt8.self).baseAddress,
                      let dstPtr = dstBuf.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return aov_zstd_decompress_dict(srcPtr, zstdFrame.count, dstPtr, capacity)
            }
        }
        if decompressedBytes >= 0 {
            dst.count = Int(decompressedBytes)
            return dst
        }
        return nil
    }

    public func jgDecrypt(_ data: Data, stem: String) throws -> Data {
        guard data.count > 8 else {
            return data
        }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]

        // Check AoV container magic: 22 4A
        guard b0 == 0x22 && b1 == 0x4A else {
            // Raw unencrypted MSES or generic binary
            return data
        }

        let uncompressedLen = Int(readUInt32LE(data, 4))
        let payload = data.subdata(in: 8..<data.count)

        // Case 1: b2 == 0x67 -> AES-128-CBC encrypted
        if b2 == 0x67 {
            let key = deriveJgKey(stem: stem)
            var iv = [UInt8](repeating: 0, count: 16)
            let outCapacity = payload.count + kCCBlockSizeAES128
            var decryptedBuffer = Data(count: outCapacity)
            var numBytesDecrypted: size_t = 0

            let status = payload.withUnsafeBytes { cipherBytes in
                decryptedBuffer.withUnsafeMutableBytes { outBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        key,
                        kCCKeySizeAES128,
                        &iv,
                        cipherBytes.baseAddress,
                        payload.count,
                        outBytes.baseAddress,
                        outCapacity,
                        &numBytesDecrypted
                    )
                }
            }

            guard status == kCCSuccess else {
                throw AovModMergerError.cryptoFailed("CCCrypt decrypt thất bại (\(stem), status=\(status))")
            }
            decryptedBuffer.count = Int(numBytesDecrypted)

            // If b3 == 0xEF, the decrypted payload is a Zstd frame
            if b3 == 0xEF {
                if let decomp = decompressAovZstd(decryptedBuffer, expectedUncompressedSize: uncompressedLen) {
                    return decomp
                }
                throw AovModMergerError.cryptoFailed("Zstd decompress thất bại sau khi giải mã AES (\(stem))")
            } else {
                if uncompressedLen > 0 && uncompressedLen <= decryptedBuffer.count {
                    decryptedBuffer.count = uncompressedLen
                }
                return decryptedBuffer
            }
        }

        // Case 2: b2 == 0x00 -> Unencrypted
        if b2 == 0x00 {
            if b3 == 0xEF {
                // Unencrypted Zstd frame (Edras skillcombine, BattleBank, etc.)
                if let decomp = decompressAovZstd(payload, expectedUncompressedSize: uncompressedLen) {
                    return decomp
                }
                throw AovModMergerError.cryptoFailed("Zstd decompress thất bại (\(stem))")
            } else {
                return payload
            }
        }

        return data
    }

    public func jgEncrypt(_ plainData: Data, stem: String) throws -> Data {
        let key = deriveJgKey(stem: stem)
        var iv = [UInt8](repeating: 0, count: 16)
        let outCapacity = plainData.count + kCCBlockSizeAES128 + 16
        var cipherBuffer = Data(count: outCapacity)
        var numBytesEncrypted: size_t = 0

        let status = plainData.withUnsafeBytes { plainBytes in
            cipherBuffer.withUnsafeMutableBytes { cipherBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionPKCS7Padding),
                    key,
                    kCCKeySizeAES128,
                    &iv,
                    plainBytes.baseAddress,
                    plainData.count,
                    cipherBytes.baseAddress,
                    outCapacity,
                    &numBytesEncrypted
                )
            }
        }

        guard status == kCCSuccess else {
            throw AovModMergerError.cryptoFailed("CCCrypt encrypt thất bại (\(stem), status=\(status))")
        }

        cipherBuffer.count = Int(numBytesEncrypted)
        var result = Data(capacity: 8 + cipherBuffer.count)
        result.append(contentsOf: [0x22, 0x4A, 0x67, 0x00])
        appendUInt32LE(&result, UInt32(plainData.count))
        result.append(cipherBuffer)
        return result
    }

    private struct MsesRecord {
        let rid: UInt32
        let rawBytes: Data
    }

    private struct MsesTable {
        var header: Data // 140 bytes (bytes 96..<128 = optional ASCII MD5 of payload)
        var hasPayloadMD5: Bool
        var maxRecordSize: UInt32
        var records: [MsesRecord]
        var footer: Data
    }

    private func parseMsesTable(_ data: Data, stem: String) throws -> MsesTable {
        guard data.count >= 140,
              String(data: data.subdata(in: 0..<4), encoding: .ascii) == "MSES" else {
            throw AovModMergerError.msesParseFailed("Không phải bảng MSES hợp lệ (\(stem))")
        }
        let maxRecSize = readUInt32LE(data, 8)
        let count = Int(readUInt32LE(data, 12))
        let header = data.subdata(in: 0..<140)

        var pos = 140
        var records: [MsesRecord] = []
        records.reserveCapacity(count)

        for _ in 0..<count {
            guard pos + 8 <= data.count else {
                throw AovModMergerError.msesParseFailed("Bảng MSES bị cắt cụt tại offset \(pos) (\(stem))")
            }
            let rlen = Int(readUInt32LE(data, pos))
            let rid = readUInt32LE(data, pos + 4)
            let totalLen = 4 + rlen
            guard rlen >= 4, pos + totalLen <= data.count else {
                throw AovModMergerError.msesParseFailed("Độ dài bản ghi MSES không hợp lệ (\(stem), rlen=\(rlen))")
            }
            let raw = data.subdata(in: pos..<(pos + totalLen))
            records.append(MsesRecord(rid: rid, rawBytes: raw))
            pos += totalLen
        }

        let payloadSlice = data.subdata(in: 140..<pos)
        let headerMD5Slice = header.subdata(in: 96..<128)
        let hasPayloadMD5: Bool = {
            guard let headerMD5Str = String(data: headerMD5Slice, encoding: .ascii) else { return false }
            let lower = headerMD5Str.lowercased()
            if lower == self.md5Hex(payloadSlice).lowercased() {
                return true
            }
            return lower.count == 32 && lower.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
            }
        }()

        let footer = pos < data.count ? data.subdata(in: pos..<data.count) : Data()
        return MsesTable(
            header: header,
            hasPayloadMD5: hasPayloadMD5,
            maxRecordSize: maxRecSize,
            records: records,
            footer: footer
        )
    }

    private func serializeMsesTable(_ table: MsesTable) -> Data {
        var header = table.header
        var maxLen = table.maxRecordSize
        for r in table.records {
            let rlen = UInt32(max(0, r.rawBytes.count - 4))
            if rlen > maxLen { maxLen = rlen }
        }
        writeUInt32LE(&header, offset: 8, value: maxLen)
        writeUInt32LE(&header, offset: 12, value: UInt32(table.records.count))

        let payloadBytesCount = table.records.reduce(0) { $0 + $1.rawBytes.count } + table.footer.count
        var payload = Data(capacity: payloadBytesCount)
        for r in table.records {
            payload.append(r.rawBytes)
        }
        payload.append(table.footer)

        if table.hasPayloadMD5 {
            let md5Bytes = Data(self.md5Hex(payload).lowercased().utf8)
            if md5Bytes.count == 32 && header.count >= 128 {
                header.replaceSubrange(96..<128, with: md5Bytes)
            }
        }

        var out = Data(capacity: header.count + payload.count)
        out.append(header)
        out.append(payload)
        return out
    }

    private func recordMatchesHero(_ rid: UInt32, heroPrefix: String?) -> Bool {
        guard let hp = heroPrefix, !hp.isEmpty else { return false }
        let ridStr = String(rid)
        return ridStr.hasPrefix(hp) || (ridStr.count == 6 && ridStr.hasPrefix("3" + hp))
    }

    private func recordMatchesAnyHero(_ rid: UInt32, heroIDs: Set<Int>) -> Bool {
        guard !heroIDs.isEmpty else { return false }
        let ridStr = String(rid)
        for hid in heroIDs {
            let hp = String(hid)
            if ridStr.hasPrefix(hp) || (ridStr.count == 6 && ridStr.hasPrefix("3" + hp)) {
                return true
            }
        }
        return false
    }

    private func mergeDatabinMsesFile(
        stem: String,
        inputs: [(heroIDs: Set<Int>, buildVersion: AovGameBuildVersion, data: Data)]
    ) throws -> Data {
        let nonWatermarkInputs = inputs.filter { $0.data.count >= 32 }
        let activeInputs = nonWatermarkInputs.isEmpty ? inputs : nonWatermarkInputs
        guard !activeInputs.isEmpty else { return Data() }

        let decryptedInputs: [(heroIDs: Set<Int>, buildVersion: AovGameBuildVersion, plain: Data)] = try activeInputs.map {
            (heroIDs: $0.heroIDs, buildVersion: $0.buildVersion, plain: try jgDecrypt($0.data, stem: stem))
        }

        // Special handling for HeadImage.bytes: pick highest buildVersion then largest customized avatar frame table
        let stemLower = stem.lowercased()
        if stemLower == "headimage" {
            let best = decryptedInputs.max { a, b in
                if a.buildVersion != b.buildVersion { return a.buildVersion < b.buildVersion }
                return a.plain.count < b.plain.count
            }!.plain
            return try jgEncrypt(best, stem: stem)
        }

        // Parse all valid MSES inputs
        var msesTables: [(heroIDs: Set<Int>, buildVersion: AovGameBuildVersion, plainSize: Int, table: MsesTable)] = []
        for item in decryptedInputs {
            if item.plain.count >= 140,
               String(data: item.plain.subdata(in: 0..<4), encoding: .ascii) == "MSES",
               let tbl = try? parseMsesTable(item.plain, stem: stem) {
                msesTables.append((heroIDs: item.heroIDs, buildVersion: item.buildVersion, plainSize: item.plain.count, table: tbl))
            }
        }

        guard !msesTables.isEmpty else {
            let best = decryptedInputs.max { a, b in
                if a.buildVersion != b.buildVersion { return a.buildVersion < b.buildVersion }
                return a.plain.count < b.plain.count
            }!.plain
            return try jgEncrypt(best, stem: stem)
        }

        // Choose the most complete MSES table (highest record count, then highest buildVersion, then largest plain size) as base
        // so older mods with fewer records (e.g. Amily BattleBank 1898 vs 1932) never overwrite newer records
        var baseIdx = 0
        for i in 1..<msesTables.count {
            let cand = msesTables[i]
            let cur = msesTables[baseIdx]
            if cand.table.records.count > cur.table.records.count ||
               (cand.table.records.count == cur.table.records.count && cand.buildVersion > cur.buildVersion) ||
               (cand.table.records.count == cur.table.records.count && cand.buildVersion == cur.buildVersion && cand.plainSize > cur.plainSize) {
                baseIdx = i
            }
        }

        var mergedTable = msesTables[baseIdx].table
        let baseBuildVersion = msesTables[baseIdx].buildVersion
        let isComponentTable = stemLower == "rescharactercomponent"
        let isHeroSoundTable = stemLower == "herosound"
        let baseIsSortedByRid = zip(mergedTable.records, mergedTable.records.dropFirst()).allSatisfy { $0.rid <= $1.rid }
        var claimedHeroIDs = msesTables[baseIdx].heroIDs

        for (tIdx, other) in msesTables.enumerated() where tIdx != baseIdx {
            let otherTable = other.table
            if otherTable.maxRecordSize > mergedTable.maxRecordSize {
                mergedTable.maxRecordSize = otherTable.maxRecordSize
            }
            let otherHeroes = other.heroIDs

            // Hero-scoped replacement for ResCharacterComponent (every input) and HeroSound (full tables within 50 rows of base)
            let useHeroScopedReplacement = !otherHeroes.isEmpty && (
                isComponentTable ||
                (isHeroSoundTable && otherTable.records.count >= mergedTable.records.count - 50)
            )

            if useHeroScopedReplacement {
                let incomingHeroRecords = otherTable.records.filter { recordMatchesAnyHero($0.rid, heroIDs: otherHeroes) }
                var newRecords: [MsesRecord] = []
                newRecords.reserveCapacity(mergedTable.records.count)
                var insertedIncoming = false
                for rec in mergedTable.records {
                    if recordMatchesAnyHero(rec.rid, heroIDs: otherHeroes) {
                        if !insertedIncoming {
                            newRecords.append(contentsOf: incomingHeroRecords)
                            insertedIncoming = true
                        }
                    } else {
                        newRecords.append(rec)
                    }
                }
                if !insertedIncoming && !incomingHeroRecords.isEmpty {
                    newRecords.append(contentsOf: incomingHeroRecords)
                }
                mergedTable.records = newRecords
                if baseIsSortedByRid {
                    mergedTable.records.sort { $0.rid < $1.rid }
                }
                claimedHeroIDs.formUnion(otherHeroes)
                continue
            }

            // General MSES record-level merge
            var indexByRid: [UInt32: Int] = [:]
            indexByRid.reserveCapacity(mergedTable.records.count)
            for (idx, r) in mergedTable.records.enumerated() {
                indexByRid[r.rid] = idx
            }

            var appendedNewRecord = false
            for oRec in otherTable.records {
                let matchesOtherHero = recordMatchesAnyHero(oRec.rid, heroIDs: otherHeroes)

                if let existingIdx = indexByRid[oRec.rid] {
                    let existing = mergedTable.records[existingIdx]
                    if existing.rawBytes != oRec.rawBytes &&
                       (matchesOtherHero || (other.buildVersion > baseBuildVersion && !recordMatchesAnyHero(oRec.rid, heroIDs: claimedHeroIDs))) {
                        mergedTable.records[existingIdx] = oRec
                    }
                } else {
                    // Never resurrect hero rows intentionally deleted by a previously merged mod (e.g. Tamyn HeroSound deletions)
                    if matchesOtherHero || !recordMatchesAnyHero(oRec.rid, heroIDs: claimedHeroIDs) {
                        indexByRid[oRec.rid] = mergedTable.records.count
                        mergedTable.records.append(oRec)
                        appendedNewRecord = true
                    }
                }
            }
            if appendedNewRecord && baseIsSortedByRid {
                mergedTable.records.sort { $0.rid < $1.rid }
            }
            claimedHeroIDs.formUnion(otherHeroes)
        }

        let mergedPlain = serializeMsesTable(mergedTable)
        return try jgEncrypt(mergedPlain, stem: stem)
    }

    // MARK: - Format 4: `Thanos/HeroSkin_1.bytes` & `HeroSkin_2.bytes` IFix Bytecode + MD5 Merger

    private struct KianaHeroSkin1Layout {
        let offA: Int
        let cntA: Int
        let endA: Int
        let offB: Int
        let cntB: Int
        let endB: Int
        let offC: Int
        let cntC: Int
        let endC: Int
        let pairs: [(heroID: Int, skinID: Int)]
    }

    private func parseKianaHeroSkin1Layout(_ dec: Data) -> KianaHeroSkin1Layout? {
        // Dynamic bytecode signature scan: inst[1..3] in Method A = [Ldarg 1; Ldfld 80; Ldc_I4 hid], followed by [Ceq 0]
        let patternA = Data([
            0xA4, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0xA7, 0x00, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00,
            0x8F, 0x00, 0x00, 0x00
        ])

        var searchStart = dec.startIndex
        while let rangeA = dec.range(of: patternA, options: [], in: searchStart..<dec.endIndex) {
            let matchPos = rangeA.lowerBound - dec.startIndex
            searchStart = rangeA.lowerBound + 4

            guard matchPos >= 12 else { continue }
            let offA = matchPos - 12
            guard offA + 4 + 10 * 8 + 8 <= dec.count else { continue }
            // Verify Ceq(0xA6, 0) immediately follows Ldc_I4(heroID)
            guard readUInt32LE(dec, matchPos + 24) == 0xA6,
                  readUInt32LE(dec, matchPos + 28) == 0 else {
                continue
            }

            let cntA = Int(readUInt32LE(dec, offA))
            let endA = offA + 4 + cntA * 8
            guard cntA >= 10, cntA < 10_000, endA + 8 <= dec.count else { continue }

            let offB = endA + 4
            let cntB = Int(readUInt32LE(dec, offB))
            let endB = offB + 4 + cntB * 8
            guard cntB >= 64, cntB < 10_000, endB + 8 <= dec.count else { continue }

            let offC = endB + 4
            let cntC = Int(readUInt32LE(dec, offC))
            let endC = offC + 4 + cntC * 8
            guard cntC >= 64, cntC < 10_000, endC <= dec.count else { continue }

            // Verify Method C's skin return sequence at inst[56..59]: Ceq, Brfalse, Ldc_I4 skinID, Ret 1
            let c56 = offC + 4 + 56 * 8
            guard readUInt32LE(dec, c56) == 0xA6,
                  readUInt32LE(dec, c56 + 8) == 0x86,
                  readUInt32LE(dec, c56 + 16) == 0x8F,
                  readUInt32LE(dec, c56 + 24) == 0xAD else {
                continue
            }

            let baseHid = Int(Int32(bitPattern: readUInt32LE(dec, matchPos + 20)))
            let baseSid = Int(Int32(bitPattern: readUInt32LE(dec, offC + 4 + 58 * 8 + 4)))
            guard baseHid >= 100 && baseHid <= 9999 && baseSid >= 10000 && baseSid <= 9_999_999 else {
                continue
            }

            var pairs: [(heroID: Int, skinID: Int)] = [(baseHid, baseSid)]
            var j = 64
            while j + 5 < cntC {
                let i0 = offC + 4 + j * 8
                if readUInt32LE(dec, i0) == 0x48 &&
                   readUInt32LE(dec, i0 + 8) == 0x8F &&
                   readUInt32LE(dec, i0 + 16) == 0xA6 &&
                   readUInt32LE(dec, i0 + 24) == 0x86 &&
                   readUInt32LE(dec, i0 + 32) == 0x8F &&
                   readUInt32LE(dec, i0 + 40) == 0xAD {
                    let eh = Int(Int32(bitPattern: readUInt32LE(dec, i0 + 12)))
                    let es = Int(Int32(bitPattern: readUInt32LE(dec, i0 + 36)))
                    if eh >= 100 && eh <= 9999 && es >= 10000 && !pairs.contains(where: { $0.heroID == eh }) {
                        pairs.append((eh, es))
                    }
                    j += 6
                } else {
                    j += 1
                }
            }

            return KianaHeroSkin1Layout(
                offA: offA, cntA: cntA, endA: endA,
                offB: offB, cntB: cntB, endB: endB,
                offC: offC, cntC: cntC, endC: endC,
                pairs: pairs
            )
        }
        return nil
    }

    private func isKianaHeroSkin1Template(_ dec: Data) -> Bool {
        return parseKianaHeroSkin1Layout(dec) != nil
    }

    private func extractAllHeroAndSkinsFromHeroSkin1(_ dec: Data) -> [(heroID: Int, skinID: Int)] {
        if let layout = parseKianaHeroSkin1Layout(dec) {
            return layout.pairs
        }
        // Dynamic pattern fallback: Ldarg(1), Ldfld(80), Ldc_I4(heroID)
        let patternA = Data([
            0xA4, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0xA7, 0x00, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00,
            0x8F, 0x00, 0x00, 0x00
        ])
        if let rangeA = dec.range(of: patternA), rangeA.upperBound + 4 <= dec.count {
            let hid = Int(readUInt32LE(dec, rangeA.upperBound - dec.startIndex))
            let patternC = Data([
                0xA6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x86, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
                0x8F, 0x00, 0x00, 0x00
            ])
            var searchPos = rangeA.upperBound
            var foundSkinID: Int? = nil
            while let rangeC = dec.range(of: patternC, options: [], in: searchPos..<dec.count),
                  rangeC.upperBound + 4 <= dec.count {
                let candidate = Int(readUInt32LE(dec, rangeC.upperBound - dec.startIndex))
                if candidate >= 10000 && candidate <= 9_999_999 {
                    foundSkinID = candidate
                    break
                }
                searchPos = rangeC.upperBound
            }
            if hid >= 100 && hid <= 9999, let sid = foundSkinID {
                return [(hid, sid)]
            }
        }
        return []
    }

    private func extractHeroAndSkinFromHeroSkin1(_ dec: Data) -> (heroID: Int, skinID: Int)? {
        return extractAllHeroAndSkinsFromHeroSkin1(dec).first
    }

    private struct KianaHeroSkin2Layout {
        let off: Int
        let cnt: Int
        let end: Int
        let params: [(heroID: Int, bcastID: Int, pbtnID: Int)]
    }

    private func parseKianaHeroSkin2Layout(_ dec: Data) -> KianaHeroSkin2Layout? {
        // Dynamic bytecode signature scan: inst[58..67] = Ldarg 1, Ldc_I4 hid, Ceq 0, Brfalse, Ldarg 0, Ldc_I4 bcast, Stfld 3, Ldarg 0, Ldc_I4 pbtn, Stfld 2
        let patPre = Data([
            0xA4, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x8F, 0x00, 0x00, 0x00
        ])

        var searchStart = dec.startIndex
        while let range = dec.range(of: patPre, options: [], in: searchStart..<dec.endIndex) {
            let matchPos = range.lowerBound - dec.startIndex
            searchStart = range.lowerBound + 4

            let headerBytesBeforeInst58 = 4 + 58 * 8
            guard matchPos >= headerBytesBeforeInst58,
                  matchPos + 10 * 8 <= dec.count else {
                continue
            }

            // Validate inst[60..67] structural opcodes relative to matchPos
            guard readUInt32LE(dec, matchPos + 16) == 0xA6, readUInt32LE(dec, matchPos + 20) == 0,
                  readUInt32LE(dec, matchPos + 24) == 0x86,
                  readUInt32LE(dec, matchPos + 32) == 0xA4, readUInt32LE(dec, matchPos + 36) == 0,
                  readUInt32LE(dec, matchPos + 40) == 0x8F,
                  readUInt32LE(dec, matchPos + 48) == 0x4B, readUInt32LE(dec, matchPos + 52) == 3,
                  readUInt32LE(dec, matchPos + 56) == 0xA4, readUInt32LE(dec, matchPos + 60) == 0,
                  readUInt32LE(dec, matchPos + 64) == 0x8F,
                  readUInt32LE(dec, matchPos + 72) == 0x4B, readUInt32LE(dec, matchPos + 76) == 2 else {
                continue
            }

            let off = matchPos - headerBytesBeforeInst58
            let cnt = Int(readUInt32LE(dec, off))
            let end = off + 4 + cnt * 8
            guard cnt >= 70, cnt < 10_000, end <= dec.count else { continue }

            let baseHid = Int(Int32(bitPattern: readUInt32LE(dec, matchPos + 12)))
            let baseBcast = Int(Int32(bitPattern: readUInt32LE(dec, matchPos + 44)))
            let basePbtn = Int(Int32(bitPattern: readUInt32LE(dec, matchPos + 68)))
            guard baseHid >= 100 && baseHid <= 9999 else { continue }

            var params: [(heroID: Int, bcastID: Int, pbtnID: Int)] = [(baseHid, baseBcast, basePbtn)]
            var j = 70
            while j + 10 < cnt {
                let i0 = off + 4 + j * 8
                if readUInt32LE(dec, i0) == 0xA4 &&
                   readUInt32LE(dec, i0 + 8) == 0x8F &&
                   readUInt32LE(dec, i0 + 16) == 0xA6 &&
                   readUInt32LE(dec, i0 + 24) == 0x86 &&
                   readUInt32LE(dec, i0 + 40) == 0x8F &&
                   readUInt32LE(dec, i0 + 48) == 0x4B &&
                   readUInt32LE(dec, i0 + 64) == 0x8F &&
                   readUInt32LE(dec, i0 + 72) == 0x4B {
                    let eh = Int(Int32(bitPattern: readUInt32LE(dec, i0 + 12)))
                    let eb = Int(Int32(bitPattern: readUInt32LE(dec, i0 + 44)))
                    let ep = Int(Int32(bitPattern: readUInt32LE(dec, i0 + 68)))
                    if eh >= 100 && eh <= 9999 && !params.contains(where: { $0.heroID == eh }) {
                        params.append((eh, eb, ep))
                    }
                    j += 11
                } else {
                    j += 1
                }
            }

            return KianaHeroSkin2Layout(off: off, cnt: cnt, end: end, params: params)
        }
        return nil
    }

    private func isKianaHeroSkin2Template(_ dec: Data) -> Bool {
        return parseKianaHeroSkin2Layout(dec) != nil
    }

    private func extractAllParamsFromHeroSkin2(_ dec: Data) -> [(heroID: Int, bcastID: Int, pbtnID: Int)] {
        return parseKianaHeroSkin2Layout(dec)?.params ?? []
    }

    private func extractParamsFromHeroSkin2(_ dec: Data) -> (heroID: Int, bcastID: Int, pbtnID: Int)? {
        return parseKianaHeroSkin2Layout(dec)?.params.first
    }

    private func ifixInst(_ op: UInt32, _ arg: Int32) -> Data {
        var d = Data(capacity: 8)
        appendUInt32LE(&d, op)
        appendUInt32LE(&d, UInt32(bitPattern: arg))
        return d
    }

    private func mergeThanosHeroSkin1(
        contributors: [(heroID: Int?, skinID: Int?, buildVersion: AovGameBuildVersion, encrypted: Data)],
        pkgMD5s: [String: String]
    ) throws -> Data {
        guard !contributors.isEmpty else { return Data() }

        let decryptedContributors: [(heroID: Int?, skinID: Int?, buildVersion: AovGameBuildVersion, plain: Data, layout: KianaHeroSkin1Layout?)] = try contributors.map {
            let plain = try jgDecrypt($0.encrypted, stem: "HeroSkin_1")
            return (heroID: $0.heroID, skinID: $0.skinID, buildVersion: $0.buildVersion, plain: plain, layout: parseKianaHeroSkin1Layout(plain))
        }

        // Find the highest-build contributor that uses the KianaMod 34KB IFix patch template
        let kianaCandidates = decryptedContributors.filter { $0.layout != nil }
        guard let baseItem = kianaCandidates.max(by: { a, b in
            if a.buildVersion != b.buildVersion { return a.buildVersion < b.buildVersion }
            return a.plain.count < b.plain.count
        }),
              let baseLayout = baseItem.layout,
              let baseHeroInfo = baseLayout.pairs.first else {
            // None of the mods use the KianaMod 34KB template:
            // Pick the highest-build / largest decrypted HeroSkin_1 and update its embedded pkg MD5s
            var bestPlain = decryptedContributors.max { a, b in
                if a.buildVersion != b.buildVersion { return a.buildVersion < b.buildVersion }
                return a.plain.count < b.plain.count
            }!.plain
            updateEmbeddedPkgMD5s(in: &bestPlain, pkgMD5s: pkgMD5s)
            return try jgEncrypt(bestPlain, stem: "HeroSkin_1")
        }

        let basePlain = baseItem.plain
        let baseHeroID = baseHeroInfo.heroID

        // Collect all unique (heroID, skinID) pairs across all contributors (including multi-hero re-merges!)
        var heroSkins: [(heroID: Int, skinID: Int)] = [baseHeroInfo]
        for c in decryptedContributors {
            let extractedPairs = extractAllHeroAndSkinsFromHeroSkin1(c.plain)
            if !extractedPairs.isEmpty {
                for pair in extractedPairs {
                    if !heroSkins.contains(where: { $0.heroID == pair.heroID }) {
                        heroSkins.append(pair)
                    }
                }
            } else if let h = c.heroID, let s = c.skinID {
                if !heroSkins.contains(where: { $0.heroID == h }) {
                    heroSkins.append((h, s))
                }
            }
        }

        var patched = Data()
        let extraHeroes = heroSkins.filter { $0.heroID != baseHeroID }

        // Method A: base header + 10 instructions at offA..<(offA + 4 + 10*8)
        var methodA = basePlain.subdata(in: baseLayout.offA..<(baseLayout.offA + 4 + 10 * 8))
        if !extraHeroes.isEmpty {
            let newCountA = UInt32(10 + 7 * extraHeroes.count + 2)
            writeUInt32LE(&methodA, offset: 0, value: newCountA)
            methodA.replaceSubrange((4 + 6 * 8)..<(4 + 7 * 8), with: ifixInst(0x5D, 4))
            for eh in extraHeroes {
                methodA.append(ifixInst(0xA4, 1))                 // Ldarg 1
                methodA.append(ifixInst(0xA7, 80))                // Ldfld 80
                methodA.append(ifixInst(0x8F, Int32(eh.heroID)))  // Ldc_I4 heroID
                methodA.append(ifixInst(0xA6, 0))                 // Ceq
                methodA.append(ifixInst(0x86, 3))                 // Brfalse +3
                methodA.append(ifixInst(0x8F, 1))                 // Ldc_I4 1
                methodA.append(ifixInst(0xAD, 1))                 // Ret 1
            }
            methodA.append(ifixInst(0x8F, 0))                     // Ldc_I4 0
            methodA.append(ifixInst(0xAD, 1))                     // Ret 1
        } else {
            writeUInt32LE(&methodA, offset: 0, value: 10)
        }

        // Method B: base header + 64 instructions at offB..<(offB + 4 + 64*8)
        var methodB = basePlain.subdata(in: baseLayout.offB..<(baseLayout.offB + 4 + 64 * 8))
        methodB.replaceSubrange((4 + 1 * 8)..<(4 + 2 * 8), with: ifixInst(0x5D, 29))
        if !extraHeroes.isEmpty {
            let newCountB = UInt32(64 + 6 * extraHeroes.count + 2)
            writeUInt32LE(&methodB, offset: 0, value: newCountB)
            methodB.replaceSubrange((4 + 58 * 8)..<(4 + 59 * 8), with: ifixInst(0x5D, 6))
            for eh in extraHeroes {
                methodB.append(ifixInst(0x48, 0))                 // Ldloc 0
                methodB.append(ifixInst(0x8F, Int32(eh.heroID)))  // Ldc_I4 heroID
                methodB.append(ifixInst(0xA6, 0))                 // Ceq
                methodB.append(ifixInst(0x86, 3))                 // Brfalse +3
                methodB.append(ifixInst(0x8F, 1))                 // Ldc_I4 1
                methodB.append(ifixInst(0xAD, 1))                 // Ret 1
            }
            methodB.append(ifixInst(0x8F, 0))                     // Ldc_I4 0
            methodB.append(ifixInst(0xAD, 1))                     // Ret 1
        } else {
            writeUInt32LE(&methodB, offset: 0, value: 64)
        }

        // Method C: base header + 64 instructions at offC..<(offC + 4 + 64*8)
        var methodC = basePlain.subdata(in: baseLayout.offC..<(baseLayout.offC + 4 + 64 * 8))
        methodC.replaceSubrange((4 + 1 * 8)..<(4 + 2 * 8), with: ifixInst(0x5D, 29))
        if !extraHeroes.isEmpty {
            let newCountC = UInt32(64 + 6 * extraHeroes.count + 2)
            writeUInt32LE(&methodC, offset: 0, value: newCountC)
            methodC.replaceSubrange((4 + 60 * 8)..<(4 + 61 * 8), with: ifixInst(0x5D, 4))
            for eh in extraHeroes {
                methodC.append(ifixInst(0x48, 0))                 // Ldloc 0
                methodC.append(ifixInst(0x8F, Int32(eh.heroID)))  // Ldc_I4 heroID
                methodC.append(ifixInst(0xA6, 0))                 // Ceq
                methodC.append(ifixInst(0x86, 3))                 // Brfalse +3
                methodC.append(ifixInst(0x8F, Int32(eh.skinID)))  // Ldc_I4 skinID
                methodC.append(ifixInst(0xAD, 1))                 // Ret 1
            }
            methodC.append(ifixInst(0x8F, 0))                     // Ldc_I4 0
            methodC.append(ifixInst(0xAD, 1))                     // Ret 1
        } else {
            writeUInt32LE(&methodC, offset: 0, value: 64)
        }

        patched.append(basePlain.subdata(in: 0..<baseLayout.offA))
        patched.append(methodA)
        patched.append(basePlain.subdata(in: baseLayout.endA..<baseLayout.offB))
        patched.append(methodB)
        patched.append(basePlain.subdata(in: baseLayout.endB..<baseLayout.offC))
        patched.append(methodC)
        patched.append(basePlain.subdata(in: baseLayout.endC..<basePlain.count))

        updateEmbeddedPkgMD5s(in: &patched, pkgMD5s: pkgMD5s)
        return try jgEncrypt(patched, stem: "HeroSkin_1")
    }

    private func mergeThanosHeroSkin2(
        contributors: [(heroID: Int?, bcastID: Int?, pbtnID: Int?, buildVersion: AovGameBuildVersion, encrypted: Data)],
        pkgMD5s: [String: String]
    ) throws -> Data {
        guard !contributors.isEmpty else { return Data() }

        let decryptedContributors: [(heroID: Int?, bcastID: Int?, pbtnID: Int?, buildVersion: AovGameBuildVersion, plain: Data, layout: KianaHeroSkin2Layout?)] = try contributors.map {
            let plain = try jgDecrypt($0.encrypted, stem: "HeroSkin_2")
            return (heroID: $0.heroID, bcastID: $0.bcastID, pbtnID: $0.pbtnID, buildVersion: $0.buildVersion, plain: plain, layout: parseKianaHeroSkin2Layout(plain))
        }

        // Find the highest-build contributor that uses the KianaMod PlayerBase::AddHero template
        let kianaCandidates = decryptedContributors.filter { $0.layout != nil }
        guard let baseItem = kianaCandidates.max(by: { a, b in
            if a.buildVersion != b.buildVersion { return a.buildVersion < b.buildVersion }
            return a.plain.count < b.plain.count
        }),
              let baseLayout = baseItem.layout,
              let baseHeroParams = baseLayout.params.first else {
            // None of the mods use the KianaMod AddHero template:
            // Filter out invalid HeroSkin_2 targeting Project_d instead of Project.Plugins_d (e.g. Edras popup ad)
            let pluginsMarker = Data("Project.Plugins_d".utf8)
            let validCandidates = decryptedContributors.filter { $0.plain.range(of: pluginsMarker) != nil }
            guard let best = validCandidates.max(by: { a, b in
                if a.buildVersion != b.buildVersion { return a.buildVersion < b.buildVersion }
                return a.plain.count < b.plain.count
            }) else {
                return Data()
            }
            var bestPlain = best.plain
            updateEmbeddedPkgMD5s(in: &bestPlain, pkgMD5s: pkgMD5s)
            return try jgEncrypt(bestPlain, stem: "HeroSkin_2")
        }

        let basePlain = baseItem.plain
        let baseHeroID = baseHeroParams.heroID

        var heroParams: [(heroID: Int, bcastID: Int, pbtnID: Int)] = [baseHeroParams]
        for c in decryptedContributors {
            for extracted in extractAllParamsFromHeroSkin2(c.plain) {
                if !heroParams.contains(where: { $0.heroID == extracted.heroID }) {
                    heroParams.append(extracted)
                }
            }
        }

        var patched = Data()
        let extraHeroes = heroParams.filter { $0.heroID != baseHeroID }
        // Base method header + 70 instructions at 1209..<1773
        var method = basePlain.subdata(in: baseLayout.off..<(baseLayout.off + 4 + 70 * 8))
        method.replaceSubrange((4 + 29 * 8)..<(4 + 30 * 8), with: ifixInst(0x5D, 29))

        if !extraHeroes.isEmpty {
            let newCount = UInt32(70 + 11 * extraHeroes.count + 1)
            writeUInt32LE(&method, offset: 0, value: newCount)
            method.replaceSubrange((4 + 61 * 8)..<(4 + 62 * 8), with: ifixInst(0x86, 9))

            for ep in extraHeroes {
                method.append(ifixInst(0xA4, 1))                  // Ldarg 1
                method.append(ifixInst(0x8F, Int32(ep.heroID)))   // Ldc_I4 heroID
                method.append(ifixInst(0xA6, 0))                  // Ceq
                method.append(ifixInst(0x86, 8))                  // Brfalse +8
                method.append(ifixInst(0xA4, 0))                  // Ldarg 0
                method.append(ifixInst(0x8F, Int32(ep.bcastID)))  // Ldc_I4 bcastID
                method.append(ifixInst(0x4B, 3))                  // Stfld 3
                method.append(ifixInst(0xA4, 0))                  // Ldarg 0
                method.append(ifixInst(0x8F, Int32(ep.pbtnID)))   // Ldc_I4 pbtnID
                method.append(ifixInst(0x4B, 2))                  // Stfld 2
                method.append(ifixInst(0xAD, 0))                  // Ret 0
            }
            method.append(ifixInst(0xAD, 0))                      // Final Ret 0
        } else {
            writeUInt32LE(&method, offset: 0, value: 70)
        }

        patched.append(basePlain.subdata(in: 0..<baseLayout.off))
        patched.append(method)
        patched.append(basePlain.subdata(in: baseLayout.end..<basePlain.count))

        updateEmbeddedPkgMD5s(in: &patched, pkgMD5s: pkgMD5s)
        return try jgEncrypt(patched, stem: "HeroSkin_2")
    }

    private func updateEmbeddedPkgMD5s(in data: inout Data, pkgMD5s: [String: String]) {
        guard !pkgMD5s.isEmpty else { return }
        @inline(__always)
        func asciiLower(_ b: UInt8) -> UInt8 {
            return (b >= 65 && b <= 90) ? (b + 32) : b
        }

        let total = data.count
        for (pkgName, md5Hex) in pkgMD5s where md5Hex.utf8.count == 32 {
            let needle = Array((pkgName.lowercased() + " ").utf8)
            let needleCount = needle.count
            guard needleCount > 0, total >= needleCount + 32 else { continue }
            let md5Bytes = Array(md5Hex.lowercased().utf8)

            var pos = 0
            while pos + needleCount + 32 <= total {
                var matched = true
                for k in 0..<needleCount {
                    if asciiLower(data[data.startIndex + pos + k]) != needle[k] {
                        matched = false
                        break
                    }
                }
                if matched {
                    let hashStart = pos + needleCount
                    let hashEnd = hashStart + 32
                    data.replaceSubrange((data.startIndex + hashStart)..<(data.startIndex + hashEnd), with: md5Bytes)
                    pos = hashEnd
                } else {
                    pos += 1
                }
            }
        }
    }

    // MARK: - In-Memory ZIP Reader/Writer for `.pkg.bytes`

    private struct InMemoryZipEntry {
        let name: String
        let modifiedTime: UInt16
        let modifiedDate: UInt16
        let data: Data
    }

    private struct CentralDirEntry {
        let name: String
        let isDirectory: Bool
        let method: UInt16
        let modifiedTime: UInt16
        let modifiedDate: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private func readZipCentralDirectory(handle: FileHandle, archiveSize: UInt64) throws -> [CentralDirEntry] {
        guard archiveSize >= 22 else { throw AovModMergerError.invalidArchive("File quá nhỏ") }
        let tailSize = min(archiveSize, 65_557)
        let tailOffset = archiveSize - tailSize
        try handle.seek(toOffset: tailOffset)
        guard let tail = try handle.read(upToCount: Int(tailSize)) else {
            throw AovModMergerError.invalidArchive("Không đọc được EOCD")
        }

        var eocdPos: Int? = nil
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if readUInt32LE(tail, i) == 0x0605_4B50 {
                eocdPos = i
                break
            }
        }
        guard let eocd = eocdPos else {
            throw AovModMergerError.invalidArchive("Không tìm thấy chữ ký EOCD")
        }

        let entryCount = Int(readUInt16LE(tail, eocd + 10))
        let centralSize = UInt64(readUInt32LE(tail, eocd + 12))
        let centralOffset = UInt64(readUInt32LE(tail, eocd + 16))
        guard centralOffset + centralSize <= archiveSize else {
            throw AovModMergerError.invalidArchive("Central Directory vượt quá kích thước tệp")
        }

        try handle.seek(toOffset: centralOffset)
        guard let cdData = try handle.read(upToCount: Int(centralSize)) else {
            throw AovModMergerError.invalidArchive("Không thể đọc Central Directory")
        }

        var results: [CentralDirEntry] = []
        var pos = 0
        for _ in 0..<entryCount {
            guard pos + 46 <= cdData.count, readUInt32LE(cdData, pos) == 0x0201_4B50 else { break }
            let method = readUInt16LE(cdData, pos + 10)
            let modTime = readUInt16LE(cdData, pos + 12)
            let modDate = readUInt16LE(cdData, pos + 14)
            let crc = readUInt32LE(cdData, pos + 16)
            let compSize = readUInt32LE(cdData, pos + 20)
            let uncompSize = readUInt32LE(cdData, pos + 24)
            let nameLen = Int(readUInt16LE(cdData, pos + 28))
            let extraLen = Int(readUInt16LE(cdData, pos + 30))
            let commentLen = Int(readUInt16LE(cdData, pos + 32))
            let localOff = readUInt32LE(cdData, pos + 42)

            guard pos + 46 + nameLen <= cdData.count else { break }
            let nameData = cdData.subdata(in: (pos + 46)..<(pos + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            let isDir = name.hasSuffix("/")
            results.append(CentralDirEntry(
                name: name,
                isDirectory: isDir,
                method: method,
                modifiedTime: modTime,
                modifiedDate: modDate,
                crc32: crc,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOff
            ))
            pos += 46 + nameLen + extraLen + commentLen
        }
        return results
    }

    private func extractSingleEntryData(handle: FileHandle, entry: CentralDirEntry) throws -> Data {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(entry.uncompressedSize)),
              !PatchPackageLimits.exceedsExpandedLimit(UInt64(entry.compressedSize)) else {
            throw AovModMergerError.sizeLimitExceeded
        }
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let lfh = try handle.read(upToCount: 30), lfh.count == 30,
              readUInt32LE(lfh, 0) == 0x0403_4B50 else {
            throw AovModMergerError.invalidArchive("Local File Header lỗi")
        }
        let nameLen = UInt64(readUInt16LE(lfh, 26))
        let extraLen = UInt64(readUInt16LE(lfh, 28))
        let dataOffset = UInt64(entry.localHeaderOffset) + 30 + nameLen + extraLen
        try handle.seek(toOffset: dataOffset)
        guard let compData = try handle.read(upToCount: Int(entry.compressedSize)) else {
            throw AovModMergerError.invalidArchive("Không đọc được payload")
        }
        if entry.method == 0 {
            return compData
        } else if entry.method == 8 {
            if entry.uncompressedSize == 0 {
                return Data()
            }
            var dst = Data(count: Int(entry.uncompressedSize))
            let rc = compData.withUnsafeBytes { srcBuf in
                dst.withUnsafeMutableBytes { dstBuf in
                    totorox_decompress_deflate(
                        srcBuf.bindMemory(to: UInt8.self).baseAddress,
                        compData.count,
                        dstBuf.bindMemory(to: UInt8.self).baseAddress,
                        Int(entry.uncompressedSize)
                    )
                }
            }
            guard rc == 0 else { throw AovModMergerError.invalidArchive("Giải nén deflate thất bại") }
            return dst
        }
        throw AovModMergerError.invalidArchive("Phương thức nén không hỗ trợ: \(entry.method)")
    }

    private func parseInMemoryZip(_ archive: Data) throws -> [InMemoryZipEntry] {
        guard archive.count >= 22 else { return [] }
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(archive.count)) else {
            throw AovModMergerError.sizeLimitExceeded
        }
        let searchLimit = max(0, archive.count - 65_557)
        var eocdOffset: Int? = nil
        for i in stride(from: archive.count - 22, through: searchLimit, by: -1) {
            if readUInt32LE(archive, i) == 0x0605_4B50 {
                eocdOffset = i
                break
            }
        }
        guard let eocd = eocdOffset else {
            throw AovModMergerError.invalidArchive("Không tìm thấy EOCD trong .pkg.bytes")
        }

        var count = Int(readUInt16LE(archive, eocd + 10))
        var cdPos = Int(readUInt32LE(archive, eocd + 16))

        if eocd >= 20 && readUInt32LE(archive, eocd - 20) == 0x0706_4B50 {
            let rawZip64Offset = readUInt64LE(archive, eocd - 12)
            if rawZip64Offset <= UInt64(archive.count),
               archive.count - Int(rawZip64Offset) >= 56 {
                let zip64EocdOff = Int(rawZip64Offset)
                if readUInt32LE(archive, zip64EocdOff) == 0x0606_4B50 {
                    let rawCount = readUInt64LE(archive, zip64EocdOff + 32)
                    let rawCdPos = readUInt64LE(archive, zip64EocdOff + 48)
                    if rawCount <= UInt64(Int.max), rawCdPos <= UInt64(Int.max) {
                        count = Int(rawCount)
                        cdPos = Int(rawCdPos)
                    }
                }
            }
        }

        var entries: [InMemoryZipEntry] = []
        entries.reserveCapacity(max(0, min(count, 20_000)))
        var totalUncompressedBytes: UInt64 = 0

        for _ in 0..<count {
            guard cdPos >= 0,
                  cdPos <= archive.count,
                  archive.count - cdPos >= 46,
                  readUInt32LE(archive, cdPos) == 0x0201_4B50 else { break }
            let method = readUInt16LE(archive, cdPos + 10)
            let modTime = readUInt16LE(archive, cdPos + 12)
            let modDate = readUInt16LE(archive, cdPos + 14)
            var compSize = Int(readUInt32LE(archive, cdPos + 20))
            var uncompSize = Int(readUInt32LE(archive, cdPos + 24))
            let nameLen = Int(readUInt16LE(archive, cdPos + 28))
            let extraLen = Int(readUInt16LE(archive, cdPos + 30))
            let commentLen = Int(readUInt16LE(archive, cdPos + 32))
            var localOff = Int(readUInt32LE(archive, cdPos + 42))

            let nameStart = cdPos + 46
            guard nameStart + nameLen + extraLen + commentLen <= archive.count else { break }
            let nameData = archive.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""

            if uncompSize == 0xFFFF_FFFF || compSize == 0xFFFF_FFFF || localOff == 0xFFFF_FFFF {
                var extraCursor = nameStart + nameLen
                let extraEnd = extraCursor + extraLen
                while extraCursor + 4 <= extraEnd {
                    let tag = readUInt16LE(archive, extraCursor)
                    let blockSz = Int(readUInt16LE(archive, extraCursor + 2))
                    var valCursor = extraCursor + 4
                    let blockEnd = min(valCursor + blockSz, extraEnd)
                    if tag == 0x0001 {
                        if uncompSize == 0xFFFF_FFFF && valCursor + 8 <= blockEnd {
                            let value = readUInt64LE(archive, valCursor)
                            guard value <= UInt64(Int.max) else { throw AovModMergerError.sizeLimitExceeded }
                            uncompSize = Int(value)
                            valCursor += 8
                        }
                        if compSize == 0xFFFF_FFFF && valCursor + 8 <= blockEnd {
                            let value = readUInt64LE(archive, valCursor)
                            guard value <= UInt64(Int.max) else { throw AovModMergerError.sizeLimitExceeded }
                            compSize = Int(value)
                            valCursor += 8
                        }
                        if localOff == 0xFFFF_FFFF && valCursor + 8 <= blockEnd {
                            let value = readUInt64LE(archive, valCursor)
                            guard value <= UInt64(Int.max) else { throw AovModMergerError.sizeLimitExceeded }
                            localOff = Int(value)
                            valCursor += 8
                        }
                        break
                    }
                    extraCursor += 4 + blockSz
                }
            }

            cdPos += 46 + nameLen + extraLen + commentLen

            if name.hasSuffix("/") { continue }
            guard uncompSize >= 0,
                  compSize >= 0,
                  uncompSize <= Int.max,
                  compSize <= Int.max else {
                throw AovModMergerError.sizeLimitExceeded
            }
            let (expandedSum, expandedOverflow) = totalUncompressedBytes.addingReportingOverflow(UInt64(uncompSize))
            guard !expandedOverflow,
                  !PatchPackageLimits.exceedsExpandedLimit(expandedSum) else {
                throw AovModMergerError.sizeLimitExceeded
            }
            totalUncompressedBytes = expandedSum
            guard localOff >= 0,
                  localOff <= archive.count,
                  archive.count - localOff >= 30,
                  readUInt32LE(archive, localOff) == 0x0403_4B50 else { continue }
            let lNameLen = Int(readUInt16LE(archive, localOff + 26))
            let lExtraLen = Int(readUInt16LE(archive, localOff + 28))
            let dataStart = localOff + 30 + lNameLen + lExtraLen
            let readSize = (method == 0) ? uncompSize : compSize
            guard readSize >= 0,
                  dataStart >= 0,
                  dataStart <= archive.count,
                  readSize <= archive.count - dataStart else { continue }
            let rawSlice = archive.subdata(in: dataStart..<(dataStart + readSize))

            let payload: Data
            if method == 0 {
                payload = rawSlice
            } else if method == 8 {
                if uncompSize == 0 {
                    payload = Data()
                } else {
                    var out = Data(count: uncompSize)
                    let ok = rawSlice.withUnsafeBytes { sPtr in
                        out.withUnsafeMutableBytes { dPtr in
                            totorox_decompress_deflate(
                                sPtr.bindMemory(to: UInt8.self).baseAddress,
                                rawSlice.count,
                                dPtr.bindMemory(to: UInt8.self).baseAddress,
                                uncompSize
                            )
                        }
                    }
                    payload = (ok == 0) ? out : rawSlice
                }
            } else {
                payload = rawSlice
            }

            entries.append(InMemoryZipEntry(
                name: name,
                modifiedTime: modTime,
                modifiedDate: modDate,
                data: payload
            ))
        }
        return entries
    }

    private func readUInt64LE(_ data: Data, _ offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var val: UInt64 = 0
        for i in 0..<8 {
            val |= UInt64(data[base + i]) << UInt64(i * 8)
        }
        return val
    }

    private func buildInMemoryStoreZip(_ entries: [InMemoryZipEntry]) throws -> Data {
        struct WrittenMeta {
            let nameData: Data
            let modTime: UInt16
            let modDate: UInt16
            let crc: UInt32
            let size: UInt32
            let localOffset: UInt32
        }

        let approxCapacity = entries.reduce(64) { $0 + $1.data.count + 96 }
        var out = Data(capacity: min(approxCapacity, Int(PatchPackageLimits.maximumExpandedBytes)))
        var metas: [WrittenMeta] = []
        metas.reserveCapacity(entries.count)
        var projectedTotal = 64

        let utf8Flag: UInt16 = 0x0800

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8) else { continue }
            guard metas.count < Int(UInt16.max),
                  nameData.count <= Int(UInt16.max) else {
                throw AovModMergerError.sizeLimitExceeded
            }
            // Local header (30 + name) + payload + central record (46 + name) + EOCD (22).
            let entryBytes = 30 + nameData.count + entry.data.count + 46 + nameData.count + 22
            let (projected, overflow) = projectedTotal.addingReportingOverflow(entryBytes)
            guard !overflow,
                  !PatchPackageLimits.exceedsExpandedLimit(Int64(projected)),
                  projected <= Int(UInt32.max) else {
                throw AovModMergerError.sizeLimitExceeded
            }
            projectedTotal = projected

            let localOffset = UInt32(out.count)
            let crc = computeCRC32(entry.data)
            let size = UInt32(entry.data.count)

            // Local File Header (30 bytes + name)
            appendUInt32LE(&out, 0x0403_4B50)
            appendUInt16LE(&out, 20)
            appendUInt16LE(&out, utf8Flag)
            appendUInt16LE(&out, 0) // STORE
            appendUInt16LE(&out, entry.modifiedTime)
            appendUInt16LE(&out, entry.modifiedDate)
            appendUInt32LE(&out, crc)
            appendUInt32LE(&out, size)
            appendUInt32LE(&out, size)
            appendUInt16LE(&out, UInt16(nameData.count))
            appendUInt16LE(&out, 0)
            out.append(nameData)
            out.append(entry.data)

            metas.append(WrittenMeta(
                nameData: nameData,
                modTime: entry.modifiedTime,
                modDate: entry.modifiedDate,
                crc: crc,
                size: size,
                localOffset: localOffset
            ))
        }

        let cdOffset = UInt32(out.count)
        for m in metas {
            appendUInt32LE(&out, 0x0201_4B50)
            appendUInt16LE(&out, 20)
            appendUInt16LE(&out, 20)
            appendUInt16LE(&out, utf8Flag)
            appendUInt16LE(&out, 0) // STORE
            appendUInt16LE(&out, m.modTime)
            appendUInt16LE(&out, m.modDate)
            appendUInt32LE(&out, m.crc)
            appendUInt32LE(&out, m.size)
            appendUInt32LE(&out, m.size)
            appendUInt16LE(&out, UInt16(m.nameData.count))
            appendUInt16LE(&out, 0)
            appendUInt16LE(&out, 0)
            appendUInt16LE(&out, 0)
            appendUInt16LE(&out, 0)
            appendUInt32LE(&out, 0)
            appendUInt32LE(&out, m.localOffset)
            out.append(m.nameData)
        }

        let cdSize = UInt32(out.count) - cdOffset
        appendUInt32LE(&out, 0x0605_4B50)
        appendUInt16LE(&out, 0)
        appendUInt16LE(&out, 0)
        appendUInt16LE(&out, UInt16(metas.count))
        appendUInt16LE(&out, UInt16(metas.count))
        appendUInt32LE(&out, cdSize)
        appendUInt32LE(&out, cdOffset)
        appendUInt16LE(&out, 0)
        return out
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

    // MARK: - Binary / Checksum Helpers

    private func md5Hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private func computeCRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            let idx = Int((crc ^ UInt32(b)) & 0xFF)
            crc = Self.crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private func readUInt16BE(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    private func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    private func appendUInt16LE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func writeUInt16BE(_ data: inout Data, offset: Int, value: UInt16) {
        let base = data.startIndex + offset
        data[base] = UInt8((value >> 8) & 0xFF)
        data[base + 1] = UInt8(value & 0xFF)
    }

    private func writeUInt32LE(_ data: inout Data, offset: Int, value: UInt32) {
        let base = data.startIndex + offset
        data[base] = UInt8(value & 0xFF)
        data[base + 1] = UInt8((value >> 8) & 0xFF)
        data[base + 2] = UInt8((value >> 16) & 0xFF)
        data[base + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func writeUInt32BE(_ data: inout Data, offset: Int, value: UInt32) {
        let base = data.startIndex + offset
        data[base] = UInt8((value >> 24) & 0xFF)
        data[base + 1] = UInt8((value >> 16) & 0xFF)
        data[base + 2] = UInt8((value >> 8) & 0xFF)
        data[base + 3] = UInt8(value & 0xFF)
    }

    private func writeUInt64BE(_ data: inout Data, offset: Int, value: UInt64) {
        let base = data.startIndex + offset
        for i in 0..<8 {
            let shift = UInt64((7 - i) * 8)
            data[base + i] = UInt8((value >> shift) & 0xFF)
        }
    }
}
