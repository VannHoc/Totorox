import XCTest
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
            name: "Tororox Super Mod",
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
}
