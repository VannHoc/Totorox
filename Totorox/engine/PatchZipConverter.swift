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
        case .corruptedArchive(let msg): return AppLanguage.current.text("error.patch_converter.corrupted_archive", msg)
        case .unsupportedFormat(let msg): return AppLanguage.current.text("error.patch_converter.unsupported_format", msg)
        case .invalidManifest(let msg): return AppLanguage.current.text("error.patch_converter.invalid_manifest", msg)
        case .missingPayloadFile(let msg): return AppLanguage.current.text("error.patch_converter.missing_payload", msg)
        case .invalidProject(let msg): return AppLanguage.current.text("error.patch_converter.invalid_project", msg)
        case .insufficientSpace: return AppLanguage.current.text("error.patch_converter.insufficient_space")
        case .sizeLimitExceeded: return AppLanguage.current.text("error.patch_converter.size_limit_exceeded")
        case .ioFailure(let msg): return AppLanguage.current.text("error.patch_converter.io_failure", msg)
        case .cryptoFailed(let msg): return AppLanguage.current.text("error.patch_converter.crypto_failed", msg)
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
                header["note"]?.string ?? AppLanguage.current.text("error.patch_converter.unrecognized_3105_kind", kind.isEmpty ? "?" : kind)
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
            throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.missing_source_3105"))
        }
        let hasScope = patchURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { patchURL.stopAccessingSecurityScopedResource() }
        }
        let size = (try? patchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(size)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        // Binary plist đặt offset table ở cuối file (sau encryptedPayload).
        // Đọc trực tiếp metadata + offset table qua FileHandle để không phụ thuộc giới hạn 64 MB
        // và không nạp phần payload hàng trăm MB vào bộ nhớ.
        if let headerMeta = try? parseEnvelopeMetadata(at: patchURL) {
            let env = headerMeta.envelope
            return PatchPackageSummary(
                packageID: env.packageID,
                schemaVersion: env.schemaVersion,
                isPasswordProtected: env.isPasswordProtected,
                keyFingerprint: env.keyFingerprint ?? Data()
            )
        }

        if Int64(size) <= Self.localInspectionLimit,
           let full = try? Data(contentsOf: patchURL, options: .alwaysMapped),
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
                header["note"]?.string ?? AppLanguage.current.text("error.patch_converter.unrecognized_3105")
            )
        }
        return PatchPackageSummary(
            packageID: header["packageID"]?.string.flatMap(UUID.init(uuidString:)) ?? header["package_id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID(),
            schemaVersion: header["schema_version"]?.int ?? 0,
            isPasswordProtected: header["is_password_protected"]?.bool ?? false,
            keyFingerprint: header["key_fingerprint"]?.string.flatMap { Data(base64Encoded: $0) } ?? Data()
        )
    }

    /// Đọc metadata gói `.3105` hoàn toàn tại local (không gọi `/convert-header`, không trừ lượt).
    func inspectProjectMetadataLocally(patchData: Data, password: String? = nil) -> PatchProject? {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(patchData.count)),
              let envelope = try? parseEnvelope(patchData),
              let encryptedPayload = envelope.encryptedPayload else {
            return nil
        }

        let contentKey: Data
        if envelope.isPasswordProtected {
            guard let unwrapped = try? unwrapContentKeyLocally(envelope: envelope, password: password) else {
                return nil
            }
            contentKey = unwrapped
        } else if let publicKey = envelope.publicContentKey, !publicKey.isEmpty {
            contentKey = publicKey
        } else {
            return nil
        }

        guard let payloadBytes = try? openPayload(
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
        ) else {
            return nil
        }

        return try? decodePayloadProject(from: payloadBytes)
    }

    func inspectProjectMetadataLocally(patchURL: URL, password: String? = nil) -> PatchProject? {
        guard fileManager.fileExists(atPath: patchURL.path) else { return nil }
        let hasScope = patchURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { patchURL.stopAccessingSecurityScopedResource() }
        }
        let size = (try? patchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(size)) else {
            return nil
        }

        if let headerMeta = try? parseEnvelopeMetadata(at: patchURL),
           let payloadRange = headerMeta.encryptedPayloadRange {
            let envelope = headerMeta.envelope
            let contentKey: Data
            if envelope.isPasswordProtected {
                guard let unwrapped = try? unwrapContentKeyLocally(envelope: envelope, password: password) else {
                    return nil
                }
                contentKey = unwrapped
            } else if let publicKey = envelope.publicContentKey, !publicKey.isEmpty {
                contentKey = publicKey
            } else {
                return nil
            }

            return autoreleasepool {
                guard let mapped = try? Data(contentsOf: patchURL, options: .alwaysMapped) else {
                    return nil
                }
                let startInt = Int(payloadRange.lowerBound)
                let endInt = Int(payloadRange.upperBound)
                guard startInt >= 0, endInt <= mapped.count, startInt <= endInt else {
                    return nil
                }
                let encryptedPayload = mapped[startInt..<endInt]
                guard let payloadBytes = try? openPayload(
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
                ) else {
                    return nil
                }
                if let dict = try? PropertyListSerialization.propertyList(from: payloadBytes, options: [], format: nil) as? [String: Any],
                   let metadataProject = projectFromDictionary(dict, includeReplacementData: false) {
                    return metadataProject
                }
                return try? decodePayloadProject(from: payloadBytes)
            }
        }

        guard Int64(size) <= Self.localInspectionLimit,
              let data = try? Data(contentsOf: patchURL, options: .alwaysMapped) else {
            return nil
        }
        return inspectProjectMetadataLocally(patchData: data, password: password)
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
            throw PatchZipConverterError.corruptedArchive(
                response.note ?? AppLanguage.current.text("error.patch_converter.missing_content_key")
            )
        }

        guard let encryptedPayload = envelope.encryptedPayload else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.missing_encrypted_payload"))
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

        return try decodePayloadProject(from: payloadBytes)
    }

    private func decodePayloadProject(from payloadBytes: Data) throws -> PatchProject {
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
        throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_payload_plist"))
    }

    private func projectFromDictionary(_ dict: [String: Any], includeReplacementData: Bool = true) -> PatchProject? {
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
                let replacementData = includeReplacementData ? ((item["replacementData"] as? Data) ?? Data()) : Data()
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

    public func convertPatch3105ToZip(
        inputURL: URL,
        outputZipURL: URL,
        password: String? = nil,
        outputPassword: String? = nil,
        progressHandler: (@Sendable (_ stage: String, _ fraction: Double) -> Void)? = nil
    ) async throws {
        try await convertPatchToZip(
            patchURL: inputURL,
            destinationZipURL: outputZipURL,
            password: password,
            outputPassword: outputPassword,
            progressHandler: progressHandler
        )
    }

    public func convertPatchToZip(
        patchURL: URL,
        destinationZipURL: URL,
        password: String? = nil,
        outputPassword: String? = nil,
        progressHandler: (@Sendable (_ stage: String, _ fraction: Double) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        progressHandler?(patchURL.lastPathComponent, 0.08)
        guard fileManager.fileExists(atPath: patchURL.path) else {
            throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.missing_source_3105"))
        }
        let patchFileSize = (try? patchURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(patchFileSize)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        let hasScope = patchURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { patchURL.stopAccessingSecurityScopedResource() }
        }

        let cleanOutputPassword = outputPassword.flatMap { $0.isEmpty ? nil : $0 }

        // Đường dẫn tối ưu cho gói `3105PATCH\0` binary plist: đọc header qua FileHandle (< 10 KB),
        // mở khóa & gọi `/convert-header` chỉ với metadata, rồi map file giải mã + stream ZIP xuống đĩa.
        if let headerMeta = try? parseEnvelopeMetadata(at: patchURL),
           let payloadRange = headerMeta.encryptedPayloadRange {
            let envelope = headerMeta.envelope
            let headerOnly: Data
            let passwordForServer: String?
            let localPreUnwrappedKey: Data?

            if envelope.isPasswordProtected {
                let unwrapped = try unwrapContentKeyLocally(envelope: envelope, password: password)
                localPreUnwrappedKey = unwrapped
                headerOnly = try unlockedEnvelopeHeader(envelope: envelope, contentKey: unwrapped)
                passwordForServer = nil
            } else {
                localPreUnwrappedKey = nil
                headerOnly = try envelopeMetadataOnlyData(envelope: envelope)
                passwordForServer = password
            }

            try Task.checkCancellation()
            progressHandler?("header.3105", 0.25)
            let response = try await sendConvertHeader(
                mode: "from_zip",
                password: passwordForServer,
                payload: headerOnly,
                fileName: "header.3105"
            )
            try Task.checkCancellation()
            progressHandler?(patchURL.lastPathComponent, 0.48)
            let contentKey: Data
            if let contentKeyB64 = response.contentKeyB64,
               let serverKey = Data(base64Encoded: contentKeyB64) {
                contentKey = serverKey
            } else if let localKey = localPreUnwrappedKey {
                contentKey = localKey
            } else {
                throw PatchZipConverterError.corruptedArchive(
                    response.note ?? AppLanguage.current.text("error.patch_converter.missing_content_key")
                )
            }

            let project: PatchProject = try autoreleasepool {
                let mapped: Data
                do {
                    mapped = try Data(contentsOf: patchURL, options: .alwaysMapped)
                } catch {
                    throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.read_3105_failed", error.localizedDescription))
                }
                let startInt = Int(payloadRange.lowerBound)
                let endInt = Int(payloadRange.upperBound)
                guard startInt >= 0, endInt <= mapped.count, startInt <= endInt else {
                    throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.missing_encrypted_payload"))
                }
                let payloadBytes = try openPayload(
                    encryptedPayload: mapped[startInt..<endInt],
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
                return try decodePayloadProject(from: payloadBytes)
            }

            try Task.checkCancellation()
            progressHandler?(destinationZipURL.lastPathComponent, 0.80)
            try writeProjectZip(project, to: destinationZipURL, password: cleanOutputPassword)
            progressHandler?(destinationZipURL.lastPathComponent, 1.0)
            return
        }

        try Task.checkCancellation()
        progressHandler?(patchURL.lastPathComponent, 0.30)
        let patchData: Data
        do {
            patchData = try Data(contentsOf: patchURL, options: .alwaysMapped)
        } catch {
            throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.read_3105_failed", error.localizedDescription))
        }

        let zipData = try await convertPatchDataToZipData(
            patchData,
            password: password,
            outputPassword: outputPassword
        )
        try Task.checkCancellation()
        progressHandler?(destinationZipURL.lastPathComponent, 0.88)
        try writeAtomically(zipData, to: destinationZipURL, description: AppLanguage.current.text("error.patch_converter.output_zip_label"))
        progressHandler?(destinationZipURL.lastPathComponent, 1.0)
    }

    public func convertPatchDataToZipData(
        _ patchData: Data,
        password: String? = nil,
        outputPassword: String? = nil
    ) async throws -> Data {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(patchData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        let cleanOutputPassword = outputPassword.flatMap { $0.isEmpty ? nil : $0 }

        // Nguồn đã là ZIP hợp lệ: không cần server.
        if patchData.count >= 4,
           patchData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) {
            if cleanOutputPassword != nil {
                let entries = try parseZipArchive(patchData, password: password)
                let sorted = entries.keys.sorted().map { (path: $0, data: entries[$0] ?? Data()) }
                return try buildZipArchive(entries: sorted, password: cleanOutputPassword)
            }
            return patchData
        }

        // Hybrid: server chỉ trả content key; client tự giải mã và dựng .zip local.
        let project = try await decodeProject(patchData: patchData, password: password)
        return try buildProjectZip(project, password: cleanOutputPassword)
    }

    // MARK: - .zip -> .3105 Conversion

    public func convertZipToPatch3105(
        inputZipURL: URL,
        outputPatchURL: URL,
        password: String? = nil,
        sourcePassword: String? = nil,
        customProjectName: String? = nil,
        progressHandler: (@Sendable (_ stage: String, _ fraction: Double) -> Void)? = nil
    ) async throws {
        try await convertZipToPatch(
            zipURL: inputZipURL,
            destinationPatchURL: outputPatchURL,
            password: password,
            sourcePassword: sourcePassword,
            customProjectName: customProjectName,
            progressHandler: progressHandler
        )
    }

    public func convertZipToPatch(
        zipURL: URL,
        destinationPatchURL: URL,
        password: String? = nil,
        sourcePassword: String? = nil,
        customProjectName: String? = nil,
        progressHandler: (@Sendable (_ stage: String, _ fraction: Double) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        progressHandler?(zipURL.lastPathComponent, 0.10)
        guard fileManager.fileExists(atPath: zipURL.path) else {
            throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.missing_source_zip"))
        }
        let zipFileSize = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(zipFileSize)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        let hasScope = zipURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { zipURL.stopAccessingSecurityScopedResource() }
        }

        let cleanPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        let built: (project: PatchProject, settings: [Any]) = try autoreleasepool {
            let zipData: Data
            do {
                zipData = try Data(contentsOf: zipURL, options: .alwaysMapped)
            } catch {
                throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.read_zip_failed", error.localizedDescription))
            }
            guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(zipData.count)) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            guard zipData.count >= 4,
                  zipData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else {
                throw PatchZipConverterError.corruptedArchive(AppLanguage.current.text("error.patch_converter.invalid_zip_magic"))
            }
            return try buildPatchProjectWithSettings(
                fromZipData: zipData,
                sourcePassword: sourcePassword,
                customProjectName: customProjectName
            )
        }
        try Task.checkCancellation()
        progressHandler?("manifest.json", 0.40)

        let project = built.project
        let metadataPayload = try manifestData(for: project)
        let response = try await sendConvertHeader(
            mode: "to_zip",
            password: cleanPassword,
            payload: metadataPayload,
            fileName: "manifest.json"
        )
        try Task.checkCancellation()
        progressHandler?(destinationPatchURL.lastPathComponent, 0.65)

        guard let contentKeyB64 = response.contentKeyB64,
              let contentKey = Data(base64Encoded: contentKeyB64) else {
            throw PatchZipConverterError.corruptedArchive(
                response.note ?? AppLanguage.current.text("error.patch_converter.missing_content_key")
            )
        }
        let packageID = response.packageId.flatMap(UUID.init(uuidString:)) ?? project.id
        let schemaVersion = 9
        let isProtected = cleanPassword != nil

        let envelopeData: Data = try autoreleasepool {
            let sealedPayload = try sealPayload(
                project: project,
                contentKey: contentKey,
                packageID: packageID,
                schemaVersion: schemaVersion,
                settingsPlist: built.settings
            )
            return try buildEnvelope(
                project: project,
                packageID: packageID,
                schemaVersion: schemaVersion,
                contentKey: contentKey,
                isProtected: isProtected,
                password: cleanPassword,
                response: response,
                sealedPayload: sealedPayload
            )
        }
        try Task.checkCancellation()
        progressHandler?(destinationPatchURL.lastPathComponent, 0.90)

        // Stream magic + envelope directly via FileHandle to avoid allocating another full copy in RAM.
        let parent = destinationPatchURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let stagingURL = parent.appendingPathComponent(".totorox-conv-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw PatchZipConverterError.ioFailure("Unable to create temporary output file.")
        }
        defer { try? fileManager.removeItem(at: stagingURL) }
        do {
            let outHandle = try FileHandle(forWritingTo: stagingURL)
            defer { try? outHandle.close() }
            try outHandle.write(contentsOf: Data("3105PATCH\0".utf8))
            try outHandle.write(contentsOf: envelopeData)
            try outHandle.synchronize()
            try outHandle.close()
            if fileManager.fileExists(atPath: destinationPatchURL.path) {
                try fileManager.removeItem(at: destinationPatchURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destinationPatchURL)
        } catch {
            throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.write_failed", AppLanguage.current.text("error.patch_converter.output_3105_label"), error.localizedDescription))
        }
        progressHandler?(destinationPatchURL.lastPathComponent, 1.0)
    }

    public func convertZipDataToPatchData(
        _ zipData: Data,
        password: String? = nil,
        sourcePassword: String? = nil,
        customProjectName: String? = nil
    ) async throws -> Data {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(zipData.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        // Chỉ kiểm tra magic ZIP để báo lỗi sớm; toàn bộ việc dựng manifest/project và
        // niêm phong `.3105` chạy trên server (thin client).
        guard zipData.count >= 4,
              zipData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw PatchZipConverterError.corruptedArchive(AppLanguage.current.text("error.patch_converter.invalid_zip_magic"))
        }

        let cleanPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        let built = try buildPatchProjectWithSettings(
            fromZipData: zipData,
            sourcePassword: sourcePassword,
            customProjectName: customProjectName
        )
        let project = built.project
        let metadataPayload = try manifestData(for: project)
        let response = try await sendConvertHeader(
            mode: "to_zip",
            password: cleanPassword,
            payload: metadataPayload,
            fileName: "manifest.json"
        )
        guard let contentKeyB64 = response.contentKeyB64,
              let contentKey = Data(base64Encoded: contentKeyB64) else {
            throw PatchZipConverterError.corruptedArchive(
                response.note ?? AppLanguage.current.text("error.patch_converter.missing_content_key")
            )
        }
        let packageID = response.packageId.flatMap(UUID.init(uuidString:)) ?? project.id
        let schemaVersion = 9
        let isProtected = cleanPassword != nil
        let sealedPayload = try sealPayload(
            project: project,
            contentKey: contentKey,
            packageID: packageID,
            schemaVersion: schemaVersion,
            settingsPlist: built.settings
        )
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
                AppLanguage.current.text(
                    "error.patch_converter.header_too_large",
                    ByteCountFormatter.string(fromByteCount: APIService.maximumUploadBytes, countStyle: .file)
                )
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
            throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.temp_file_failed", error.localizedDescription))
        }

        let cleanPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        switch await APIService.shared.convertHeader(
            fileURL: payloadURL,
            mode: mode,
            password: cleanPassword,
            token: LicenseManager.shared.authToken,
            hwid: LicenseManager.shared.deviceIdentifier
        ) {
        case .success(let response):
            return response
        case .failure(let error):
            let message = error.localizedDescription
            let lower = message.lowercased()
            if lower.contains("mật khẩu") || lower.contains("password") || lower.contains("wrapped content key") || lower.contains("giải mã") || lower.contains("密码") {
                throw PatchZipConverterError.cryptoFailed(message)
            }
            throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.server_header_error", message))
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
            throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.write_failed", description, error.localizedDescription))
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
                throw PatchZipConverterError.ioFailure(AppLanguage.current.text("error.patch_converter.create_zip_failed"))
            }
            self.handle = try FileHandle(forWritingTo: destinationURL)
        }

        /// Ghi entry dạng STORE từ Data trong bộ nhớ (hỗ trợ tùy chọn ZipCrypto password)
        func add(path: String, data: Data, password: String? = nil) throws {
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
            let cleanPassword = password.flatMap { $0.isEmpty ? nil : $0 }
            let bitFlags: UInt16 = cleanPassword != nil ? ((1 << 11) | 0x0001) : (1 << 11)
            let localHeaderOffset = UInt32(offset)
            let entryCRC = PatchZipConverter.crc32Checksum(data)
            let uncompressedSize = UInt32(data.count)
            let storedPayload: Data
            if let zipPassword = cleanPassword {
                guard data.count <= Int(UInt32.max) - 12 else {
                    throw PatchZipConverterError.sizeLimitExceeded
                }
                storedPayload = ZipCryptoCodec.encrypt(data, crc32: entryCRC, password: zipPassword)
            } else {
                storedPayload = data
            }
            let compressedSize = UInt32(storedPayload.count)

            var header = Data()
            header.appendUInt32(0x04034b50)
            header.appendUInt16(20)
            header.appendUInt16(bitFlags)
            header.appendUInt16(0)
            header.appendUInt16(0)
            header.appendUInt16(0x0021) // DOS 1980-01-01 valid date (month=0/day=0 is invalid)
            header.appendUInt32(entryCRC)
            header.appendUInt32(compressedSize)
            header.appendUInt32(uncompressedSize)
            header.appendUInt16(UInt16(pathBytes.count))
            header.appendUInt16(0)
            header.append(pathBytes)

            try write(header)
            try write(storedPayload)

            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(bitFlags)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0x0021)
            centralDirectory.appendUInt32(entryCRC)
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
            header.appendUInt16(0x0021)
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
                    throw PatchZipConverterError.corruptedArchive(AppLanguage.current.text("error.patch_converter.truncated_entry", destinationPath))
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
            centralDirectory.appendUInt16(0x0021)
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
            header.appendUInt16(0x0021)
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
            centralDirectory.appendUInt16(0x0021)
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

    public struct ZipInspectionInfo: Sendable, Equatable {
        public let isPasswordProtected: Bool
        public let suggestedName: String?
        public let entryCount: Int
        public let isUnlocked: Bool
        public let isValidPatchOrModArchive: Bool
        public let detectedTarget: String?
        public let hasUnsupportedCompression: Bool

        public init(
            isPasswordProtected: Bool,
            suggestedName: String?,
            entryCount: Int,
            isUnlocked: Bool,
            isValidPatchOrModArchive: Bool = true,
            detectedTarget: String? = nil,
            hasUnsupportedCompression: Bool = false
        ) {
            self.isPasswordProtected = isPasswordProtected
            self.suggestedName = suggestedName
            self.entryCount = entryCount
            self.isUnlocked = isUnlocked
            self.isValidPatchOrModArchive = isValidPatchOrModArchive
            self.detectedTarget = detectedTarget
            self.hasUnsupportedCompression = hasUnsupportedCompression
        }
    }

    private struct ZipCryptoCodec {
        private var key0: UInt32 = 0x12345678
        private var key1: UInt32 = 0x23456789
        private var key2: UInt32 = 0x34567890

        init(password: String) {
            for byte in Data(password.utf8) {
                updateKeys(byte)
            }
        }

        private mutating func updateKeys(_ byte: UInt8) {
            key0 = Self.crc32Update(key0, byte: byte)
            key1 = key1 &+ (key0 & 0xFF)
            key1 = key1 &* 134775813 &+ 1
            key2 = Self.crc32Update(key2, byte: UInt8((key1 >> 24) & 0xFF))
        }

        private static func crc32Update(_ crc: UInt32, byte: UInt8) -> UInt32 {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            return (crc >> 8) ^ PatchZipConverter.crcTable[index]
        }

        private func keyStreamByte() -> UInt8 {
            let temp = UInt32(UInt16(truncatingIfNeeded: key2) | 2)
            return UInt8(((temp &* (temp ^ 1)) >> 8) & 0xFF)
        }

        mutating func encryptByte(_ plain: UInt8) -> UInt8 {
            let encrypted = plain ^ keyStreamByte()
            updateKeys(plain)
            return encrypted
        }

        mutating func decryptByte(_ cipher: UInt8) -> UInt8 {
            let plain = cipher ^ keyStreamByte()
            updateKeys(plain)
            return plain
        }

        static func encrypt(_ plaintext: Data, crc32: UInt32, password: String) -> Data {
            var codec = ZipCryptoCodec(password: password)
            var header = [UInt8](repeating: 0, count: 12)
            if SecRandomCopyBytes(kSecRandomDefault, 11, &header) != errSecSuccess {
                var rng = SystemRandomNumberGenerator()
                for idx in 0..<11 {
                    header[idx] = UInt8.random(in: 0...255, using: &rng)
                }
            }
            header[11] = UInt8((crc32 >> 24) & 0xFF)

            var output = Data(capacity: 12 + plaintext.count)
            for byte in header {
                output.append(codec.encryptByte(byte))
            }
            for byte in plaintext {
                output.append(codec.encryptByte(byte))
            }
            return output
        }

        static func verifyHeaderOnly(
            encryptedPayload: Data,
            crc32: UInt32,
            bitFlags: UInt16,
            dosTime: UInt16,
            password: String
        ) -> Bool {
            guard encryptedPayload.count >= 12 else { return false }
            var codec = ZipCryptoCodec(password: password)
            let start = encryptedPayload.startIndex
            var lastDecrypted: UInt8 = 0
            for idx in 0..<12 {
                lastDecrypted = codec.decryptByte(encryptedPayload[start + idx])
            }
            let expectedCheckByte = (bitFlags & 0x0008) != 0
                ? UInt8((dosTime >> 8) & 0xFF)
                : UInt8((crc32 >> 24) & 0xFF)
            return lastDecrypted == expectedCheckByte
        }

        static func decrypt(
            _ encryptedPayload: Data,
            crc32: UInt32,
            bitFlags: UInt16,
            dosTime: UInt16,
            password: String
        ) throws -> Data {
            guard encryptedPayload.count >= 12 else {
                throw PatchZipConverterError.corruptedArchive("Truncated encrypted ZIP payload.")
            }
            var codec = ZipCryptoCodec(password: password)
            let start = encryptedPayload.startIndex
            var lastDecrypted: UInt8 = 0
            for idx in 0..<12 {
                lastDecrypted = codec.decryptByte(encryptedPayload[start + idx])
            }
            let expectedCheckByte = (bitFlags & 0x0008) != 0
                ? UInt8((dosTime >> 8) & 0xFF)
                : UInt8((crc32 >> 24) & 0xFF)
            guard lastDecrypted == expectedCheckByte else {
                throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.zip_wrong_password"))
            }

            var output = Data(capacity: encryptedPayload.count - 12)
            for idx in 12..<encryptedPayload.count {
                output.append(codec.decryptByte(encryptedPayload[start + idx]))
            }
            return output
        }
    }

    func buildZipArchive(entries: [(path: String, data: Data)], password: String? = nil, compress: Bool = false) throws -> Data {
        let cleanPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        let bitFlags: UInt16 = cleanPassword != nil ? ((1 << 11) | 0x0001) : (1 << 11)

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
            let uncompressedSize = UInt32(entry.data.count)
            var compressionMethod: UInt16 = 0
            let storedPayload: Data
            if let zipPassword = cleanPassword {
                guard entry.data.count <= Int(UInt32.max) - 12 else {
                    throw PatchZipConverterError.sizeLimitExceeded
                }
                storedPayload = ZipCryptoCodec.encrypt(entry.data, crc32: entryCRC, password: zipPassword)
            } else if compress, let deflated = compressDeflate(entry.data) {
                compressionMethod = 8
                storedPayload = deflated
            } else {
                storedPayload = entry.data
            }
            let compressedSize = UInt32(storedPayload.count)

            // 1. Local File Header
            archive.appendUInt32(0x04034b50) // Local file header signature
            archive.appendUInt16(20)         // Version needed to extract (2.0)
            archive.appendUInt16(bitFlags)   // General purpose bit flag (UTF-8 + optional ZipCrypto)
            archive.appendUInt16(compressionMethod) // Compression method: 0 (Stored) or 8 (Deflate)
            archive.appendUInt16(0)          // Last mod file time
            archive.appendUInt16(0x0021)     // Last mod file date (DOS 1980-01-01)
            archive.appendUInt32(entryCRC)   // CRC-32
            archive.appendUInt32(compressedSize)   // Compressed size
            archive.appendUInt32(uncompressedSize) // Uncompressed size
            archive.appendUInt16(UInt16(pathBytes.count)) // File name length
            archive.appendUInt16(0)          // Extra field length
            archive.append(pathBytes)        // File name
            archive.append(storedPayload)    // File data (plaintext, Deflate, or ZipCrypto payload)

            // 2. Central Directory Header
            centralDirectory.appendUInt32(0x02014b50) // Central file header signature
            centralDirectory.appendUInt16(20)         // Version made by
            centralDirectory.appendUInt16(20)         // Version needed to extract
            centralDirectory.appendUInt16(bitFlags)   // Bit flag
            centralDirectory.appendUInt16(compressionMethod) // Compression method (Stored / Deflate)
            centralDirectory.appendUInt16(0)          // Last mod time
            centralDirectory.appendUInt16(0x0021)     // Last mod date (DOS 1980-01-01)
            centralDirectory.appendUInt32(entryCRC)   // CRC-32
            centralDirectory.appendUInt32(compressedSize)   // Compressed size
            centralDirectory.appendUInt32(uncompressedSize) // Uncompressed size
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

    private func findZipCentralDirectory(in data: Data) throws -> (entryCount: Int, offset: Int) {
        guard data.count >= 22 else {
            throw PatchZipConverterError.corruptedArchive("Zip file too small to contain EOCD.")
        }
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(data.count)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }

        let eocdSig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var eocdOffset: Int?
        var fallbackEocdOffset: Int?
        let maxSearch = min(data.count, 65535 + 22)
        let searchStart = data.count - maxSearch

        for i in stride(from: data.count - 22, through: searchStart, by: -1) {
            if data[i] == eocdSig[0] &&
               data[i+1] == eocdSig[1] &&
               data[i+2] == eocdSig[2] &&
               data[i+3] == eocdSig[3] {
                let commentLen = Int(data.readUInt16(at: i + 20))
                if i + 22 + commentLen == data.count {
                    eocdOffset = i
                    break
                } else if fallbackEocdOffset == nil {
                    fallbackEocdOffset = i
                }
            }
        }

        guard let eocdPos = eocdOffset ?? fallbackEocdOffset else {
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

        guard cdOffset >= 0, cdOffset <= eocdPos, cdOffset <= data.count else {
            throw PatchZipConverterError.corruptedArchive("Invalid central directory offset.")
        }

        return (cdTotalEntries, cdOffset)
    }

    public func parseZipArchive(_ data: Data, password: String? = nil) throws -> [String: Data] {
        let directory = try findZipCentralDirectory(in: data)
        var results: [String: Data] = [:]
        var currentCDPos = directory.offset
        var totalUncompressedBytes: UInt64 = 0

        for _ in 0..<directory.entryCount {
            guard currentCDPos + 46 <= data.count else {
                throw PatchZipConverterError.corruptedArchive("Truncated central directory record.")
            }
            let sig = data.readUInt32(at: currentCDPos)
            guard sig == 0x02014b50 else {
                throw PatchZipConverterError.corruptedArchive("Invalid central directory header signature.")
            }

            let bitFlags = data.readUInt16(at: currentCDPos + 8)
            let compressionMethod = data.readUInt16(at: currentCDPos + 10)
            let dosTime = data.readUInt16(at: currentCDPos + 12)
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

            let isEncrypted = (bitFlags & 0x0001) != 0
            let payloadSize = (isEncrypted || compressionMethod != 0) ? Int(compressedSize) : Int(uncompressedSize)
            guard dataStart >= 0,
                  dataStart <= data.count,
                  payloadSize >= 0,
                  payloadSize <= data.count - dataStart else {
                throw PatchZipConverterError.corruptedArchive("Truncated file payload for: \(filename)")
            }

            let rawPayload = data.subdata(in: dataStart..<(dataStart + payloadSize))
            results[filename] = try extractZipEntryPayload(
                rawPayload: rawPayload,
                path: filename,
                compressionMethod: compressionMethod,
                bitFlags: bitFlags,
                dosTime: dosTime,
                crc32: entryCRC,
                uncompressedSize: Int(uncompressedSize),
                password: password
            )
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
        public let bitFlags: UInt16
        public let dosTime: UInt16

        public var isEncrypted: Bool {
            (bitFlags & 0x0001) != 0
        }

        public init(
            path: String,
            compressionMethod: UInt16,
            crc32: UInt32,
            compressedSize: UInt32,
            uncompressedSize: UInt32,
            localHeaderOffset: UInt64,
            payloadOffset: UInt64,
            bitFlags: UInt16 = 0,
            dosTime: UInt16 = 0
        ) {
            self.path = path
            self.compressionMethod = compressionMethod
            self.crc32 = crc32
            self.compressedSize = compressedSize
            self.uncompressedSize = uncompressedSize
            self.localHeaderOffset = localHeaderOffset
            self.payloadOffset = payloadOffset
            self.bitFlags = bitFlags
            self.dosTime = dosTime
        }
    }

    /// Đọc nhanh danh mục Central Directory của file ZIP mà KHÔNG giải nén bất kỳ payload nào.
    /// Thời gian thực thi < 2ms cho file 150 MB, tiêu tốn 0 byte RAM giải nén.
    public func readZipArchiveHeaders(from data: Data) throws -> [String: ZipArchiveEntryHeader] {
        let directory = try findZipCentralDirectory(in: data)
        var results: [String: ZipArchiveEntryHeader] = [:]
        var currentCDPos = directory.offset
        var totalUncompressedBytes: UInt64 = 0

        for _ in 0..<directory.entryCount {
            guard currentCDPos + 46 <= data.count else {
                throw PatchZipConverterError.corruptedArchive("Truncated central directory record.")
            }
            let sig = data.readUInt32(at: currentCDPos)
            guard sig == 0x02014b50 else {
                throw PatchZipConverterError.corruptedArchive("Invalid central directory header signature.")
            }

            let bitFlags = data.readUInt16(at: currentCDPos + 8)
            let compressionMethod = data.readUInt16(at: currentCDPos + 10)
            let dosTime = data.readUInt16(at: currentCDPos + 12)
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
                guard extraEnd <= data.count else {
                    throw PatchZipConverterError.corruptedArchive("Truncated extra field in central directory.")
                }
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

            let (expandedSum, expandedOverflow) = totalUncompressedBytes.addingReportingOverflow(uncompressedSize)
            guard !expandedOverflow,
                  !PatchPackageLimits.exceedsExpandedLimit(expandedSum),
                  compressedSize <= UInt64(UInt32.max),
                  uncompressedSize <= UInt64(UInt32.max) else {
                throw PatchZipConverterError.sizeLimitExceeded
            }
            totalUncompressedBytes = expandedSum

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
            let isEncrypted = (bitFlags & 0x0001) != 0
            let storedPayloadSize = (isEncrypted || compressionMethod != 0) ? compressedSize : uncompressedSize
            guard payloadOffset <= UInt64(data.count),
                  storedPayloadSize <= UInt64(data.count) - payloadOffset else {
                throw PatchZipConverterError.corruptedArchive("Truncated file payload for: \(filename)")
            }

            results[filename] = ZipArchiveEntryHeader(
                path: filename,
                compressionMethod: compressionMethod,
                crc32: entryCRC,
                compressedSize: UInt32(compressedSize),
                uncompressedSize: UInt32(uncompressedSize),
                localHeaderOffset: localHeaderOffset,
                payloadOffset: payloadOffset,
                bitFlags: bitFlags,
                dosTime: dosTime
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

    /// Giải nén cuốn chiếu từng entry từ tệp `.zip` (hỗ trợ cả mật khẩu PKZIP & ZIP64)
    /// trực tiếp ra đĩa qua `mmap` + `autoreleasepool`, giữ đỉnh RAM chỉ bằng ~1 tệp con
    /// thay vì nạp toàn bộ `[String: Data]` vào RAM gây tràn bộ nhớ (Jetsam) với gói lớn.
    @discardableResult
    public func extractZipArchiveToDirectory(
        at archiveURL: URL,
        into destinationDir: URL,
        password: String? = nil,
        stripMetadataEntries: Bool = false,
        shouldCancel: (() -> Bool)? = nil,
        progressHandler: ((_ extracted: Int, _ total: Int, _ entryName: String) -> Void)? = nil
    ) throws -> Int {
        let archiveSize = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(archiveSize)) else {
            throw PatchZipConverterError.sizeLimitExceeded
        }
        let mappedData = try Data(contentsOf: archiveURL, options: .alwaysMapped)
        let headers = try readZipArchiveHeaders(from: mappedData)
        let sortedKeys = headers.keys.sorted()
        let total = max(sortedKeys.count, 1)
        var written = 0
        var createdDirs = Set<String>()

        for rawPath in sortedKeys {
            if shouldCancel?() == true || Task.isCancelled {
                throw CancellationError()
            }
            guard let header = headers[rawPath] else { continue }
            let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            let parts = normalized
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { continue }
            if stripMetadataEntries {
                if parts.first == "__MACOSX"
                    || parts.last == ".DS_Store"
                    || parts.last?.lowercased() == "patch.json" {
                    continue
                }
            }

            var targetFile = destinationDir
            for (idx, part) in parts.enumerated() {
                targetFile.appendPathComponent(part, isDirectory: idx < parts.count - 1)
            }
            let parentDir = targetFile.deletingLastPathComponent()
            if createdDirs.insert(parentDir.path).inserted {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            try autoreleasepool {
                let entryData = try extractZipEntry(header: header, from: mappedData, password: password)
                try entryData.write(to: targetFile, options: .atomic)
            }
            written += 1
            if written == 1 || written == total || written % 4 == 0 {
                let lastName = parts.last ?? targetFile.lastPathComponent
                progressHandler?(written, total, lastName)
            }
        }
        return written
    }

    public func isZipPasswordProtected(url: URL) -> Bool {
        (try? readZipArchiveHeaders(from: url).values.contains { $0.isEncrypted }) ?? false
    }

    public func isZipPasswordProtected(data: Data) -> Bool {
        (try? readZipArchiveHeaders(from: data).values.contains { $0.isEncrypted }) ?? false
    }

    public func inspectZipMetadata(at url: URL, password: String? = nil) throws -> ZipInspectionInfo {
        let hasSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurity { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 4,
              data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) || data.prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]) else {
            throw PatchZipConverterError.corruptedArchive(AppLanguage.current.text("error.patch_converter.invalid_zip_magic"))
        }
        let headers = try readZipArchiveHeaders(from: data)
        let isProtected = headers.values.contains { $0.isEncrypted }
        let hasUnsupportedCompression = headers.values.contains { $0.compressionMethod != 0 && $0.compressionMethod != 8 }
        let activePaths = headers.keys.sorted().filter { path in
            let parts = path.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").map(String.init)
            guard !parts.isEmpty else { return false }
            if parts.contains(where: { $0.caseInsensitiveCompare("__MACOSX") == .orderedSame }) { return false }
            if let last = parts.last, last == ".DS_Store" || last.hasPrefix("._") { return false }
            return true
        }

        let classification = Self.classifyZipPaths(activePaths)
        var resolvedTarget = classification.detectedTarget
        let cleanPwd = password.flatMap { $0.isEmpty ? nil : $0 }
        var detectedName: String? = nil
        var isUnlocked = !isProtected

        if !hasUnsupportedCompression && (!isProtected || cleanPwd != nil) {
            let metaCandidates = ["settings.json", "patch.json", "manifest.json"]
            if let metaHeader = headers.values.first(where: { header in
                let last = (header.path as NSString).lastPathComponent.lowercased()
                return metaCandidates.contains(last)
            }) {
                if let jsonData = try? extractZipEntry(header: metaHeader, from: data, password: cleanPwd) {
                    isUnlocked = true
                    if let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        if let name = dict["name"] as? String {
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                detectedName = trimmed
                            }
                        }
                        if let bundles = dict["bundleIdentifiers"] as? [String],
                           let firstBundle = bundles.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !firstBundle.isEmpty {
                            resolvedTarget = firstBundle
                        }
                    }
                } else if metaHeader.isEncrypted {
                    isUnlocked = false
                }
            } else if isProtected, let zipPassword = cleanPwd {
                let encryptedHeaders = headers.values.filter { $0.isEncrypted }
                if let smallHeader = encryptedHeaders.filter({ $0.uncompressedSize <= 256 * 1024 }).min(by: { $0.uncompressedSize < $1.uncompressedSize }) {
                    isUnlocked = (try? extractZipEntry(header: smallHeader, from: data, password: zipPassword)) != nil
                } else if let anyHeader = encryptedHeaders.first {
                    let start = Int(anyHeader.payloadOffset)
                    let end = min(data.count, start + min(12, Int(anyHeader.compressedSize)))
                    if start >= 0, end - start >= 12 {
                        isUnlocked = ZipCryptoCodec.verifyHeaderOnly(
                            encryptedPayload: data.subdata(in: start..<end),
                            crc32: anyHeader.crc32,
                            bitFlags: anyHeader.bitFlags,
                            dosTime: anyHeader.dosTime,
                            password: zipPassword
                        )
                    }
                }
            }
        }

        if detectedName == nil {
            let dummyItems = activePaths.map { path in
                let parts = path.replacingOccurrences(of: "\\", with: "/")
                    .split(separator: "/").map(String.init)
                return (parts: parts, data: Data())
            }
            detectedName = Self.unwrapCommonRootWrappers(dummyItems).inferredName
        }

        return ZipInspectionInfo(
            isPasswordProtected: isProtected,
            suggestedName: detectedName,
            entryCount: activePaths.count,
            isUnlocked: isUnlocked,
            isValidPatchOrModArchive: classification.isValid,
            detectedTarget: resolvedTarget,
            hasUnsupportedCompression: hasUnsupportedCompression
        )
    }

    private func extractZipEntryPayload(
        rawPayload: Data,
        path: String,
        compressionMethod: UInt16,
        bitFlags: UInt16,
        dosTime: UInt16,
        crc32 entryCRC: UInt32,
        uncompressedSize: Int,
        password: String?
    ) throws -> Data {
        if compressionMethod == 99 {
            throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.zip_aes_unsupported"))
        }

        let isEncrypted = (bitFlags & 0x0001) != 0
        let clearPayload: Data
        if isEncrypted {
            let cleanPwd = password.flatMap { $0.isEmpty ? nil : $0 }
            guard let zipPassword = cleanPwd else {
                throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.zip_password_required"))
            }
            clearPayload = try ZipCryptoCodec.decrypt(
                rawPayload,
                crc32: entryCRC,
                bitFlags: bitFlags,
                dosTime: dosTime,
                password: zipPassword
            )
        } else {
            clearPayload = rawPayload
        }

        let result: Data
        if compressionMethod == 0 {
            result = clearPayload
        } else if compressionMethod == 8 {
            do {
                result = try decompressDeflate(clearPayload, expectedSize: uncompressedSize)
            } catch {
                if isEncrypted {
                    throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.zip_wrong_password"))
                }
                throw error
            }
        } else {
            throw PatchZipConverterError.unsupportedFormat(
                AppLanguage.current.text("error.patch_converter.unsupported_compression", compressionMethod)
            )
        }

        let shouldVerifyCRC = (isEncrypted && (entryCRC != 0 || result.isEmpty)) || (compressionMethod == 8 && entryCRC != 0)
        if shouldVerifyCRC {
            let calc = crc32Checksum(result)
            if calc != entryCRC {
                if isEncrypted {
                    throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.zip_wrong_password"))
                }
                throw PatchZipConverterError.corruptedArchive("CRC32 checksum mismatch for \(path)")
            }
        }
        return result
    }

    /// Trích xuất/giải nén có chọn lọc một entry duy nhất từ Data
    public func extractZipEntry(header: ZipArchiveEntryHeader, from sourceData: Data, password: String? = nil) throws -> Data {
        let byteCount = (header.isEncrypted || header.compressionMethod != 0)
            ? Int(header.compressedSize)
            : Int(header.uncompressedSize)
        let start = Int(header.payloadOffset)
        let end = start + byteCount
        guard start >= 0, byteCount >= 0, end <= sourceData.count else {
            throw PatchZipConverterError.corruptedArchive("Payload out of bounds for \(header.path)")
        }
        let rawPayload = sourceData.subdata(in: start..<end)
        return try extractZipEntryPayload(
            rawPayload: rawPayload,
            path: header.path,
            compressionMethod: header.compressionMethod,
            bitFlags: header.bitFlags,
            dosTime: header.dosTime,
            crc32: header.crc32,
            uncompressedSize: Int(header.uncompressedSize),
            password: password
        )
    }

    /// Trích xuất/giải nén có chọn lọc một entry duy nhất từ URL file ZIP
    public func extractZipEntry(header: ZipArchiveEntryHeader, from url: URL, password: String? = nil) throws -> Data {
        let hasSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurity { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try extractZipEntry(header: header, from: data, password: password)
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

    private func compressDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= Int(UInt32.max) else { return nil }
        let capacity = data.count + (data.count / 1000) + 64
        var destination = Data(count: capacity)
        var outSize = capacity
        let status: Int32 = destination.withUnsafeMutableBytes { dstBuf in
            data.withUnsafeBytes { srcBuf in
                guard let src = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                return totorox_compress_deflate(src, data.count, dst, &outSize)
            }
        }
        guard status == 0, outSize > 0, outSize < data.count else {
            return nil
        }
        destination.count = outSize
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
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.missing_magic"))
        }
        let body = data.dropFirst(magic.count)
        guard let plist = try PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as? [String: Any] else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }
        guard let packageIDString = plist["packageID"] as? String,
              let packageID = UUID(uuidString: packageIDString) else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_package_id"))
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
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
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

    private func envelopeMetadataOnlyData(envelope: ParsedEnvelope) throws -> Data {
        let magic = Data("3105PATCH\0".utf8)
        var metadata: [String: Any] = [
            "schemaVersion": envelope.schemaVersion,
            "packageID": envelope.packageIDRaw.isEmpty ? envelope.packageID.uuidString : envelope.packageIDRaw,
            "isPasswordProtected": envelope.isPasswordProtected,
        ]
        if let keyAADVersion = envelope.keyAADVersion { metadata["keyAADVersion"] = keyAADVersion }
        if let keyFingerprint = envelope.keyFingerprint { metadata["keyFingerprint"] = keyFingerprint }
        if let kdfSalt = envelope.kdfSalt { metadata["kdfSalt"] = kdfSalt }
        if let kdfIterations = envelope.kdfIterations { metadata["kdfIterations"] = kdfIterations }
        if let wrappedContentKey = envelope.wrappedContentKey { metadata["wrappedContentKey"] = wrappedContentKey }
        if let publicContentKey = envelope.publicContentKey { metadata["publicContentKey"] = publicContentKey }
        let serialized = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        return magic + serialized
    }

    private func unlockedEnvelopeHeader(from data: Data, contentKey: Data) throws -> Data {
        let envelope = try parseEnvelope(data)
        return try unlockedEnvelopeHeader(envelope: envelope, contentKey: contentKey)
    }

    private func unlockedEnvelopeHeader(envelope: ParsedEnvelope, contentKey: Data) throws -> Data {
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

    private struct EnvelopeHeaderMetadata {
        let envelope: ParsedEnvelope
        let encryptedPayloadRange: Range<UInt64>?
    }

    /// Đọc trực tiếp phần metadata + offset table ở cuối binary plist (`bplist00`) qua `FileHandle`
    /// mà không đọc phần `encryptedPayload` vào bộ nhớ, giúp xử lý tức thì gói `.3105` hàng trăm MB / vài GB.
    private func parseEnvelopeMetadata(at patchURL: URL) throws -> EnvelopeHeaderMetadata {
        let handle = try FileHandle(forReadingFrom: patchURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let packageMagic = Data("3105PATCH\0".utf8)
        let bplistMagic = Data("bplist00".utf8)
        let bplistStart = UInt64(packageMagic.count)
        let trailerSize: UInt64 = 32
        guard fileSize >= bplistStart + UInt64(bplistMagic.count) + trailerSize else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.missing_magic"))
        }

        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: packageMagic.count + bplistMagic.count),
              head.count == packageMagic.count + bplistMagic.count,
              head.prefix(packageMagic.count) == packageMagic else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.missing_magic"))
        }
        guard head.suffix(bplistMagic.count) == bplistMagic else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }

        try handle.seek(toOffset: fileSize - trailerSize)
        guard let trailer = try handle.read(upToCount: Int(trailerSize)), trailer.count == Int(trailerSize) else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }

        let offsetIntSize = Int(trailer[6])
        let objectRefSize = Int(trailer[7])
        guard [1, 2, 4, 8].contains(offsetIntSize),
              [1, 2, 4, 8].contains(objectRefSize) else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }

        func readBigEndian(_ bytes: Data, at offset: Int, count: Int) -> UInt64 {
            var val: UInt64 = 0
            let base = bytes.startIndex + offset
            for i in 0..<count {
                val = (val << 8) | UInt64(bytes[base + i])
            }
            return val
        }

        let numObjects = readBigEndian(trailer, at: 8, count: 8)
        let topObject = readBigEndian(trailer, at: 16, count: 8)
        let offsetTableRel = readBigEndian(trailer, at: 24, count: 8)
        let bplistSize = fileSize - bplistStart

        guard numObjects > 0, numObjects <= 1_000_000, topObject < numObjects else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }
        let (tableBytes, overflow) = numObjects.multipliedReportingOverflow(by: UInt64(offsetIntSize))
        guard !overflow,
              tableBytes <= 8_000_000,
              offsetTableRel >= UInt64(bplistMagic.count),
              offsetTableRel <= bplistSize - trailerSize,
              tableBytes <= bplistSize - trailerSize - offsetTableRel else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }

        try handle.seek(toOffset: bplistStart + offsetTableRel)
        guard let offsetTable = try handle.read(upToCount: Int(tableBytes)), offsetTable.count == Int(tableBytes) else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }
        let objectsEndOffset = bplistStart + offsetTableRel

        func objectFileOffset(index: UInt64) throws -> UInt64 {
            guard index < numObjects else {
                throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
            }
            let rel = readBigEndian(offsetTable, at: Int(index) * offsetIntSize, count: offsetIntSize)
            guard rel >= UInt64(bplistMagic.count), rel < offsetTableRel else {
                throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
            }
            return bplistStart + rel
        }

        func readExact(at offset: UInt64, count: Int) throws -> Data {
            guard count >= 0, offset <= objectsEndOffset, UInt64(count) <= objectsEndOffset - offset else {
                throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
            }
            if count == 0 { return Data() }
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
            }
            return chunk
        }

        func readLength(objectOffset: UInt64, lowNibble: UInt8) throws -> (length: UInt64, payloadOffset: UInt64) {
            if lowNibble < 0x0F {
                return (UInt64(lowNibble), objectOffset + 1)
            }
            let markerByte = try readExact(at: objectOffset + 1, count: 1)[0]
            guard (markerByte & 0xF0) == 0x10 else {
                throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
            }
            let pow2 = Int(markerByte & 0x0F)
            guard pow2 <= 3 else {
                throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
            }
            let byteCount = 1 << pow2
            let lenBytes = try readExact(at: objectOffset + 2, count: byteCount)
            return (readBigEndian(lenBytes, at: 0, count: byteCount), objectOffset + 2 + UInt64(byteCount))
        }

        func readString(at index: UInt64) throws -> String? {
            let offset = try objectFileOffset(index: index)
            let marker = try readExact(at: offset, count: 1)[0]
            let typeNibble = marker & 0xF0
            guard typeNibble == 0x50 || typeNibble == 0x60 else { return nil }
            let (charCount, payloadStart) = try readLength(objectOffset: offset, lowNibble: marker & 0x0F)
            guard charCount <= 1_048_576 else { return nil }
            let byteCount = typeNibble == 0x50 ? Int(charCount) : Int(charCount) * 2
            let bytes = try readExact(at: payloadStart, count: byteCount)
            return String(data: bytes, encoding: typeNibble == 0x50 ? .utf8 : .utf16BigEndian)
        }

        func readSmallValue(at index: UInt64) throws -> Any? {
            let offset = try objectFileOffset(index: index)
            let marker = try readExact(at: offset, count: 1)[0]
            let typeNibble = marker & 0xF0
            let low = marker & 0x0F
            switch typeNibble {
            case 0x00:
                if low == 0x08 { return false }
                if low == 0x09 { return true }
                return nil
            case 0x10:
                let pow2 = Int(low)
                guard pow2 <= 3 else { return nil }
                let byteCount = 1 << pow2
                let rawBytes = try readExact(at: offset + 1, count: byteCount)
                let raw = readBigEndian(rawBytes, at: 0, count: byteCount)
                let parsed = byteCount == 8 ? Int(exactly: Int64(bitPattern: raw)) : Int(exactly: raw)
                if let parsed {
                    return parsed
                }
                return nil
            case 0x40:
                let (len, payloadStart) = try readLength(objectOffset: offset, lowNibble: low)
                guard len <= 16 * 1024 * 1024 else { return nil }
                return try readExact(at: payloadStart, count: Int(len))
            case 0x50:
                let (len, payloadStart) = try readLength(objectOffset: offset, lowNibble: low)
                guard len <= 1_048_576 else { return nil }
                let bytes = try readExact(at: payloadStart, count: Int(len))
                return String(data: bytes, encoding: .utf8)
            case 0x60:
                let (len, payloadStart) = try readLength(objectOffset: offset, lowNibble: low)
                guard len <= 524_288 else { return nil }
                let bytes = try readExact(at: payloadStart, count: Int(len) * 2)
                return String(data: bytes, encoding: .utf16BigEndian)
            default:
                return nil
            }
        }

        let topOffset = try objectFileOffset(index: topObject)
        let topMarker = try readExact(at: topOffset, count: 1)[0]
        guard (topMarker & 0xF0) == 0xD0 else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }
        let (entryCount, refsStart) = try readLength(objectOffset: topOffset, lowNibble: topMarker & 0x0F)
        guard entryCount <= 10_000 else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_envelope_plist"))
        }
        let refsData = try readExact(at: refsStart, count: Int(entryCount) * 2 * objectRefSize)

        var metadata: [String: Any] = [:]
        var encryptedPayloadRange: Range<UInt64>? = nil
        let countInt = Int(entryCount)
        for i in 0..<countInt {
            let keyRef = readBigEndian(refsData, at: i * objectRefSize, count: objectRefSize)
            let valRef = readBigEndian(refsData, at: (countInt + i) * objectRefSize, count: objectRefSize)
            guard let key = try readString(at: keyRef) else { continue }
            if key == "encryptedPayload" {
                let valOffset = try objectFileOffset(index: valRef)
                let valMarker = try readExact(at: valOffset, count: 1)[0]
                if (valMarker & 0xF0) == 0x40 {
                    let (len, payloadStart) = try readLength(objectOffset: valOffset, lowNibble: valMarker & 0x0F)
                    if payloadStart <= objectsEndOffset, len <= objectsEndOffset - payloadStart {
                        encryptedPayloadRange = payloadStart..<(payloadStart + len)
                    }
                }
            } else if Self.envelopeMetadataKeys.contains(key), let val = try readSmallValue(at: valRef) {
                metadata[key] = val
            }
        }

        guard let packageIDString = metadata["packageID"] as? String,
              let packageID = UUID(uuidString: packageIDString) else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.invalid_package_id"))
        }
        let envelope = ParsedEnvelope(
            packageID: packageID,
            packageIDRaw: packageIDString,
            schemaVersion: metadata["schemaVersion"] as? Int ?? 0,
            keyAADVersion: metadata["keyAADVersion"] as? Int,
            isPasswordProtected: metadata["isPasswordProtected"] as? Bool ?? false,
            encryptedPayload: nil,
            keyFingerprint: metadata["keyFingerprint"] as? Data,
            kdfSalt: metadata["kdfSalt"] as? Data,
            kdfIterations: metadata["kdfIterations"] as? Int,
            wrappedContentKey: metadata["wrappedContentKey"] as? Data,
            publicContentKey: metadata["publicContentKey"] as? Data
        )
        return EnvelopeHeaderMetadata(envelope: envelope, encryptedPayloadRange: encryptedPayloadRange)
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
            throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.pbkdf2_failed", status))
        }
        return derivedKey
    }

    private func unwrapContentKeyLocally(envelope: ParsedEnvelope, password: String?) throws -> Data {
        let cleanPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanPassword.isEmpty else {
            throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.password_required"))
        }
        guard let salt = envelope.kdfSalt, !salt.isEmpty,
              let wrapped = envelope.wrappedContentKey, !wrapped.isEmpty else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.missing_kdf_or_wrapped_key"))
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

        throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.wrong_3105_password"))
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
        var idStrings: [String] = []
        for candidate in [packageIDRaw, packageID.uuidString, packageID.uuidString.lowercased()] {
            if !candidate.isEmpty && !idStrings.contains(candidate) {
                idStrings.append(candidate)
            }
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
        throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.payload_decrypt_failed"))
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

        throw PatchZipConverterError.cryptoFailed(AppLanguage.current.text("error.patch_converter.aes_gcm_decrypt_failed"))
    }

    private func projectZipEntryPath(for rule: PatchRule, fallbackBundle: String) -> String? {
        let bundleID = rule.bundleID.isEmpty ? fallbackBundle : rule.bundleID
        var relativePath = rule.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relativePath.hasPrefix("payload/\(bundleID)/") {
            relativePath = String(relativePath.dropFirst("payload/\(bundleID)/".count))
        } else if relativePath.hasPrefix("\(bundleID)/") {
            relativePath = String(relativePath.dropFirst("\(bundleID)/".count))
        }
        if relativePath.lowercased().hasPrefix("documents/resources/") {
            relativePath = String(relativePath.dropFirst("documents/".count))
        }
        guard !relativePath.isEmpty else { return nil }
        return relativePath
    }

    func buildProjectZip(_ project: PatchProject, password: String? = nil) throws -> Data {
        let fallbackBundle = project.bundleIdentifiers.first(where: { !$0.isEmpty }) ?? "com.garena.game.kgvn"
        var payloadEntries: [(path: String, data: Data)] = []
        var seenPayloadPaths = Set<String>()
        for rule in project.rules {
            guard let zipEntryPath = projectZipEntryPath(for: rule, fallbackBundle: fallbackBundle) else { continue }
            if seenPayloadPaths.insert(zipEntryPath).inserted {
                payloadEntries.append((path: zipEntryPath, data: rule.replacementData))
            }
        }
        return try buildZipArchive(entries: payloadEntries, password: password)
    }

    /// Stream từng rule của `PatchProject` thành `.zip` xuống đĩa qua `ZipArchiveWriter`
    /// để tránh giữ thêm bản sao toàn bộ gói `.zip` trong RAM.
    func writeProjectZip(_ project: PatchProject, to destinationURL: URL, password: String? = nil) throws {
        let fallbackBundle = project.bundleIdentifiers.first(where: { !$0.isEmpty }) ?? "com.garena.game.kgvn"
        let cleanPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        let writer = try ZipArchiveWriter(destinationURL: destinationURL, fileManager: fileManager)
        defer { writer.cancel() }
        var seenPayloadPaths = Set<String>()
        for rule in project.rules {
            guard let zipEntryPath = projectZipEntryPath(for: rule, fallbackBundle: fallbackBundle) else { continue }
            if seenPayloadPaths.insert(zipEntryPath).inserted {
                try writer.add(path: zipEntryPath, data: rule.replacementData, password: cleanPassword)
            }
        }
        try writer.finish()
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

    private static func isVersionSegment(_ segment: String) -> Bool {
        let parts = segment.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
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

    private struct ArchiveStructureClassification {
        let isValid: Bool
        let hasManifestOrSettings: Bool
        let hasExplicitContainer: Bool
        let hasContainerFolder: Bool
        let hasAovStructure: Bool
        let detectedAovVersion: String?
        let explicitAppBundles: [String]
        let detectedTarget: String?
    }

    private static let aovStructureMarkers: Set<String> = [
        "resources", "databin", "ages", "assetrefs", "prefab_characters",
        "thanos", "commonactions", "sound", "sound_vn", "languages",
        "assetbundle", "assetbundles", "behaviac", "lua_signed"
    ]

    private static let aovStructureFileExtensions: Set<String> = [
        ".pkg.bytes", ".assetbundle", ".mses", ".bytes", ".bnk", ".wem"
    ]

    private static let aovStructureKnownFiles: Set<String> = [
        "languagemap.txt", "version.txt"
    ]

    private static func classifyZipPaths(_ rawPaths: [String]) -> ArchiveStructureClassification {
        let rawItems: [(parts: [String], data: Data)] = rawPaths.sorted().compactMap { rawName in
            let cleaned = rawName.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !cleaned.isEmpty, !rawName.hasSuffix("/") else { return nil }
            let parts = cleaned.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { return nil }
            if parts.contains(where: { $0.caseInsensitiveCompare("__MACOSX") == .orderedSame }) { return nil }
            if let last = parts.last, last == ".DS_Store" || last.hasPrefix("._") { return nil }
            return (parts: parts, data: Data())
        }
        let items = unwrapCommonRootWrappers(rawItems).items
        return classifyUnwrappedItems(items)
    }

    private static func classifyUnwrappedItems(_ items: [(parts: [String], data: Data)]) -> ArchiveStructureClassification {
        guard !items.isEmpty else {
            return ArchiveStructureClassification(
                isValid: false,
                hasManifestOrSettings: false,
                hasExplicitContainer: false,
                hasContainerFolder: false,
                hasAovStructure: false,
                detectedAovVersion: nil,
                explicitAppBundles: [],
                detectedTarget: nil
            )
        }

        let metadataRoots: Set<String> = ["patch.json", "manifest.json", "settings.json"]
        let containerFolderRoots: Set<String> = ["documents", "library", "tmp"]
        var hasManifestOrSettings = false
        var hasExplicitContainer = false
        var hasContainerFolder = false
        var hasAovStructure = false
        var detectedAovVersion: String?
        var explicitAppBundles: [String] = []
        var firstExplicitBundle: String?

        for item in items {
            if item.parts.count == 1 && metadataRoots.contains(item.parts[0].lowercased()) {
                hasManifestOrSettings = true
                continue
            }
            if let classified = classifyContainerParts(item.parts) {
                hasExplicitContainer = true
                firstExplicitBundle = firstExplicitBundle ?? classified.bundleID
                if classified.containerKind == "application" && !explicitAppBundles.contains(classified.bundleID) {
                    explicitAppBundles.append(classified.bundleID)
                }
                let relParts = classified.relativePath.split(separator: "/").map(String.init)
                if relParts.contains(where: { aovStructureMarkers.contains($0.lowercased()) }) {
                    hasAovStructure = true
                }
                continue
            }
            if let firstLower = item.parts.first?.lowercased(),
               containerFolderRoots.contains(firstLower),
               item.parts.count >= 2 {
                hasContainerFolder = true
            }
            for (idx, seg) in item.parts.enumerated() {
                let lowerSeg = seg.lowercased()
                if aovStructureMarkers.contains(lowerSeg) {
                    hasAovStructure = true
                    if lowerSeg == "resources", idx + 1 < item.parts.count, isVersionSegment(item.parts[idx + 1]) {
                        detectedAovVersion = detectedAovVersion ?? item.parts[idx + 1]
                    }
                } else if idx == 0 && item.parts.count > 1 && isVersionSegment(seg) {
                    hasAovStructure = true
                    detectedAovVersion = detectedAovVersion ?? seg
                }
            }
            if AovModMergerEngine.normalizeAovPath(item.parts.joined(separator: "/"), fallbackVersion: nil) != nil {
                hasAovStructure = true
            }
            let lastLower = item.parts.last?.lowercased() ?? ""
            if aovStructureKnownFiles.contains(lastLower)
                || aovStructureFileExtensions.contains(where: { lastLower.hasSuffix($0) }) {
                hasAovStructure = true
            }
        }

        let isValid = hasManifestOrSettings || hasExplicitContainer || hasContainerFolder || hasAovStructure
        let detectedTarget: String?
        if let bundle = explicitAppBundles.first ?? firstExplicitBundle {
            detectedTarget = bundle
        } else if hasAovStructure {
            detectedTarget = "com.garena.game.kgvn"
        } else if hasManifestOrSettings || hasContainerFolder {
            detectedTarget = "Documents / Container"
        } else {
            detectedTarget = nil
        }

        return ArchiveStructureClassification(
            isValid: isValid,
            hasManifestOrSettings: hasManifestOrSettings,
            hasExplicitContainer: hasExplicitContainer,
            hasContainerFolder: hasContainerFolder,
            hasAovStructure: hasAovStructure,
            detectedAovVersion: detectedAovVersion,
            explicitAppBundles: explicitAppBundles,
            detectedTarget: detectedTarget
        )
    }

    private static func unwrapCommonRootWrappers(
        _ rawItems: [(parts: [String], data: Data)]
    ) -> (items: [(parts: [String], data: Data)], inferredName: String?) {
        let protectedRoots: Set<String> = [
            "application", "appgroup", "systemappgroup", "payload",
            "documents", "library", "tmp",
            "resources", "databin", "ages", "assetrefs", "prefab_characters",
            "thanos", "commonactions", "sound", "sound_vn", "languages",
            "assetbundle", "assetbundles", "behaviac", "lua_signed"
        ]
        var current = rawItems
        var lastStripped: String?
        for _ in 0..<4 {
            guard !current.isEmpty,
                  current.allSatisfy({ $0.parts.count > 1 }),
                  let candidate = current.first?.parts.first else {
                break
            }
            let lower = candidate.lowercased()
            if protectedRoots.contains(lower)
                || isLikelyBundleIDSegment(candidate)
                || isVersionSegment(candidate) {
                break
            }
            guard current.allSatisfy({ $0.parts.first == candidate }) else {
                break
            }
            lastStripped = candidate
            current = current.map { (parts: Array($0.parts.dropFirst()), data: $0.data) }
        }
        return (current, lastStripped)
    }

    private static func classifyContainerParts(
        _ parts: [String]
    ) -> (containerKind: String, bundleID: String, relativePath: String)? {
        guard !parts.isEmpty else { return nil }
        let rootLower = parts[0].lowercased()
        if parts.count >= 3 {
            let targetID = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let relPath = parts.dropFirst(2).joined(separator: "/")
            if !targetID.isEmpty, targetID != ".", targetID != "..", !relPath.isEmpty {
                switch rootLower {
                case "application":
                    return ("application", targetID, relPath)
                case "appgroup":
                    return ("appGroup", targetID, relPath)
                case "systemappgroup":
                    return ("systemAppGroup", targetID, relPath)
                case "payload" where isLikelyBundleIDSegment(targetID):
                    return ("application", targetID, relPath)
                default:
                    break
                }
            }
        }
        if parts.count >= 2, isLikelyBundleIDSegment(parts[0]) {
            let relPath = parts.dropFirst().joined(separator: "/")
            if !relPath.isEmpty {
                return ("application", parts[0], relPath)
            }
        }
        return nil
    }

    func buildPatchProject(
        fromZipData zipData: Data,
        sourcePassword: String? = nil,
        customProjectName: String? = nil
    ) throws -> PatchProject {
        try buildPatchProjectWithSettings(
            fromZipData: zipData,
            sourcePassword: sourcePassword,
            customProjectName: customProjectName
        ).project
    }

    private func buildPatchProjectWithSettings(
        fromZipData zipData: Data,
        sourcePassword: String? = nil,
        customProjectName: String? = nil
    ) throws -> (project: PatchProject, settings: [Any]) {
        let entries = try parseZipArchive(zipData, password: sourcePassword)
        let rawItems: [(parts: [String], data: Data)] = entries.keys.sorted().compactMap { rawName in
            let cleaned = rawName.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = cleaned.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { return nil }
            if parts.contains(where: { $0.caseInsensitiveCompare("__MACOSX") == .orderedSame }) { return nil }
            if let last = parts.last, last == ".DS_Store" || last.hasPrefix("._") { return nil }
            return (parts: parts, data: entries[rawName] ?? Data())
        }
        let unwrapped = Self.unwrapCommonRootWrappers(rawItems)
        let items = unwrapped.items

        var manifest: [String: Any]?
        for name in ["patch.json", "manifest.json"] {
            let foundData = entries[name]
                ?? items.first(where: { $0.parts.count == 1 && $0.parts[0].lowercased() == name })?.data
            if let data = foundData,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                manifest = json
                break
            }
        }

        var settingsPlist: [Any] = []
        var settingsName: String?
        var settingsAuthor: String?
        var settingsIsPrivate: Bool?
        if let settingsItem = items.first(where: { $0.parts.count == 1 && $0.parts[0].lowercased() == "settings.json" }),
           let json = try? JSONSerialization.jsonObject(with: settingsItem.data) {
            if let array = json as? [Any] {
                settingsPlist = array
            } else if let dict = json as? [String: Any] {
                settingsName = dict["name"] as? String
                settingsAuthor = dict["author"] as? String
                settingsIsPrivate = dict["isPrivate"] as? Bool
                if let fields = dict["fields"] as? [Any] {
                    settingsPlist = fields
                } else if let nested = dict["settings"] as? [Any] {
                    settingsPlist = nested
                }
            }
        }

        func normalizedBundle(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "com.garena.game.kgvn" : trimmed
        }

        func payloadFor(relativePath: String, payloadPath: String, bundleID: String, containerKind: String) -> Data {
            let target = normalizedBundle(bundleID)
            let kindFolder: String
            switch containerKind {
            case "appGroup": kindFolder = "AppGroup"
            case "systemAppGroup": kindFolder = "SystemAppGroup"
            default: kindFolder = "Application"
            }
            let candidates = [
                payloadPath,
                "\(kindFolder)/\(target)/\(relativePath)",
                "\(target)/\(relativePath)",
                "payload/\(target)/\(relativePath)",
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
                let containerKind = (item["containerKind"] as? String) ?? "application"
                let payload = payloadFor(
                    relativePath: relativePath,
                    payloadPath: (item["payloadPath"] as? String) ?? "",
                    bundleID: bundleID,
                    containerKind: containerKind
                )
                let rule = PatchRule(
                    id: (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    bundleID: bundleID,
                    relativePath: relativePath,
                    replacementFilename: (item["replacementFilename"] as? String) ?? (relativePath as NSString).lastPathComponent,
                    replacementData: payload,
                    operation: (item["operation"] as? String) ?? "replace",
                    containerKind: containerKind
                )
                rules.append(rule)
            }
            if !rules.isEmpty {
                let appBundles = (manifest["bundleIdentifiers"] as? [String])
                    ?? rules.filter { $0.containerKind == "application" }.map(\.bundleID)
                let bundleIdentifiers = appBundles.isEmpty ? [rules[0].bundleID] : appBundles
                let directoriesRaw = (manifest["directories"] as? [[String: Any]]) ?? []
                let directories = directoriesRaw.map { dir in
                    PatchDirectory(
                        id: (dir["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                        bundleID: normalizedBundle((dir["bundleID"] as? String) ?? ""),
                        relativePath: (dir["relativePath"] as? String) ?? ""
                    )
                }
                let project = PatchProject(
                    id: (manifest["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    name: (manifest["name"] as? String) ?? "Patch",
                    author: (manifest["author"] as? String) ?? "",
                    isPrivate: (manifest["isPrivate"] as? Bool) ?? false,
                    bundleIdentifiers: bundleIdentifiers,
                    directories: directories,
                    rules: rules
                )
                return (project, settingsPlist)
            }
        }

        let classification = Self.classifyUnwrappedItems(items)
        guard classification.isValid else {
            throw PatchZipConverterError.invalidProject(
                AppLanguage.current.text("error.patch_converter.zip_unrecognized_structure")
            )
        }
        let hasAovStructure = classification.hasAovStructure
        let detectedAovVersion = classification.detectedAovVersion
        let explicitAppBundles = classification.explicitAppBundles
        let metadataRoots: Set<String> = ["patch.json", "manifest.json", "settings.json"]

        let fallbackBundleID = explicitAppBundles.first
            ?? (hasAovStructure ? "com.garena.game.kgvn" : "com.apple.mobile.MobileHouseArrest")
        let fallbackAovVersion = detectedAovVersion ?? "1.64.1"
        let containerRoots: [String: String] = [
            "documents": "Documents",
            "library": "Library",
            "tmp": "tmp",
        ]

        var rules: [PatchRule] = []
        var seenApplicationBundles: [String] = []

        for item in items {
            if item.parts.count == 1 && metadataRoots.contains(item.parts[0].lowercased()) {
                continue
            }

            let containerKind: String
            let targetBundleID: String
            let relativePath: String

            if let classified = Self.classifyContainerParts(item.parts) {
                containerKind = classified.containerKind
                targetBundleID = classified.bundleID
                relativePath = classified.relativePath
            } else {
                containerKind = "application"
                targetBundleID = fallbackBundleID
                let firstLower = item.parts[0].lowercased()
                if let canonicalRoot = containerRoots[firstLower], item.parts.count >= 2 {
                    relativePath = ([canonicalRoot] + item.parts.dropFirst()).joined(separator: "/")
                } else if hasAovStructure,
                          let aovNormalized = AovModMergerEngine.normalizeAovPath(
                              item.parts.joined(separator: "/"),
                              fallbackVersion: fallbackAovVersion
                          ) {
                    relativePath = "Documents/\(aovNormalized)"
                } else {
                    relativePath = item.parts.joined(separator: "/")
                }
            }

            guard !relativePath.isEmpty else { continue }
            if containerKind == "application", !seenApplicationBundles.contains(targetBundleID) {
                seenApplicationBundles.append(targetBundleID)
            }
            rules.append(
                PatchRule(
                    bundleID: targetBundleID,
                    relativePath: relativePath,
                    replacementFilename: (relativePath as NSString).lastPathComponent,
                    replacementData: item.data,
                    operation: "replace",
                    containerKind: containerKind
                )
            )
        }
        guard !rules.isEmpty else {
            throw PatchZipConverterError.invalidProject(AppLanguage.current.text("error.patch_converter.zip_no_rules"))
        }
        let customName = customProjectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let patchName = (customName?.isEmpty == false ? customName : nil)
            ?? (settingsName?.isEmpty == false ? settingsName : nil)
            ?? (unwrapped.inferredName?.isEmpty == false ? unwrapped.inferredName : nil)
            ?? "Converted Patch"
        let patchAuthor = (settingsAuthor?.isEmpty == false ? settingsAuthor : nil) ?? "Totorox"
        let project = PatchProject(
            name: patchName,
            author: patchAuthor,
            isPrivate: settingsIsPrivate ?? false,
            bundleIdentifiers: seenApplicationBundles.isEmpty ? [fallbackBundleID] : seenApplicationBundles,
            rules: rules
        )
        return (project, settingsPlist)
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
            "keyAADVersion": schemaVersion,
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
            let iterations = response.kdfIterations ?? PatchPackageLimits.defaultKDFIterations
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

    private func sealPayload(
        project: PatchProject,
        contentKey: Data,
        packageID: UUID,
        schemaVersion: Int,
        settingsPlist: [Any] = []
    ) throws -> Data {
        let plistData = try Self.native3105PayloadPlist(
            project: project,
            packageID: packageID,
            settingsPlist: settingsPlist
        )
        let aad = Data("3105PATCH/v\(schemaVersion)/payload/\(packageID.uuidString)".utf8)
        return try aesGCMSeal(plaintext: plistData, key: contentKey, aad: aad)
    }

    /// Dựng payload đúng chuẩn app 3105 gốc (schema v9, phân tích từ gói do admin 3105 xuất):
    /// `{ project: {id, name, author, isPrivate, createdAt, updatedAt, bundleIdentifiers,
    ///   appGroupIdentifiers, systemAppGroupIdentifiers, settings, directories, rules},
    ///   replacementDigests: { ruleID: SHA256(replacementData) } }`.
    /// `directories` phải liệt kê MỌI thư mục cha của từng rule (Documents, Documents/Resources,
    /// Documents/Resources/1.64.1, ...) kèm `containerKind`; thiếu mục này app 3105 báo
    /// "Không tìm thấy hoặc không thể mở đích patch 1.64.1".
    static func native3105PayloadPlist(
        project: PatchProject,
        packageID: UUID,
        settingsPlist: [Any] = []
    ) throws -> Data {
        let fallbackBundle = project.bundleIdentifiers.first(where: { !$0.isEmpty }) ?? "com.garena.game.kgvn"
        var digests: [String: Data] = [:]
        var ruleDicts: [[String: Any]] = []
        var dirKeys: [String: (bundle: String, kind: String, path: String)] = [:]
        var appBundles: [String] = []
        var appGroupIDs: [String] = []
        var sysAppGroupIDs: [String] = []

        for rule in project.rules {
            let bundleID = rule.bundleID.isEmpty ? fallbackBundle : rule.bundleID
            let kind = rule.containerKind.isEmpty ? "application" : rule.containerKind
            let relativePath = rule.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }
            switch kind {
            case "appGroup":
                if !appGroupIDs.contains(bundleID) { appGroupIDs.append(bundleID) }
            case "systemAppGroup":
                if !sysAppGroupIDs.contains(bundleID) { sysAppGroupIDs.append(bundleID) }
            default:
                if !appBundles.contains(bundleID) { appBundles.append(bundleID) }
            }
            let ruleID = rule.id.uuidString
            ruleDicts.append([
                "id": ruleID,
                "operation": rule.operation.isEmpty ? "replace" : rule.operation,
                "containerKind": kind,
                "bundleID": bundleID,
                "relativePath": relativePath,
                "replacementFilename": rule.replacementFilename.isEmpty
                    ? (relativePath as NSString).lastPathComponent : rule.replacementFilename,
                "replacementData": rule.replacementData,
            ])
            digests[ruleID] = Data(SHA256.hash(data: rule.replacementData))

            let parts = relativePath.split(separator: "/").map(String.init)
            if parts.count > 1 {
                for depth in 1..<parts.count {
                    let dirPath = parts.prefix(depth).joined(separator: "/")
                    dirKeys["\(kind)|\(bundleID)|\(dirPath)"] = (bundleID, kind, dirPath)
                }
            }
        }
        for dir in project.directories where !dir.relativePath.isEmpty {
            dirKeys["application|\(dir.bundleID)|\(dir.relativePath)"] = (dir.bundleID, "application", dir.relativePath)
        }
        let directories: [[String: Any]] = dirKeys.values
            .sorted { ($0.kind, $0.bundle, $0.path) < ($1.kind, $1.bundle, $1.path) }
            .map { ["id": UUID().uuidString, "containerKind": $0.kind, "bundleID": $0.bundle, "relativePath": $0.path] }

        let resolvedAppBundles = (appBundles.isEmpty && appGroupIDs.isEmpty && sysAppGroupIDs.isEmpty)
            ? [fallbackBundle]
            : appBundles
        let projectDict: [String: Any] = [
            "id": packageID.uuidString,
            "name": project.name.isEmpty ? "Patch" : project.name,
            "author": project.author,
            "isPrivate": project.isPrivate,
            "createdAt": project.createdAt,
            "updatedAt": Date(),
            "bundleIdentifiers": resolvedAppBundles,
            "appGroupIdentifiers": appGroupIDs,
            "systemAppGroupIdentifiers": sysAppGroupIDs,
            "settings": settingsPlist,
            "directories": directories,
            "rules": ruleDicts,
        ]
        let root: [String: Any] = ["project": projectDict, "replacementDigests": digests]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
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
