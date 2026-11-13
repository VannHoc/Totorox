import XCTest
@testable import Totorox

final class ArchiveSizeLimitTests: XCTestCase {
    private var converter: PatchZipConverter!
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        converter = PatchZipConverter()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveSizeLimitTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    func testHardLimitIsThreePointSixGigabytes() {
        XCTAssertEqual(PatchPackageLimits.maximumExpandedBytes, 3_600_000_000)
        XCTAssertEqual(PatchPackageLimits.maximumExpandedBytesUnsigned, 3_600_000_000)
    }

    func testExpandedLimitBoundaryIsInclusive() {
        XCTAssertFalse(PatchPackageLimits.exceedsExpandedLimit(UInt64(3_600_000_000)))
        XCTAssertTrue(PatchPackageLimits.exceedsExpandedLimit(UInt64(3_600_000_001)))

        XCTAssertFalse(PatchPackageLimits.exceedsExpandedLimit(Int64(0)))
        XCTAssertFalse(PatchPackageLimits.exceedsExpandedLimit(Int64(3_600_000_000)))
        XCTAssertTrue(PatchPackageLimits.exceedsExpandedLimit(Int64(3_600_000_001)))
    }

    func testParseZipArchiveRejectsDeclaredExpansionAboveLimit() {
        // Minimal EOCD + one central-directory record that *declares* a 3.7 GB
        // uncompressed entry. The parser must reject on the declared size before
        // trying to allocate or read the payload.
        var data = Data()
        func u16(_ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        func u32(_ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }

        let inflatedSize: UInt32 = 3_700_000_000
        u32(0x0201_4B50)        // Central directory signature
        u16(20)                 // Version made by
        u16(20)                 // Version needed
        u16(0)                  // Flags
        u16(8)                  // Method: deflate
        u16(0)                  // Mod time
        u16(0)                  // Mod date
        u32(0)                  // CRC
        u32(0)                  // Compressed size
        u32(inflatedSize)       // Uncompressed size
        u16(0)                  // Name length
        u16(0)                  // Extra length
        u16(0)                  // Comment length
        u16(0)                  // Disk number
        u16(0)                  // Internal attributes
        u32(0)                  // External attributes
        u32(0)                  // Local header offset
        u32(0x0605_4B50)        // EOCD signature
        u16(0)                  // Disk number
        u16(0)                  // Central directory disk
        u16(1)                  // Entries on this disk
        u16(1)                  // Total entries
        u32(46)                 // Central directory size
        u32(0)                  // Central directory offset
        u16(0)                  // Comment length

        XCTAssertThrowsError(try converter.parseZipArchive(data)) { error in
            XCTAssertEqual(error as? PatchZipConverterError, PatchZipConverterError.sizeLimitExceeded)
        }
    }

    func testBuildZipArchiveStaysWithinLimitForNormalEntries() throws {
        let entries: [(path: String, data: Data)] = [
            ("Resources/one.bin", Data(repeating: 0x11, count: 4_096)),
            ("Resources/two.bin", Data(repeating: 0x22, count: 4_096))
        ]
        let archive = try converter.buildZipArchive(entries: entries)
        let parsed = try converter.parseZipArchive(archive)

        XCTAssertEqual(parsed.count, entries.count)
        for (path, payload) in entries {
            XCTAssertEqual(parsed[path], payload)
        }
    }
}
