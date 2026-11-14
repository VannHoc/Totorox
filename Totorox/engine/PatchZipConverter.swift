import Foundation
import CryptoKit
import CommonCrypto

public enum PatchZipConverterError: Error, LocalizedError, Equatable {
    case corruptedArchive(String)
    case unsupportedFormat(String)
    case invalidManifest(String)
    case missingPayloadFile(String)
    case invalidProject(String)
    case insufficientSpace
    case sizeLimitExceeded
    case ioFailure(String)
    case cryptoFailed(String)

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
        case .cryptoFailed(let msg): return "Lỗi mật mã: \(msg)"
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

    /// Gói nhỏ hơn ngưỡng này được đọc trọn để parse envelope local (metadata hiển thị
    /// ngay, không phụ thuộc mạng và không vướng giới hạn upload của server).
    private static let localInspectionLimit: Int64 = 64 * 1024 * 1024

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Server-backed inspection (chỉ gửi header/metadata nhẹ)

    /// Đọc metadata gói `.3105`.
    ///
    /// Gói có magic `3105PATCH` được parse ngay tại máy (chỉ đọc header plist, không
    /// upload) nên không bao giờ vướng giới hạn 100 MB của `/api/v1/convert-header`.
    /// Chỉ khi magic không khớp mới nhờ server nhận diện.
    func inspect(patchData: Data) async throws -> PatchPackageSummary {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(patchData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        if let localSummary = try? localSummary(patchData: patchData) {
            return localSummary
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

        // Binary plist đặt offset table ở cuối, nên slice đầu file không parse được.
        // Gói nhỏ đọc trọn để parse local; gói lớn mới cần nhờ server.
        if Int64(size) <= Self.localInspectionLimit,
           let full = try? Data(contentsOf: patchURL),
           let localSummary = try? localSummary(patchData: full) {
            return localSummary
        }

        let handle = try FileHandle(forReadingFrom: patchURL)
        defer { try? handle.close() }
        let slice = (try? handle.read(upToCount: Self.headerSliceLimit)) ?? Data()

        if let localSummary = try? localSummary(patchData: slice) {
            return localSummary
        }

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

        let envelope = try parseEnvelope(patchData)
        let headerOnly: Data
        let passwordForServer: String?
        let localPreUnwrappedKey: Data?

        if envelope.isPasswordProtected {
            // Mở khóa wrappedContentKey ngay trên thiết bị với đầy đủ biến thể AAD (UUID chữ hoa & chữ thường)
            // để tránh lỗi server cũ hạ chữ thường UUID trong AAD, sau đó gửi header đã mở khóa lên server
            // để xác thực bản quyền/quota.
            let unwrapped = try unwrapContentKeyLocally(envelope: envelope, password: password)
            localPreUnwrappedKey = unwrapped
            headerOnly = try unlockedEnvelopeHeader(from: patchData, contentKey: unwrapped)
            passwordForServer = nil
        } else {
            localPreUnwrappedKey = nil
            headerOnly = try envelopeWithoutPayload(patchData)
            passwordForServer = password
        }

        let response = try await sendConvertHeader(
            mode: "from_zip",
            password: passwordForServer,
            payload: headerOnly,
            fileName: "header.3105"
        )
        let contentKey: Data
        if let contentKeyB64 = response.contentKeyB64,
           let serverKey = Data(base64Encoded: contentKeyB64) {
            contentKey = serverKey
        } else if let localKey = localPreUnwrappedKey {
            contentKey = localKey
        } else {
            throw PatchZipConverterError.corruptedArchive(response.note ?? "Máy chủ không trả content key.")
        }

        guard let encryptedPayload = envelope.encryptedPayload else {
            throw PatchZipConverterError.invalidProject("Gói .3105 thiếu encryptedPayload.")
        }
        let payloadBytes = try openPayload(
            encryptedPayload: encryptedPayload,
            contentKey: contentKey,
            packageID: envelope.packageID,
            packageIDRaw: envelope.packageIDRaw,
            schemaVersion: envelope.schemaVersion,
            passwordProtected: envelope.isPasswordProtected,
            password: password,
            kdfSalt: envelope.kdfSalt,
            kdfIterations: envelope.kdfIterations,
            wrappedContentKey: envelope.wrappedContentKey,
            publicContentKey: envelope.publicContentKey
        )

        let decoder = PropertyListDecoder()
        if let wrapper = try? decoder.decode(PatchProjectPayload.self, from: payloadBytes) {
            return wrapper.project
        }
        if let project = try? decoder.decode(PatchProject.self, from: payloadBytes) {
            return project
        }
        if let dict = try? PropertyListSerialization.propertyList(from: payloadBytes, options: [], format: nil) as? [String: Any],
           let project = projectFromDictionary(dict) {
            return project
        }
        throw PatchZipConverterError.invalidProject("Không giải mã được payload PLIST của gói .3105.")
    }

    private func projectFromDictionary(_ dict: [String: Any]) -> PatchProject? {
        let p = (dict["project"] as? [String: Any]) ?? dict
        let id = (p["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let name = (p["name"] as? String) ?? "Patch"
        let author = (p["author"] as? String) ?? ""
        let isPrivate = (p["isPrivate"] as? Bool) ?? false
        let createdAt = (p["createdAt"] as? Date) ?? Date()
        let updatedAt = (p["updatedAt"] as? Date) ?? Date()
        let bundleIDs = (p["bundleIdentifiers"] as? [String]) ?? []

        var directories: [PatchDirectory] = []
        if let dirArray = p["directories"] as? [[String: Any]] {
            for item in dirArray {
                let dirID = (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                let bundleID = (item["bundleID"] as? String) ?? "com.apple.mobile.MobileHouseArrest"
                let relativePath = (item["relativePath"] as? String) ?? ""
                directories.append(PatchDirectory(id: dirID, bundleID: bundleID, relativePath: relativePath))
            }
        }

        var rules: [PatchRule] = []
        if let ruleArray = p["rules"] as? [[String: Any]] {
            for item in ruleArray {
                let ruleID = (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                let bundleID = (item["bundleID"] as? String) ?? "com.apple.mobile.MobileHouseArrest"
                let relativePath = (item["relativePath"] as? String) ?? ""
                let replacementFilename = (item["replacementFilename"] as? String) ?? (relativePath as NSString).lastPathComponent
                let replacementData = (item["replacementData"] as? Data) ?? Data()
                let operation = (item["operation"] as? String) ?? "replace"
                let containerKind = (item["containerKind"] as? String) ?? "application"
                rules.append(
                    PatchRule(
                        id: ruleID,
                        bundleID: bundleID,
                        relativePath: relativePath,
                        replacementFilename: replacementFilename,
                        replacementData: replacementData,
                        operation: operation,
                        containerKind: containerKind
                    )
                )
            }
        }

        return PatchProject(
            id: id,
            name: name,
            author: author,
            isPrivate: isPrivate,
            createdAt: createdAt,
            updatedAt: updatedAt,
            bundleIdentifiers: bundleIDs,
            directories: directories,
            rules: rules
        )
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

        // Hybrid: server chỉ trả content key; client tự giải mã và dựng .zip local.
        let project = try await decodeProject(patchData: patchData, password: password)
        return try buildProjectZip(project)
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

        let cleanPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        let project = try buildPatchProject(fromZipData: zipData)
        let metadataPayload = try manifestData(for: project)
        let response = try await sendConvertHeader(
            mode: "to_zip",
            password: cleanPassword,
            payload: metadataPayload,
            fileName: "manifest.json"
        )
        guard let contentKeyB64 = response.contentKeyB64,
              let contentKey = Data(base64Encoded: contentKeyB64) else {
            throw PatchZipConverterError.corruptedArchive(response.note ?? "Máy chủ không trả content key.")
        }
        let packageID = response.packageId.flatMap(UUID.init(uuidString:)) ?? project.id
        let schemaVersion = 3
        let isProtected = cleanPassword != nil
        let sealedPayload = try sealPayload(project: project, contentKey: contentKey, packageID: packageID, schemaVersion: schemaVersion)
        let envelopeData = try buildEnvelope(
            project: project,
            packageID: packageID,
            schemaVersion: schemaVersion,
            contentKey: contentKey,
            isProtected: isProtected,
            password: cleanPassword,
            response: response,
            sealedPayload: sealedPayload
        )
        return Data("3105PATCH\0".utf8) + envelopeData
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

        let cleanPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        switch await APIService.shared.convertHeader(
            fileURL: payloadURL,
            mode: mode,
            password: cleanPassword,
            licenseKey: LicenseManager.shared.licenseKey,
            hwid: LicenseManager.shared.deviceIdentifier
        ) {
        case .success(let response):
            return response
        case .failure(let error):
            let message = error.localizedDescription
            let lower = message.lowercased()
            if lower.contains("mật khẩu") || lower.contains("password") || lower.contains("wrapped content key") || lower.contains("giải mã") {
                throw PatchZipConverterError.cryptoFailed(message)
            }
            throw PatchZipConverterError.ioFailure("Máy chủ convert-header: \(message)")
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

    private struct PatchProjectPayload: Codable {
        let project: PatchProject
    }

    // MARK: - Internal Standard PKZIP Engine (Pure Swift, portable, zero external dependencies)

    /// Ghi ZIP trực tiếp xuống đĩa, không giữ toàn bộ output trong RAM.
    ///
    /// Bản `buildZipArchive` cần `Data` đầu ra nên với gói mod ~600 MB sẽ chiếm gấp đôi
    /// bộ nhớ (nội dung + output) và dễ bị jetsam trên iOS. Helper này ghi từng entry
    /// xuống `FileHandle` và chỉ giữ central directory (nhỏ) trong bộ nhớ.
    func writeZipArchive(entries: [(path: String, data: Data)], to destinationURL: URL) throws {
        let writer = try ZipArchiveWriter(destinationURL: destinationURL)
        defer { writer.cancel() }
        for entry in entries {
            try writer.add(path: entry.path, data: entry.data)
        }
        try writer.finish()
    }

    /// Writer ZIP stream: mỗi entry được ghi ngay xuống đĩa rồi giải phóng,
    /// nên bộ nhớ đỉnh chỉ còn ~1 entry thay vì cả gói kết quả.
    final class ZipArchiveWriter {
        private let handle: FileHandle
        private let destinationURL: URL
        private var centralDirectory = Data()
        private var centralCount: UInt16 = 0
        private var totalBytes: Int64 = 0
        private var offset: UInt64 = 0
        private var finished = false

        var totalEntriesWritten: Int {
            Int(centralCount)
        }

        init(destinationURL: URL, fileManager: FileManager = .default) throws {
            self.destinationURL = destinationURL
            let parent = destinationURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
                throw PatchZipConverterError.ioFailure("Không tạo được tệp .zip đầu ra.")
            }
            self.handle = try FileHandle(forWritingTo: destinationURL)
        }

        /// Ghi entry dạng STORE từ Data trong bộ nhớ
        func add(path: String, data: Data) throws {
            let pathBytes = Data(path.utf8)
            guard pathBytes.count <= UInt16.max else {
                throw PatchZipConverterError.corruptedArchive("Filename too long in archive: \(path)")
            }
            guard centralCount < UInt16.max else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(Int64(data.count))
            guard !overflow, !PatchPackageLimits.exceedsExpandedLimit(sum) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            guard data.count <= Int(UInt32.max), offset <= UInt64(UInt32.max) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            totalBytes = sum
            let localHeaderOffset = UInt32(offset)
            let entryCRC = PatchZipConverter.crc32Checksum(data)
            let size = UInt32(data.count)

            var header = Data()
            header.appendUInt32(0x04034b50)
            header.appendUInt16(20)
            header.appendUInt16(1 << 11)
            header.appendUInt16(0)
            header.appendUInt16(0)
            header.appendUInt16(0)
            header.appendUInt32(entryCRC)
            header.appendUInt32(size)
            header.appendUInt32(size)
            header.appendUInt16(UInt16(pathBytes.count))
            header.appendUInt16(0)
            header.append(pathBytes)

            try write(header)
            try write(data)

            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(1 << 11)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(entryCRC)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt16(UInt16(pathBytes.count))
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(localHeaderOffset)
            centralDirectory.append(pathBytes)

            centralCount += 1
        }

        /// Sao chép thẳng luồng dữ liệu (đã nén Deflate hoặc STORE) từ FileHandle nguồn
        /// mà KHÔNG giải nén và KHÔNG nén lại, đạt tốc độ I/O đĩa tối đa.
        func copyRawEntry(
            destinationPath: String,
            from sourceHandle: FileHandle,
            payloadOffset: UInt64,
            compressedSize: UInt32,
            uncompressedSize: UInt32,
            compressionMethod: UInt16,
            crc32: UInt32
        ) throws {
            let pathBytes = Data(destinationPath.utf8)
            guard pathBytes.count <= UInt16.max else {
                throw PatchZipConverterError.corruptedArchive("Filename too long in archive: \(destinationPath)")
            }
            guard centralCount < UInt16.max else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(Int64(uncompressedSize))
            guard !overflow, !PatchPackageLimits.exceedsExpandedLimit(sum) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            guard offset <= UInt64(UInt32.max) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            totalBytes = sum
            let localHeaderOffset = UInt32(offset)

            var header = Data()
            header.appendUInt32(0x04034b50)
            header.appendUInt16(20)
            header.appendUInt16(1 << 11)
            header.appendUInt16(compressionMethod)
            header.appendUInt16(0)
            header.appendUInt16(0)
            header.appendUInt32(crc32)
            header.appendUInt32(compressedSize)
            header.appendUInt32(uncompressedSize)
            header.appendUInt16(UInt16(pathBytes.count))
            header.appendUInt16(0)
            header.append(pathBytes)

            try write(header)

            try sourceHandle.seek(toOffset: payloadOffset)
            var remaining = Int(compressedSize)
            let bufferSize = 1024 * 1024 // 1 MB buffer streaming
            while remaining > 0 {
                let toRead = min(remaining, bufferSize)
                guard let chunk = try sourceHandle.read(upToCount: toRead), !chunk.isEmpty else {
                    throw PatchZipConverterError.corruptedArchive("Dữ liệu entry bị cắt ngắn trong tệp mod nguồn: \(destinationPath)")
                }
                try write(chunk)
                remaining -= chunk.count
            }

            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(1 << 11)
            centralDirectory.appendUInt16(compressionMethod)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(crc32)
            centralDirectory.appendUInt32(compressedSize)
            centralDirectory.appendUInt32(uncompressedSize)
            centralDirectory.appendUInt16(UInt16(pathBytes.count))
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(localHeaderOffset)
            centralDirectory.append(pathBytes)

            centralCount += 1
        }

        /// Ghi raw payload có sẵn trong bộ nhớ mà không giải nén hay nén lại
        func addRaw(
            path: String,
            rawPayload: Data,
            compressionMethod: UInt16,
            crc32: UInt32,
            uncompressedSize: UInt32
        ) throws {
            let pathBytes = Data(path.utf8)
            guard pathBytes.count <= UInt16.max else {
                throw PatchZipConverterError.corruptedArchive("Filename too long in archive: \(path)")
            }
            guard centralCount < UInt16.max else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(Int64(uncompressedSize))
            guard !overflow, !PatchPackageLimits.exceedsExpandedLimit(sum) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            guard offset <= UInt64(UInt32.max) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            totalBytes = sum
            let localHeaderOffset = UInt32(offset)
            let compressedSize = UInt32(rawPayload.count)

            var header = Data()
            header.appendUInt32(0x04034b50)
            header.appendUInt16(20)
            header.appendUInt16(1 << 11)
            header.appendUInt16(compressionMethod)
            header.appendUInt16(0)
            header.appendUInt16(0)
            header.appendUInt32(crc32)
            header.appendUInt32(compressedSize)
            header.appendUInt32(uncompressedSize)
            header.appendUInt16(UInt16(pathBytes.count))
            header.appendUInt16(0)
            header.append(pathBytes)

            try write(header)
            try write(rawPayload)

            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(1 << 11)
            centralDirectory.appendUInt16(compressionMethod)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(crc32)
            centralDirectory.appendUInt32(compressedSize)
            centralDirectory.appendUInt32(uncompressedSize)
            centralDirectory.appendUInt16(UInt16(pathBytes.count))
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(localHeaderOffset)
            centralDirectory.append(pathBytes)

            centralCount += 1
        }

        func finish() throws {
            guard !finished else { return }
            guard offset <= UInt64(UInt32.max) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            let centralOffset = UInt32(offset)
            let centralSize = UInt32(centralDirectory.count)
            try write(centralDirectory)
            centralDirectory.removeAll(keepingCapacity: false)

            var eocd = Data()
            eocd.appendUInt32(0x06054b50)
            eocd.appendUInt16(0)
            eocd.appendUInt16(0)
            eocd.appendUInt16(centralCount)
            eocd.appendUInt16(centralCount)
            eocd.appendUInt32(centralSize)
            eocd.appendUInt32(centralOffset)
            eocd.appendUInt16(0)
            try write(eocd)
            try handle.synchronize()
            try handle.close()
            finished = true
        }

        /// Đóng handle và xoá tệp dở khi có lỗi giữa chừng.
        func cancel() {
            guard !finished else { return }
            try? handle.close()
            try? FileManager.default.removeItem(at: destinationURL)
            finished = true
        }

        private func write(_ data: Data) throws {
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
        }
    }

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

    public struct ZipArchiveEntryHeader: Sendable, Equatable {
        public let path: String
        public let compressionMethod: UInt16
        public let crc32: UInt32
        public let compressedSize: UInt32
        public let uncompressedSize: UInt32
        public let localHeaderOffset: UInt64
        public let payloadOffset: UInt64

        public init(
            path: String,
            compressionMethod: UInt16,
            crc32: UInt32,
            compressedSize: UInt32,
            uncompressedSize: UInt32,
            localHeaderOffset: UInt64,
            payloadOffset: UInt64
        ) {
            self.path = path
            self.compressionMethod = compressionMethod
            self.crc32 = crc32
            self.compressedSize = compressedSize
            self.uncompressedSize = uncompressedSize
            self.localHeaderOffset = localHeaderOffset
            self.payloadOffset = payloadOffset
        }
    }

    /// Đọc nhanh danh mục Central Directory của file ZIP mà KHÔNG giải nén bất kỳ payload nào.
    /// Thời gian thực thi < 2ms cho file 150 MB, tiêu tốn 0 byte RAM giải nén.
    public func readZipArchiveHeaders(from data: Data) throws -> [String: ZipArchiveEntryHeader] {
        guard data.count >= 22 else {
            throw PatchZipConverterError.corruptedArchive("Zip file too small to contain EOCD.")
        }
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(data.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

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

        var results: [String: ZipArchiveEntryHeader] = [:]
        var currentCDPos = cdOffset

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

            if uncompressedSize == 0xFFFFFFFF || compressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                var extraOffset = nameStart + nameLen
                let extraEnd = extraOffset + extraLen
                while extraOffset + 4 <= extraEnd {
                    let tag = data.readUInt16(at: extraOffset)
                    let blockSize = Int(data.readUInt16(at: extraOffset + 2))
                    var blockCursor = extraOffset + 4
                    let blockEnd = min(blockCursor + blockSize, extraEnd)
                    if tag == 0x0001 {
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

            if filename.hasSuffix("/") {
                continue
            }

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
            let payloadOffset = UInt64(localOff + 30 + localNameLen + localExtraLen)

            results[filename] = ZipArchiveEntryHeader(
                path: filename,
                compressionMethod: compressionMethod,
                crc32: entryCRC,
                compressedSize: UInt32(compressedSize),
                uncompressedSize: UInt32(uncompressedSize),
                localHeaderOffset: localHeaderOffset,
                payloadOffset: payloadOffset
            )
        }

        return results
    }

    /// Đọc nhanh danh mục header ZIP từ URL dùng memory mapping
    public func readZipArchiveHeaders(from url: URL) throws -> [String: ZipArchiveEntryHeader] {
        let hasSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurity { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try readZipArchiveHeaders(from: data)
    }

    /// Trích xuất/giải nén có chọn lọc một entry duy nhất từ Data
    public func extractZipEntry(header: ZipArchiveEntryHeader, from sourceData: Data) throws -> Data {
        let start = Int(header.payloadOffset)
        let end = start + Int(header.compressedSize)
        guard start >= 0, end <= sourceData.count else {
            throw PatchZipConverterError.corruptedArchive("Payload out of bounds for \(header.path)")
        }
        let payload = sourceData.subdata(in: start..<end)
        if header.compressionMethod == 0 {
            return payload
        } else if header.compressionMethod == 8 {
            let decompressed = try decompressDeflate(payload, expectedSize: Int(header.uncompressedSize))
            if header.crc32 != 0 {
                let calc = crc32Checksum(decompressed)
                guard calc == header.crc32 else {
                    throw PatchZipConverterError.corruptedArchive("CRC32 checksum mismatch for \(header.path)")
                }
            }
            return decompressed
        } else {
            throw PatchZipConverterError.unsupportedFormat("Phương thức nén không được hỗ trợ: \(header.compressionMethod)")
        }
    }

    /// Trích xuất/giải nén có chọn lọc một entry duy nhất từ URL file ZIP
    public func extractZipEntry(header: ZipArchiveEntryHeader, from url: URL) throws -> Data {
        let hasSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurity { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try extractZipEntry(header: header, from: data)
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

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    public static func crc32Checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            var crc: UInt32 = 0xFFFFFFFF
            let count = buffer.count
            for i in 0..<count {
                crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(ptr[i])) & 0xFF)]
            }
            return crc ^ 0xFFFFFFFF
        }
    }

    private func crc32Checksum(_ data: Data) -> UInt32 {
        Self.crc32Checksum(data)
    }

// MARK: - Hybrid helpers

    private struct ParsedEnvelope {
        let packageID: UUID
        let packageIDRaw: String
        let schemaVersion: Int
        let keyAADVersion: Int?
        let isPasswordProtected: Bool
        let encryptedPayload: Data?
        let keyFingerprint: Data?
        let kdfSalt: Data?
        let kdfIterations: Int?
        let wrappedContentKey: Data?
        let publicContentKey: Data?
    }

    /// Metadata gói đọc thuần local — không cần server, không giới hạn dung lượng upload.
    private func localSummary(patchData: Data) throws -> PatchPackageSummary {
        let envelope = try parseEnvelope(patchData)
        return PatchPackageSummary(
            packageID: envelope.packageID,
            schemaVersion: envelope.schemaVersion,
            isPasswordProtected: envelope.isPasswordProtected,
            keyFingerprint: envelope.keyFingerprint ?? Data()
        )
    }

    private func parseEnvelope(_ data: Data) throws -> ParsedEnvelope {
        let magic = Data("3105PATCH\0".utf8)
        guard data.count > magic.count,
              data.prefix(magic.count) == magic else {
            throw PatchZipConverterError.invalidProject("Thiếu magic 3105PATCH.")
        }
        let body = data.dropFirst(magic.count)
        guard let plist = try PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as? [String: Any] else {
            throw PatchZipConverterError.invalidProject("Envelope không phải plist hợp lệ.")
        }
        guard let packageIDString = plist["packageID"] as? String,
              let packageID = UUID(uuidString: packageIDString) else {
            throw PatchZipConverterError.invalidProject("packageID không hợp lệ.")
        }
        let schemaVersion = plist["schemaVersion"] as? Int ?? 0
        let keyAADVersion = plist["keyAADVersion"] as? Int
        let isProtected = plist["isPasswordProtected"] as? Bool ?? false
        let encryptedPayload = plist["encryptedPayload"] as? Data
        let keyFingerprint = plist["keyFingerprint"] as? Data
        let kdfSalt = plist["kdfSalt"] as? Data
        let kdfIterations = plist["kdfIterations"] as? Int
        let wrappedContentKey = plist["wrappedContentKey"] as? Data
        let publicContentKey = plist["publicContentKey"] as? Data
        return ParsedEnvelope(
            packageID: packageID,
            packageIDRaw: packageIDString,
            schemaVersion: schemaVersion,
            keyAADVersion: keyAADVersion,
            isPasswordProtected: isProtected,
            encryptedPayload: encryptedPayload,
            keyFingerprint: keyFingerprint,
            kdfSalt: kdfSalt,
            kdfIterations: kdfIterations,
            wrappedContentKey: wrappedContentKey,
            publicContentKey: publicContentKey
        )
    }

    /// Dựng lại envelope chỉ với các khoá metadata server thật sự đọc.
    private static let envelopeMetadataKeys: Set<String> = [
        "schemaVersion",
        "packageID",
        "isPasswordProtected",
        "keyAADVersion",
        "keyFingerprint",
        "kdfSalt",
        "kdfIterations",
        "wrappedContentKey",
        "publicContentKey",
    ]

    func envelopeWithoutPayload(_ data: Data) throws -> Data {
        _ = try parseEnvelope(data)
        let magic = Data("3105PATCH\0".utf8)
        let body = data.dropFirst(magic.count)
        guard let plist = try PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as? [String: Any] else {
            throw PatchZipConverterError.invalidProject("Envelope không phải plist hợp lệ.")
        }
        var metadata: [String: Any] = [:]
        for key in Self.envelopeMetadataKeys {
            if let value = plist[key] {
                metadata[key] = value
            }
        }
        let serialized = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        return magic + serialized
    }

    private func unlockedEnvelopeHeader(from data: Data, contentKey: Data) throws -> Data {
        let envelope = try parseEnvelope(data)
        let magic = Data("3105PATCH\0".utf8)
        let metadata: [String: Any] = [
            "schemaVersion": envelope.schemaVersion,
            "packageID": envelope.packageID.uuidString,
            "isPasswordProtected": false,
            "keyFingerprint": Data(SHA256.hash(data: contentKey)),
            "publicContentKey": contentKey,
        ]
        let serialized = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        return magic + serialized
    }

    private func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyByteCount: Int = 32) throws -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: keyByteCount)
        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(max(iterations, 1)),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw PatchZipConverterError.cryptoFailed("Không thể dẫn xuất khóa PBKDF2 (\(status)).")
        }
        return derivedKey
    }

    private func unwrapContentKeyLocally(envelope: ParsedEnvelope, password: String?) throws -> Data {
        let cleanPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanPassword.isEmpty else {
            throw PatchZipConverterError.cryptoFailed("Gói bảo vệ mật khẩu nhưng chưa nhập mật khẩu.")
        }
        guard let salt = envelope.kdfSalt, !salt.isEmpty,
              let wrapped = envelope.wrappedContentKey, !wrapped.isEmpty else {
            throw PatchZipConverterError.invalidProject("Gói .3105 thiếu kdfSalt hoặc wrappedContentKey.")
        }
        let iterations = envelope.kdfIterations ?? 120_000
        let kek = try pbkdf2SHA256(password: cleanPassword, salt: salt, iterations: iterations, keyByteCount: 32)

        var idStrings: [String] = []
        for candidate in [envelope.packageIDRaw, envelope.packageID.uuidString, envelope.packageID.uuidString.lowercased()] {
            if !candidate.isEmpty && !idStrings.contains(candidate) {
                idStrings.append(candidate)
            }
        }

        var versions: [Int] = []
        if let kv = envelope.keyAADVersion, !versions.contains(kv) {
            versions.append(kv)
        }
        if !versions.contains(envelope.schemaVersion) {
            versions.append(envelope.schemaVersion)
        }
        for v in [9, 3, 2, 1, 0, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16] where !versions.contains(v) {
            versions.append(v)
        }

        var aadCandidates: [Data] = []
        for idStr in idStrings {
            for v in versions {
                aadCandidates.append(Data("3105PATCH/v\(v)/key/\(idStr)".utf8))
            }
            aadCandidates.append(Data("3105PATCH/key/\(idStr)".utf8))
        }
        aadCandidates.append(Data())

        for aad in aadCandidates {
            if let unwrapped = try? aesGCMOpen(ciphertext: wrapped, key: kek, aad: aad) {
                if let expectedFP = envelope.keyFingerprint, !expectedFP.isEmpty {
                    if Data(SHA256.hash(data: unwrapped)) == expectedFP {
                        return unwrapped
                    }
                } else {
                    return unwrapped
                }
            }
        }

        throw PatchZipConverterError.cryptoFailed("Mật khẩu gói .3105 không chính xác hoặc không mở được wrapped content key.")
    }

    private func openPayload(
        encryptedPayload: Data,
        contentKey: Data,
        packageID: UUID,
        packageIDRaw: String = "",
        schemaVersion: Int,
        passwordProtected: Bool,
        password: String?,
        kdfSalt: Data?,
        kdfIterations: Int?,
        wrappedContentKey: Data?,
        publicContentKey: Data?
    ) throws -> Data {
        var idStrings = [packageID.uuidString, packageID.uuidString.lowercased()]
        if !packageIDRaw.isEmpty && !idStrings.contains(packageIDRaw) {
            idStrings.append(packageIDRaw)
        }

        var versions = [schemaVersion]
        for v in 0...16 {
            if !versions.contains(v) { versions.append(v) }
        }

        var aadCandidates: [Data] = []
        for idStr in idStrings {
            for v in versions {
                aadCandidates.append(Data("3105PATCH/v\(v)/payload/\(idStr)".utf8))
            }
            aadCandidates.append(Data("3105PATCH/payload/\(idStr)".utf8))
        }
        aadCandidates.append(Data()) // Fallback: empty AAD

        for aad in aadCandidates {
            if let decrypted = try? aesGCMOpen(ciphertext: encryptedPayload, key: contentKey, aad: aad) {
                return decrypted
            }
        }
        throw PatchZipConverterError.invalidProject("Không giải mã được payload AES-GCM.")
    }

    private func aesGCMSeal(plaintext: Data, key: Data, aad: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
        return sealed.combined ?? (sealed.ciphertext + sealed.tag)
    }

    private func aesGCMOpen(ciphertext: Data, key: Data, aad: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)

        // 1. Thử chuẩn CryptoKit SealedBox (12-byte nonce ở đầu + ct + 16-byte tag ở cuối)
        if ciphertext.count >= 28 {
            if let box = try? AES.GCM.SealedBox(combined: ciphertext) {
                if let decrypted = try? AES.GCM.open(box, using: symKey, authenticating: aad) {
                    return decrypted
                }
            }
        }

        // 2. Thử 12-byte zero-nonce (nonce = 0x00*12, ciphertext = ct + 16-byte tag)
        if ciphertext.count >= 16 {
            let zeroNonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
            let tag = ciphertext.suffix(16)
            let ct = ciphertext.dropLast(16)
            if let box = try? AES.GCM.SealedBox(nonce: zeroNonce, ciphertext: ct, tag: tag) {
                if let decrypted = try? AES.GCM.open(box, using: symKey, authenticating: aad) {
                    return decrypted
                }
            }
        }

        // 3. Thử trailing nonce (ct + 16-byte tag + 12-byte nonce)
        if ciphertext.count >= 28 {
            let nonceData = ciphertext.suffix(12)
            let remaining = ciphertext.dropLast(12)
            let tag = remaining.suffix(16)
            let ct = remaining.dropLast(16)
            if let trailingNonce = try? AES.GCM.Nonce(data: nonceData),
               let box = try? AES.GCM.SealedBox(nonce: trailingNonce, ciphertext: ct, tag: tag) {
                if let decrypted = try? AES.GCM.open(box, using: symKey, authenticating: aad) {
                    return decrypted
                }
            }
        }

        throw PatchZipConverterError.cryptoFailed("Không thể giải mã AES-GCM với bất kỳ cấu trúc nonce nào.")
    }

    func buildProjectZip(_ project: PatchProject) throws -> Data {
        let fallbackBundle = project.bundleIdentifiers.first(where: { !$0.isEmpty }) ?? "com.garena.game.kgvn"
        var payloadEntries: [(path: String, data: Data)] = []
        var seenPayloadPaths = Set<String>()
        for rule in project.rules {
            let bundleID = rule.bundleID.isEmpty ? fallbackBundle : rule.bundleID
            var relativePath = rule.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relativePath.hasPrefix("payload/\(bundleID)/") {
                relativePath = String(relativePath.dropFirst("payload/\(bundleID)/".count))
            } else if relativePath.hasPrefix("\(bundleID)/") {
                relativePath = String(relativePath.dropFirst("\(bundleID)/".count))
            }
            guard !relativePath.isEmpty else { continue }
            let zipEntryPath = "\(bundleID)/\(relativePath)"
            if !seenPayloadPaths.contains(zipEntryPath) {
                seenPayloadPaths.insert(zipEntryPath)
                payloadEntries.append((path: zipEntryPath, data: rule.replacementData))
            }
        }
        return try buildZipArchive(entries: payloadEntries)
    }

    private func manifestData(for project: PatchProject) throws -> Data {
        let fallbackBundle = project.bundleIdentifiers.first(where: { !$0.isEmpty }) ?? "com.garena.game.kgvn"
        var manifestRules: [[String: Any]] = []
        for rule in project.rules {
            let bundleID = rule.bundleID.isEmpty ? fallbackBundle : rule.bundleID
            let relativePath = rule.relativePath
            let payloadPath = "\(bundleID)/\(relativePath)"
            var entry: [String: Any] = [
                "id": rule.id.uuidString,
                "bundleID": bundleID,
                "relativePath": relativePath,
                "replacementFilename": rule.replacementFilename,
                "payloadPath": payloadPath,
            ]
            if rule.operation != "replace" { entry["operation"] = rule.operation }
            if rule.containerKind != "application" { entry["containerKind"] = rule.containerKind }
            manifestRules.append(entry)
        }
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let manifest: [String: Any] = [
            "schemaVersion": 3,
            "id": project.id.uuidString,
            "name": project.name,
            "author": project.author,
            "isPrivate": project.isPrivate,
            "createdAt": now,
            "updatedAt": now,
            "bundleIdentifiers": project.bundleIdentifiers,
            "directories": project.directories.map { dir in
                [
                    "id": dir.id.uuidString,
                    "bundleID": dir.bundleID,
                    "relativePath": dir.relativePath,
                ] as [String: Any]
            },
            "rules": manifestRules,
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    }

    private static func isLikelyBundleIDSegment(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        let forbiddenSuffixes = [
            ".bytes", ".assetbundle", ".bnk", ".xml", ".json", ".plist",
            ".txt", ".png", ".jpg", ".jpeg", ".lua", ".pkg", ".zip", ".3105", ".app", ".bundle"
        ]
        for suffix in forbiddenSuffixes where lower.hasSuffix(suffix) {
            return false
        }
        return segment.range(of: #"^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil
    }

    private func buildPatchProject(fromZipData zipData: Data) throws -> PatchProject {
        let entries = try parseZipArchive(zipData)
        // Try manifest if present (legacy ZIPs)
        var manifest: [String: Any]?
        for name in ["patch.json", "manifest.json"] {
            if let data = entries[name],
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                manifest = json
                break
            }
        }

        func normalizedBundle(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "com.garena.game.kgvn" : trimmed
        }

        func payloadFor(relativePath: String, payloadPath: String, bundleID: String) -> Data {
            let candidates = [
                payloadPath,
                "\(normalizedBundle(bundleID))/\(relativePath)",
                "payload/\(normalizedBundle(bundleID))/\(relativePath)",
                relativePath,
            ]
            for candidate in candidates {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let data = entries[trimmed] {
                    return data
                }
            }
            return Data()
        }

        if let manifest = manifest,
           let rulesArray = manifest["rules"] as? [[String: Any]] {
            var rules: [PatchRule] = []
            for item in rulesArray {
                let relativePath = (item["relativePath"] as? String) ?? ""
                guard !relativePath.isEmpty else { continue }
                let bundleID = normalizedBundle((item["bundleID"] as? String) ?? "")
                let payload = payloadFor(
                    relativePath: relativePath,
                    payloadPath: (item["payloadPath"] as? String) ?? "",
                    bundleID: bundleID
                )
                let rule = PatchRule(
                    id: (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    bundleID: bundleID,
                    relativePath: relativePath,
                    replacementFilename: (item["replacementFilename"] as? String) ?? (relativePath as NSString).lastPathComponent,
                    replacementData: payload,
                    operation: (item["operation"] as? String) ?? "replace",
                    containerKind: (item["containerKind"] as? String) ?? "application"
                )
                rules.append(rule)
            }
            if !rules.isEmpty {
                let bundleIdentifiers = (manifest["bundleIdentifiers"] as? [String]) ?? [rules[0].bundleID]
                let directoriesRaw = (manifest["directories"] as? [[String: Any]]) ?? []
                let directories = directoriesRaw.map { dir in
                    PatchDirectory(
                        id: (dir["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                        bundleID: normalizedBundle((dir["bundleID"] as? String) ?? ""),
                        relativePath: (dir["relativePath"] as? String) ?? ""
                    )
                }
                return PatchProject(
                    id: (manifest["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    name: (manifest["name"] as? String) ?? "Patch",
                    author: (manifest["author"] as? String) ?? "",
                    isPrivate: (manifest["isPrivate"] as? Bool) ?? false,
                    bundleIdentifiers: bundleIdentifiers,
                    directories: directories,
                    rules: rules
                )
            }
        }

        // Infer bundle ID from directory segments ONLY (never match filenames like Actor_116_Infos.pkg.bytes)
        var detectedBundle: String?
        var hasAovStructure = false
        for name in entries.keys.sorted() {
            if name.hasPrefix("__MACOSX/") || name.hasSuffix(".DS_Store") { continue }
            let parts = name.split(separator: "/").map(String.init)
            if parts.count > 1 {
                for dirSegment in parts.dropLast() {
                    if Self.isLikelyBundleIDSegment(dirSegment) {
                        detectedBundle = dirSegment
                        break
                    }
                    let lowerSeg = dirSegment.lowercased()
                    if lowerSeg == "resources" || lowerSeg == "databin" || lowerSeg == "ages" || lowerSeg == "assetrefs" || lowerSeg == "prefab_characters" {
                        hasAovStructure = true
                    }
                }
            }
            if detectedBundle != nil { break }
        }
        let bundleID = detectedBundle ?? (hasAovStructure ? "com.garena.game.kgvn" : "com.apple.mobile.MobileHouseArrest")

        var rules: [PatchRule] = []
        for name in entries.keys.sorted() {
            if name == "patch.json" || name == "manifest.json" { continue }
            if name.hasPrefix("__MACOSX/") || name.hasSuffix(".DS_Store") { continue }
            let parts = name.split(separator: "/").map(String.init)
            if let last = parts.last, last.hasPrefix("._") { continue }

            var relativePath = name
            if let bidIdx = parts.dropLast().firstIndex(of: bundleID) {
                relativePath = parts.suffix(from: bidIdx + 1).joined(separator: "/")
            } else {
                for prefix in ["payload/\(bundleID)/", "\(bundleID)/", "payload/"] {
                    if relativePath.hasPrefix(prefix) {
                        relativePath = String(relativePath.dropFirst(prefix.count))
                        break
                    }
                }
                // Normalize AOV mod paths (e.g. "files/Resources/1.64.1/..." or "Resources/1.64.1/...")
                // into container-relative "Documents/Resources/1.64.1/..."
                let relParts = relativePath.split(separator: "/").map(String.init)
                if let resIdx = relParts.firstIndex(where: { $0.caseInsensitiveCompare("Resources") == .orderedSame }) {
                    if resIdx == 0 || relParts[resIdx - 1].caseInsensitiveCompare("Documents") != .orderedSame {
                        let tail = relParts.suffix(from: resIdx).joined(separator: "/")
                        relativePath = "Documents/\(tail)"
                    } else if resIdx > 1 {
                        relativePath = relParts.suffix(from: resIdx - 1).joined(separator: "/")
                    }
                }
            }

            guard !relativePath.isEmpty else { continue }
            let rule = PatchRule(
                bundleID: bundleID,
                relativePath: relativePath,
                replacementFilename: (relativePath as NSString).lastPathComponent,
                replacementData: entries[name] ?? Data(),
                operation: "replace",
                containerKind: "application"
            )
            rules.append(rule)
        }
        guard !rules.isEmpty else {
            throw PatchZipConverterError.invalidProject("ZIP không chứa rule nào.")
        }
        return PatchProject(
            name: "Converted Patch",
            author: "Totorox",
            bundleIdentifiers: [bundleID],
            rules: rules
        )
    }

    private func buildEnvelope(
        project: PatchProject,
        packageID: UUID,
        schemaVersion: Int,
        contentKey: Data,
        isProtected: Bool,
        password: String?,
        response: ConvertHeaderResponse,
        sealedPayload: Data
    ) throws -> Data {
        var envelope: [String: Any] = [
            "schemaVersion": schemaVersion,
            "packageID": packageID.uuidString,
            "isPasswordProtected": isProtected,
            "keyFingerprint": Data(SHA256.hash(data: contentKey)),
            "encryptedPayload": sealedPayload,
        ]
        if isProtected {
            envelope["keyAADVersion"] = schemaVersion
            var saltData = response.kdfSaltB64.flatMap { Data(base64Encoded: $0) }
            if saltData == nil || saltData!.isEmpty {
                var randomSalt = Data(count: 16)
                _ = randomSalt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
                saltData = randomSalt
            }
            let iterations = response.kdfIterations ?? 120_000
            envelope["kdfSalt"] = saltData
            envelope["kdfIterations"] = iterations

            if let cleanPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cleanPassword.isEmpty,
               let salt = saltData {
                let kek = try pbkdf2SHA256(password: cleanPassword, salt: salt, iterations: iterations, keyByteCount: 32)
                let keyAAD = Data("3105PATCH/v\(schemaVersion)/key/\(packageID.uuidString)".utf8)
                envelope["wrappedContentKey"] = try aesGCMSeal(plaintext: contentKey, key: kek, aad: keyAAD)
            } else if let wrappedB64 = response.wrappedContentKeyB64,
                      let wrapped = Data(base64Encoded: wrappedB64) {
                envelope["wrappedContentKey"] = wrapped
            }
        } else {
            envelope["publicContentKey"] = contentKey
        }
        return try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
    }

    private func sealPayload(project: PatchProject, contentKey: Data, packageID: UUID, schemaVersion: Int) throws -> Data {
        let plistData = try PropertyListEncoder().encode(PatchProjectPayload(project: project))
        let aad = Data("3105PATCH/v\(schemaVersion)/payload/\(packageID.uuidString)".utf8)
        return try aesGCMSeal(plaintext: plistData, key: contentKey, aad: aad)
    }
}

// MARK: - Binary Data Helpers

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
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
