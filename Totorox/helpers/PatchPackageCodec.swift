import CommonCrypto
import CryptoKit
import Foundation
import Security

enum PatchPackageCodec {
    private static let magic = Data("3105PATCH\0".utf8)
    static let latestSchemaVersion = 3
    private static let minimumSchemaVersion = 1

    private struct Envelope: Codable {
        let schemaVersion: Int
        let keyAADVersion: Int?
        let packageID: UUID
        let isPasswordProtected: Bool
        let kdfSalt: Data?
        let kdfIterations: Int?
        let wrappedContentKey: Data?
        let publicContentKey: Data?
        let keyFingerprint: Data
        let encryptedPayload: Data
    }

    private struct Payload: Codable {
        let project: PatchProject
        let replacementDigests: [String: Data]?

        private enum CodingKeys: String, CodingKey {
            case project
            case replacementDigests
        }

        init(project: PatchProject, replacementDigests: [String: Data]?) {
            self.project = project
            self.replacementDigests = replacementDigests
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            project = try container.decode(PatchProject.self, forKey: .project)
            replacementDigests = try? container.decodeIfPresent([String: Data].self, forKey: .replacementDigests)
        }
    }

    static func encodeNew(
        project: PatchProject,
        password: String?,
        kdfIterations: Int = PatchPackageLimits.defaultKDFIterations
    ) throws -> EncodedPatchPackage {
        try encode(
            project: project,
            password: password,
            schemaVersion: latestSchemaVersion,
            kdfIterations: kdfIterations
        )
    }

    static func encodeLegacyV1(
        project: PatchProject,
        password: String?,
        kdfIterations: Int = PatchPackageLimits.defaultKDFIterations
    ) throws -> EncodedPatchPackage {
        try encode(
            project: project,
            password: password,
            schemaVersion: 1,
            kdfIterations: kdfIterations
        )
    }

    static func encodeLegacyV2(
        project: PatchProject,
        password: String?,
        kdfIterations: Int = PatchPackageLimits.defaultKDFIterations
    ) throws -> EncodedPatchPackage {
        try encode(
            project: project,
            password: password,
            schemaVersion: 2,
            kdfIterations: kdfIterations
        )
    }

    static func encode(
        project: PatchProject,
        password: String?,
        schemaVersion: Int,
        kdfIterations: Int = PatchPackageLimits.defaultKDFIterations
    ) throws -> EncodedPatchPackage {
        try validate(project)
        guard schemaVersion >= minimumSchemaVersion else {
            throw PatchPackageError.unsupportedVersion
        }
        let contentKey = try randomData(count: 32)
        let protected = !(password ?? "").isEmpty
        guard !project.isPrivate || protected else {
            throw PatchPackageError.privatePatchRequiresPassword
        }
        let salt: Data?
        let iterations: Int?
        let wrappedKey: Data?
        let publicKey: Data?

        if protected {
            guard let password, password.utf8.count <= PatchPackageLimits.maximumPasswordBytes,
                  kdfIterations >= PatchPackageLimits.minimumKDFIterations,
                  kdfIterations <= PatchPackageLimits.maximumKDFIterations
            else {
                throw PatchPackageError.invalidProject
            }
            salt = try randomData(count: 16)
            iterations = kdfIterations
            let wrappingKey = try deriveKey(password: password, salt: salt!, iterations: kdfIterations)
            wrappedKey = try seal(
                contentKey,
                key: wrappingKey,
                aad: keyAAD(for: project.id, version: schemaVersion)
            )
            publicKey = nil
        } else {
            salt = nil
            iterations = nil
            wrappedKey = nil
            publicKey = contentKey
        }

        let envelope = try makeEnvelope(
            project: project,
            schemaVersion: schemaVersion,
            keyAADVersion: protected ? schemaVersion : nil,
            contentKey: contentKey,
            isPasswordProtected: protected,
            kdfSalt: salt,
            kdfIterations: iterations,
            wrappedContentKey: wrappedKey,
            publicContentKey: publicKey
        )
        return EncodedPatchPackage(data: try serialize(envelope), contentKey: contentKey)
    }

    static func inspect(_ data: Data) throws -> PatchPackageSummary {
        let envelope = try parseEnvelope(data)
        return PatchPackageSummary(
            packageID: envelope.packageID,
            schemaVersion: envelope.schemaVersion,
            isPasswordProtected: envelope.isPasswordProtected,
            keyFingerprint: envelope.keyFingerprint
        )
    }

    static func decode(_ data: Data, password: String?) throws -> DecodedPatchPackage {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(data.count)) else {
            throw PatchPackageError.sizeLimitExceeded
        }
        if !(data.count > magic.count && data.prefix(magic.count) == magic) {
            if let directPayload = try? PropertyListDecoder().decode(Payload.self, from: data) {
                return DecodedPatchPackage(
                    project: normalizeProject(directPayload.project),
                    contentKey: Data(repeating: 0, count: 32)
                )
            }
            if let directProject = try? PropertyListDecoder().decode(PatchProject.self, from: data) {
                return DecodedPatchPackage(
                    project: normalizeProject(directProject),
                    contentKey: Data(repeating: 0, count: 32)
                )
            }
        }
        do {
            let envelope = try parseEnvelope(data)
            let contentKey: Data
            if envelope.isPasswordProtected {
                if let password, !password.isEmpty,
                   password.utf8.count <= PatchPackageLimits.maximumPasswordBytes,
                   let salt = envelope.kdfSalt,
                   let iterations = envelope.kdfIterations,
                   let wrappedKey = envelope.wrappedContentKey {
                    let wrappingKey = try deriveKey(password: password, salt: salt, iterations: iterations)
                    let preferredVersion = envelope.keyAADVersion ?? envelope.schemaVersion
                    contentKey = try openWithFallbackVersions(
                        wrappedKey,
                        key: wrappingKey,
                        packageID: envelope.packageID,
                        preferredVersion: preferredVersion,
                        isKeyAAD: true
                    )
                } else if let storedKey = envelope.publicContentKey, storedKey.count == 32 {
                    contentKey = storedKey
                } else {
                    throw PatchPackageError.invalidPasswordOrCorruptedPackage
                }
            } else {
                guard let storedKey = envelope.publicContentKey else {
                    throw PatchPackageError.invalidPasswordOrCorruptedPackage
                }
                contentKey = storedKey
            }
            return try decode(envelope: envelope, contentKey: contentKey)
        } catch let error as PatchPackageError {
            switch error {
            case .unsupportedFormat, .sizeLimitExceeded:
                throw error
            default:
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        } catch {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
    }

    static func decode(_ data: Data, contentKey: Data) throws -> DecodedPatchPackage {
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(data.count)) else {
            throw PatchPackageError.sizeLimitExceeded
        }
        do {
            let envelope = try parseEnvelope(data)
            return try decode(envelope: envelope, contentKey: contentKey)
        } catch let error as PatchPackageError {
            switch error {
            case .unsupportedFormat, .sizeLimitExceeded:
                throw error
            default:
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        } catch {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
    }

    static func update(
        _ originalData: Data,
        project: PatchProject,
        contentKey: Data,
        schemaVersion requestedSchemaVersion: Int? = nil
    ) throws -> Data {
        let oldEnvelope = try parseEnvelope(originalData)
        guard project.id == oldEnvelope.packageID,
              fingerprint(contentKey) == oldEnvelope.keyFingerprint
        else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        try validate(project)
        let schemaVersion = max(minimumSchemaVersion, requestedSchemaVersion ?? oldEnvelope.schemaVersion)
        guard !project.isPrivate || oldEnvelope.isPasswordProtected else {
            throw PatchPackageError.privatePatchRequiresPassword
        }
        let envelope = try makeEnvelope(
            project: project,
            schemaVersion: schemaVersion,
            keyAADVersion: oldEnvelope.isPasswordProtected
                ? (oldEnvelope.keyAADVersion ?? oldEnvelope.schemaVersion)
                : nil,
            contentKey: contentKey,
            isPasswordProtected: oldEnvelope.isPasswordProtected,
            kdfSalt: oldEnvelope.kdfSalt,
            kdfIterations: oldEnvelope.kdfIterations,
            wrappedContentKey: oldEnvelope.wrappedContentKey,
            publicContentKey: oldEnvelope.publicContentKey
        )
        return try serialize(envelope)
    }

    private static func makeEnvelope(
        project: PatchProject,
        schemaVersion: Int,
        keyAADVersion: Int?,
        contentKey: Data,
        isPasswordProtected: Bool,
        kdfSalt: Data?,
        kdfIterations: Int?,
        wrappedContentKey: Data?,
        publicContentKey: Data?
    ) throws -> Envelope {
        let digests = Dictionary(uniqueKeysWithValues: project.rules.map {
            ($0.id.uuidString, Data(SHA256.hash(data: $0.replacementData)))
        })
        let payload = Payload(project: project, replacementDigests: digests)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payloadData = try encoder.encode(payload)
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(payloadData.count)) else {
            throw PatchPackageError.sizeLimitExceeded
        }
        let encryptedPayload = try seal(
            payloadData,
            key: contentKey,
            aad: payloadAAD(for: project.id, version: schemaVersion)
        )

        return Envelope(
            schemaVersion: schemaVersion,
            keyAADVersion: keyAADVersion,
            packageID: project.id,
            isPasswordProtected: isPasswordProtected,
            kdfSalt: kdfSalt,
            kdfIterations: kdfIterations,
            wrappedContentKey: wrappedContentKey,
            publicContentKey: publicContentKey,
            keyFingerprint: fingerprint(contentKey),
            encryptedPayload: encryptedPayload
        )
    }

    private static func openWithFallbackVersions(
        _ ciphertext: Data,
        key: Data,
        packageID: UUID,
        preferredVersion: Int,
        isKeyAAD: Bool
    ) throws -> Data {
        let primaryAAD = isKeyAAD
            ? keyAAD(for: packageID, version: preferredVersion)
            : payloadAAD(for: packageID, version: preferredVersion)
        if let opened = try? open(ciphertext, key: key, aad: primaryAAD) {
            return opened
        }
        for v in 1...16 where v != preferredVersion {
            let candidateAAD = isKeyAAD
                ? keyAAD(for: packageID, version: v)
                : payloadAAD(for: packageID, version: v)
            if let opened = try? open(ciphertext, key: key, aad: candidateAAD) {
                return opened
            }
        }
        throw PatchPackageError.invalidPasswordOrCorruptedPackage
    }

    private static func normalizeProject(_ project: PatchProject) -> PatchProject {
        var copy = project
        if copy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.name = "Patch"
        }
        copy.author = copy.author.trimmingCharacters(in: .whitespacesAndNewlines)
        for idx in copy.rules.indices {
            if copy.rules[idx].replacementFilename.isEmpty {
                copy.rules[idx].replacementFilename = (copy.rules[idx].relativePath as NSString).lastPathComponent
            }
            if copy.rules[idx].bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.rules[idx].bundleID = copy.bundleIdentifiers.first ?? "com.apple.mobile.MobileHouseArrest"
            }
        }
        var seenBundles = Set<String>()
        var mergedBundles: [String] = []
        for bid in (copy.bundleIdentifiers + copy.directories.map(\.bundleID) + copy.rules.map(\.bundleID)) {
            let clean = bid.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && seenBundles.insert(clean).inserted {
                mergedBundles.append(clean)
            }
        }
        if mergedBundles.isEmpty {
            mergedBundles = ["com.apple.mobile.MobileHouseArrest"]
        }
        copy.bundleIdentifiers = mergedBundles
        return copy
    }

    private static func decode(envelope: Envelope, contentKey: Data) throws -> DecodedPatchPackage {
        guard contentKey.count == 32,
              fingerprint(contentKey) == envelope.keyFingerprint
        else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        let payloadData = try openWithFallbackVersions(
            envelope.encryptedPayload,
            key: contentKey,
            packageID: envelope.packageID,
            preferredVersion: envelope.schemaVersion,
            isKeyAAD: false
        )
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(payloadData.count)) else {
            throw PatchPackageError.sizeLimitExceeded
        }
        let decoder = PropertyListDecoder()
        let decodedProject: PatchProject
        if let payload = try? decoder.decode(Payload.self, from: payloadData) {
            if let digests = payload.replacementDigests, !digests.isEmpty {
                for rule in payload.project.rules {
                    if let expected = digests[rule.id.uuidString] {
                        let actual = Data(SHA256.hash(data: rule.replacementData))
                        guard expected == actual else {
                            throw PatchPackageError.invalidPasswordOrCorruptedPackage
                        }
                    }
                }
            }
            decodedProject = normalizeProject(payload.project)
        } else if let directProject = try? decoder.decode(PatchProject.self, from: payloadData) {
            decodedProject = normalizeProject(directProject)
        } else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        return DecodedPatchPackage(project: decodedProject, contentKey: contentKey)
    }

    static func validate(_ project: PatchProject) throws {
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !project.allBundleIdentifiers.isEmpty else {
            throw PatchPackageError.invalidProject
        }
        var totalPayloadBytes: Int64 = 0
        for directory in project.directories {
            _ = try PatchPathValidator.canonicalRelativePath(directory.relativePath)
        }
        for rule in project.rules {
            _ = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            let (sum, overflow) = totalPayloadBytes.addingReportingOverflow(Int64(rule.replacementData.count))
            guard !overflow, !PatchPackageLimits.exceedsExpandedLimit(sum) else {
                throw PatchPackageError.sizeLimitExceeded
            }
            totalPayloadBytes = sum
        }
    }

    private static func parseEnvelope(_ data: Data) throws -> Envelope {
        guard data.count > magic.count,
              data.prefix(magic.count) == magic
        else {
            throw PatchPackageError.unsupportedFormat
        }
        guard !PatchPackageLimits.exceedsExpandedLimit(UInt64(data.count)) else {
            throw PatchPackageError.sizeLimitExceeded
        }
        let encoded = data.dropFirst(magic.count)
        let envelope: Envelope
        do {
            envelope = try PropertyListDecoder().decode(Envelope.self, from: Data(encoded))
        } catch {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        guard envelope.schemaVersion >= minimumSchemaVersion else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        guard envelope.keyFingerprint.count == 32,
              envelope.encryptedPayload.count >= 28,
              !PatchPackageLimits.exceedsExpandedLimit(UInt64(envelope.encryptedPayload.count))
        else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        if envelope.isPasswordProtected {
            if envelope.publicContentKey?.count == 32 && envelope.wrappedContentKey == nil {
                return envelope
            }
            guard (envelope.keyAADVersion ?? envelope.schemaVersion) >= minimumSchemaVersion,
                  envelope.kdfSalt?.count == 16,
                  let iterations = envelope.kdfIterations,
                  iterations >= PatchPackageLimits.minimumKDFIterations,
                  iterations <= PatchPackageLimits.maximumKDFIterations,
                  envelope.wrappedContentKey != nil
            else {
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        } else {
            guard envelope.publicContentKey?.count == 32 else {
                throw PatchPackageError.invalidPasswordOrCorruptedPackage
            }
        }
        return envelope
    }

    private static func serialize(_ envelope: Envelope) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(envelope)
        var result = magic
        result.append(body)
        return result
    }

    private static func seal(_ plaintext: Data, key: Data, aad: Data) throws -> Data {
        guard key.count == 32 else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
        guard let combined = sealed.combined else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        return combined
    }

    private static func open(_ ciphertext: Data, key: Data, aad: Data) throws -> Data {
        guard key.count == 32 else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        guard iterations >= PatchPackageLimits.minimumKDFIterations,
              iterations <= PatchPackageLimits.maximumKDFIterations else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        let passwordData = Data(password.utf8)
        let derivedKeyLength = 32
        var output = Data(count: derivedKeyLength)
        let status = output.withUnsafeMutableBytes { outputBuffer in
            passwordData.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw PatchPackageError.invalidPasswordOrCorruptedPackage
        }
        return output
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PatchPackageError.invalidProject
        }
        return data
    }

    private static func fingerprint(_ key: Data) -> Data {
        Data(SHA256.hash(data: key))
    }

    private static func keyAAD(for packageID: UUID, version: Int) -> Data {
        Data("3105PATCH/v\(version)/key/\(packageID.uuidString)".utf8)
    }

    private static func payloadAAD(for packageID: UUID, version: Int) -> Data {
        Data("3105PATCH/v\(version)/payload/\(packageID.uuidString)".utf8)
    }
}
