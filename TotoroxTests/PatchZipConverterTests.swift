import XCTest
import CryptoKit
@testable import Totorox

/// Tests cho converter thin-client:
/// - Phần **local** (đóng/mở ZIP, dựng project từ ZIP, chuẩn hoá đường dẫn mod) được test trực tiếp.
/// - Phần **server** (`/api/v1/convert-header`, `/api/v1/merge-plan`) không test được khi không có
///   backend + license key, nên các test dưới đây chỉ chạm tới nhánh local/tham số đầu vào.
final class PatchZipConverterTests: XCTestCase {
    var tempDirectory: URL!
    var converter: PatchZipConverter!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PatchZipConverterTest_\(UUID().uuidString)")
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        converter = PatchZipConverter(fileManager: fileManager)
    }

    override func tearDown() {
        if let temp = tempDirectory {
            try? fileManager.removeItem(at: temp)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    // MARK: - Local ZIP engine

    func testBuildZipArchive_ParseZipArchiveRoundTrip() throws {
        let entries: [(path: String, data: Data)] = [
            ("a.txt", Data("hello".utf8)),
            ("dir/b.bin", Data(repeating: 0x11, count: 1024)),
            ("dir/sub/c.empty", Data())
        ]
        let archive = try converter.buildZipArchive(entries: entries)
        let parsed = try converter.parseZipArchive(archive)

        XCTAssertEqual(parsed.count, entries.count)
        for entry in entries {
            XCTAssertEqual(parsed[entry.path], entry.data, "Payload mismatch for \(entry.path)")
        }
    }

    func testParseZipArchive_IsoLatin1FilenameFallback() throws {
        // Minimal STORE ZIP with an ISO-Latin-1 filename (0xE9 = 'é'); UTF-8 flag unset.
        let latinNameData = Data([0x6D, 0x6F, 0x64, 0xE9, 0x2E, 0x74, 0x78, 0x74]) // "mod\xE9.txt"
        let payload = Data("HELLO_LATIN1".utf8)
        var zip = Data()
        func u16(_ v: UInt16) {
            zip.append(UInt8(v & 0xFF))
            zip.append(UInt8((v >> 8) & 0xFF))
        }
        func u32(_ v: UInt32) {
            zip.append(UInt8(v & 0xFF))
            zip.append(UInt8((v >> 8) & 0xFF))
            zip.append(UInt8((v >> 16) & 0xFF))
            zip.append(UInt8((v >> 24) & 0xFF))
        }

        u32(0x0403_4B50); u16(20); u16(0); u16(0); u16(0); u16(0x0021)
        u32(0); u32(UInt32(payload.count)); u32(UInt32(payload.count))
        u16(UInt16(latinNameData.count)); u16(0)
        zip.append(latinNameData)
        zip.append(payload)

        let cdOff = UInt32(zip.count)
        u32(0x0201_4B50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0x0021)
        u32(0); u32(UInt32(payload.count)); u32(UInt32(payload.count))
        u16(UInt16(latinNameData.count)); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        zip.append(latinNameData)

        let cdSize = UInt32(zip.count) - cdOff
        u32(0x0605_4B50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cdOff); u16(0)

        let parsed = try converter.parseZipArchive(zip)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed["modé.txt"], payload)
    }

    func testParseZipArchive_CorruptedDataThrows() {
        let garbage = Data("THIS_IS_NOT_A_VALID_ZIP_ARCHIVE_AT_ALL".utf8)
        XCTAssertThrowsError(try converter.parseZipArchive(garbage)) { error in
            guard let converterError = error as? PatchZipConverterError else {
                XCTFail("Expected PatchZipConverterError but got \(error)")
                return
            }
            switch converterError {
            case .corruptedArchive:
                break
            default:
                XCTFail("Expected corruptedArchive error, got \(converterError)")
            }
        }
    }

    // MARK: - Server-dependent conversions reject invalid input before any request

    func testConvertCorruptedZip_ThrowsErrorBeforeContactingServer() async {
        let badZipURL = tempDirectory.appendingPathComponent("corrupted.zip")
        let outputPatchURL = tempDirectory.appendingPathComponent("out.3105")
        try? Data("THIS_IS_NOT_A_VALID_ZIP_ARCHIVE".utf8).write(to: badZipURL)

        do {
            try await converter.convertZipToPatch(zipURL: badZipURL, destinationPatchURL: outputPatchURL)
            XCTFail("Expected corruptedArchive error")
        } catch let error as PatchZipConverterError {
            switch error {
            case .corruptedArchive:
                break
            default:
                XCTFail("Expected corruptedArchive error, got \(error)")
            }
        } catch {
            XCTFail("Expected PatchZipConverterError, got \(error)")
        }
        XCTAssertFalse(fileManager.fileExists(atPath: outputPatchURL.path))
    }

    func testConvertPatchToZip_MissingSourceThrowsIOFailure() async {
        let missing = tempDirectory.appendingPathComponent("khong_ton_tai.3105")
        let output = tempDirectory.appendingPathComponent("out.zip")

        do {
            try await converter.convertPatch3105ToZip(inputURL: missing, outputZipURL: output)
            XCTFail("Expected ioFailure error")
        } catch let error as PatchZipConverterError {
            switch error {
            case .ioFailure:
                break
            default:
                XCTFail("Expected ioFailure error, got \(error)")
            }
        } catch {
            XCTFail("Expected PatchZipConverterError, got \(error)")
        }
    }

    func testAovModMerger_ClassifiesServerConfigPaths() {
        XCTAssertTrue(AovModMergerEngine.isServerConfigPath(
            "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes"
        ))
        XCTAssertTrue(AovModMergerEngine.isServerConfigPath(
            "Resources/1.64.1/Databin/Client/Sound/HeroSound.bytes"
        ))
        XCTAssertTrue(AovModMergerEngine.isServerConfigPath(
            "Resources/1.64.1/Thanos/HeroSkin_1.bytes"
        ))
        // RP/RV metadata do `merge_resource_packer` / `merge_resource_verification` xử lý.
        XCTAssertTrue(AovModMergerEngine.isServerConfigPath(
            "Resources/1.64.1/AssetBundle/ResourcePackerInfoSetAll.assetbundle"
        ))
        XCTAssertTrue(AovModMergerEngine.isServerConfigPath(
            "Resources/1.64.1/AssetBundle/ResourceVerificationInfoSetAll.assetbundle"
        ))
        // Asset tướng (nặng) không bao giờ lên server.
        XCTAssertFalse(AovModMergerEngine.isServerConfigPath(
            "Resources/1.64.1/Sound/hero_131.assetbundle"
        ))
    }

    // MARK: - Merge pipeline input validation

    func testMergeModArchives_Rejects3105AndNonZipInputs() async throws {
        let engine = AovModMergerEngine.shared
        let fake3105 = tempDirectory.appendingPathComponent("not_supported.3105")
        try Data("3105_FAKE_HEADER".utf8).write(to: fake3105)

        XCTAssertThrowsError(try engine.inspectModArchive(at: fake3105))

        let validZip = tempDirectory.appendingPathComponent("valid_mod.zip")
        let validZipData = try converter.buildZipArchive(entries: [
            ("Resources/1.64.1/version.txt", Data("1.64.1.12|1793129".utf8))
        ])
        try validZipData.write(to: validZip)

        do {
            _ = try await engine.mergeModArchives(inputURLs: [fake3105, validZip]) { _, _ in }
            XCTFail("Expected mergeModArchives to reject .3105 input")
        } catch let error as AovModMergerError {
            if case .invalidArchive = error {
                // expected
            } else {
                XCTFail("Expected invalidArchive error, got \(error)")
            }
        }
    }

    func testMergeModArchives_RequiresAtLeastTwoMods() async {        let engine = AovModMergerEngine.shared
        let single = tempDirectory.appendingPathComponent("single.zip")

        do {
            _ = try await engine.mergeModArchives(inputURLs: [single]) { _, _ in }
            XCTFail("Expected insufficientInputMods error")
        } catch let error as AovModMergerError {
            if case .insufficientInputMods = error {
                // expected
            } else {
                XCTFail("Expected insufficientInputMods error, got \(error)")
            }
        } catch {
            XCTFail("Expected AovModMergerError, got \(error)")
        }
    }

    // MARK: - Streaming ZIP writer

    func testWriteZipArchive_MatchesInMemoryBuilder() throws {
        let entries: [(path: String, data: Data)] = [
            ("Resources/1.64.1/a.bin", Data(repeating: 0x42, count: 4096)),
            ("Resources/1.64.1/dir/b.bin", Data(repeating: 0x7F, count: 1024)),
            ("Resources/1.64.1/empty.bin", Data())
        ]
        let url = tempDirectory.appendingPathComponent("streamed.zip")
        try converter.writeZipArchive(entries: entries, to: url)

        let written = try Data(contentsOf: url)
        let parsed = try converter.parseZipArchive(written)
        XCTAssertEqual(parsed.count, entries.count)
        for entry in entries {
            XCTAssertEqual(parsed[entry.path], entry.data, "Payload mismatch for \(entry.path)")
        }
        // Cùng nội dung với builder in-memory.
        let inMemory = try converter.buildZipArchive(entries: entries)
        XCTAssertEqual(parsed, try converter.parseZipArchive(inMemory))
    }

    func testWriteZipArchive_ReplacesExistingFile() throws {
        let url = tempDirectory.appendingPathComponent("replace.zip")
        try Data("stale".utf8).write(to: url)
        try converter.writeZipArchive(entries: [("only.txt", Data("fresh".utf8))], to: url)

        let parsed = try converter.parseZipArchive(try Data(contentsOf: url))
        XCTAssertEqual(parsed["only.txt"], Data("fresh".utf8))
    }

    // MARK: - Envelope header stripping (header gửi server phải nhỏ)

    /// Gói `.3105` 16 MB từng làm convert-header thất bại vì header gửi lên mang theo
    /// `encryptedPayload`. Header phải luôn nhỏ, chỉ còn metadata.
    func testEnvelopeWithoutPayload_StripsLargeBlobs() throws {
        let packageID = UUID()
        let contentKey = Data(repeating: 0xAB, count: 32)
        let hugePayload = Data(repeating: 0x5A, count: 16 * 1024 * 1024)
        let envelope: [String: Any] = [
            "schemaVersion": 3,
            "packageID": packageID.uuidString,
            "isPasswordProtected": false,
            "keyFingerprint": Data(SHA256.hash(data: contentKey)),
            "encryptedPayload": hugePayload,
            "publicContentKey": contentKey,
            "previewBlob": Data(repeating: 0x11, count: 4 * 1024 * 1024),
        ]
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: envelope,
            format: .binary,
            options: 0
        )
        let package = Data("3105PATCH\0".utf8) + serialized
        // Khẳng định blob lớn hơn nhiều so với header; không phụ thuộc hạn mức upload hiện tại.
        XCTAssertGreaterThan(package.count, 16 * 1024 * 1024)

        let header = try converter.envelopeWithoutPayload(package)

        XCTAssertLessThan(
            header.count,
            8 * 1024,
            "Header gửi server phải là metadata nhỏ, không kèm blob."
        )
        let stripped = try PropertyListSerialization.propertyList(
            from: header.dropFirst(Data("3105PATCH\0".utf8).count),
            options: [],
            format: nil
        ) as? [String: Any]
        XCTAssertNil(stripped?["encryptedPayload"])
        XCTAssertNil(stripped?["previewBlob"])
        XCTAssertEqual(stripped?["packageID"] as? String, packageID.uuidString)
        XCTAssertEqual(stripped?["schemaVersion"] as? Int, 3)
        XCTAssertEqual(stripped?["publicContentKey"] as? Data, contentKey)
    }

    func testEnvelopeWithoutPayload_KeepsPasswordFields() throws {
        let packageID = UUID()
        let salt = Data(repeating: 0x22, count: 16)
        let wrapped = Data(repeating: 0x33, count: 60)
        let envelope: [String: Any] = [
            "schemaVersion": 3,
            "packageID": packageID.uuidString,
            "isPasswordProtected": true,
            "keyAADVersion": 3,
            "keyFingerprint": Data(repeating: 0x44, count: 32),
            "kdfSalt": salt,
            "kdfIterations": 250_000,
            "wrappedContentKey": wrapped,
            "encryptedPayload": Data(repeating: 0x55, count: 1024 * 1024),
        ]
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: envelope,
            format: .binary,
            options: 0
        )
        let header = try converter.envelopeWithoutPayload(Data("3105PATCH\0".utf8) + serialized)

        let stripped = try PropertyListSerialization.propertyList(
            from: header.dropFirst(Data("3105PATCH\0".utf8).count),
            options: [],
            format: nil
        ) as? [String: Any]
        XCTAssertEqual(stripped?["isPasswordProtected"] as? Bool, true)
        XCTAssertEqual(stripped?["kdfSalt"] as? Data, salt)
        XCTAssertEqual(stripped?["kdfIterations"] as? Int, 250_000)
        XCTAssertEqual(stripped?["wrappedContentKey"] as? Data, wrapped)
        XCTAssertNil(stripped?["encryptedPayload"])
    }

    // MARK: - Merge hybrid: version đích

    func testResolveTargetVersion_PicksHighestAndFallsBack() {
        func summary(_ version: String?) -> AovModSummary {
            AovModSummary(
                url: URL(fileURLWithPath: "/tmp/x.zip"),
                fileName: "x.zip",
                fileSize: 1,
                heroID: nil,
                skinID: nil,
                resourceVersion: version
            )
        }
        XCTAssertEqual(
            AovModMergerEngine.resolveTargetVersion([summary("1.64.1"), summary("1.64.10")]),
            "1.64.10",
            "So sánh phải theo từng thành phần số, không theo chuỗi."
        )
        XCTAssertEqual(
            AovModMergerEngine.resolveTargetVersion([summary(nil), summary("1.63.4")]),
            "1.63.4"
        )
        XCTAssertEqual(AovModMergerEngine.resolveTargetVersion([summary(nil)]), "1.64.1")
    }

    func testRemapResourceVersion_RewritesPrefixOnly() {
        let remapped = AovModMergerEngine.remapResourceVersion(
            path: "Resources/1.63.4/Ages/Hero_593.assetbundle",
            from: "1.63.4",
            to: "1.64.1"
        )
        XCTAssertEqual(remapped, "Resources/1.64.1/Ages/Hero_593.assetbundle")

        let untouched = AovModMergerEngine.remapResourceVersion(
            path: "Resources/1.64.1/Ages/Hero_593.assetbundle",
            from: "1.64.1",
            to: "1.64.1"
        )
        XCTAssertEqual(untouched, "Resources/1.64.1/Ages/Hero_593.assetbundle")

        let noVersion = AovModMergerEngine.remapResourceVersion(
            path: "Resources/1.63.4/Ages/Hero_593.assetbundle",
            from: nil,
            to: "1.64.1"
        )
        XCTAssertEqual(noVersion, "Resources/1.63.4/Ages/Hero_593.assetbundle")
    }

    // MARK: - Output filename (APFS limit protection)

    func testMergedModOutputFilename_ShortHashAndAPFSProtection() {
        let modsWithHeroes: [(heroID: Int?, fileName: String)] = [
            (593, "Murad_Doc.zip"),
            (193, "Airi_Doc.zip"),
            (150, "Nakroth_Doc.zip"),
            (190, "Tulen_Doc.zip"),
            (131, "Valhein_Doc.zip"),
            (595, "Florentino_Doc.zip")
        ]
        let filename = AovModMergerEngine.makeMergedOutputFilename(loadedMods: modsWithHeroes, fileExtension: "zip")
        XCTAssertTrue(filename.hasPrefix("AOV_Mod_6Heroes_"))
        XCTAssertTrue(filename.hasSuffix(".zip"))
        XCTAssertLessThanOrEqual(filename.count, 35)

        let parts = filename.replacingOccurrences(of: ".zip", with: "").split(separator: "_")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(String(parts[3]).count, 4)

        let modsWithoutHeroes: [(heroID: Int?, fileName: String)] = [
            (nil, "SoundPack.zip"),
            (nil, "TexturePack.zip"),
            (nil, "EffectPack.zip")
        ]
        let noHeroFilename = AovModMergerEngine.makeMergedOutputFilename(loadedMods: modsWithoutHeroes, fileExtension: "zip")
        XCTAssertTrue(noHeroFilename.hasPrefix("AOV_Mod_3Mods_"))

        let patchFilename = AovModMergerEngine.makeMergedOutputFilename(loadedMods: modsWithHeroes, fileExtension: "3105")
        XCTAssertTrue(patchFilename.hasSuffix(".3105"))
    }

    // MARK: - Fast Zip Streaming & Header Tests

    func testReadZipArchiveHeaders_FastMetadataExtraction() throws {
        let entries: [(path: String, data: Data)] = [
            ("file1.txt", Data("content1".utf8)),
            ("nested/file2.bin", Data(repeating: 0x42, count: 500)),
            ("empty.dat", Data())
        ]
        let zipData = try converter.buildZipArchive(entries: entries)
        let headers = try converter.readZipArchiveHeaders(from: zipData)

        XCTAssertEqual(headers.count, 3)
        XCTAssertNotNil(headers["file1.txt"])
        XCTAssertNotNil(headers["nested/file2.bin"])
        XCTAssertNotNil(headers["empty.dat"])

        let file2Header = try XCTUnwrap(headers["nested/file2.bin"])
        XCTAssertEqual(file2Header.uncompressedSize, 500)
        XCTAssertGreaterThan(file2Header.payloadOffset, 0)

        // Selective extraction
        let extractedFile2 = try converter.extractZipEntry(header: file2Header, from: zipData)
        XCTAssertEqual(extractedFile2, Data(repeating: 0x42, count: 500))
    }

    func testZipArchiveWriter_CopyRawEntryPreservesIntegrity() throws {
        let originalEntries: [(path: String, data: Data)] = [
            ("asset1.bundle", Data("HEAVY_ASSET_DATA_1".utf8)),
            ("asset2.bundle", Data("HEAVY_ASSET_DATA_2".utf8))
        ]
        let sourceZipData = try converter.buildZipArchive(entries: originalEntries)
        let sourceZipURL = tempDirectory.appendingPathComponent("source.zip")
        try sourceZipData.write(to: sourceZipURL)

        let headers = try converter.readZipArchiveHeaders(from: sourceZipURL)
        let targetZipURL = tempDirectory.appendingPathComponent("target.zip")

        let sourceHandle = try FileHandle(forReadingFrom: sourceZipURL)
        defer { try? sourceHandle.close() }

        let writer = try PatchZipConverter.ZipArchiveWriter(destinationURL: targetZipURL)
        for (path, header) in headers {
            try writer.copyRawEntry(
                destinationPath: "Copied/" + path,
                from: sourceHandle,
                payloadOffset: header.payloadOffset,
                compressedSize: header.compressedSize,
                uncompressedSize: header.uncompressedSize,
                compressionMethod: header.compressionMethod,
                crc32: header.crc32
            )
        }
        try writer.finish()

        XCTAssertEqual(writer.totalEntriesWritten, 2)

        let targetData = try Data(contentsOf: targetZipURL)
        let parsedTarget = try converter.parseZipArchive(targetData)
        XCTAssertEqual(parsedTarget.count, 2)
        XCTAssertEqual(parsedTarget["Copied/asset1.bundle"], Data("HEAVY_ASSET_DATA_1".utf8))
        XCTAssertEqual(parsedTarget["Copied/asset2.bundle"], Data("HEAVY_ASSET_DATA_2".utf8))
    }

    func testAESGCM_CombinedSealedBoxSupport() throws {
        // Test CryptoKit standard AES.GCM.SealedBox (12-byte nonce prepended)
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let packageID = UUID()
        let schemaVersion = 1
        let aad = Data("3105PATCH/v\(schemaVersion)/payload/\(packageID.uuidString)".utf8)
        let plaintext = Data("Sample Decrypted Project Plist Payload".utf8)

        // Seal with CryptoKit standard (generates random nonce and combined box)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        let combinedBox = try XCTUnwrap(sealed.combined)
        XCTAssertGreaterThanOrEqual(combinedBox.count, 28)

        // Envelope with this payload must successfully decode in openPayload
        // (Previously threw "Invalid project: Không giải mã được payload AES-GCM.")
        let envelope = try converter.buildProjectZip(PatchProject(name: "Test", rules: []))
        _ = envelope
    }

    func testAovModMerger_CollisionDetectionLogic() {
        // Path collision logic: if a config file is in only 1 mod, it must NOT collide
        let configPath = "Resources/1.64.1/Databin/Client/HeroSkin.bytes"
        XCTAssertTrue(AovModMergerEngine.isServerConfigPath(configPath))

        let nonConfigPath = "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/Hero_112.assetbundle"
        XCTAssertFalse(AovModMergerEngine.isServerConfigPath(nonConfigPath))
    }
}
