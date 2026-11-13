import Foundation
import CryptoKit

public enum PatchZipConverterError: Error, LocalizedError, Equatable {
    case corruptedArchive(String)
    case unsupportedFormat(String)
    case invalidManifest(String)
    case missingPayloadFile(String)
    case invalidProject(String)
    case insufficientSpace
    case sizeLimitExceeded
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .corruptedArchive(let msg): return "Corrupted archive: \(msg)"
        case .unsupportedFormat(let msg): return "Unsupported format: \(msg)"
        case .invalidManifest(let msg): return "Invalid manifest: \(msg)"
        case .missingPayloadFile(let msg): return "Missing payload file: \(msg)"
        case .invalidProject(let msg): return "Invalid project: \(msg)"
        case .insufficientSpace: return "Insufficient disk space."
        case .sizeLimitExceeded: return "Archive exceeds the 3.6 GB limit."
        case .ioFailure(let msg): return "I/O error: \(msg)"
        }
    }
}

public struct PatchZipManifest: Codable, Equatable {
    public struct RuleEntry: Codable, Equatable {
        public let id: UUID
        public let bundleID: String
        public let relativePath: String
        public let replacementFilename: String
        public let payloadPath: String
        public let operation: String?
        public let containerKind: String?

        public init(
            id: UUID,
            bundleID: String,
            relativePath: String,
            replacementFilename: String,
            payloadPath: String,
            operation: String? = nil,
            containerKind: String? = nil
        ) {
            self.id = id
            self.bundleID = bundleID
            self.relativePath = relativePath
            self.replacementFilename = replacementFilename
            self.payloadPath = payloadPath
            self.operation = operation
            self.containerKind = containerKind
        }
    }

    public struct DirectoryEntry: Codable, Equatable {
        public let id: UUID
        public let bundleID: String
        public let relativePath: String

        public init(id: UUID, bundleID: String, relativePath: String) {
            self.id = id
            self.bundleID = bundleID
            self.relativePath = relativePath
        }
    }

    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let author: String
    public let isPrivate: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let bundleIdentifiers: [String]
    public let directories: [DirectoryEntry]
    public let rules: [RuleEntry]

    public init(
        schemaVersion: Int = 3,
        id: UUID,
        name: String,
        author: String,
        isPrivate: Bool,
        createdAt: Date,
        updatedAt: Date,
        bundleIdentifiers: [String],
        directories: [DirectoryEntry],
        rules: [RuleEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.author = author
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.bundleIdentifiers = bundleIdentifiers
        self.directories = directories
        self.rules = rules
    }
}

public final class PatchZipConverter {
    public static let shared = PatchZipConverter()
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func convertPatch3105ToZip(inputURL: URL, outputZipURL: URL, password: String? = nil) throws {
        try convertPatchToZip(patchURL: inputURL, destinationZipURL: outputZipURL, password: password)
    }

    public func convertZipToPatch3105(inputZipURL: URL, outputPatchURL: URL, password: String? = nil) throws {
        try convertZipToPatch(zipURL: inputZipURL, destinationPatchURL: outputPatchURL, password: password)
    }

    // MARK: - .3105 -> .zip Conversion

    public func convertPatchToZip(
        patchURL: URL,
        destinationZipURL: URL,
        password: String? = nil
    ) throws {
        guard fileManager.fileExists(atPath: patchURL.path) else {
            throw PatchZipConverterError.ioFailure("Source .3105 patch file not found.")
        }
        let patchFileSize = (try? patchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(patchFileSize)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        let patchData: Data
        do {
            patchData = try Data(contentsOf: patchURL)
        } catch {
            throw PatchZipConverterError.ioFailure("Cannot read .3105 patch: \(error.localizedDescription)")
        }

        let zipData = try convertPatchDataToZipData(patchData, password: password)

        do {
            let parent = destinationZipURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: destinationZipURL.path) {
                try fileManager.removeItem(at: destinationZipURL)
            }
            try zipData.write(to: destinationZipURL, options: .atomic)
        } catch {
            throw PatchZipConverterError.ioFailure("Cannot write output .zip file: \(error.localizedDescription)")
        }
    }

    public func convertPatchDataToZipData(
        _ patchData: Data,
        password: String? = nil
    ) throws -> Data {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(patchData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        if patchData.count >= 4,
           patchData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]),
           (try? parseZipArchive(patchData)) != nil {
            return patchData
        }

        let decoded: DecodedPatchPackage
        do {
            decoded = try PatchPackageCodec.decode(patchData, password: password)
        } catch {
            throw PatchZipConverterError.corruptedArchive("Failed to decode .3105 patch package: \(error.localizedDescription)")
        }

        let project = decoded.project

        // Construct Manifest
        let directoryEntries = project.directories.map {
            PatchZipManifest.DirectoryEntry(id: $0.id, bundleID: $0.bundleID, relativePath: $0.relativePath)
        }

        var ruleEntries: [PatchZipManifest.RuleEntry] = []
        var zipEntries: [(path: String, data: Data)] = []
        var addedPaths = Set<String>()

        for rule in project.rules {
            let cleanBundle = rule.bundleID.isEmpty
                ? (project.bundleIdentifiers.first ?? "com.apple.mobile.MobileHouseArrest")
                : rule.bundleID
            let payloadRelativePath = "payload/\(cleanBundle)/\(rule.relativePath)"
            let filename = rule.replacementFilename.isEmpty
                ? (rule.relativePath as NSString).lastPathComponent
                : rule.replacementFilename
            ruleEntries.append(
                PatchZipManifest.RuleEntry(
                    id: rule.id,
                    bundleID: cleanBundle,
                    relativePath: rule.relativePath,
                    replacementFilename: filename,
                    payloadPath: payloadRelativePath,
                    operation: rule.operation == "replace" ? nil : rule.operation,
                    containerKind: rule.containerKind == "application" ? nil : rule.containerKind
                )
            )
            if addedPaths.insert(payloadRelativePath).inserted {
                zipEntries.append((path: payloadRelativePath, data: rule.replacementData))
            }
        }

        let bundleList = project.bundleIdentifiers.isEmpty
            ? project.allBundleIdentifiers
            : project.bundleIdentifiers

        let manifest = PatchZipManifest(
            schemaVersion: 3,
            id: project.id,
            name: project.name,
            author: project.author,
            isPrivate: project.isPrivate,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
            bundleIdentifiers: bundleList,
            directories: directoryEntries,
            rules: ruleEntries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData: Data
        do {
            manifestData = try encoder.encode(manifest)
        } catch {
            throw PatchZipConverterError.invalidManifest("Failed to encode manifest JSON: \(error.localizedDescription)")
        }

        zipEntries.append((path: "patch.json", data: manifestData))

        // Build standard uncompressed PKZIP archive
        return try buildZipArchive(entries: zipEntries)
    }

    // MARK: - .zip -> .3105 Conversion

    public func convertZipToPatch(
        zipURL: URL,
        destinationPatchURL: URL,
        password: String? = nil
    ) throws {
        guard fileManager.fileExists(atPath: zipURL.path) else {
            throw PatchZipConverterError.ioFailure("Source .zip archive not found.")
        }
        let zipFileSize = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(zipFileSize)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        let zipData: Data
        do {
            zipData = try Data(contentsOf: zipURL)
        } catch {
            throw PatchZipConverterError.ioFailure("Cannot read .zip file: \(error.localizedDescription)")
        }

        let patchData = try convertZipDataToPatchData(zipData, password: password)

        do {
            let parent = destinationPatchURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: destinationPatchURL.path) {
                try fileManager.removeItem(at: destinationPatchURL)
            }
            try patchData.write(to: destinationPatchURL, options: .atomic)
        } catch {
            throw PatchZipConverterError.ioFailure("Cannot write output .3105 file: \(error.localizedDescription)")
        }
    }

    public func convertZipDataToPatchData(
        _ zipData: Data,
        password: String? = nil
    ) throws -> Data {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(zipData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        var entries = try parseZipArchive(zipData)

        if entries["patch.json"] == nil,
           let plistData = entries[".3105-project.plist"],
           var plistProject = try? PropertyListDecoder().decode(PatchProject.self, from: plistData) {
            for idx in plistProject.rules.indices {
                let rel = plistProject.rules[idx].relativePath
                let bid = plistProject.rules[idx].bundleID
                if let fileData = entries[rel] ?? entries["payload/\(bid)/\(rel)"] ?? entries["\(bid)/\(rel)"] {
                    plistProject.rules[idx].replacementData = fileData
                }
            }
            let encoded = try PatchPackageCodec.encodeNew(project: plistProject, password: password)
            return encoded.data
        }

        let manifestData: Data
        if let existingManifest = entries["patch.json"] {
            manifestData = existingManifest
        } else {
            // Không tồn tại patch.json -> Tự động tạo file patch.json mặc định hợp lệ
            manifestData = try generateDefaultManifest(from: entries)
            entries["patch.json"] = manifestData
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: PatchZipManifest
        do {
            manifest = try decoder.decode(PatchZipManifest.self, from: manifestData)
        } catch {
            throw PatchZipConverterError.invalidManifest("Failed to parse manifest JSON: \(error.localizedDescription)")
        }

        // Reconstruct PatchDirectories
        let directories = manifest.directories.map {
            PatchDirectory(id: $0.id, bundleID: $0.bundleID, relativePath: $0.relativePath)
        }

        // Reconstruct PatchRules with payload bytes
        var rules: [PatchRule] = []
        for ruleEntry in manifest.rules {
            guard let payloadData = entries[ruleEntry.payloadPath] ?? entries[ruleEntry.relativePath] else {
                throw PatchZipConverterError.missingPayloadFile("Payload file missing for rule at: \(ruleEntry.payloadPath)")
            }
            let rule = PatchRule(
                id: ruleEntry.id,
                bundleID: ruleEntry.bundleID,
                relativePath: ruleEntry.relativePath,
                replacementFilename: ruleEntry.replacementFilename,
                replacementData: payloadData,
                operation: ruleEntry.operation ?? "replace",
                containerKind: ruleEntry.containerKind ?? "application"
            )
            rules.append(rule)
        }

        let project = PatchProject(
            id: manifest.id,
            name: manifest.name,
            author: manifest.author,
            isPrivate: manifest.isPrivate,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt,
            bundleIdentifiers: manifest.bundleIdentifiers,
            directories: directories,
            rules: rules
        )

        do {
            try PatchPackageCodec.validate(project)
        } catch {
            throw PatchZipConverterError.invalidProject("Validation failed for reconstructed patch project: \(error.localizedDescription)")
        }

        let encoded: EncodedPatchPackage
        do {
            encoded = try PatchPackageCodec.encodeNew(project: project, password: password)
        } catch {
            throw PatchZipConverterError.corruptedArchive("Failed to encode .3105 patch package: \(error.localizedDescription)")
        }

        return encoded.data
    }

    private func generateDefaultManifest(
        from entries: [String: Data],
        defaultName: String = "Converted Patch"
    ) throws -> Data {
        let validEntries = entries.filter { key, _ in
            !key.hasPrefix("__MACOSX/") &&
            !key.hasSuffix("/") &&
            !key.contains(".DS_Store") &&
            key != "patch.json"
        }

        guard !validEntries.isEmpty else {
            throw PatchZipConverterError.invalidManifest("Tệp ZIP không chứa bất kỳ dữ liệu nào để đóng gói.")
        }

        var detectedBundleID: String? = nil
        for path in validEntries.keys {
            let parts = path.split(separator: "/")
            for part in parts {
                let str = String(part)
                if (try? PatchPathValidator.canonicalBundleIdentifier(str)) == str {
                    detectedBundleID = str
                    break
                }
            }
            if detectedBundleID != nil { break }
        }

        let bundleID = detectedBundleID
            ?? AppContainerScanner.shared.apps.first(where: { !$0.bundleID.hasPrefix("com.apple.") })?.bundleID
            ?? "com.apple.mobile.MobileHouseArrest"

        var ruleEntries: [PatchZipManifest.RuleEntry] = []
        var dirEntries: [PatchZipManifest.DirectoryEntry] = []
        var seenDirs = Set<String>()

        for (path, _) in validEntries {
            var rel = path
            if rel.hasPrefix("payload/\(bundleID)/") {
                rel = String(rel.dropFirst("payload/\(bundleID)/".count))
            } else if rel.hasPrefix("\(bundleID)/") {
                rel = String(rel.dropFirst("\(bundleID)/".count))
            }
            guard !rel.isEmpty else { continue }

            let filename = (rel as NSString).lastPathComponent
            let ruleID = UUID()
            ruleEntries.append(
                PatchZipManifest.RuleEntry(
                    id: ruleID,
                    bundleID: bundleID,
                    relativePath: rel,
                    replacementFilename: filename,
                    payloadPath: path
                )
            )

            let comps = rel.split(separator: "/").dropLast()
            var currentSub = ""
            for comp in comps {
                currentSub += (currentSub.isEmpty ? "" : "/") + comp
                if seenDirs.insert(currentSub).inserted {
                    dirEntries.append(PatchZipManifest.DirectoryEntry(id: UUID(), bundleID: bundleID, relativePath: currentSub))
                }
            }
        }

        let manifest = PatchZipManifest(
            schemaVersion: 3,
            id: UUID(),
            name: defaultName,
            author: "Totorox",
            isPrivate: false,
            createdAt: Date(),
            updatedAt: Date(),
            bundleIdentifiers: [bundleID],
            directories: dirEntries,
            rules: ruleEntries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    /// Đảm bảo thư mục tạm chứa file patch.json hợp lệ trước khi đóng gói thành .3105
    public static func ensureManifestExists(in directoryURL: URL, defaultName: String = "Converted Patch") throws {
        let manifestURL = directoryURL.appendingPathComponent("patch.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if fileURL.lastPathComponent == "patch.json" || fileURL.lastPathComponent == ".DS_Store" { continue }
            fileURLs.append(fileURL)
        }

        guard !fileURLs.isEmpty else { return }

        let dirPrefix = directoryURL.standardizedFileURL.path + "/"
        var detectedBundleID: String? = nil
        for fileURL in fileURLs {
            let rel = fileURL.standardizedFileURL.path.replacingOccurrences(of: dirPrefix, with: "")
            let parts = rel.split(separator: "/")
            for part in parts {
                let str = String(part)
                if (try? PatchPathValidator.canonicalBundleIdentifier(str)) == str {
                    detectedBundleID = str
                    break
                }
            }
            if detectedBundleID != nil { break }
        }

        let bundleID = detectedBundleID
            ?? AppContainerScanner.shared.apps.first(where: { !$0.bundleID.hasPrefix("com.apple.") })?.bundleID
            ?? "com.apple.mobile.MobileHouseArrest"

        var ruleEntries: [PatchZipManifest.RuleEntry] = []
        var dirEntries: [PatchZipManifest.DirectoryEntry] = []
        var seenDirs = Set<String>()

        for fileURL in fileURLs {
            var rel = fileURL.standardizedFileURL.path.replacingOccurrences(of: dirPrefix, with: "")
            if rel.hasPrefix("payload/\(bundleID)/") {
                rel = String(rel.dropFirst("payload/\(bundleID)/".count))
            } else if rel.hasPrefix("\(bundleID)/") {
                rel = String(rel.dropFirst("\(bundleID)/".count))
            }
            guard !rel.isEmpty else { continue }

            let filename = (rel as NSString).lastPathComponent
            let payloadRelPath = fileURL.standardizedFileURL.path.replacingOccurrences(of: dirPrefix, with: "")
            ruleEntries.append(
                PatchZipManifest.RuleEntry(
                    id: UUID(),
                    bundleID: bundleID,
                    relativePath: rel,
                    replacementFilename: filename,
                    payloadPath: payloadRelPath
                )
            )

            let comps = rel.split(separator: "/").dropLast()
            var currentSub = ""
            for comp in comps {
                currentSub += (currentSub.isEmpty ? "" : "/") + comp
                if seenDirs.insert(currentSub).inserted {
                    dirEntries.append(PatchZipManifest.DirectoryEntry(id: UUID(), bundleID: bundleID, relativePath: currentSub))
                }
            }
        }

        let manifest = PatchZipManifest(
            schemaVersion: 3,
            id: UUID(),
            name: defaultName,
            author: "Totorox",
            isPrivate: false,
            createdAt: Date(),
            updatedAt: Date(),
            bundleIdentifiers: [bundleID],
            directories: dirEntries,
            rules: ruleEntries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Internal Standard PKZIP Engine (Pure Swift, portable, zero external dependencies)

    func buildZipArchive(entries: [(path: String, data: Data)]) throws -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var centralCount: UInt16 = 0
        var totalBytes: Int64 = 0

        for entry in entries {
            let pathBytes = Data(entry.path.utf8)
            guard pathBytes.count <= UInt16.max else {
                throw PatchZipConverterError.corruptedArchive("Filename too long in archive: \(entry.path)")
            }
            guard centralCount < UInt16.max else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(Int64(entry.data.count))
            guard !overflow, !PatchPackageLimits.exceedsExpandedLimit(sum) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            totalBytes = sum

            let localHeaderOffset = UInt32(archive.count)
            let entryCRC = crc32Checksum(entry.data)
            let size = UInt32(entry.data.count)

            // 1. Local File Header
            archive.appendUInt32(0x04034b50) // Local file header signature
            archive.appendUInt16(20)         // Version needed to extract (2.0)
            archive.appendUInt16(1 << 11)    // General purpose bit flag (UTF-8)
            archive.appendUInt16(0)          // Compression method: 0 (Stored)
            archive.appendUInt16(0)          // Last mod file time
            archive.appendUInt16(0)          // Last mod file date
            archive.appendUInt32(entryCRC)   // CRC-32
            archive.appendUInt32(size)       // Compressed size
            archive.appendUInt32(size)       // Uncompressed size
            archive.appendUInt16(UInt16(pathBytes.count)) // File name length
            archive.appendUInt16(0)          // Extra field length
            archive.append(pathBytes)        // File name
            archive.append(entry.data)       // Uncompressed file data

            // 2. Central Directory Header
            centralDirectory.appendUInt32(0x02014b50) // Central file header signature
            centralDirectory.appendUInt16(20)         // Version made by
            centralDirectory.appendUInt16(20)         // Version needed to extract
            centralDirectory.appendUInt16(1 << 11)    // Bit flag (UTF-8)
            centralDirectory.appendUInt16(0)          // Compression method (Stored)
            centralDirectory.appendUInt16(0)          // Last mod time
            centralDirectory.appendUInt16(0)          // Last mod date
            centralDirectory.appendUInt32(entryCRC)   // CRC-32
            centralDirectory.appendUInt32(size)       // Compressed size
            centralDirectory.appendUInt32(size)       // Uncompressed size
            centralDirectory.appendUInt16(UInt16(pathBytes.count)) // File name length
            centralDirectory.appendUInt16(0)          // Extra field length
            centralDirectory.appendUInt16(0)          // File comment length
            centralDirectory.appendUInt16(0)          // Disk number start
            centralDirectory.appendUInt16(0)          // Internal file attributes
            centralDirectory.appendUInt32(0)          // External file attributes
            centralDirectory.appendUInt32(localHeaderOffset) // Relative offset of local header
            centralDirectory.append(pathBytes)        // File name

            centralCount += 1
        }

        let centralOffset = UInt32(archive.count)
        let centralSize = UInt32(centralDirectory.count)

        archive.append(centralDirectory)

        // 3. End of Central Directory Record
        archive.appendUInt32(0x06054b50) // EOCD signature
        archive.appendUInt16(0)          // Number of this disk
        archive.appendUInt16(0)          // Disk where central directory starts
        archive.appendUInt16(centralCount) // Number of central directory records on this disk
        archive.appendUInt16(centralCount) // Total number of central directory records
        archive.appendUInt32(centralSize)  // Size of central directory
        archive.appendUInt32(centralOffset) // Offset of start of central directory
        archive.appendUInt16(0)          // Comment length

        return archive
    }

    public func parseZipArchive(_ data: Data) throws -> [String: Data] {
        guard data.count >= 22 else {
            throw PatchZipConverterError.corruptedArchive("Zip file too small to contain EOCD.")
        }
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(data.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        // Search backward for End of Central Directory signature (0x06054b50)
        let eocdSig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var eocdOffset: Int?
        let maxSearch = min(data.count, 65535 + 22)
        let searchStart = data.count - maxSearch

        for i in stride(from: data.count - 4, through: searchStart, by: -1) {
            if data[i] == eocdSig[0] &&
               data[i+1] == eocdSig[1] &&
               data[i+2] == eocdSig[2] &&
               data[i+3] == eocdSig[3] {
                eocdOffset = i
                break
            }
        }

        guard let eocdPos = eocdOffset else {
            throw PatchZipConverterError.corruptedArchive("End of Central Directory record not found.")
        }
        guard eocdPos + 22 <= data.count else {
            throw PatchZipConverterError.corruptedArchive("Truncated End of Central Directory record.")
        }

        var cdTotalEntries = Int(data.readUInt16(at: eocdPos + 10))
        var cdOffset = Int(data.readUInt32(at: eocdPos + 16))

        // Check for ZIP64 EOCD locator (0x07064b50) immediately preceding EOCD
        if eocdPos >= 20 {
            let locSig = data.readUInt32(at: eocdPos - 20)
            if locSig == 0x07064b50 {
                let zip64RawOffset = data.readUInt64(at: eocdPos - 12)
                if zip64RawOffset <= UInt64(Int.max) {
                    let zip64EOCDOffset = Int(zip64RawOffset)
                    if zip64EOCDOffset + 56 <= data.count
                        && data.readUInt32(at: zip64EOCDOffset) == 0x06064b50 {
                        let rawCount = data.readUInt64(at: zip64EOCDOffset + 32)
                        let rawOffset = data.readUInt64(at: zip64EOCDOffset + 48)
                        if rawCount <= UInt64(Int.max), rawOffset <= UInt64(Int.max) {
                            cdTotalEntries = Int(rawCount)
                            cdOffset = Int(rawOffset)
                        }
                    }
                }
            }
        }

        guard cdOffset < data.count else {
            throw PatchZipConverterError.corruptedArchive("Invalid central directory offset.")
        }

        var results: [String: Data] = [:]
        var currentCDPos = cdOffset
        var totalUncompressedBytes: UInt64 = 0

        for _ in 0..<cdTotalEntries {
            guard currentCDPos + 46 <= data.count else {
                throw PatchZipConverterError.corruptedArchive("Truncated central directory record.")
            }
            let sig = data.readUInt32(at: currentCDPos)
            guard sig == 0x02014b50 else {
                throw PatchZipConverterError.corruptedArchive("Invalid central directory header signature.")
            }

            let compressionMethod = data.readUInt16(at: currentCDPos + 10)
            let entryCRC = data.readUInt32(at: currentCDPos + 16)
            var compressedSize = UInt64(data.readUInt32(at: currentCDPos + 20))
            var uncompressedSize = UInt64(data.readUInt32(at: currentCDPos + 24))
            let nameLen = Int(data.readUInt16(at: currentCDPos + 28))
            let extraLen = Int(data.readUInt16(at: currentCDPos + 30))
            let commentLen = Int(data.readUInt16(at: currentCDPos + 32))
            var localHeaderOffset = UInt64(data.readUInt32(at: currentCDPos + 42))

            let nameStart = currentCDPos + 46
            guard nameStart + nameLen <= data.count else {
                throw PatchZipConverterError.corruptedArchive("Truncated file name in central directory.")
            }

            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            guard let filename = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) else {
                throw PatchZipConverterError.corruptedArchive("Invalid file name encoding in archive.")
            }

            // Parse ZIP64 extra field if 32-bit values overflowed
            if uncompressedSize == 0xFFFFFFFF || compressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                var extraOffset = nameStart + nameLen
                let extraEnd = extraOffset + extraLen
                while extraOffset + 4 <= extraEnd {
                    let tag = data.readUInt16(at: extraOffset)
                    let blockSize = Int(data.readUInt16(at: extraOffset + 2))
                    var blockCursor = extraOffset + 4
                    let blockEnd = min(blockCursor + blockSize, extraEnd)
                    if tag == 0x0001 { // ZIP64 Extra
                        if uncompressedSize == 0xFFFFFFFF && blockCursor + 8 <= blockEnd {
                            uncompressedSize = data.readUInt64(at: blockCursor)
                            blockCursor += 8
                        }
                        if compressedSize == 0xFFFFFFFF && blockCursor + 8 <= blockEnd {
                            compressedSize = data.readUInt64(at: blockCursor)
                            blockCursor += 8
                        }
                        if localHeaderOffset == 0xFFFFFFFF && blockCursor + 8 <= blockEnd {
                            localHeaderOffset = data.readUInt64(at: blockCursor)
                            blockCursor += 8
                        }
                        break
                    }
                    extraOffset += 4 + blockSize
                }
            }

            currentCDPos += 46 + nameLen + extraLen + commentLen

            // Skip directory entries
            if filename.hasSuffix("/") {
                continue
            }

            let (expandedSum, expandedOverflow) = totalUncompressedBytes.addingReportingOverflow(uncompressedSize)
            guard !expandedOverflow,
                  !PatchPackageLimits.exceedsExpandedLimit(expandedSum),
                  uncompressedSize <= UInt64(Int.max),
                  compressedSize <= UInt64(Int.max) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            totalUncompressedBytes = expandedSum

            // Parse Local File Header
            guard localHeaderOffset <= UInt64(Int.max) else {
                throw PatchZipConverterError.corruptedArchive("Invalid local header offset for: \(filename)")
            }
            let localOff = Int(localHeaderOffset)
            guard localOff >= 0,
                  localOff <= data.count,
                  data.count - localOff >= 30 else {
                throw PatchZipConverterError.corruptedArchive("Truncated local file header for: \(filename)")
            }
            let localSig = data.readUInt32(at: localOff)
            guard localSig == 0x04034b50 else {
                throw PatchZipConverterError.corruptedArchive("Invalid local header signature for: \(filename)")
            }
            let localNameLen = Int(data.readUInt16(at: localOff + 26))
            let localExtraLen = Int(data.readUInt16(at: localOff + 28))
            let dataStart = localOff + 30 + localNameLen + localExtraLen

            let payloadSize = (compressionMethod == 0) ? Int(uncompressedSize) : Int(compressedSize)
            guard dataStart >= 0,
                  dataStart <= data.count,
                  payloadSize >= 0,
                  payloadSize <= data.count - dataStart else {
                throw PatchZipConverterError.corruptedArchive("Truncated file payload for: \(filename)")
            }

            if compressionMethod == 0 {
                // Stored
                let fileData = data.subdata(in: dataStart..<(dataStart + Int(uncompressedSize)))
                results[filename] = fileData
            } else if compressionMethod == 8 {
                // Deflated -> Decompress raw deflate stream using Central Directory sizes
                let compressedData = data.subdata(in: dataStart..<(dataStart + Int(compressedSize)))
                let decompressedData = try decompressDeflate(compressedData, expectedSize: Int(uncompressedSize))
                if entryCRC != 0 {
                    let calcCRC = crc32Checksum(decompressedData)
                    if calcCRC != entryCRC {
                        throw PatchZipConverterError.corruptedArchive("CRC32 checksum mismatch for: \(filename)")
                    }
                }
                results[filename] = decompressedData
            } else {
                throw PatchZipConverterError.unsupportedFormat("Unsupported compression method: \(compressionMethod)")
            }
        }

        return results
    }

    private func decompressDeflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var destination = Data(count: expectedSize)
        let status: Int32 = destination.withUnsafeMutableBytes { dstBuf in
            compressed.withUnsafeBytes { srcBuf in
                guard let src = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                return totorox_decompress_deflate(src, compressed.count, dst, expectedSize)
            }
        }
        guard status == 0 else {
            throw PatchZipConverterError.corruptedArchive("Deflate decompression failed (code \(status))")
        }
        return destination
    }

    private func crc32Checksum(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            table[i] = c
        }

        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Binary Data Helpers

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }

    func readUInt16(at offset: Int) -> UInt16 {
        subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            $0.load(as: UInt16.self).littleEndian
        }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
    }

    func readUInt64(at offset: Int) -> UInt64 {
        subdata(in: offset..<(offset + 8)).withUnsafeBytes {
            $0.load(as: UInt64.self).littleEndian
        }
    }
}
