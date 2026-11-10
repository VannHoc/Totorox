import XCTest
@testable import Totorox

final class FileIOEngineTests: XCTestCase {
    var tempDirectory: URL!
    var engine: FileIOEngine!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("TotoroxTest_\(UUID().uuidString)")
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        engine = FileIOEngine(fileManager: fileManager)
    }

    override func tearDown() {
        if let temp = tempDirectory {
            try? fileManager.removeItem(at: temp)
        }
        super.tearDown()
    }

    // MARK: - 1. Test Copy File Trùng Tên (Ghi đè hoàn toàn, không diff/hash)
    func testCopyFileOverwritingSameName() async throws {
        let srcDir = tempDirectory.appendingPathComponent("Src1")
        let destDir = tempDirectory.appendingPathComponent("Dest1")
        try fileManager.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let srcFile = srcDir.appendingPathComponent("test_file.txt")
        let destFile = destDir.appendingPathComponent("test_file.txt")

        let sourceData = "BRAND_NEW_SOURCE_DATA_123456789".data(using: .utf8)!
        let oldDestData = "OLD_EXISTING_DEST_DATA_OLD".data(using: .utf8)!

        try sourceData.write(to: srcFile)
        try oldDestData.write(to: destFile)

        let result = await engine.copyAndMerge(
            from: srcFile,
            to: destFile,
            conflictResolver: { _, _, _ in .replace }
        )

        XCTAssertTrue(result.failed.isEmpty, "Failed records should be empty: \(result.failed)")
        XCTAssertFalse(result.isCancelled, "Operation should not be cancelled")
        XCTAssertTrue(result.succeeded.contains(destFile.standardizedFileURL))

        let readData = try Data(contentsOf: destFile)
        XCTAssertEqual(readData, sourceData, "Destination file must be completely overwritten with source content")
    }

    // MARK: - 2. Test Copy Folder Trùng Tên (Merge đệ quy nhiều cấp)
    func testRecursiveFolderMerge() async throws {
        let srcFolder = tempDirectory.appendingPathComponent("SourceDir2")
        let destFolder = tempDirectory.appendingPathComponent("DestDir2")

        let srcSub1 = srcFolder.appendingPathComponent("sub1")
        let srcSub2Deep = srcFolder.appendingPathComponent("sub2/deep")
        try fileManager.createDirectory(at: srcSub1, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: srcSub2Deep, withIntermediateDirectories: true)

        try "Source Shared".data(using: .utf8)!.write(to: srcSub1.appendingPathComponent("shared.txt"))
        try "Source Only".data(using: .utf8)!.write(to: srcSub1.appendingPathComponent("source_only.txt"))
        try "Deep Leaf".data(using: .utf8)!.write(to: srcSub2Deep.appendingPathComponent("leaf.txt"))

        let destSub1 = destFolder.appendingPathComponent("sub1")
        let destPreserved = destFolder.appendingPathComponent("preserved_folder")
        try fileManager.createDirectory(at: destSub1, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destPreserved, withIntermediateDirectories: true)

        try "Old Dest Shared".data(using: .utf8)!.write(to: destSub1.appendingPathComponent("shared.txt"))
        try "Preserved Dest File".data(using: .utf8)!.write(to: destSub1.appendingPathComponent("dest_only.txt"))
        try "Untouched".data(using: .utf8)!.write(to: destPreserved.appendingPathComponent("untouched.txt"))

        let result = await engine.copyAndMerge(
            from: srcFolder,
            to: destFolder,
            conflictResolver: { _, _, _ in .replace }
        )

        XCTAssertTrue(result.failed.isEmpty, "No errors expected during merge: \(result.failed)")
        XCTAssertFalse(result.isCancelled)

        // 1. Shared file overwritten
        let sharedContent = try String(contentsOf: destSub1.appendingPathComponent("shared.txt"))
        XCTAssertEqual(sharedContent, "Source Shared", "Overwritten file must match source")

        // 2. Source-only file added
        let sourceOnlyContent = try String(contentsOf: destSub1.appendingPathComponent("source_only.txt"))
        XCTAssertEqual(sourceOnlyContent, "Source Only")

        // 3. Deep folder and file created
        let deepLeafContent = try String(contentsOf: destFolder.appendingPathComponent("sub2/deep/leaf.txt"))
        XCTAssertEqual(deepLeafContent, "Deep Leaf")

        // 4. Destination-only items preserved
        let destOnlyContent = try String(contentsOf: destSub1.appendingPathComponent("dest_only.txt"))
        XCTAssertEqual(destOnlyContent, "Preserved Dest File")

        let untouchedContent = try String(contentsOf: destPreserved.appendingPathComponent("untouched.txt"))
        XCTAssertEqual(untouchedContent, "Untouched")
    }

    // MARK: - 3. Test Xung Đột Loại (File vs Folder) - Mock 3 trạng thái Replace / Skip / Cancel
    func testTypeConflict_FileOverwritingFolder_Skip() async throws {
        let srcDir = tempDirectory.appendingPathComponent("SrcSkip3")
        let destDir = tempDirectory.appendingPathComponent("DestSkip3")
        try fileManager.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let srcFile = srcDir.appendingPathComponent("conflict_target")
        let destFolder = destDir.appendingPathComponent("conflict_target")

        try "File Data".data(using: .utf8)!.write(to: srcFile)
        try fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
        let insideDest = destFolder.appendingPathComponent("inside.txt")
        try "Inside Folder".data(using: .utf8)!.write(to: insideDest)

        var promptCalled = false
        let result = await engine.copyAndMerge(
            from: srcFile,
            to: destFolder,
            conflictResolver: { src, dst, kind in
                promptCalled = true
                XCTAssertEqual(kind, .fileOverwritingFolder)
                return .skip
            }
        )

        XCTAssertTrue(promptCalled, "Conflict resolver must be triggered")
        XCTAssertTrue(fileManager.fileExists(atPath: insideDest.path), "Destination folder must NOT be deleted when skipped")
        XCTAssertTrue(result.skipped.contains(srcFile.standardizedFileURL))
    }

    func testTypeConflict_FileOverwritingFolder_Cancel() async throws {
        let srcDir = tempDirectory.appendingPathComponent("SrcCancel3")
        let destDir = tempDirectory.appendingPathComponent("DestCancel3")
        try fileManager.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let srcFile = srcDir.appendingPathComponent("conflict_target_cancel")
        let destFolder = destDir.appendingPathComponent("conflict_target_cancel")

        try "File Data".data(using: .utf8)!.write(to: srcFile)
        try fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
        let insideDest = destFolder.appendingPathComponent("important.txt")
        try "Important Data".data(using: .utf8)!.write(to: insideDest)

        let result = await engine.copyAndMerge(
            from: srcFile,
            to: destFolder,
            conflictResolver: { _, _, kind in
                XCTAssertEqual(kind, .fileOverwritingFolder)
                return .cancel
            }
        )

        XCTAssertTrue(result.isCancelled, "Result must indicate cancellation")
        XCTAssertTrue(fileManager.fileExists(atPath: insideDest.path), "Destination folder must NOT be deleted on cancel")
    }

    func testTypeConflict_FileOverwritingFolder_Replace() async throws {
        let srcDir = tempDirectory.appendingPathComponent("SrcReplace3")
        let destDir = tempDirectory.appendingPathComponent("DestReplace3")
        try fileManager.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let srcFile = srcDir.appendingPathComponent("conflict_replace")
        let destFolder = destDir.appendingPathComponent("conflict_replace")

        try "Replacement File".data(using: .utf8)!.write(to: srcFile)
        try fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
        try "Old Nested".data(using: .utf8)!.write(to: destFolder.appendingPathComponent("nested.txt"))

        let result = await engine.copyAndMerge(
            from: srcFile,
            to: destFolder,
            conflictResolver: { _, _, kind in
                XCTAssertEqual(kind, .fileOverwritingFolder)
                return .replace
            }
        )

        XCTAssertFalse(result.isCancelled)
        XCTAssertTrue(result.failed.isEmpty, "Failed records should be empty: \(result.failed)")
        var isDir: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: destFolder.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue, "Destination should now be a regular file after Replace")
        let content = try String(contentsOf: destFolder)
        XCTAssertEqual(content, "Replacement File")
    }

    func testTypeConflict_FolderOverwritingFile_SkipAndReplace() async throws {
        let srcDir = tempDirectory.appendingPathComponent("SrcFolderConflict3")
        let destDir = tempDirectory.appendingPathComponent("DestFolderConflict3")
        try fileManager.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let srcFolder = srcDir.appendingPathComponent("conflict_folder")
        let destFile = destDir.appendingPathComponent("conflict_folder")

        try fileManager.createDirectory(at: srcFolder, withIntermediateDirectories: true)
        try "Nested in src".data(using: .utf8)!.write(to: srcFolder.appendingPathComponent("item.txt"))
        try "Existing file at dest".data(using: .utf8)!.write(to: destFile)

        // 1. Skip
        let skipResult = await engine.copyAndMerge(
            from: srcFolder,
            to: destFile,
            conflictResolver: { _, _, kind in
                XCTAssertEqual(kind, .folderOverwritingFile)
                return .skip
            }
        )
        XCTAssertTrue(skipResult.skipped.contains(srcFolder.standardizedFileURL))
        var isDir: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: destFile.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue, "Destination file must still remain a file")

        // 2. Replace
        let replaceResult = await engine.copyAndMerge(
            from: srcFolder,
            to: destFile,
            conflictResolver: { _, _, kind in
                XCTAssertEqual(kind, .folderOverwritingFile)
                return .replace
            }
        )
        XCTAssertFalse(replaceResult.isCancelled)
        XCTAssertTrue(replaceResult.failed.isEmpty, "Failed records should be empty: \(replaceResult.failed)")
        XCTAssertTrue(fileManager.fileExists(atPath: destFile.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "Destination must now be a directory")
        XCTAssertTrue(fileManager.fileExists(atPath: destFile.appendingPathComponent("item.txt").path))
    }

    // MARK: - 4. Test Hủy thao tác & Báo cáo kết quả I/O chính xác
    func testCancellationAndFailureReporting() async throws {
        let srcFolder = tempDirectory.appendingPathComponent("CancelTestSrc4")
        let destFolder = tempDirectory.appendingPathComponent("CancelTestDst4")

        try fileManager.createDirectory(at: srcFolder, withIntermediateDirectories: true)
        for i in 1...5 {
            try "Data \(i)".data(using: .utf8)!.write(to: srcFolder.appendingPathComponent("file\(i).txt"))
        }

        let task = Task {
            await engine.copyAndMerge(
                from: srcFolder,
                to: destFolder,
                conflictResolver: { _, _, _ in .replace }
            )
        }
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.isCancelled, "Operation should be marked as cancelled")
        XCTAssertTrue(result.succeeded.count + result.failed.count + result.skipped.count > 0, "Reporting must track items accurately")
    }

    // MARK: - 5. Test Windows Conflict Prompt: Replace All & Skip
    func testWindowsFileCollision_WithReplaceAll_OverwritesAllSubsequentFiles() async throws {
        let srcDir = tempDirectory.appendingPathComponent("Src5")
        let destDir = tempDirectory.appendingPathComponent("Dest5")
        try fileManager.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        try "New 1".data(using: .utf8)!.write(to: srcDir.appendingPathComponent("f1.txt"))
        try "New 2".data(using: .utf8)!.write(to: srcDir.appendingPathComponent("f2.txt"))

        try "Old 1".data(using: .utf8)!.write(to: destDir.appendingPathComponent("f1.txt"))
        try "Old 2".data(using: .utf8)!.write(to: destDir.appendingPathComponent("f2.txt"))

        var promptCount = 0
        let result = await engine.copyAndMerge(
            from: srcDir,
            to: destDir,
            conflictResolver: { _, _, _ in
                promptCount += 1
                return .replaceAll
            }
        )

        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(promptCount, 1, "ReplaceAll should only prompt once and auto-overwrite subsequent colliding files")
        XCTAssertEqual(try String(contentsOf: destDir.appendingPathComponent("f1.txt")), "New 1")
        XCTAssertEqual(try String(contentsOf: destDir.appendingPathComponent("f2.txt")), "New 2")
    }

    func testWindowsFileCollision_WithSkip_PreservesDestinationFile() async throws {
        let srcFile = tempDirectory.appendingPathComponent("src_skip.txt")
        let destFile = tempDirectory.appendingPathComponent("dst_skip.txt")
        try "New Data".data(using: .utf8)!.write(to: srcFile)
        try "Old Data".data(using: .utf8)!.write(to: destFile)

        let result = await engine.copyAndMerge(
            from: srcFile,
            to: destFile,
            conflictResolver: { _, _, _ in .skip }
        )

        XCTAssertTrue(result.skipped.contains(srcFile.standardizedFileURL))
        XCTAssertEqual(try String(contentsOf: destFile), "Old Data", "Destination must remain untouched on Skip")
    }

    // MARK: - 6. Regression Test Bug 1: Không Hijack sang danh sách App khi thư mục con rỗng hoặc có tên giống Bundle ID
    func testSubfolderInsideContainer_DoesNotHijackToAppListWhenEmptyOrBundleIDNamed() throws {
        // Seed a fake app in ContainerMetadataCache to ensure the cache is non-empty
        ContainerMetadataCache.shared.store(
            app: AppContainerMetadata(
                uuid: UUID().uuidString,
                containerPath: "/var/mobile/Containers/Data/Application/\(UUID().uuidString)",
                bundleID: "ai.x.GrokApp",
                appName: "ai.x.GrokApp",
                icon: nil,
                isUserApp: true,
                modificationDate: nil
            )
        )
        ContainerMetadataCache.shared.rebuildApplicationDirectoryListCache()

        let fakeContainerSubdir = tempDirectory
            .appendingPathComponent("Containers/Data/Application/\(UUID().uuidString)/Documents/Patches/Patch1", isDirectory: true)
        let bundleNamedFolder = fakeContainerSubdir.appendingPathComponent("com.apple.AAUIViewService", isDirectory: true)
        try fileManager.createDirectory(at: bundleNamedFolder, withIntermediateDirectories: true)

        let beforeDelete = ContainerStore.listFiles(at: fakeContainerSubdir.path)
        XCTAssertEqual(beforeDelete.count, 1)
        XCTAssertEqual(beforeDelete.first?.name, "com.apple.AAUIViewService")
        XCTAssertFalse(beforeDelete.first?.isAppContainer ?? true, "Regular subfolder must never be marked as an App Container")

        // Delete the subfolder so Patch1 is now empty
        try fileManager.removeItem(at: bundleNamedFolder)
        let afterDelete = ContainerStore.listFiles(at: fakeContainerSubdir.path)
        XCTAssertTrue(afterDelete.isEmpty, "Empty subfolder inside container must return [] and NEVER hijack into the installed apps list")
    }

    // MARK: - 7. Regression Test Bug 2: Không tự động nhân bản thư mục ma "... 2"
    func testPatchWorkspace_DoesNotCreateGhostDuplicateSuffix2() throws {
        let patchesRoot = tempDirectory.appendingPathComponent("Patches", isDirectory: true)
        let existingFolder = patchesRoot.appendingPathComponent("Amily Đông Hải Long Vương", isDirectory: true)
        try fileManager.createDirectory(at: existingFolder, withIntermediateDirectories: true)

        let rule = PatchRule(
            id: UUID(),
            bundleID: "com.garena.game.kgvn",
            relativePath: "Documents/test.bin",
            replacementFilename: "test.bin",
            replacementData: Data([0x01, 0x02])
        )
        let project = PatchProject(
            id: UUID(),
            name: "Amily Đông Hải Long Vương",
            author: "VannHoc",
            isPrivate: false,
            createdAt: Date(),
            updatedAt: Date(),
            bundleIdentifiers: ["com.garena.game.kgvn"],
            directories: [],
            rules: [rule]
        )

        let workspace = try PatchWorkspaceService.createWorkspace(
            for: project,
            patchesRoot: patchesRoot,
            fileManager: fileManager
        )
        XCTAssertEqual(workspace.lastPathComponent, "Amily Đông Hải Long Vương")
        let ghostDuplicate = patchesRoot.appendingPathComponent("Amily Đông Hải Long Vương 2")
        XCTAssertFalse(fileManager.fileExists(atPath: ghostDuplicate.path), "Ghost duplicate ' 2' folder must never be created")
    }

    // MARK: - 8. Regression Test: Không báo xung đột giả khi copy vào thư mục đích hoặc thư mục rỗng
    func testCopySingleFile_IntoParentDirectoryWithoutFilename_DoesNotFalseConflict() async throws {
        let patchesDir = tempDirectory.appendingPathComponent("Patches", isDirectory: true)
        try fileManager.createDirectory(at: patchesDir, withIntermediateDirectories: true)

        let srcZip = tempDirectory.appendingPathComponent("NgoKhongVoTuong.zip")
        try "ZIP_BYTES".data(using: .utf8)!.write(to: srcZip)

        var promptCount = 0
        let result = await engine.copyAndMerge(
            from: srcZip,
            to: patchesDir,
            conflictResolver: { _, _, _ in
                promptCount += 1
                return .cancel
            }
        )

        XCTAssertEqual(promptCount, 0, "Copying a new file into parent directory must NEVER prompt for fileOverwritingFolder conflict")
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: patchesDir.appendingPathComponent("NgoKhongVoTuong.zip").path))
    }

    func testCopyDirectory_IntoExistingNonCollidingFolder_AutoMergesWithoutPrompt() async throws {
        let stagingDir = tempDirectory.appendingPathComponent("ExtractStaging", isDirectory: true)
        let patchesDir = tempDirectory.appendingPathComponent("PatchesExisting", isDirectory: true)
        try fileManager.createDirectory(at: stagingDir.appendingPathComponent("files/sub"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: patchesDir.appendingPathComponent("files"), withIntermediateDirectories: true)
        try "NEW_CONTENT".data(using: .utf8)!.write(to: stagingDir.appendingPathComponent("files/sub/hero.bytes"))
        try "EXISTING_OTHER".data(using: .utf8)!.write(to: patchesDir.appendingPathComponent("files/keep.txt"))

        var promptCount = 0
        let result = await engine.copyAndMerge(
            from: stagingDir,
            to: patchesDir,
            conflictResolver: { _, _, _ in
                promptCount += 1
                return .cancel
            }
        )

        XCTAssertEqual(promptCount, 0, "Directory-over-directory merge with non-colliding children must NEVER prompt")
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(try String(contentsOf: patchesDir.appendingPathComponent("files/sub/hero.bytes")), "NEW_CONTENT")
        XCTAssertEqual(try String(contentsOf: patchesDir.appendingPathComponent("files/keep.txt")), "EXISTING_OTHER")
    }

    // MARK: - 9. Regression Test: Replace All phải triệt tiêu mọi popup tiếp theo (cả File-vs-File và Type Conflict)
    func testReplaceAllConflicts_SuppressesAllSubsequentPrompts_IncludingTypeConflicts() async throws {
        let srcDir = tempDirectory.appendingPathComponent("SrcReplaceAll", isDirectory: true)
        let destDir = tempDirectory.appendingPathComponent("DestReplaceAll", isDirectory: true)
        try fileManager.createDirectory(at: srcDir.appendingPathComponent("a_nested"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Multiple colliding items: file-vs-file AND folder-vs-file AND file-vs-folder
        try "new_a".data(using: .utf8)!.write(to: srcDir.appendingPathComponent("file1.txt"))
        try "new_b".data(using: .utf8)!.write(to: srcDir.appendingPathComponent("file2.txt"))
        try "new_nested".data(using: .utf8)!.write(to: srcDir.appendingPathComponent("a_nested/inner.txt"))
        try "new_type".data(using: .utf8)!.write(to: srcDir.appendingPathComponent("type_item"))

        try "old_a".data(using: .utf8)!.write(to: destDir.appendingPathComponent("file1.txt"))
        try "old_b".data(using: .utf8)!.write(to: destDir.appendingPathComponent("file2.txt"))
        try "old_file_where_folder_goes".data(using: .utf8)!.write(to: destDir.appendingPathComponent("a_nested"))
        try fileManager.createDirectory(at: destDir.appendingPathComponent("type_item"), withIntermediateDirectories: true)
        try "inside_old_dir".data(using: .utf8)!.write(to: destDir.appendingPathComponent("type_item/stale.txt"))

        var promptCount = 0
        let result = await engine.copyAndMerge(
            from: srcDir,
            to: destDir,
            conflictResolver: { _, _, _ in
                promptCount += 1
                return .replaceAll
            }
        )

        XCTAssertTrue(result.failed.isEmpty, "Errors: \(result.failed)")
        XCTAssertEqual(promptCount, 1, "Selecting Replace All on the first conflict must suppress ALL subsequent prompts including type conflicts")
        XCTAssertTrue(engine.shouldReplaceAllConflicts)
        XCTAssertEqual(try String(contentsOf: destDir.appendingPathComponent("file1.txt")), "new_a")
        XCTAssertEqual(try String(contentsOf: destDir.appendingPathComponent("file2.txt")), "new_b")
        XCTAssertEqual(try String(contentsOf: destDir.appendingPathComponent("a_nested/inner.txt")), "new_nested")
        XCTAssertEqual(try String(contentsOf: destDir.appendingPathComponent("type_item")), "new_type")
    }
}
