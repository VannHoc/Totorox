import XCTest
@testable import Totorox

final class OverwriteBackupManagerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwriteBackupTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @MainActor
    func testAutoBackupAndFullRestoreRevertsOriginalAndRemovesNewFiles() async throws {
        let fm = FileManager.default
        let backupRoot = tempRoot.appendingPathComponent("Backups", isDirectory: true)
        let sourceRoot = tempRoot.appendingPathComponent("SourcePatch", isDirectory: true)
        let destRoot = tempRoot.appendingPathComponent("TargetDocuments", isDirectory: true)

        try fm.createDirectory(at: sourceRoot.appendingPathComponent("Resources/1.64.1/NewMod", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: destRoot.appendingPathComponent("Resources/1.64.1", isDirectory: true), withIntermediateDirectories: true)

        let existingRel = "Resources/1.64.1/heroSkin.bytes"
        let addedRel = "Resources/1.64.1/NewMod/extra.bytes"
        let skippedRel = "Resources/1.64.1/keep_me.bytes"

        let origHeroData = Data("ORIGINAL_HERO_SKIN_DATA_12345".utf8)
        let modHeroData = Data("MODDED_HERO_SKIN_PAYLOAD_9999999".utf8)
        let addedModData = Data("BRAND_NEW_MOD_ASSET".utf8)
        let keepOrigData = Data("KEEP_ME_ORIGINAL".utf8)
        let keepModData = Data("KEEP_ME_MODDED".utf8)

        try origHeroData.write(to: destRoot.appendingPathComponent(existingRel))
        try keepOrigData.write(to: destRoot.appendingPathComponent(skippedRel))

        try modHeroData.write(to: sourceRoot.appendingPathComponent(existingRel))
        try addedModData.write(to: sourceRoot.appendingPathComponent(addedRel))
        try keepModData.write(to: sourceRoot.appendingPathComponent(skippedRel))

        let manager = OverwriteBackupManager(rootDirectory: backupRoot, maxRetainedSessions: 5)
        let recorder = manager.createRecorder(
            patchName: "TestMod_20Skins.zip",
            bundleID: "",
            appName: "TestGame",
            targetSubfolder: "Documents",
            destinationRoot: destRoot
        )

        let mappings: [(source: String, destination: String)] = [
            (source: existingRel, destination: existingRel),
            (source: addedRel, destination: addedRel),
            (source: skippedRel, destination: skippedRel)
        ]

        let ioResult = await FileIOEngine.shared.applyMappedFiles(
            mappings,
            from: sourceRoot,
            to: destRoot,
            beforeWriteFile: { destURL, existedBefore in
                recorder.recordBeforeWrite(destinationURL: destURL, existedBefore: existedBefore)
            },
            conflictResolver: { _, destURL, _ in
                if destURL.lastPathComponent == "keep_me.bytes" {
                    return .skip
                }
                return .replace
            }
        )

        XCTAssertEqual(ioResult.succeeded.count, 2)
        XCTAssertEqual(ioResult.skipped.count, 1)
        XCTAssertEqual(try Data(contentsOf: destRoot.appendingPathComponent(existingRel)), modHeroData)
        XCTAssertEqual(try Data(contentsOf: destRoot.appendingPathComponent(addedRel)), addedModData)
        XCTAssertEqual(try Data(contentsOf: destRoot.appendingPathComponent(skippedRel)), keepOrigData)

        let finalized = recorder.finalize(succeededURLs: ioResult.succeeded)
        XCTAssertNotNil(finalized)
        let session = try XCTUnwrap(finalized)
        XCTAssertEqual(session.totalFilesCount, 2)
        XCTAssertEqual(session.overwrittenCount, 1)
        XCTAssertEqual(session.addedCount, 1)
        XCTAssertEqual(session.totalBackupBytes, Int64(origHeroData.count))
        XCTAssertFalse(session.isRestored)

        manager.saveSession(session)
        XCTAssertEqual(manager.sessions.count, 1)

        // Khôi phục về trạng thái trước khi đè file
        let restoreResult = await manager.restoreSession(session)
        XCTAssertFalse(restoreResult.hasFailures)
        XCTAssertEqual(restoreResult.restoredOriginalCount, 1)
        XCTAssertEqual(restoreResult.deletedNewCount, 1)

        // File gốc trở về nguyên vẹn, file mới thêm bị xóa, thư mục con mới rỗng bị dọn, file bị skip không đổi
        XCTAssertEqual(try Data(contentsOf: destRoot.appendingPathComponent(existingRel)), origHeroData)
        XCTAssertFalse(fm.fileExists(atPath: destRoot.appendingPathComponent(addedRel).path))
        XCTAssertFalse(fm.fileExists(atPath: destRoot.appendingPathComponent("Resources/1.64.1/NewMod").path))
        XCTAssertEqual(try Data(contentsOf: destRoot.appendingPathComponent(skippedRel)), keepOrigData)

        // Kiểm tra lưu trữ trạng thái isRestored qua reload
        let reloaded = OverwriteBackupManager(rootDirectory: backupRoot, maxRetainedSessions: 5)
        XCTAssertEqual(reloaded.sessions.count, 1)
        XCTAssertTrue(reloaded.sessions[0].isRestored)
    }

    @MainActor
    func testRetentionLimitPrunesOldestBackupDirectories() throws {
        let fm = FileManager.default
        let backupRoot = tempRoot.appendingPathComponent("RetentionBackups", isDirectory: true)
        let manager = OverwriteBackupManager(rootDirectory: backupRoot, maxRetainedSessions: 2)

        var createdIDs: [UUID] = []
        for idx in 1...3 {
            let sid = UUID()
            createdIDs.append(sid)
            let sDir = backupRoot.appendingPathComponent(sid.uuidString, isDirectory: true)
            try fm.createDirectory(at: sDir, withIntermediateDirectories: true)
            let session = OverwriteBackupSession(
                id: sid,
                patchName: "Mod_\(idx).zip",
                bundleID: "com.example.game",
                appName: "Game",
                targetSubfolder: "Documents",
                destinationRootPath: tempRoot.path,
                entries: [
                    OverwriteBackupEntry(
                        relativePath: "a.bin",
                        destinationPath: tempRoot.appendingPathComponent("a.bin").path,
                        backupRelativePath: nil,
                        wasNewFile: true,
                        originalSize: nil,
                        writtenSize: 10
                    )
                ],
                totalBackupBytes: 0
            )
            manager.saveSession(session)
        }

        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.sessions.map(\.patchName), ["Mod_3.zip", "Mod_2.zip"])
        XCTAssertFalse(fm.fileExists(atPath: backupRoot.appendingPathComponent(createdIDs[0].uuidString).path))
    }
}
