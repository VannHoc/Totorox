import XCTest
import CryptoKit
import Compression
@testable import Totorox

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

    // MARK: - 5. Test Chuyển đổi khứ hồi (Round-trip test) .3105 -> .zip -> .3105
    func testRoundTripConversion_PreservesAllDataAndMetadata() throws {
        let bundleID = "com.apple.mobile.MobileHouseArrest"
        let rule1Payload = "PAYLOAD_BYTES_TEXTURE_DATA_1".data(using: .utf8)!
        let rule2Payload = "PAYLOAD_BYTES_BINARY_CONFIG_2".data(using: .utf8)!

        let rule1 = PatchRule(
            id: UUID(),
            bundleID: bundleID,
            relativePath: "Documents/Assets/texture.png",
            replacementFilename: "texture.png",
            replacementData: rule1Payload
        )
        let rule2 = PatchRule(
            id: UUID(),
            bundleID: bundleID,
            relativePath: "Library/Preferences/config.plist",
            replacementFilename: "config.plist",
            replacementData: rule2Payload
        )

        let directory = PatchDirectory(
            id: UUID(),
            bundleID: bundleID,
            relativePath: "Documents/Assets"
        )

        let originalProject = PatchProject(
            id: UUID(),
            name: "Totorox Super Mod",
            author: "VannHoc",
            isPrivate: false,
            createdAt: Date(),
            updatedAt: Date(),
            bundleIdentifiers: [bundleID],
            directories: [directory],
            rules: [rule1, rule2]
        )

        // Step A: Encode original project to .3105 format
        let encodedPatch = try PatchPackageCodec.encodeNew(project: originalProject, password: nil)
        let initialPatchURL = tempDirectory.appendingPathComponent("initial_patch.3105")
        try encodedPatch.data.write(to: initialPatchURL)

        // Step B: Convert .3105 -> .zip
        let outputZipURL = tempDirectory.appendingPathComponent("exported_patch.zip")
        try converter.convertPatchToZip(patchURL: initialPatchURL, destinationZipURL: outputZipURL)

        XCTAssertTrue(fileManager.fileExists(atPath: outputZipURL.path), "Output .zip archive must be generated")

        // Step C: Convert .zip -> .3105
        let reconstructedPatchURL = tempDirectory.appendingPathComponent("reconstructed_patch.3105")
        try converter.convertZipToPatch(zipURL: outputZipURL, destinationPatchURL: reconstructedPatchURL)

        XCTAssertTrue(fileManager.fileExists(atPath: reconstructedPatchURL.path), "Reconstructed .3105 file must be generated")

        // Step D: Decode reconstructed .3105 and verify 100% data preservation
        let reconstructedData = try Data(contentsOf: reconstructedPatchURL)
        let decodedReconstructed = try PatchPackageCodec.decode(reconstructedData, password: nil)
        let reconProject = decodedReconstructed.project

        XCTAssertEqual(reconProject.id, originalProject.id, "Package UUID must match exactly")
        XCTAssertEqual(reconProject.name, originalProject.name, "Package name must match")
        XCTAssertEqual(reconProject.author, originalProject.author, "Author must match VannHoc")
        XCTAssertEqual(reconProject.bundleIdentifiers, originalProject.bundleIdentifiers)
        XCTAssertEqual(reconProject.directories.count, 1)
        XCTAssertEqual(reconProject.directories[0].relativePath, "Documents/Assets")
        XCTAssertEqual(reconProject.rules.count, 2)

        let reconRule1 = reconProject.rules.first { $0.relativePath == "Documents/Assets/texture.png" }
        XCTAssertNotNil(reconRule1)
        XCTAssertEqual(reconRule1?.replacementFilename, "texture.png")
        XCTAssertEqual(reconRule1?.replacementData, rule1Payload, "Rule 1 byte payload must be 100% identical")

        let reconRule2 = reconProject.rules.first { $0.relativePath == "Library/Preferences/config.plist" }
        XCTAssertNotNil(reconRule2)
        XCTAssertEqual(reconRule2?.replacementFilename, "config.plist")
        XCTAssertEqual(reconRule2?.replacementData, rule2Payload, "Rule 2 byte payload must be 100% identical")
    }

    func testConvertDeepBinaryPayload_WithoutTruncationError() throws {
        let bundleID = "com.apple.mobile.MobileHouseArrest"
        let deepRelativePath = "files/Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes"
        let binaryPayload = Data(repeating: 0x5A, count: 64 * 1024)

        let rule = PatchRule(
            id: UUID(),
            bundleID: bundleID,
            relativePath: deepRelativePath,
            replacementFilename: "CommonActions.pkg.bytes",
            replacementData: binaryPayload
        )

        let project = PatchProject(
            id: UUID(),
            name: "Deep Resource Mod",
            author: "VannHoc",
            isPrivate: false,
            createdAt: Date(),
            updatedAt: Date(),
            bundleIdentifiers: [bundleID],
            directories: [],
            rules: [rule]
        )

        let initialPatch = try PatchPackageCodec.encodeNew(project: project, password: nil)
        let patchURL = tempDirectory.appendingPathComponent("deep.3105")
        try initialPatch.data.write(to: patchURL)

        let zipURL = tempDirectory.appendingPathComponent("deep.zip")
        try converter.convertPatchToZip(patchURL: patchURL, destinationZipURL: zipURL)

        let reconPatchURL = tempDirectory.appendingPathComponent("deep_recon.3105")
        XCTAssertNoThrow(try converter.convertZipToPatch(zipURL: zipURL, destinationPatchURL: reconPatchURL))

        let reconData = try Data(contentsOf: reconPatchURL)
        let decoded = try PatchPackageCodec.decode(reconData, password: nil)
        let reconRule = decoded.project.rules.first { $0.relativePath == deepRelativePath }
        XCTAssertNotNil(reconRule)
        XCTAssertEqual(reconRule?.replacementData, binaryPayload)
    }

    // MARK: - Error Handling Tests
    func testConvertCorruptedZip_ThrowsError() {
        let badZipURL = tempDirectory.appendingPathComponent("corrupted.zip")
        let outputPatchURL = tempDirectory.appendingPathComponent("out.3105")
        try? "THIS_IS_NOT_A_VALID_ZIP_ARCHIVE".data(using: .utf8)!.write(to: badZipURL)

        XCTAssertThrowsError(try converter.convertZipToPatch(zipURL: badZipURL, destinationPatchURL: outputPatchURL)) { error in
            guard let convError = error as? PatchZipConverterError else {
                XCTFail("Expected PatchZipConverterError but got \(error)")
                return
            }
            switch convError {
            case .corruptedArchive: break
            default: XCTFail("Expected corruptedArchive error, got \(convError)")
            }
        }
    }

    func testConvertZipMissingManifest_AutoGeneratesManifestAndSucceeds() throws {
        let zipURL = tempDirectory.appendingPathComponent("missing_manifest.zip")
        let dummyData = "dummy content without patch.json".data(using: .utf8)!
        let zipData = try converter.buildZipArchive(entries: [("Resources/dummy.txt", dummyData)])
        try zipData.write(to: zipURL)

        let outputPatch = tempDirectory.appendingPathComponent("out_missing.3105")
        XCTAssertNoThrow(try converter.convertZipToPatch(zipURL: zipURL, destinationPatchURL: outputPatch))
        XCTAssertTrue(fileManager.fileExists(atPath: outputPatch.path), "Output .3105 file must be generated even if patch.json was missing")

        // Verify the generated patch can be decoded
        let patchData = try Data(contentsOf: outputPatch)
        let decoded = try PatchPackageCodec.decode(patchData, password: nil)
        XCTAssertEqual(decoded.project.rules.count, 1)
        XCTAssertEqual(decoded.project.rules[0].replacementFilename, "dummy.txt")
        XCTAssertEqual(decoded.project.rules[0].replacementData, dummyData)
    }

    func testConvertAllSchemaVersions_V1ThroughV9_WithoutVersionBlock() throws {
        let bundleID = "com.apple.mobile.MobileHouseArrest"
        let payloadBytes = "REMOTE_CONFIG_PAYLOAD_V9".data(using: .utf8)!
        let rule = PatchRule(
            id: UUID(),
            bundleID: bundleID,
            relativePath: "Documents/RemoteConfig.plist",
            replacementFilename: "RemoteConfig.plist",
            replacementData: payloadBytes,
            operation: "mergePlist",
            containerKind: "application"
        )
        let project = PatchProject(
            id: UUID(),
            name: "RemoteConfig MultiVersion",
            author: "Exploitv2.3",
            isPrivate: false,
            createdAt: Date(),
            updatedAt: Date(),
            bundleIdentifiers: [bundleID],
            directories: [],
            rules: [rule]
        )

        for version in [1, 2, 3, 4, 5, 9] {
            let encoded = try PatchPackageCodec.encode(
                project: project,
                password: nil,
                schemaVersion: version
            )
            let zipData = try converter.convertPatchDataToZipData(encoded.data, password: nil)
            let reconPatchData = try converter.convertZipDataToPatchData(zipData, password: nil)
            let decoded = try PatchPackageCodec.decode(reconPatchData, password: nil)
            XCTAssertEqual(decoded.project.rules.count, 1, "Failed for schemaVersion \(version)")
            XCTAssertEqual(decoded.project.rules[0].replacementData, payloadBytes)
            XCTAssertEqual(decoded.project.rules[0].operation, "mergePlist")
        }
    }

    func testAovModMerger_PathNormalizationAndJgCryptoRoundTrip() throws {
        let engine = AovModMergerEngine.shared

        let norm1 = engine.normalizeAovRelativePath("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        XCTAssertEqual(norm1, "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")

        let normMacOS = engine.normalizeAovRelativePath("__MACOSX/Murad/._CommonActions.pkg.bytes")
        XCTAssertNil(normMacOS)

        let plain = Data("MSES_TEST_PAYLOAD_FOR_JG_CRYPTO_1234567890".utf8)
        let encrypted = try engine.jgEncrypt(plain, stem: "HeroSkin_1")
        XCTAssertEqual(Array(encrypted.prefix(4)), [0x22, 0x4A, 0x67, 0x00])

        let decrypted = try engine.jgDecrypt(encrypted, stem: "HeroSkin_1")
        XCTAssertEqual(decrypted, plain)
    }

    // MARK: - Test Chuyển đổi gói .3105 có mật khẩu (Password Protected Patch)
    func testConvertPasswordProtectedPatch_SuccessWithCorrectPassword() throws {
        let bundleID = "com.garena.game.kgvn"
        let payload = "ENCRYPTED_MOD_PAYLOAD_CONTENT".data(using: .utf8)!
        let password = "SecretPassword3105"

        let rule = PatchRule(
            id: UUID(),
            bundleID: bundleID,
            relativePath: "Documents/Resources/mod.bytes",
            replacementFilename: "mod.bytes",
            replacementData: payload
        )
        let project = PatchProject(
            id: UUID(),
            name: "Protected Mod",
            author: "TotoroxAuthor",
            isPrivate: true,
            createdAt: Date(),
            updatedAt: Date(),
            bundleIdentifiers: [bundleID],
            directories: [],
            rules: [rule]
        )

        let encoded = try PatchPackageCodec.encodeNew(project: project, password: password)
        let patchURL = tempDirectory.appendingPathComponent("protected.3105")
        try encoded.data.write(to: patchURL)

        // Verify that inspect shows isPasswordProtected = true
        let summary = try PatchPackageCodec.inspect(encoded.data)
        XCTAssertTrue(summary.isPasswordProtected)

        // 1. Convert with correct password -> Success
        let outputZipURL = tempDirectory.appendingPathComponent("unlocked.zip")
        XCTAssertNoThrow(try converter.convertPatch3105ToZip(inputURL: patchURL, outputZipURL: outputZipURL, password: password))
        XCTAssertTrue(fileManager.fileExists(atPath: outputZipURL.path))

        // 2. Convert with wrong password -> Throws error
        let wrongZipURL = tempDirectory.appendingPathComponent("wrong.zip")
        XCTAssertThrowsError(try converter.convertPatch3105ToZip(inputURL: patchURL, outputZipURL: wrongZipURL, password: "IncorrectPassword"))

        // 3. Convert with nil password -> Throws error
        let nilZipURL = tempDirectory.appendingPathComponent("nil.zip")
        XCTAssertThrowsError(try converter.convertPatch3105ToZip(inputURL: patchURL, outputZipURL: nilZipURL, password: nil))
    }

    // MARK: - Test Đặt tên file gộp mod tối ưu Short Hash (APFS Limit Protection)
    func testMergedModOutputFilename_ShortHashAndAPFSProtection() {
        // Case 1: 6 Heroes merged -> AOV_Mod_6Heroes_[4-char hash].zip
        let modsWithHeroes: [(heroID: Int?, fileName: String)] = [
            (593, "Murad_Doc.zip"),
            (193, "Airi_Doc.zip"),
            (150, "Nakroth_Doc.zip"),
            (190, "Tulen_Doc.zip"),
            (131, "Valhein_Doc.zip"),
            (595, "Florentino_Doc.zip")
        ]
        let filename = AovModMergerEngine.makeMergedOutputFilename(loadedMods: modsWithHeroes, fileExtension: "zip")
        XCTAssertTrue(filename.hasPrefix("AOV_Mod_6Heroes_"), "Filename must start with AOV_Mod_6Heroes_")
        XCTAssertTrue(filename.hasSuffix(".zip"), "Filename must end with .zip")
        XCTAssertLessThanOrEqual(filename.count, 35, "Filename must be compact and under 35 chars, well below APFS 255-char limit")

        // Parse short hash
        let parts = filename.replacingOccurrences(of: ".zip", with: "").split(separator: "_")
        XCTAssertEqual(parts.count, 4) // ["AOV", "Mod", "6Heroes", "[hash]"]
        let shortHash = String(parts[3])
        XCTAssertEqual(shortHash.count, 4, "Short hash must be 4 characters long")

        // Case 2: Mods without detected heroID -> AOV_Mod_3Mods_[hash].zip
        let modsWithoutHeroes: [(heroID: Int?, fileName: String)] = [
            (nil, "SoundPack.zip"),
            (nil, "TexturePack.zip"),
            (nil, "EffectPack.zip")
        ]
        let noHeroFilename = AovModMergerEngine.makeMergedOutputFilename(loadedMods: modsWithoutHeroes, fileExtension: "zip")
        XCTAssertTrue(noHeroFilename.hasPrefix("AOV_Mod_3Mods_"))
        XCTAssertTrue(noHeroFilename.hasSuffix(".zip"))

        // Case 3: Custom extension .3105
        let patchFilename = AovModMergerEngine.makeMergedOutputFilename(loadedMods: modsWithHeroes, fileExtension: "3105")
        XCTAssertTrue(patchFilename.hasPrefix("AOV_Mod_6Heroes_"))
        XCTAssertTrue(patchFilename.hasSuffix(".3105"))
    }

    // MARK: - Merge Pipeline Tests (ZIP-Only, Dynamic IFix Scanning, XML/MSES/UnityFS, Case-Insensitive & Re-Merge)

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
        } catch let err as AovModMergerError {
            if case .invalidArchive = err {
                // expected
            } else {
                XCTFail("Expected invalidArchive error, got \(err)")
            }
        }
    }

    func testParseZipArchive_IsoLatin1FilenameFallback() throws {
        // Construct minimal STORE ZIP with CP437/ISO-Latin-1 filename containing 0xE9 ('é') and bit 11 (UTF-8 flag) unset
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

        // Local File Header
        u32(0x0403_4B50); u16(20); u16(0); u16(0); u16(0); u16(0x0021)
        u32(0); u32(UInt32(payload.count)); u32(UInt32(payload.count))
        u16(UInt16(latinNameData.count)); u16(0)
        zip.append(latinNameData)
        zip.append(payload)

        // Central Directory Header
        let cdOff = UInt32(zip.count)
        u32(0x0201_4B50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0x0021)
        u32(0); u32(UInt32(payload.count)); u32(UInt32(payload.count))
        u16(UInt16(latinNameData.count)); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        zip.append(latinNameData)

        // EOCD
        let cdSize = UInt32(zip.count) - cdOff
        u32(0x0605_4B50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cdOff); u16(0)

        let parsed = try converter.parseZipArchive(zip)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed["modé.txt"], payload)
    }

    func testMergeModArchives_DynamicPipeline_ShiftedIfix_Xml_Mses_UnityFS_AndReMerge() async throws {
        let engine = AovModMergerEngine.shared

        func appendU32LE(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
        }
        func appendU32BE(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8((v >> 24) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF))
        }
        func appendU64BE(_ d: inout Data, _ v: UInt64) {
            for i in 0..<8 { d.append(UInt8((v >> UInt64((7 - i) * 8)) & 0xFF)) }
        }
        func md5Lower(_ data: Data) -> String {
            Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func makeUnityString(_ s: String) -> Data {
            var d = Data()
            let utf8 = Data(s.utf8)
            appendU32LE(&d, UInt32(utf8.count))
            d.append(utf8)
            while d.count % 4 != 0 { d.append(0) }
            return d
        }
        func makeUnityFS(payload: Data) -> Data {
            var tailInfo = Data(count: 64)
            tailInfo.withUnsafeMutableBytes { buf in
                let p = buf.bindMemory(to: UInt8.self)
                // blockCompType = 0 at offset 20..21; compSize at 24..28; uncompSize at 28..32 (BE)
                let sz = UInt32(payload.count)
                p[24] = UInt8((sz >> 24) & 0xFF); p[25] = UInt8((sz >> 16) & 0xFF)
                p[26] = UInt8((sz >> 8) & 0xFF); p[27] = UInt8(sz & 0xFF)
                p[28] = p[24]; p[29] = p[25]; p[30] = p[26]; p[31] = p[27]
            }

            var hdr = Data("UnityFS\0".utf8)
            appendU32BE(&hdr, 8)
            hdr.append("5.x.x\0".data(using: .utf8)!)
            hdr.append("2022.3.5f1\0".data(using: .utf8)!)
            let sizeFieldOffset = hdr.count
            let headerPadded = ((sizeFieldOffset + 20) + 15) & ~15
            let totalSize = UInt64(headerPadded + payload.count + tailInfo.count)
            appendU64BE(&hdr, totalSize)
            appendU32BE(&hdr, UInt32(tailInfo.count))
            appendU32BE(&hdr, UInt32(tailInfo.count))
            appendU32BE(&hdr, 0x80) // uncompressed BlocksInfo at end
            while hdr.count < headerPadded { hdr.append(0) }

            var out = hdr
            out.append(payload)
            out.append(tailInfo)
            return out
        }
        func makeRVBundle(ver: String, build: String) -> Data {
            var payload = Data([0x1E, 0x00, 0x00, 0x00]) + Data("ResourceVerificationInfoSetXML".utf8)
            payload.append(contentsOf: [0x01, 0x00]) // 2-byte extra padding
            payload.append(makeUnityString(ver))
            payload.append(makeUnityString(build))
            payload.append(Data(repeating: 0xAA, count: 64))
            return makeUnityFS(payload: payload)
        }
        func makeRPBundle(ver: String, build: String, path1Hash8: Data, path2Hash8: Data) -> Data {
            var payload = Data([0x18, 0x00, 0x00, 0x00]) + Data("ResourcePackerInfoSetXML".utf8)
            payload.append(makeUnityString(ver))
            payload.append(makeUnityString(build))
            payload.append(Data([0x18, 0x00, 0x00, 0x00]) + Data("ResourcePackerInfoSetXML".utf8))
            appendU32LE(&payload, 2) // recCount = 2
            for (path, h8) in [("assetbundle/hero_a", path1Hash8), ("assetbundle/hero_b", path2Hash8)] {
                payload.append(makeUnityString(path))
                appendU32LE(&payload, 1); appendU32LE(&payload, 2); appendU32LE(&payload, 3)
                payload.append(makeUnityString("tag"))
                appendU32LE(&payload, 0)
                appendU32LE(&payload, 1) // hcnt = 1
                payload.append(h8.prefix(8))
                payload.append(makeUnityString("bytes"))
            }
            payload.append(Data("RunTimeResourcePackerInfoSet".utf8))
            return makeUnityFS(payload: payload)
        }
        func inst(_ op: UInt32, _ arg: Int32) -> Data {
            var d = Data(capacity: 8)
            appendU32LE(&d, op)
            appendU32LE(&d, UInt32(bitPattern: arg))
            return d
        }
        func makeShiftedHS1(prefixLen: Int, heroID: Int, skinID: Int) -> Data {
            var d = Data(repeating: 0x11, count: prefixLen)
            appendU32LE(&d, 10)
            d.append(inst(0x47, 0))
            d.append(inst(0xA4, 1)); d.append(inst(0xA7, 80)); d.append(inst(0x8F, Int32(heroID)))
            d.append(inst(0xA6, 0)); d.append(inst(0x86, 3)); d.append(inst(0x8F, 1)); d.append(inst(0xAD, 1))
            d.append(inst(0x8F, 0)); d.append(inst(0xAD, 1))
            d.append(Data(repeating: 0x00, count: 4))

            appendU32LE(&d, 64)
            for _ in 0..<64 { d.append(inst(0x00, 0)) }
            d.append(Data(repeating: 0x00, count: 4))

            appendU32LE(&d, 64)
            for i in 0..<64 {
                switch i {
                case 56: d.append(inst(0xA6, 0))
                case 57: d.append(inst(0x86, 3))
                case 58: d.append(inst(0x8F, Int32(skinID)))
                case 59: d.append(inst(0xAD, 1))
                default: d.append(inst(0x00, 0))
                }
            }
            d.append(Data("KernelLua.pkg.bytes 00000000000000000000000000000000\0".utf8))
            return d
        }
        func makeShiftedHS2(prefixLen: Int, heroID: Int, bcast: Int, pbtn: Int) -> Data {
            var d = Data(repeating: 0x22, count: prefixLen)
            appendU32LE(&d, 70)
            for i in 0..<70 {
                switch i {
                case 58: d.append(inst(0xA4, 1))
                case 59: d.append(inst(0x8F, Int32(heroID)))
                case 60: d.append(inst(0xA6, 0))
                case 61: d.append(inst(0x86, 8))
                case 62: d.append(inst(0xA4, 0))
                case 63: d.append(inst(0x8F, Int32(bcast)))
                case 64: d.append(inst(0x4B, 3))
                case 65: d.append(inst(0xA4, 0))
                case 66: d.append(inst(0x8F, Int32(pbtn)))
                case 67: d.append(inst(0x4B, 2))
                default: d.append(inst(0x00, 0))
                }
            }
            d.append(Data("kernellua.pkg.bytes 11111111111111111111111111111111\0".utf8))
            return d
        }
        func makeMses(records: [(UInt32, Data)]) -> Data {
            var payload = Data()
            var maxRecLen: UInt32 = 0
            for (rid, body) in records {
                let rlen = UInt32(4 + body.count)
                if rlen > maxRecLen { maxRecLen = rlen }
                appendU32LE(&payload, rlen)
                appendU32LE(&payload, rid)
                payload.append(body)
            }
            var hdr = Data("MSES".utf8)
            appendU32LE(&hdr, 1)
            appendU32LE(&hdr, maxRecLen)
            appendU32LE(&hdr, UInt32(records.count))
            hdr.append(Data(repeating: 0, count: 96 - hdr.count))
            hdr.append(Data(md5Lower(payload).utf8))
            hdr.append(Data(repeating: 0, count: 140 - hdr.count))
            return hdr + payload
        }

        let baseXml = """
        <Project><Action>
          <Track trackName="BaseHit" eventType="HitTrigger" guid="g-base-0" SkinAvatarFilterType="SkinOnly">
            <Condition id="-1" guid="" status="true" />
            <Event time="0" />
            <SkinOrAvatarList id="13118" />
          </Track>
        </Action></Project>
        """
        let incXml = """
        <Project><Action>
          <Track trackName="BaseHit" eventType="HitTrigger" guid="" SkinAvatarFilterType="SkinOnly">
            <Condition id="-1" guid="" status="true" />
            <Condition id="1" guid="" status="false" />
            <Event time="0" />
          </Track>
          <Track trackName="Amily19309RecallReceiver" eventType="PlayFx" guid="">
            <Event time="10" />
          </Track>
        </Action></Project>
        """
        let encBaseBackXml = try engine.jgEncrypt(Data(baseXml.utf8), stem: "Back")
        let commonA = try converter.buildZipArchive(entries: [("Back.xml", encBaseBackXml)])
        let commonB = try converter.buildZipArchive(entries: [("Back.xml", Data(incXml.utf8))])
        let kernelA = try converter.buildZipArchive(entries: [("hero131.lua", Data("--131".utf8))])
        let kernelB = try converter.buildZipArchive(entries: [("hero193.lua", Data("--193".utf8))])

        let msesA = try engine.jgEncrypt(makeMses(records: [
            (131001, Data([1, 2, 3, 4])),
            (5930081, Data([9, 9, 9, 9]))
        ]), stem: "HeroSound")
        let msesB = try engine.jgEncrypt(makeMses(records: [
            (193001, Data([5, 6, 7, 8])),
            (5930081, Data([9, 9, 9, 9]))
        ]), stem: "HeroSound")

        let modAURL = tempDirectory.appendingPathComponent("modA_131.zip")
        let modBURL = tempDirectory.appendingPathComponent("modB_193.zip")

        try converter.buildZipArchive(entries: [
            ("__MACOSX/._junk", Data([0])),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/version.txt", Data("1.64.1.12|1793129".utf8)),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/Actor_131_Actions.pkg.bytes", Data("A".utf8)),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes", commonA),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/KernelLua.pkg.bytes", kernelA),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/Databin/Client/Sound/HeroSound.bytes", msesA),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/assetbundle/resourceverificationinfosetall.assetbundle", makeRVBundle(ver: "1.64.1.12", build: "1793129")),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/assetbundle/resourcepackerinfosetall.assetbundle", makeRPBundle(ver: "1.64.1.12", build: "1793129", path1Hash8: Data("KianaMod".utf8), path2Hash8: Data("Stock002".utf8))),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/Thanos/HeroSkin_1.bytes", try engine.jgEncrypt(makeShiftedHS1(prefixLen: 128, heroID: 131, skinID: 13118), stem: "HeroSkin_1")),
            ("Murad/com.garena.game.kgvn/Documents/Resources/1.64.1/Thanos/HeroSkin_2.bytes", try engine.jgEncrypt(makeShiftedHS2(prefixLen: 96, heroID: 131, bcast: 20, pbtn: 21), stem: "HeroSkin_2"))
        ]).write(to: modAURL)

        // Mod B mixes older real RV (1.63.1.14) with spoofed version.txt and flipped path casings
        try converter.buildZipArchive(entries: [
            ("Resources/1.64.1/version.txt", Data("1.64.1.12|1793129".utf8)),
            ("Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/Actor_193_Actions.pkg.bytes", Data("B".utf8)),
            ("Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes", commonB),
            ("Resources/1.64.1/kernellua.pkg.bytes", kernelB),
            ("Resources/1.64.1/databin/client/sound/herosound.bytes", msesB),
            ("Resources/1.64.1/AssetBundle/ResourceVerificationInfoSetAll.assetbundle", makeRVBundle(ver: "1.63.1.14", build: "1747431")),
            ("Resources/1.64.1/AssetBundle/ResourcePackerInfoSetAll.assetbundle", makeRPBundle(ver: "1.64.1.12", build: "1793129", path1Hash8: Data("Stock001".utf8), path2Hash8: Data("KianaMod".utf8))),
            ("Resources/1.64.1/thanos/heroskin_1.bytes", try engine.jgEncrypt(makeShiftedHS1(prefixLen: 256, heroID: 193, skinID: 19300), stem: "HeroSkin_1")),
            ("Resources/1.64.1/thanos/heroskin_2.bytes", try engine.jgEncrypt(makeShiftedHS2(prefixLen: 64, heroID: 193, bcast: 30, pbtn: 31), stem: "HeroSkin_2"))
        ]).write(to: modBURL)

        let res1 = try await engine.mergeModArchives(inputURLs: [modAURL, modBURL]) { _, _ in }
        XCTAssertEqual(res1.outputZipURL.pathExtension.lowercased(), "zip")

        let outEntries = try converter.parseZipArchive(try Data(contentsOf: res1.outputZipURL))
        let outByLower = Dictionary(uniqueKeysWithValues: outEntries.map { ($0.key.lowercased(), $0.value) })
        XCTAssertEqual(outByLower.count, outEntries.count, "No duplicate case-variant paths may exist")

        // Verify merged CommonActions XML tracks, Conditions, and null Condition id="-1"
        let mergedCommon = try converter.parseZipArchive(outByLower["resources/1.64.1/ages/prefab_characters/prefab_hero/commonactions.pkg.bytes"]!)
        let backRaw = try XCTUnwrap(mergedCommon["Back.xml"])
        let backXml = String(data: try engine.decodeAovXmlEntryIfNeeded(backRaw, entryPath: "Back.xml"), encoding: .utf8)!
        XCTAssertTrue(backXml.contains("<SkinOrAvatarList id=\"13118\" />"))
        XCTAssertTrue(backXml.contains("Amily19309RecallReceiver"))
        XCTAssertTrue(backXml.contains("id=\"-1\""))
        XCTAssertTrue(backXml.contains("id=\"1\" status=\"false\""))

        // Verify merged KernelLua contains both hero files + lowercase MD5 updated in HeroSkin_1/2
        let mergedKernelData = outByLower["resources/1.64.1/kernellua.pkg.bytes"]!
        let mergedKernelKeys = Set(try converter.parseZipArchive(mergedKernelData).keys)
        XCTAssertTrue(mergedKernelKeys.contains("hero131.lua"))
        XCTAssertTrue(mergedKernelKeys.contains("hero193.lua"))

        let kernelMd5 = md5Lower(mergedKernelData)
        let decHS1 = try engine.jgDecrypt(outByLower["resources/1.64.1/thanos/heroskin_1.bytes"]!, stem: "HeroSkin_1")
        let decHS2 = try engine.jgDecrypt(outByLower["resources/1.64.1/thanos/heroskin_2.bytes"]!, stem: "HeroSkin_2")
        XCTAssertTrue(String(decoding: decHS1, as: UTF8.self).contains("KernelLua.pkg.bytes \(kernelMd5)"))
        XCTAssertTrue(String(decoding: decHS2, as: UTF8.self).contains("kernellua.pkg.bytes \(kernelMd5)"))

        // Verify merged HeroSound MSES preserves records from both mods and has valid MD5
        let decMSES = try engine.jgDecrypt(outByLower["resources/1.64.1/databin/client/sound/herosound.bytes"]!, stem: "HeroSound")
        let expectedRecCount = UInt32(decMSES[12]) | (UInt32(decMSES[13]) << 8)
        XCTAssertEqual(expectedRecCount, 3)
        let headerMd5 = String(data: decMSES.subdata(in: 96..<128), encoding: .ascii)
        XCTAssertEqual(headerMd5, md5Lower(decMSES.subdata(in: 140..<decMSES.count)))

        // Re-merge previously merged ZIP with a 3rd mod (Hero 190) and verify all 3 heroes survive inspect + merge
        let modCURL = tempDirectory.appendingPathComponent("modC_190.zip")
        try converter.buildZipArchive(entries: [
            ("Resources/1.64.1/version.txt", Data("1.64.1.12|1793129".utf8)),
            ("Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/Actor_190_Actions.pkg.bytes", Data("C".utf8)),
            ("Resources/1.64.1/AssetBundle/ResourceVerificationInfoSetAll.assetbundle", makeRVBundle(ver: "1.64.1.12", build: "1793129")),
            ("Resources/1.64.1/AssetBundle/ResourcePackerInfoSetAll.assetbundle", makeRPBundle(ver: "1.64.1.12", build: "1793129", path1Hash8: Data("Stock001".utf8), path2Hash8: Data("Stock002".utf8))),
            ("Resources/1.64.1/Thanos/HeroSkin_1.bytes", try engine.jgEncrypt(makeShiftedHS1(prefixLen: 40, heroID: 190, skinID: 19015), stem: "HeroSkin_1")),
            ("Resources/1.64.1/Thanos/HeroSkin_2.bytes", try engine.jgEncrypt(makeShiftedHS2(prefixLen: 48, heroID: 190, bcast: 23, pbtn: 25), stem: "HeroSkin_2"))
        ]).write(to: modCURL)

        let res2 = try await engine.mergeModArchives(inputURLs: [res1.outputZipURL, modCURL]) { _, _ in }
        let inspected2 = try engine.inspectModArchive(at: res2.outputZipURL)
        XCTAssertEqual(Set(inspected2.heroIDs), Set([131, 190, 193]))
        XCTAssertEqual(Set(inspected2.skinIDs), Set([13118, 19015, 19300]))
    }
}
