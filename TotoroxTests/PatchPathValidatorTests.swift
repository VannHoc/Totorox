import XCTest
@testable import Totorox

final class PatchPathValidatorTests: XCTestCase {
    func testAcceptsSafeRelativeContainerPaths() throws {
        XCTAssertEqual(try PatchPathValidator.canonicalRelativePath("Documents"), "Documents")
        XCTAssertEqual(try PatchPathValidator.canonicalRelativePath("Documents/Assets"), "Documents/Assets")
        XCTAssertEqual(try PatchPathValidator.canonicalRelativePath("Library/Caches"), "Library/Caches")
        XCTAssertEqual(
            try PatchPathValidator.canonicalRelativePath("  Documents/Assets  "),
            "Documents/Assets"
        )
    }

    func testFileManagerValidatedNameRejectsTraversalAndSeparators() throws {
        XCTAssertEqual(try FileManagerService.validatedName("  New Folder  "), "New Folder")

        for name in ["", ".", "..", "../escape", "a/b", "a\\b", "bad\u{0000}name"] {
            XCTAssertThrowsError(
                try FileManagerService.validatedName(name),
                "Expected name to be rejected: \(name.debugDescription)"
            )
        }
    }

    func testRejectsPathsThatEscapeTheContainer() {
        let invalidPaths = [
            "",
            "..",
            "../Foo",
            "Documents/../../Foo",
            "Documents/../Library",
            "/private/var/mobile",
            "Documents//Assets",
            "Documents\\Assets",
            "Documents/./Assets",
            "Documents/Assets\u{0000}"
        ]

        for path in invalidPaths {
            XCTAssertThrowsError(
                try PatchPathValidator.canonicalRelativePath(path),
                "Expected path to be rejected: \(path.debugDescription)"
            )
        }
    }
}
