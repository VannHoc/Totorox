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
    public let resourceVersion: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        fileSize: Int64,
        heroID: Int?,
        skinID: Int?,
        resourceVersion: String?
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileSize = fileSize
        self.heroID = heroID
        self.skinID = skinID
        self.resourceVersion = resourceVersion
    }

    public var heroBadgeText: String {
        if let h = heroID, let s = skinID {
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
        }
    }
}

// MARK: - Main Smart Merger Engine

public final class AovModMergerEngine: @unchecked Sendable {
    public static let shared = AovModMergerEngine()

    private init() {}

    // MARK: - Quick Inspection when user picks a ZIP file

    public func inspectModArchive(at url: URL) throws -> AovModSummary {
        let hasSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurity { url.stopAccessingSecurityScopedResource() }
        }

        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let centralEntries = try readZipCentralDirectory(handle: handle, archiveSize: UInt64(max(0, fileSize)))
        var detectedHeroID: Int? = nil
        var detectedSkinID: Int? = nil
        var detectedVersion: String? = nil

        for entry in centralEntries where !entry.isDirectory {
            guard let norm = normalizeAovRelativePath(entry.name) else { continue }
            if detectedVersion == nil {
                let parts = norm.split(separator: "/")
                if parts.count >= 2 && parts[0] == "Resources" {
                    detectedVersion = String(parts[1])
                }
            }
            if detectedHeroID == nil, let hid = extractHeroIDFromPath(norm) {
                detectedHeroID = hid
            }
            if norm.hasSuffix("Thanos/HeroSkin_1.bytes"),
               let rawBytes = try? extractSingleEntryData(handle: handle, entry: entry),
               let dec = try? jgDecrypt(rawBytes, stem: "HeroSkin_1"),
               let info = extractHeroAndSkinFromHeroSkin1(dec) {
                detectedHeroID = info.heroID
                detectedSkinID = info.skinID
            }
        }

        return AovModSummary(
            url: url,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            heroID: detectedHeroID,
            skinID: detectedSkinID,
            resourceVersion: detectedVersion
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

            // 1. Extract and index all input mod archives
            struct LoadedMod {
                let summary: AovModSummary
                let extractRoot: URL
                let filesByRelPath: [String: URL]
                let heroID: Int?
                let skinID: Int?
                let bcastID: Int?
                let pbtnID: Int?
                let version: String
            }

            var loadedMods: [LoadedMod] = []
            for (idx, url) in inputURLs.enumerated() {
                let stepBase = Double(idx) / Double(inputURLs.count) * 0.35
                progress("Đang đọc & giải nén gói mod (\(idx + 1)/\(inputURLs.count)): \(url.lastPathComponent)...", stepBase)

                let hasSecurity = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurity { url.stopAccessingSecurityScopedResource() }
                }

                let modRawDir = workDir.appendingPathComponent("mod_\(idx)", isDirectory: true)
                try fm.createDirectory(at: modRawDir, withIntermediateDirectories: true)

                do {
                    _ = try ZIPArchiveExtractor.extractFlatContents(archiveURL: url, into: modRawDir, fileManager: fm)
                } catch {
                    let archiveData = try Data(contentsOf: url)
                    let parsed = try PatchZipConverter.shared.parseZipArchive(archiveData)
                    for (relPath, data) in parsed {
                        guard let norm = self.normalizeAovRelativePath(relPath) else { continue }
                        let dest = modRawDir.appendingPathComponent(norm)
                        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: dest)
                    }
                }

                var map: [String: URL] = [:]
                var detectedVersion: String? = nil
                var detectedHeroID: Int? = nil

                if let enumerator = fm.enumerator(
                    at: modRawDir,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let fileURL as URL in enumerator {
                        let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                        guard vals?.isRegularFile == true, vals?.isDirectory != true else { continue }
                        let relRaw = fileURL.path.replacingOccurrences(of: modRawDir.path, with: "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
                        guard let norm = self.normalizeAovRelativePath(relRaw) else { continue }
                        map[norm] = fileURL
                        if detectedVersion == nil {
                            let parts = norm.split(separator: "/")
                            if parts.count >= 2 && parts[0] == "Resources" {
                                detectedVersion = String(parts[1])
                            }
                        }
                        if detectedHeroID == nil, let hid = self.extractHeroIDFromPath(norm) {
                            detectedHeroID = hid
                        }
                    }
                }

                guard !map.isEmpty, let ver = detectedVersion else {
                    throw AovModMergerError.missingResourceStructure(url.lastPathComponent)
                }

                var skinID: Int? = nil
                var bcastID: Int? = nil
                var pbtnID: Int? = nil

                if let hs1URL = map["Resources/\(ver)/Thanos/HeroSkin_1.bytes"],
                   let raw1 = try? Data(contentsOf: hs1URL),
                   let dec1 = try? self.jgDecrypt(raw1, stem: "HeroSkin_1"),
                   let info1 = self.extractHeroAndSkinFromHeroSkin1(dec1) {
                    detectedHeroID = info1.heroID
                    skinID = info1.skinID
                }

                if let hs2URL = map["Resources/\(ver)/Thanos/HeroSkin_2.bytes"],
                   let raw2 = try? Data(contentsOf: hs2URL),
                   let dec2 = try? self.jgDecrypt(raw2, stem: "HeroSkin_2"),
                   let info2 = self.extractParamsFromHeroSkin2(dec2) {
                    if detectedHeroID == nil { detectedHeroID = info2.heroID }
                    bcastID = info2.bcastID
                    pbtnID = info2.pbtnID
                }

                let fsize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let summary = AovModSummary(
                    url: url,
                    fileName: url.lastPathComponent,
                    fileSize: fsize,
                    heroID: detectedHeroID,
                    skinID: skinID,
                    resourceVersion: ver
                )
                loadedMods.append(LoadedMod(
                    summary: summary,
                    extractRoot: modRawDir,
                    filesByRelPath: map,
                    heroID: detectedHeroID,
                    skinID: skinID,
                    bcastID: bcastID,
                    pbtnID: pbtnID,
                    version: ver
                ))
                appendLog("Đã nạp \(url.lastPathComponent): Hero=\(detectedHeroID.map(String.init) ?? "?"), Skin=\(skinID.map(String.init) ?? "?"), Version=\(ver), Files=\(map.count)")
            }

            let targetVersion = loadedMods[0].version
            let outputStagingRoot = workDir.appendingPathComponent("merged_root", isDirectory: true)
            try fm.createDirectory(at: outputStagingRoot, withIntermediateDirectories: true)

            // Collect union of all normalized relative paths (harmonizing version folder if needed)
            var allPathsSet = Set<String>()
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
                    remapped[canonicalPath] = fileURL
                    allPathsSet.insert(canonicalPath)
                }
                remappedModFiles.append(remapped)
            }

            let sortedPaths = allPathsSet.sorted()
            var totalWritten = 0
            var smartMergedCount = 0

            // Track merged KernelLua & StableSystems_3 MD5 hashes so Thanos/HeroSkin_1..2 can be updated
            var mergedPkgMD5s: [String: String] = [:]

            // Separate Thanos/HeroSkin_*.bytes to process last (after KernelLua & StableSystems_3 MD5s are computed)
            let nonThanosPaths = sortedPaths.filter { !$0.contains("/Thanos/HeroSkin_") }
            let thanosPaths = sortedPaths.filter { $0.contains("/Thanos/HeroSkin_") }

            for (pIdx, relPath) in nonThanosPaths.enumerated() {
                if pIdx % 12 == 0 {
                    let ratio = 0.35 + (Double(pIdx) / Double(max(1, sortedPaths.count))) * 0.50
                    let shortName = (relPath as NSString).lastPathComponent
                    progress("Đang hợp nhất: \(shortName)...", ratio)
                }

                // Collect mods that have this file
                var contributors: [(modIndex: Int, mod: LoadedMod, url: URL)] = []
                for (mIdx, mod) in loadedMods.enumerated() {
                    if let u = remappedModFiles[mIdx][relPath] {
                        contributors.append((mIdx, mod, u))
                    }
                }
                guard let first = contributors.first else { continue }

                let destURL = outputStagingRoot.appendingPathComponent(relPath)
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                if contributors.count == 1 {
                    try fm.copyItem(at: first.url, to: destURL)
                    totalWritten += 1
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
                    if relPath.hasSuffix("/KernelLua.pkg.bytes") {
                        mergedPkgMD5s["KernelLua.pkg.bytes"] = self.md5Hex(firstData)
                    } else if relPath.hasSuffix("/StableSystems_3.pkg.bytes") {
                        mergedPkgMD5s["StableSystems_3.pkg.bytes"] = self.md5Hex(firstData)
                    }
                    continue
                }

                // Smart Binary Merge based on file type!
                let mergedData: Data
                if relPath.hasSuffix("resourcepackerinfosetall.assetbundle") {
                    mergedData = try self.mergeResourcePackerAssetBundle(otherDatas.map(\.data))
                    smartMergedCount += 1
                    appendLog("Gộp thông minh UnityFS LZ4: \(relPath) (\(mergedData.count) bytes)")
                } else if relPath.hasSuffix("CommonActions.pkg.bytes") {
                    let inputs = otherDatas.map { (heroID: $0.mod.heroID, data: $0.data) }
                    mergedData = try self.mergeCommonActionsPkg(inputs: inputs, logs: &logs)
                    smartMergedCount += 1
                    appendLog("Gộp thông minh XML Zstd: \(relPath) (\(mergedData.count) bytes)")
                } else if relPath.hasSuffix(".pkg.bytes") {
                    mergedData = try self.mergeGenericPkgZipPreferModified(otherDatas.map(\.data))
                    smartMergedCount += 1
                    let fileName = (relPath as NSString).lastPathComponent
                    mergedPkgMD5s[fileName] = self.md5Hex(mergedData)
                    appendLog("Gộp gói ZIP \(fileName): MD5=\(mergedPkgMD5s[fileName] ?? "")")
                } else if relPath.contains("/Databin/") && relPath.hasSuffix(".bytes") {
                    let stem = ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension
                    let inputs = otherDatas.map { (heroID: $0.mod.heroID, data: $0.data) }
                    mergedData = try self.mergeDatabinMsesFile(stem: stem, inputs: inputs)
                    smartMergedCount += 1
                    appendLog("Gộp bảng Databin MSES: \(stem).bytes")
                } else {
                    // Default fallback for unknown colliding file: take latest mod's version
                    mergedData = otherDatas.last!.data
                }

                try mergedData.write(to: destURL)
                totalWritten += 1
            }

            // Now process Thanos/HeroSkin_1.bytes & HeroSkin_2.bytes
            progress("Đang hợp nhất bytecode Thanos IFix & cập nhật MD5...", 0.88)
            for relPath in thanosPaths {
                var contributors: [(mod: LoadedMod, data: Data)] = []
                for (mIdx, mod) in loadedMods.enumerated() {
                    if let u = remappedModFiles[mIdx][relPath],
                       let d = try? Data(contentsOf: u) {
                        contributors.append((mod, d))
                    }
                }
                guard let first = contributors.first else { continue }
                let destURL = outputStagingRoot.appendingPathComponent(relPath)
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let fileName = (relPath as NSString).lastPathComponent
                let stem = (fileName as NSString).deletingPathExtension

                if stem == "HeroSkin_1" {
                    let merged = try self.mergeThanosHeroSkin1(
                        contributors: contributors.map { (heroID: $0.mod.heroID, skinID: $0.mod.skinID, encrypted: $0.data) },
                        pkgMD5s: mergedPkgMD5s
                    )
                    try merged.write(to: destURL)
                    totalWritten += 1
                    smartMergedCount += 1
                    appendLog("Gộp IFix Bytecode: Thanos/HeroSkin_1.bytes (\(contributors.count) tướng)")
                } else if stem == "HeroSkin_2" {
                    let merged = try self.mergeThanosHeroSkin2(
                        contributors: contributors.map {
                            (heroID: $0.mod.heroID, bcastID: $0.mod.bcastID, pbtnID: $0.mod.pbtnID, encrypted: $0.data)
                        },
                        pkgMD5s: mergedPkgMD5s
                    )
                    try merged.write(to: destURL)
                    totalWritten += 1
                    smartMergedCount += 1
                    appendLog("Gộp IFix Bytecode: Thanos/HeroSkin_2.bytes (\(contributors.count) tướng)")
                } else {
                    try contributors.last!.data.write(to: destURL)
                    totalWritten += 1
                }
            }

            // Package output .zip with Resources/<version>/... at root
            progress("Đang đóng gói tệp .zip đầu ra...", 0.94)
            let resourcesFolderURL = outputStagingRoot.appendingPathComponent("Resources", isDirectory: true)
            guard fm.fileExists(atPath: resourcesFolderURL.path) else {
                throw AovModMergerError.zipCreationFailed("Không tìm thấy thư mục Resources sau khi hợp nhất.")
            }

            let heroTags = loadedMods.compactMap { $0.heroID.map(String.init) }.joined(separator: "_")
            let suffix = heroTags.isEmpty ? "\(loadedMods.count)Mods" : "Hero_\(heroTags)"
            let outDir = fm.temporaryDirectory.appendingPathComponent("TotoroxMergedMods", isDirectory: true)
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            let outZipName = "GopMod_AOV_\(suffix).zip"
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

    public func normalizeAovRelativePath(_ rawPath: String) -> String? {
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

        return nil
    }

    private func extractHeroIDFromPath(_ normPath: String) -> Int? {
        let fileName = (normPath as NSString).lastPathComponent
        // Pattern 1: Actor_131_Actions.pkg.bytes or Actor_131_Infos.pkg.bytes
        if fileName.hasPrefix("Actor_") {
            let parts = fileName.split(separator: "_")
            if parts.count >= 2, let hid = Int(parts[1]), hid >= 100 && hid <= 999 {
                return hid
            }
        }
        // Pattern 2: 131_AssetRef.bytes
        if fileName.hasSuffix("_AssetRef.bytes") {
            let prefix = fileName.replacingOccurrences(of: "_AssetRef.bytes", with: "")
            if let hid = Int(prefix), hid >= 100 && hid <= 999 {
                return hid
            }
        }
        return nil
    }

    // MARK: - Format 1: UnityFS v8 LZ4 AssetBundle Merger (`resourcepackerinfosetall.assetbundle`)

    private func mergeResourcePackerAssetBundle(_ bundles: [Data]) throws -> Data {
        guard let baseBundle = bundles.first, baseBundle.count > 133 else {
            throw AovModMergerError.assetBundleMergeFailed("Dữ liệu AssetBundle rỗng hoặc quá ngắn.")
        }

        struct UnpackedUnityFS {
            let sizeFieldOffset: Int
            let headerEnd: Int
            let header: Data
            let tailInfo: Data
            let uncompressedSize: Int
            let payload: [UInt8]
        }

        func unpackUnityFS(_ data: Data) throws -> UnpackedUnityFS {
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

            let compInfoSize = Int(readUInt32BE(data, pos + 8))
            let uncompInfoSize = Int(readUInt32BE(data, pos + 12))
            let headerEnd = ((pos + 20) + 15) & ~15

            guard compInfoSize > 0, compInfoSize < data.count - headerEnd, uncompInfoSize >= 32 else {
                throw AovModMergerError.assetBundleMergeFailed("Kích thước BlocksInfo không hợp lệ (comp=\(compInfoSize), uncomp=\(uncompInfoSize)).")
            }

            let tailInfo = data.subdata(in: (data.count - compInfoSize)..<data.count)
            let infoRaw = try lz4DecompressBlock(tailInfo, uncompressedSize: uncompInfoSize)
            let u28 = Int(readUInt32BE(infoRaw, 28))
            let u20 = Int(readUInt32BE(infoRaw, 20))
            let uncompBlockSize = (u28 > 0 && u28 < 50_000_000) ? u28 : u20

            guard uncompBlockSize > 0 && uncompBlockSize < 50_000_000 else {
                throw AovModMergerError.assetBundleMergeFailed("Kích thước payload giải nén không hợp lệ: \(uncompBlockSize)")
            }

            let compBlockData = data.subdata(in: headerEnd..<(data.count - compInfoSize))
            let payloadData = try lz4DecompressBlock(compBlockData, uncompressedSize: uncompBlockSize)
            return UnpackedUnityFS(
                sizeFieldOffset: pos,
                headerEnd: headerEnd,
                header: data.subdata(in: 0..<headerEnd),
                tailInfo: tailInfo,
                uncompressedSize: uncompBlockSize,
                payload: [UInt8](payloadData)
            )
        }

        let baseUnpacked = try unpackUnityFS(baseBundle)
        var mergedBytes = baseUnpacked.payload
        let baseBytes = baseUnpacked.payload
        let kianaMarker: [UInt8] = [0x4B, 0x69, 0x61, 0x6E, 0x61, 0x4D, 0x6F, 0x64] // "KianaMod"

        for otherBundle in bundles.dropFirst() {
            let otherUnpacked = try unpackUnityFS(otherBundle)
            let otherBytes = otherUnpacked.payload
            let limit = min(mergedBytes.count, otherBytes.count)

            // 1. Copy every KianaMod 12-byte hash slot from otherBytes
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

            // 2. Copy any other modified byte range where baseBytes wasn't the one with KianaMod
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

        // Re-compress mergedBytes using Apple's COMPRESSION_LZ4_RAW
        let mergedData = Data(mergedBytes)
        let compressedPayload = try lz4CompressBlock(mergedData)
        let newCompSize = UInt32(compressedPayload.count)

        var newHeader = baseUnpacked.header
        var newTailInfo = baseUnpacked.tailInfo
        let sizeFieldPos = baseUnpacked.sizeFieldOffset

        if newTailInfo.count == 69 && newCompSize < 0x0100_0000 {
            // Direct 4-byte big-endian compressedBlockSize update inside the 69-byte BlocksInfo literal run
            writeUInt32BE(&newTailInfo, offset: 10, value: newCompSize)
        } else {
            // Fallback: decompress 93-byte BlocksInfo, update offset 24..28, wrap in LZ4 literal block (0xF0, len-15)
            let uncompInfoSize = Int(readUInt32BE(newHeader, sizeFieldPos + 12))
            var infoRaw = try lz4DecompressBlock(newTailInfo, uncompressedSize: uncompInfoSize)
            writeUInt32BE(&infoRaw, offset: 24, value: newCompSize)
            if infoRaw.count >= 15 && infoRaw.count < 270 {
                var litBlock = Data([0xF0, UInt8(infoRaw.count - 15)])
                litBlock.append(infoRaw)
                newTailInfo = litBlock
                writeUInt32BE(&newHeader, offset: sizeFieldPos + 8, value: UInt32(newTailInfo.count))
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

    private func mergeGenericPkgZipPreferModified(_ archives: [Data]) throws -> Data {
        guard let first = archives.first else { return Data() }
        var baseEntries = try parseInMemoryZip(first)
        var indexByName: [String: Int] = [:]
        for (i, e) in baseEntries.enumerated() {
            indexByName[e.name] = i
        }

        for otherArchive in archives.dropFirst() {
            let otherEntries = try parseInMemoryZip(otherArchive)
            for oe in otherEntries {
                let isOtherModified = !(oe.modifiedDate == 0x0021 && oe.modifiedTime == 0x0000)
                if let existingIdx = indexByName[oe.name] {
                    let existing = baseEntries[existingIdx]
                    let isExistingModified = !(existing.modifiedDate == 0x0021 && existing.modifiedTime == 0x0000)
                    if isOtherModified && (!isExistingModified || oe.data != existing.data) {
                        baseEntries[existingIdx] = oe
                    }
                } else {
                    indexByName[oe.name] = baseEntries.count
                    baseEntries.append(oe)
                }
            }
        }

        return buildInMemoryStoreZip(baseEntries)
    }

    // MARK: - Format 2B: `CommonActions.pkg.bytes` XML + Zstd Dict Merger

    private func mergeCommonActionsPkg(
        inputs: [(heroID: Int?, data: Data)],
        logs: inout [String]
    ) throws -> Data {
        guard let first = inputs.first else { return Data() }
        var mergedEntries = try parseInMemoryZip(first.data)
        var indexByName: [String: Int] = [:]
        for (idx, entry) in mergedEntries.enumerated() {
            indexByName[entry.name] = idx
        }

        for other in inputs.dropFirst() {
            let otherEntries = try parseInMemoryZip(other.data)
            let heroPrefix = other.heroID.map(String.init)

            for oe in otherEntries {
                guard let existingIdx = indexByName[oe.name] else {
                    indexByName[oe.name] = mergedEntries.count
                    mergedEntries.append(oe)
                    continue
                }

                let existing = mergedEntries[existingIdx]
                if existing.data == oe.data {
                    continue
                }

                let xmlData1 = try decodeAovXmlEntryIfNeeded(existing.data)
                let xmlData2 = try decodeAovXmlEntryIfNeeded(oe.data)

                if xmlData1 == xmlData2 {
                    continue
                }

                guard let xmlStr1 = String(data: xmlData1, encoding: .utf8),
                      let xmlStr2 = String(data: xmlData2, encoding: .utf8) else {
                    continue
                }

                let mergedXmlStr = mergeAovActionXmlTracks(
                    baseXml: xmlStr1,
                    incomingXml: xmlStr2,
                    incomingHeroPrefix: heroPrefix
                )

                if let mergedXmlBytes = mergedXmlStr.data(using: .utf8) {
                    mergedEntries[existingIdx] = InMemoryZipEntry(
                        name: existing.name,
                        modifiedTime: oe.modifiedTime != 0 ? oe.modifiedTime : existing.modifiedTime,
                        modifiedDate: oe.modifiedDate != 0x0021 ? oe.modifiedDate : existing.modifiedDate,
                        data: mergedXmlBytes
                    )
                    logs.append("  + Đã gộp Track XML: \(existing.name) (Hero \(heroPrefix ?? "?"))")
                }
            }
        }

        return buildInMemoryStoreZip(mergedEntries)
    }

    public func decodeAovXmlEntryIfNeeded(_ raw: Data) throws -> Data {
        // Check for 22 4A 00 EF or 22 4A 67 EF header (4B magic + 4B uint32_le uncompressed size + Zstd frame)
        guard raw.count > 12 else { return raw }
        let b0 = raw[raw.startIndex]
        let b1 = raw[raw.startIndex + 1]
        let b2 = raw[raw.startIndex + 2]
        let b3 = raw[raw.startIndex + 3]

        if b0 == 0x22 && b1 == 0x4A && (b2 == 0x00 || b2 == 0x67) && b3 == 0xEF {
            let uncompSize = Int(readUInt32LE(raw, 4))
            let capacity = max(uncompSize + 1024, raw.count * 12, 65_536)
            var dst = Data(count: capacity)
            let zstdFrame = raw.subdata(in: 8..<raw.count)

            let decompressedBytes: Int64 = zstdFrame.withUnsafeBytes { srcBuf in
                dst.withUnsafeMutableBytes { dstBuf in
                    guard let srcPtr = srcBuf.bindMemory(to: UInt8.self).baseAddress,
                          let dstPtr = dstBuf.bindMemory(to: UInt8.self).baseAddress else {
                        return -1
                    }
                    return aov_zstd_decompress_dict(srcPtr, zstdFrame.count, dstPtr, capacity)
                }
            }

            if decompressedBytes > 0 {
                dst.count = Int(decompressedBytes)
                return dst
            }
        }
        return raw
    }

    private func mergeAovActionXmlTracks(
        baseXml: String,
        incomingXml: String,
        incomingHeroPrefix: String?
    ) -> String {
        struct ParsedTrack {
            let guid: String
            let skel: String
            let skins: [String]
            let rawText: String
        }

        func extractSkinIds(from trackText: String) -> [String] {
            var ids: [String] = []
            var searchStart = trackText.startIndex
            while let idStart = trackText.range(of: "<SkinOrAvatarList id=\"", range: searchStart..<trackText.endIndex),
                  let idEnd = trackText.range(of: "\"", range: idStart.upperBound..<trackText.endIndex) {
                let idVal = String(trackText[idStart.upperBound..<idEnd.lowerBound])
                ids.append(idVal)
                searchStart = idEnd.upperBound
            }
            return ids
        }

        func trackSkeleton(from trackText: String) -> String {
            var result = ""
            result.reserveCapacity(trackText.count)
            var searchStart = trackText.startIndex
            while let tagStart = trackText.range(of: "<SkinOrAvatarList", range: searchStart..<trackText.endIndex),
                  let tagEnd = trackText.range(of: "/>", range: tagStart.lowerBound..<trackText.endIndex) {
                result.append(contentsOf: trackText[searchStart..<tagStart.lowerBound])
                searchStart = tagEnd.upperBound
            }
            result.append(contentsOf: trackText[searchStart..<trackText.endIndex])
            return result.filter { !$0.isWhitespace }
        }

        func replaceSkinTags(in trackText: String, with newIds: [String]) -> String {
            guard !newIds.isEmpty else { return trackText }
            let newSkinsBlock = newIds.map { "<SkinOrAvatarList id=\"\($0)\" />" }.joined()
            var result = ""
            result.reserveCapacity(trackText.count)
            var searchStart = trackText.startIndex
            var inserted = false
            while let tagStart = trackText.range(of: "<SkinOrAvatarList", range: searchStart..<trackText.endIndex),
                  let tagEnd = trackText.range(of: "/>", range: tagStart.lowerBound..<trackText.endIndex) {
                if !inserted {
                    result.append(contentsOf: trackText[searchStart..<tagStart.lowerBound])
                    result.append(newSkinsBlock)
                    inserted = true
                } else {
                    let between = trackText[searchStart..<tagStart.lowerBound]
                    if !between.allSatisfy({ $0.isWhitespace }) {
                        result.append(contentsOf: between)
                    }
                }
                searchStart = tagEnd.upperBound
            }
            result.append(contentsOf: trackText[searchStart..<trackText.endIndex])
            return result
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
                var guid = ""
                if let gStart = rawTrack.range(of: "guid=\""),
                   let gEnd = rawTrack.range(of: "\"", range: gStart.upperBound..<rawTrack.endIndex) {
                    guid = String(rawTrack[gStart.upperBound..<gEnd.lowerBound])
                }
                let skins = extractSkinIds(from: rawTrack)
                let skel = trackSkeleton(from: rawTrack)
                tracks.append(ParsedTrack(guid: guid, skel: skel, skins: skins, rawText: rawTrack))
                searchStart = closeRange.upperBound
            }
            return (header, tracks, footer)
        }

        guard let baseParsed = splitXmlIntoTracks(baseXml),
              let incParsed = splitXmlIntoTracks(incomingXml) else {
            return baseXml
        }

        var incBySkel: [String: ParsedTrack] = [:]
        for t in incParsed.tracks where incBySkel[t.skel] == nil {
            incBySkel[t.skel] = t
        }
        let baseSkels = Set(baseParsed.tracks.map(\.skel))

        var outRawTracks: [String] = []
        for bt in baseParsed.tracks {
            if let it = incBySkel[bt.skel] {
                if bt.skins == it.skins {
                    outRawTracks.append(bt.rawText)
                } else if let hp = incomingHeroPrefix, !hp.isEmpty {
                    var mergedSkins = bt.skins.filter { !$0.hasPrefix(hp) }
                    mergedSkins.append(contentsOf: it.skins.filter { $0.hasPrefix(hp) })
                    if !mergedSkins.isEmpty || bt.skins.isEmpty {
                        outRawTracks.append(replaceSkinTags(in: bt.rawText, with: mergedSkins))
                    }
                } else {
                    var seen = Set(bt.skins)
                    var mergedSkins = bt.skins
                    for s in it.skins where !seen.contains(s) {
                        seen.insert(s)
                        mergedSkins.append(s)
                    }
                    outRawTracks.append(replaceSkinTags(in: bt.rawText, with: mergedSkins))
                }
            } else {
                // Track exists in base but was removed or replaced in incoming
                if let hp = incomingHeroPrefix, !hp.isEmpty, bt.skins.contains(where: { $0.hasPrefix(hp) }) {
                    let remainingSkins = bt.skins.filter { !$0.hasPrefix(hp) }
                    if !remainingSkins.isEmpty {
                        outRawTracks.append(replaceSkinTags(in: bt.rawText, with: remainingSkins))
                    }
                } else {
                    outRawTracks.append(bt.rawText)
                }
            }
        }

        // Append tracks from incoming that are not in base
        for it in incParsed.tracks where !baseSkels.contains(it.skel) {
            if let hp = incomingHeroPrefix, !hp.isEmpty {
                let heroSkins = it.skins.filter { $0.hasPrefix(hp) }
                if !heroSkins.isEmpty {
                    if heroSkins.count == it.skins.count {
                        outRawTracks.append(it.rawText)
                    } else {
                        outRawTracks.append(replaceSkinTags(in: it.rawText, with: heroSkins))
                    }
                } else if it.guid.hasPrefix(hp) || it.rawText.contains("\(hp)_") {
                    outRawTracks.append(it.rawText)
                }
            } else {
                outRawTracks.append(it.rawText)
            }
        }

        let joinedTracks = outRawTracks.joined(separator: "\n    ")
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

    public func jgDecrypt(_ data: Data, stem: String) throws -> Data {
        guard data.count > 8 else {
            throw AovModMergerError.cryptoFailed("Dữ liệu quá ngắn (\(stem))")
        }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]

        // Check 22 4A 67 00 magic
        guard b0 == 0x22 && b1 == 0x4A && b2 == 0x67 && b3 == 0x00 else {
            return data
        }

        let expectedLen = Int(readUInt32LE(data, 4))
        let cipherData = data.subdata(in: 8..<data.count)
        let key = deriveJgKey(stem: stem)
        var iv = [UInt8](repeating: 0, count: 16)
        let outCapacity = cipherData.count + kCCBlockSizeAES128
        var outBuffer = Data(count: outCapacity)
        var numBytesDecrypted: size_t = 0

        let status = cipherData.withUnsafeBytes { cipherBytes in
            outBuffer.withUnsafeMutableBytes { outBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionPKCS7Padding),
                    key,
                    kCCKeySizeAES128,
                    &iv,
                    cipherBytes.baseAddress,
                    cipherData.count,
                    outBytes.baseAddress,
                    outCapacity,
                    &numBytesDecrypted
                )
            }
        }

        guard status == kCCSuccess else {
            throw AovModMergerError.cryptoFailed("CCCrypt decrypt thất bại (\(stem), status=\(status))")
        }
        outBuffer.count = min(Int(numBytesDecrypted), expectedLen > 0 ? expectedLen : Int(numBytesDecrypted))
        return outBuffer
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
        let cutVer: UInt32
        let rawBytes: Data
    }

    private struct MsesTable {
        var header: Data // 136 bytes
        var maxRecordSize: UInt32
        var records: [MsesRecord]
        var footer: Data // 4 bytes
    }

    private func parseMsesTable(_ data: Data, stem: String) throws -> MsesTable {
        guard data.count >= 140,
              String(data: data.subdata(in: 0..<4), encoding: .ascii) == "MSES" else {
            throw AovModMergerError.msesParseFailed("Không phải bảng MSES hợp lệ (\(stem))")
        }
        let maxRecSize = readUInt32LE(data, 8)
        let count = Int(readUInt32LE(data, 12))
        let header = data.subdata(in: 0..<136)

        var pos = 136
        var records: [MsesRecord] = []
        records.reserveCapacity(count)

        for _ in 0..<count {
            guard pos + 12 <= data.count else {
                throw AovModMergerError.msesParseFailed("Bảng MSES bị cắt cụt tại offset \(pos) (\(stem))")
            }
            let cutVer = readUInt32LE(data, pos)
            let rlen = Int(readUInt32LE(data, pos + 4))
            let rid = readUInt32LE(data, pos + 8)
            let totalLen = 4 + rlen
            guard rlen >= 4, pos + totalLen <= data.count else {
                throw AovModMergerError.msesParseFailed("Độ dài bản ghi MSES không hợp lệ (\(stem), rlen=\(rlen))")
            }
            let raw = data.subdata(in: pos..<(pos + totalLen))
            records.append(MsesRecord(rid: rid, cutVer: cutVer, rawBytes: raw))
            pos += totalLen
        }

        let footer = pos < data.count ? data.subdata(in: pos..<data.count) : Data([0, 0, 0, 0])
        return MsesTable(header: header, maxRecordSize: maxRecSize, records: records, footer: footer)
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

        let totalBytes = 136 + table.records.reduce(0) { $0 + $1.rawBytes.count } + table.footer.count
        var out = Data(capacity: totalBytes)
        out.append(header)
        for r in table.records {
            out.append(r.rawBytes)
        }
        out.append(table.footer)
        return out
    }

    private func mergeDatabinMsesFile(
        stem: String,
        inputs: [(heroID: Int?, data: Data)]
    ) throws -> Data {
        guard let first = inputs.first else { return Data() }

        let decryptedInputs: [(heroID: Int?, plain: Data)] = try inputs.map {
            (heroID: $0.heroID, plain: try jgDecrypt($0.data, stem: stem))
        }

        // Special handling for HeadImage.bytes: if one mod customized avatar frames (larger size), pick it
        if stem.lowercased() == "headimage" {
            let best = decryptedInputs.max(by: { $0.plain.count < $1.plain.count })!.plain
            return try jgEncrypt(best, stem: stem)
        }

        var mergedTable = try parseMsesTable(decryptedInputs[0].plain, stem: stem)
        let isComponentTable = stem.lowercased() == "rescharactercomponent"

        for other in decryptedInputs.dropFirst() {
            let otherTable = try parseMsesTable(other.plain, stem: stem)
            if otherTable.maxRecordSize > mergedTable.maxRecordSize {
                mergedTable.maxRecordSize = otherTable.maxRecordSize
            }
            let heroPrefix = other.heroID.map(String.init)

            if isComponentTable, let hp = heroPrefix, !hp.isEmpty {
                // In ResCharacterComponent.bytes, mods often remove component rows for their heroID
                // Replace all rows starting with `hp` with otherTable's rows starting with `hp`
                let incomingHeroRecords = otherTable.records.filter { String($0.rid).hasPrefix(hp) }
                var newRecords: [MsesRecord] = []
                var insertedIncoming = false
                for rec in mergedTable.records {
                    if String(rec.rid).hasPrefix(hp) {
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
                continue
            }

            // General MSES record-level merge
            var indexByRid: [UInt32: Int] = [:]
            for (idx, r) in mergedTable.records.enumerated() {
                indexByRid[r.rid] = idx
            }

            for oRec in otherTable.records {
                let ridStr = String(oRec.rid)
                let matchesHero = (heroPrefix != nil && ridStr.hasPrefix(heroPrefix!))

                if let existingIdx = indexByRid[oRec.rid] {
                    let existing = mergedTable.records[existingIdx]
                    if existing.rawBytes != oRec.rawBytes {
                        // Prefer incoming record if it belongs to incoming mod's heroID OR has non-zero cutVer over zero cutVer
                        if matchesHero || (oRec.cutVer > existing.cutVer) {
                            mergedTable.records[existingIdx] = oRec
                        }
                    }
                } else {
                    // Record only exists in otherTable (e.g. new skin label row in ResSkinSeniorLabelCfg)
                    indexByRid[oRec.rid] = mergedTable.records.count
                    mergedTable.records.append(oRec)
                }
            }
        }

        let mergedPlain = serializeMsesTable(mergedTable)
        return try jgEncrypt(mergedPlain, stem: stem)
    }

    // MARK: - Format 4: `Thanos/HeroSkin_1.bytes` & `HeroSkin_2.bytes` IFix Bytecode + MD5 Merger

    private func extractHeroAndSkinFromHeroSkin1(_ dec: Data) -> (heroID: Int, skinID: Int)? {
        if dec.count >= 34652 {
            let hid = Int(readUInt32LE(dec, 33560))
            let sid = Int(readUInt32LE(dec, 34608))
            if hid >= 100 && hid <= 999 && sid >= 10000 && sid <= 999999 {
                return (hid, sid)
            }
        }
        // Dynamic pattern fallback: Ldarg(1), Ldfld(80), Ldc_I4(heroID)
        let patternA = Data([
            0xA4, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0xA7, 0x00, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00,
            0x8F, 0x00, 0x00, 0x00
        ])
        if let rangeA = dec.range(of: patternA), rangeA.upperBound + 4 <= dec.count {
            let hid = Int(readUInt32LE(dec, rangeA.upperBound - dec.startIndex))
            // Search after rangeA for Ceq; Brfalse(3); Ldc_I4(skinID); Ret(1)
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
                if candidate >= 10000 && candidate <= 999999 {
                    foundSkinID = candidate
                    break
                }
                searchPos = rangeC.upperBound
            }
            if hid >= 100 && hid <= 999, let sid = foundSkinID {
                return (hid, sid)
            }
        }
        return nil
    }

    private func extractParamsFromHeroSkin2(_ dec: Data) -> (heroID: Int, bcastID: Int, pbtnID: Int)? {
        if dec.count >= 1773 {
            let hid = Int(readUInt32LE(dec, 1689))
            let bcast = Int(readUInt32LE(dec, 1721))
            let pbtn = Int(readUInt32LE(dec, 1745))
            if hid >= 100 && hid <= 999 {
                return (hid, bcast, pbtn)
            }
        }
        // Dynamic pattern fallback: Ldarg(1), Ldc_I4(heroID), Ceq
        let pattern2 = Data([
            0xA4, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x8F, 0x00, 0x00, 0x00
        ])
        if let range2 = dec.range(of: pattern2), range2.upperBound + 60 <= dec.count {
            let baseOff = range2.lowerBound - dec.startIndex
            let hid = Int(readUInt32LE(dec, baseOff + 12))
            let bcast = Int(readUInt32LE(dec, baseOff + 44))
            let pbtn = Int(readUInt32LE(dec, baseOff + 68))
            if hid >= 100 && hid <= 999 {
                return (hid, bcast, pbtn)
            }
        }
        return nil
    }

    private func ifixInst(_ op: UInt32, _ arg: Int32) -> Data {
        var d = Data(capacity: 8)
        appendUInt32LE(&d, op)
        appendUInt32LE(&d, UInt32(bitPattern: arg))
        return d
    }

    private func mergeThanosHeroSkin1(
        contributors: [(heroID: Int?, skinID: Int?, encrypted: Data)],
        pkgMD5s: [String: String]
    ) throws -> Data {
        guard let first = contributors.first else { return Data() }
        let basePlain = try jgDecrypt(first.encrypted, stem: "HeroSkin_1")
        guard basePlain.count >= 34652 else {
            return first.encrypted
        }

        // Collect unique (heroID, skinID) pairs across all contributors
        var heroSkins: [(heroID: Int, skinID: Int)] = []
        for c in contributors {
            let plain = try jgDecrypt(c.encrypted, stem: "HeroSkin_1")
            if let extracted = extractHeroAndSkinFromHeroSkin1(plain) {
                if !heroSkins.contains(where: { $0.heroID == extracted.heroID }) {
                    heroSkins.append(extracted)
                }
            } else if let h = c.heroID, let s = c.skinID {
                if !heroSkins.contains(where: { $0.heroID == h }) {
                    heroSkins.append((h, s))
                }
            }
        }

        var patched = Data()
        if heroSkins.count <= 1 {
            patched = basePlain
        } else {
            let extraHeroes = Array(heroSkins.dropFirst())

            // Method A: header at 33528 (cnt=10), instructions at 33532..<33612
            // Replace inst[6] at 33580 with Br(+4) -> jumps to [10]
            var methodA = basePlain.subdata(in: 33528..<33612)
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

            // Method B: header at 33616 (cnt=64), instructions at 33620..<34132
            // Replace inst[58] with Br(+6) -> jumps to [64]
            var methodB = basePlain.subdata(in: 33616..<34132)
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

            // Method C: header at 34136 (cnt=64), instructions at 34140..<34652
            // Replace inst[60] with Br(+4) -> jumps to [64]
            var methodC = basePlain.subdata(in: 34136..<34652)
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

            patched.append(basePlain.subdata(in: 0..<33528))
            patched.append(methodA)
            patched.append(basePlain.subdata(in: 33612..<33616))
            patched.append(methodB)
            patched.append(basePlain.subdata(in: 34132..<34136))
            patched.append(methodC)
            patched.append(basePlain.subdata(in: 34652..<basePlain.count))
        }

        updateEmbeddedPkgMD5s(in: &patched, pkgMD5s: pkgMD5s)
        return try jgEncrypt(patched, stem: "HeroSkin_1")
    }

    private func mergeThanosHeroSkin2(
        contributors: [(heroID: Int?, bcastID: Int?, pbtnID: Int?, encrypted: Data)],
        pkgMD5s: [String: String]
    ) throws -> Data {
        guard let first = contributors.first else { return Data() }
        let basePlain = try jgDecrypt(first.encrypted, stem: "HeroSkin_2")
        guard basePlain.count >= 1773 else {
            return first.encrypted
        }

        var heroParams: [(heroID: Int, bcastID: Int, pbtnID: Int)] = []
        for c in contributors {
            let plain = try jgDecrypt(c.encrypted, stem: "HeroSkin_2")
            if let extracted = extractParamsFromHeroSkin2(plain) {
                if !heroParams.contains(where: { $0.heroID == extracted.heroID }) {
                    heroParams.append(extracted)
                }
            }
        }

        var patched = Data()
        if heroParams.count <= 1 {
            patched = basePlain
        } else {
            let extraHeroes = Array(heroParams.dropFirst())
            // Method header at 1209 (cnt=70), instructions at 1213..<1773
            // Change inst[61] Brfalse operand from 8 to 9 (so it jumps over [69] to [70])
            var method = basePlain.subdata(in: 1209..<1773)
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

            patched.append(basePlain.subdata(in: 0..<1209))
            patched.append(method)
            patched.append(basePlain.subdata(in: 1773..<basePlain.count))
        }

        updateEmbeddedPkgMD5s(in: &patched, pkgMD5s: pkgMD5s)
        return try jgEncrypt(patched, stem: "HeroSkin_2")
    }

    private func updateEmbeddedPkgMD5s(in data: inout Data, pkgMD5s: [String: String]) {
        for (pkgName, md5Hex) in pkgMD5s where md5Hex.utf8.count == 32 {
            let marker = Data((pkgName + " ").utf8)
            let md5Bytes = Data(md5Hex.lowercased().utf8)
            var searchStart = 0
            while searchStart + marker.count + 32 <= data.count,
                  let foundRange = data.range(of: marker, options: [], in: searchStart..<data.count) {
                let hashStart = foundRange.upperBound
                let hashEnd = hashStart + 32
                if hashEnd <= data.count {
                    data.replaceSubrange(hashStart..<hashEnd, with: md5Bytes)
                }
                searchStart = hashEnd
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

        let count = Int(readUInt16LE(archive, eocd + 10))
        var cdPos = Int(readUInt32LE(archive, eocd + 16))
        var entries: [InMemoryZipEntry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            guard cdPos + 46 <= archive.count, readUInt32LE(archive, cdPos) == 0x0201_4B50 else { break }
            let method = readUInt16LE(archive, cdPos + 10)
            let modTime = readUInt16LE(archive, cdPos + 12)
            let modDate = readUInt16LE(archive, cdPos + 14)
            let compSize = Int(readUInt32LE(archive, cdPos + 20))
            let uncompSize = Int(readUInt32LE(archive, cdPos + 24))
            let nameLen = Int(readUInt16LE(archive, cdPos + 28))
            let extraLen = Int(readUInt16LE(archive, cdPos + 30))
            let commentLen = Int(readUInt16LE(archive, cdPos + 32))
            let localOff = Int(readUInt32LE(archive, cdPos + 42))

            let nameData = archive.subdata(in: (cdPos + 46)..<(cdPos + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            cdPos += 46 + nameLen + extraLen + commentLen

            if name.hasSuffix("/") { continue }
            guard localOff + 30 <= archive.count, readUInt32LE(archive, localOff) == 0x0403_4B50 else { continue }
            let lNameLen = Int(readUInt16LE(archive, localOff + 26))
            let lExtraLen = Int(readUInt16LE(archive, localOff + 28))
            let dataStart = localOff + 30 + lNameLen + lExtraLen
            guard dataStart + compSize <= archive.count else { continue }
            let rawSlice = archive.subdata(in: dataStart..<(dataStart + compSize))

            let payload: Data
            if method == 0 {
                payload = rawSlice
            } else if method == 8 {
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

    private func buildInMemoryStoreZip(_ entries: [InMemoryZipEntry]) -> Data {
        struct WrittenMeta {
            let nameData: Data
            let modTime: UInt16
            let modDate: UInt16
            let crc: UInt32
            let size: UInt32
            let localOffset: UInt32
        }

        let approxCapacity = entries.reduce(64) { $0 + $1.data.count + 96 }
        var out = Data(capacity: approxCapacity)
        var metas: [WrittenMeta] = []
        metas.reserveCapacity(entries.count)

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8) else { continue }
            let localOffset = UInt32(out.count)
            let crc = computeCRC32(entry.data)
            let size = UInt32(entry.data.count)

            // Local File Header (30 bytes + name)
            appendUInt32LE(&out, 0x0403_4B50)
            appendUInt16LE(&out, 20)
            appendUInt16LE(&out, 0)
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
            appendUInt16LE(&out, 0)
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
