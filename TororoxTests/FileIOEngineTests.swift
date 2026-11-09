import XCTest
@testable import Tororox

final class FileIOEngineTests: XCTestCase {
    var tempDirectory: URL!
    var engine: FileIOEngine!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("TororoxTest_\(UUID().uuidString)")
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
        let srcFile = tempDirectory.appendingPathComponent("source_file.txt")
        let destFile = tempDirectory.appendingPathComponent("dest_file.txt")

        let sourceData = "BRAND_NEW_SOURCE_DATA_123456789".data(using: .utf8)!
        let oldDestData = "OLD_EXISTING_DEST_DATA_OLD".data(using: .utf8)!

        try sourceData.write(to: srcFile)
        try oldDestData.write(to: destFile)

        let result = await engine.copyAndMerge(
            from: srcFile,
            to: destFile,
            conflictResolver: { _, _, _ in .replace }
        )

        XCTAssertTrue(result.failed.isEmpty, "Failed records should be empty")
        XCTAssertFalse(result.isCancelled, "Operation should not be cancelled")
        XCTAssertTrue(result.succeeded.contains(destFile.standardizedFileURL))

        let readData = try Data(contentsOf: destFile)
        XCTAssertEqual(readData, sourceData, "Destination file must be completely overwritten with source content")
    }

    // MARK: - 2. Test Copy Folder Trùng Tên (Merge đệ quy nhiều cấp)
    func testRecursiveFolderMerge() async throws {
        let srcFolder = tempDirectory.appendingPathComponent("SourceDir")
        let destFolder = tempDirectory.appendingPathComponent("DestDir")

        // Setup source structure:
        // SourceDir/
        //   sub1/
        //     shared.txt ("Source Shared")
        //     source_only.txt ("Source Only")
        //   sub2/
        //     deep/
        //       leaf.txt ("Deep Leaf")
        let srcSub1 = srcFolder.appendingPathComponent("sub1")
        let srcSub2Deep = srcFolder.appendingPathComponent("sub2/deep")
        try fileManager.createDirectory(at: srcSub1, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: srcSub2Deep, withIntermediateDirectories: true)

        try "Source Shared".data(using: .utf8)!.write(to: srcSub1.appendingPathComponent("shared.txt"))
        try "Source Only".data(using: .utf8)!.write(to: srcSub1.appendingPathComponent("source_only.txt"))
        try "Deep Leaf".data(using: .utf8)!.write(to: srcSub2Deep.appendingPathComponent("leaf.txt"))

        // Setup destination structure:
        // DestDir/
        //   sub1/
        //     shared.txt ("Old Dest Shared")
        //     dest_only.txt ("Preserved Dest File")
        //   preserved_folder/
        //     untouched.txt ("Untouched")
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

        XCTAssertTrue(result.failed.isEmpty, "No errors expected during merge")
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
        let srcFile = tempDirectory.appendingPathComponent("conflict_target")
        let destFolder = tempDirectory.appendingPathComponent("conflict_target")

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
        let srcFile = tempDirectory.appendingPathComponent("conflict_target_cancel")
        let destFolder = tempDirectory.appendingPathComponent("conflict_target_cancel")

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
        let srcFile = tempDirectory.appendingPathComponent("conflict_replace_src")
        let destFolder = tempDirectory.appendingPathComponent("conflict_replace_dst")

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
        XCTAssertTrue(result.failed.isEmpty)
        var isDir: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: destFolder.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue, "Destination should now be a regular file after Replace")
        let content = try String(contentsOf: destFolder)
        XCTAssertEqual(content, "Replacement File")
    }

    func testTypeConflict_FolderOverwritingFile_SkipAndReplace() async throws {
        let srcFolder = tempDirectory.appendingPathComponent("src_folder")
        let destFile = tempDirectory.appendingPathComponent("dest_file")

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
        XCTAssertTrue(replaceResult.failed.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: destFile.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "Destination must now be a directory")
        XCTAssertTrue(fileManager.fileExists(atPath: destFile.appendingPathComponent("item.txt").path))
    }

    // MARK: - 4. Test Hủy thao tác & Báo cáo kết quả I/O chính xác
    func testCancellationAndFailureReporting() async throws {
        let srcFolder = tempDirectory.appendingPathComponent("CancelTestSrc")
        let destFolder = tempDirectory.appendingPathComponent("CancelTestDst")

        try fileManager.createDirectory(at: srcFolder, withIntermediateDirectories: true)
        for i in 1...5 {
            try "Data \(i)".data(using: .utf8)!.write(to: srcFolder.appendingPathComponent("file\(i).txt"))
        }

        // Simulating cancellation task
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
        // Check that result accurately tracks items
        XCTAssertTrue(result.succeeded.count + result.failed.count + result.skipped.count > 0, "Reporting must track items accurately")
    }
}
