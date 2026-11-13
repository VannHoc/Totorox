import XCTest
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
        XCTAssertFalse(AovModMergerEngine.isServerConfigPath(
            "Resources/1.64.1/AssetBundle/ResourcePackerInfoSetAll.assetbundle"
        ))
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

    func testMergeModArchives_RequiresAtLeastTwoMods() async {
        let engine = AovModMergerEngine.shared
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
}
