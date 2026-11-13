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

    /// Kích thước header/metadata nhẹ được gửi lên server cho mode `inspect`.
    private static let headerSliceLimit = 4 * 1024 * 1024

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Server-backed inspection (chỉ gửi header/metadata nhẹ)

    /// Đọc metadata gói `.3105` bằng cách gửi header nhẹ lên `/api/v1/convert-header` (mode `inspect`).
    func inspect(patchData: Data) async throws -> PatchPackageSummary {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(patchData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        let slice = patchData.count > Self.headerSliceLimit
            ? patchData.prefix(Self.headerSliceLimit)
            : patchData.prefix(patchData.count)

        let response = try await sendConvertHeader(
            mode: "inspect",
            password: nil,
            payload: Data(slice),
            fileName: "header.bin"
        )

        let header = response.header
        let kind = header["kind"]?.string ?? ""
        guard kind == "patch_package" else {
            throw PatchZipConverterError.unsupportedFormat(
                header["note"]?.string ?? "Không nhận diện được gói .3105 (kind=\(kind.isEmpty ? "?" : kind))."
            )
        }

        let packageID = header["package_id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID()
        let schemaVersion = header["schema_version"]?.int ?? 0
        let isProtected = header["is_password_protected"]?.bool ?? false
        let fingerprintData = header["key_fingerprint"]?.string
            .flatMap { Data(base64Encoded: $0) } ?? Data()

        return PatchPackageSummary(
            packageID: packageID,
            schemaVersion: schemaVersion,
            isPasswordProtected: isProtected,
            keyFingerprint: fingerprintData
        )
    }

    func inspect(patchURL: URL) async throws -> PatchPackageSummary {
        guard fileManager.fileExists(atPath: patchURL.path) else {
            throw PatchZipConverterError.ioFailure("Không tìm thấy gói .3105 nguồn.")
        }
        let size = (try? patchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(size)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        let handle = try FileHandle(forReadingFrom: patchURL)
        defer { try? handle.close() }
        let slice = (try? handle.read(upToCount: Self.headerSliceLimit)) ?? Data()

        let response = try await sendConvertHeader(
            mode: "inspect",
            password: nil,
            payload: slice,
            fileName: "header.bin"
        )

        let header = response.header
        guard header["kind"]?.string == "patch_package" else {
            throw PatchZipConverterError.unsupportedFormat(
                header["note"]?.string ?? "Không nhận diện được gói .3105."
            )
        }
        return PatchPackageSummary(
            packageID: header["package_id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID(),
            schemaVersion: header["schema_version"]?.int ?? 0,
            isPasswordProtected: header["is_password_protected"]?.bool ?? false,
            keyFingerprint: header["key_fingerprint"]?.string.flatMap { Data(base64Encoded: $0) } ?? Data()
        )
    }

    /// Giải mã gói `.3105` trên server (`mode: from_zip`) và dựng `PatchProject` ở local.
    func decodeProject(patchData: Data, password: String? = nil) async throws -> PatchProject {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(patchData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        let response = try await sendConvertHeader(
            mode: "from_zip",
            password: password,
            payload: patchData,
            fileName: "package.3105"
        )

        guard let encodedPayload = response.payloadBytesB64,
              let payloadBytes = Data(base64Encoded: encodedPayload) else {
            throw PatchZipConverterError.corruptedArchive(
                response.note ?? "Máy chủ không trả payload đã giải mã."
            )
        }

        let decoder = PropertyListDecoder()
        if let wrapper = try? decoder.decode(PatchProjectPayload.self, from: payloadBytes) {
            return wrapper.project
        }
        if let project = try? decoder.decode(PatchProject.self, from: payloadBytes) {
            return project
        }
        throw PatchZipConverterError.invalidProject("Không giải mã được payload PLIST của gói .3105.")
    }

    // MARK: - .3105 -> .zip Conversion

    public func convertPatch3105ToZip(inputURL: URL, outputZipURL: URL, password: String? = nil) async throws {
        try await convertPatchToZip(patchURL: inputURL, destinationZipURL: outputZipURL, password: password)
    }

    public func convertPatchToZip(
        patchURL: URL,
        destinationZipURL: URL,
        password: String? = nil
    ) async throws {
        guard fileManager.fileExists(atPath: patchURL.path) else {
            throw PatchZipConverterError.ioFailure("Không tìm thấy gói .3105 nguồn.")
        }
        let patchFileSize = (try? patchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(patchFileSize)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        let hasScope = patchURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { patchURL.stopAccessingSecurityScopedResource() }
        }
        let patchData: Data
        do {
            patchData = try Data(contentsOf: patchURL)
        } catch {
            throw PatchZipConverterError.ioFailure("Không đọc được gói .3105: \(error.localizedDescription)")
        }

        let zipData = try await convertPatchDataToZipData(patchData, password: password)
        try writeAtomically(zipData, to: destinationZipURL, description: "tệp .zip đầu ra")
    }

    public func convertPatchDataToZipData(
        _ patchData: Data,
        password: String? = nil
    ) async throws -> Data {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(patchData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        // Nguồn đã là ZIP hợp lệ: không cần server.
        if patchData.count >= 4,
           patchData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) {
            return patchData
        }

        // Server giải mã envelope và dựng luôn tệp .zip (patch.json + payload).
        let response = try await sendConvertHeader(
            mode: "from_zip",
            password: password,
            payload: patchData,
            fileName: "source.3105"
        )
        guard let encodedZip = response.zipBytesB64,
              let zipBytes = Data(base64Encoded: encodedZip) else {
            throw PatchZipConverterError.corruptedArchive(
                response.note ?? "Máy chủ không trả tệp .zip."
            )
        }
        return zipBytes
    }

    // MARK: - .zip -> .3105 Conversion

    public func convertZipToPatch3105(inputZipURL: URL, outputPatchURL: URL, password: String? = nil) async throws {
        try await convertZipToPatch(zipURL: inputZipURL, destinationPatchURL: outputPatchURL, password: password)
    }

    public func convertZipToPatch(
        zipURL: URL,
        destinationPatchURL: URL,
        password: String? = nil
    ) async throws {
        guard fileManager.fileExists(atPath: zipURL.path) else {
            throw PatchZipConverterError.ioFailure("Không tìm thấy tệp .zip nguồn.")
        }
        let zipFileSize = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(zipFileSize)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        let hasScope = zipURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { zipURL.stopAccessingSecurityScopedResource() }
        }
        let zipData: Data
        do {
            zipData = try Data(contentsOf: zipURL)
        } catch {
            throw PatchZipConverterError.ioFailure("Không đọc được tệp .zip: \(error.localizedDescription)")
        }

        let patchData = try await convertZipDataToPatchData(zipData, password: password)
        try writeAtomically(patchData, to: destinationPatchURL, description: "tệp .3105 đầu ra")
    }

    public func convertZipDataToPatchData(
        _ zipData: Data,
        password: String? = nil
    ) async throws -> Data {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(zipData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        // Chỉ kiểm tra magic ZIP để báo lỗi sớm; toàn bộ việc dựng manifest/project và
        // niêm phong `.3105` chạy trên server (thin client).
        guard zipData.count >= 4,
              zipData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw PatchZipConverterError.corruptedArchive("Tệp nguồn không phải ZIP hợp lệ.")
        }

        let response = try await sendConvertHeader(
            mode: "to_zip",
            password: password,
            payload: zipData,
            fileName: "source.zip"
        )

        guard let encodedPackage = response.packageBytesB64,
              let packageBytes = Data(base64Encoded: encodedPackage) else {
            throw PatchZipConverterError.corruptedArchive(
                response.note ?? "Máy chủ không trả gói .3105."
            )
        }

        return packageBytes
    }

    // MARK: - Server transport

    private func sendConvertHeader(
        mode: String,
        password: String?,
        payload: Data,
        fileName: String
    ) async throws -> ConvertHeaderResponse {
        guard Int64(payload.count) <= APIService.maximumUploadBytes else {
            throw PatchZipConverterError.ioFailure(
                "Header/ngữ cảnh vượt quá \(ByteCountFormatter.string(fromByteCount: APIService.maximumUploadBytes, countStyle: .file)) nên không gửi được lên máy chủ."
            )
        }

        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("TotoroxConvert_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        let payloadURL = workDir.appendingPathComponent(fileName)
        do {
            try payload.write(to: payloadURL, options: .atomic)
        } catch {
            throw PatchZipConverterError.ioFailure("Không tạo được tệp tạm: \(error.localizedDescription)")
        }

        switch await APIService.shared.convertHeader(
            fileURL: payloadURL,
            mode: mode,
            password: password,
            licenseKey: LicenseManager.shared.licenseKey,
            hwid: LicenseManager.shared.deviceIdentifier
        ) {
        case .success(let response):
            return response
        case .failure(let error):
            throw PatchZipConverterError.ioFailure("Máy chủ convert-header: \(error.localizedDescription)")
        }
    }

    private func writeAtomically(_ data: Data, to destinationURL: URL, description: String) throws {
        do {
            let parent = destinationURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            throw PatchZipConverterError.ioFailure("Không ghi được \(description): \(error.localizedDescription)")
        }
    }

    private struct PatchProjectPayload: Decodable {
        let project: PatchProject
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
