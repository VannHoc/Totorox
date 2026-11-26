import XCTest
@testable import Totorox

/// Tests for the `worse_query` path helpers, `SandboxGrantRouter` access checks,
/// and `ExploitSupportPolicy` build-train boundaries on iOS 26–27.3 beta 1.
///
/// These never touch the private ContainerManager API: the C helpers under test
/// only manipulate a temporary directory, so everything runs on the simulator.
final class WorseQueryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wq-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func cachesPath() -> String {
        root.appendingPathComponent("group/Library/Caches", isDirectory: true).path
    }

    private func makeCachesDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: cachesPath(),
            withIntermediateDirectories: true
        )
    }

    private func makeTarget(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func swap(_ caches: String, _ target: String, requireExists: Bool) -> Bool {
        WorseQuery.swapCaches(at: caches, to: target, requireTargetExists: requireExists)
    }

    private func restore(_ caches: String) -> Bool {
        WorseQuery.restoreCaches(at: caches)
    }

    private func recover(_ caches: String) -> Bool {
        WorseQuery.recoverCaches(at: caches)
    }

    private func isSymlink(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // MARK: - Swap

    func testSwapCreatesSymlinkToTarget() throws {
        try makeCachesDirectory()
        let target = try makeTarget("target")

        XCTAssertTrue(swap(cachesPath(), target, requireExists: true))
        XCTAssertTrue(isSymlink(cachesPath()))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: cachesPath()),
            target
        )
    }

    func testSwapRejectsMissingTargetWhenRequired() throws {
        try makeCachesDirectory()

        let missing = root.appendingPathComponent("does-not-exist").path
        XCTAssertFalse(swap(cachesPath(), missing, requireExists: true))
        XCTAssertTrue(isDirectory(cachesPath()))
        XCTAssertFalse(isSymlink(cachesPath()))
    }

    func testSwapAllowsMissingTargetWhenNotRequired() throws {
        try makeCachesDirectory()
        let missing = root.appendingPathComponent("not-created-yet").path

        XCTAssertTrue(swap(cachesPath(), missing, requireExists: false))
        XCTAssertTrue(isSymlink(cachesPath()))
    }

    func testSwapReplacesStaleSymlink() throws {
        try makeCachesDirectory()
        let first = try makeTarget("first")
        let second = try makeTarget("second")

        XCTAssertTrue(swap(cachesPath(), first, requireExists: true))
        XCTAssertTrue(swap(cachesPath(), second, requireExists: true))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: cachesPath()),
            second
        )
    }

    func testSwapRejectsRelativePaths() throws {
        XCTAssertFalse(swap("relative/Caches", "/tmp", requireExists: false))
        XCTAssertFalse(swap(cachesPath(), "relative", requireExists: false))
    }

    // MARK: - Restore / recover

    func testRestoreRebuildsRealDirectory() throws {
        try makeCachesDirectory()
        let target = try makeTarget("target")
        XCTAssertTrue(swap(cachesPath(), target, requireExists: true))

        XCTAssertTrue(restore(cachesPath()))
        XCTAssertTrue(isDirectory(cachesPath()))
        XCTAssertFalse(isSymlink(cachesPath()))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cachesPath()),
            [String]()
        )
    }

    func testRestoreCreatesMissingDirectory() throws {
        XCTAssertTrue(restore(cachesPath()))
        XCTAssertTrue(isDirectory(cachesPath()))
    }

    func testRecoverIsIdempotentOnHealthyDirectory() throws {
        try makeCachesDirectory()

        XCTAssertTrue(recover(cachesPath()))
        XCTAssertTrue(recover(cachesPath()))
        XCTAssertTrue(recover(cachesPath()))
        XCTAssertTrue(isDirectory(cachesPath()))
    }

    func testRecoverRepairsStaleSymlink() throws {
        try makeCachesDirectory()
        let target = try makeTarget("target")
        XCTAssertTrue(swap(cachesPath(), target, requireExists: true))
        XCTAssertTrue(isSymlink(cachesPath()))

        XCTAssertTrue(recover(cachesPath()))
        XCTAssertTrue(isDirectory(cachesPath()))
        XCTAssertFalse(isSymlink(cachesPath()))
    }

    func testRecoverCreatesMissingDirectory() throws {
        XCTAssertTrue(recover(cachesPath()))
        XCTAssertTrue(isDirectory(cachesPath()))
    }

    // MARK: - Error helpers

    func testErrorNamesAreStable() {
        XCTAssertEqual(WorseQuery.errorName(-1), "WQ_ERR_NO_GROUP_CONTAINER")
        XCTAssertEqual(WorseQuery.errorName(-2), "WQ_ERR_API_UNAVAILABLE")
        XCTAssertEqual(WorseQuery.errorName(-4), "WQ_ERR_SYMLINK")
        XCTAssertEqual(WorseQuery.errorName(0), "OK")
    }

    // MARK: - Eligibility

    func testEligibilityBoundary() {
        XCTAssertFalse(WorseQuery.isEligible(majorVersion: 18))
        XCTAssertFalse(WorseQuery.isEligible(majorVersion: 25))
        XCTAssertTrue(WorseQuery.isEligible(majorVersion: 26))
        XCTAssertTrue(WorseQuery.isEligible(majorVersion: 27))
    }

    // MARK: - Access verification & worse_query-only routing

    func testAccessDenialErrorFlagsOnlyPermissionDenials() {
        XCTAssertEqual(SandboxGrantRouter.accessDenialError(forErrno: EPERM), -Int64(EPERM))
        XCTAssertEqual(SandboxGrantRouter.accessDenialError(forErrno: EACCES), -Int64(EACCES))
        XCTAssertEqual(SandboxGrantRouter.accessDenialError(forErrno: ENOENT), 0)
        XCTAssertEqual(SandboxGrantRouter.accessDenialError(forErrno: ENOTDIR), 0)
        XCTAssertEqual(SandboxGrantRouter.accessDenialError(forErrno: 0), 0)
    }

    func testSupportPolicyAndPatchedBuildTrainAlignment() {
        // 27.0 / 27.1 / 27.2.1 use 24A / 24B build trains (unpatched)
        XCTAssertFalse(ExploitSupportPolicy.isPatchedWorseQueryBuild("24A348"))
        XCTAssertFalse(ExploitSupportPolicy.isPatchedWorseQueryBuild("24B2091"))
        XCTAssertTrue(ExploitSupportPolicy.isSupported(major: 27, minor: 2, patch: 1, build: "24B2091"))

        // 27.3 beta 1 uses 24C5000..<24C5049 (unpatched)
        XCTAssertFalse(ExploitSupportPolicy.isPatchedWorseQueryBuild("24C5030a"))
        XCTAssertTrue(ExploitSupportPolicy.isSupported(major: 27, minor: 3, patch: 0, build: "24C5030a"))

        // Any 24C build outside 5000..<5049 (e.g. 27.3 beta 2 `24C5049d` or 24C release `24C101`) is patched!
        XCTAssertTrue(ExploitSupportPolicy.isPatchedWorseQueryBuild("24C5049d"))
        XCTAssertTrue(ExploitSupportPolicy.isPatchedWorseQueryBuild("24C101"))
        XCTAssertFalse(ExploitSupportPolicy.isSupported(major: 27, minor: 3, patch: 0, build: "24C5049d"))
        XCTAssertFalse(ExploitSupportPolicy.isSupported(major: 27, minor: 2, patch: 1, build: "24C101"))
        XCTAssertFalse(ExploitSupportPolicy.isSupported(major: 27, minor: 3, patch: 1, build: "24C5055a"))

        // 24D+ and 25A+ are patched
        XCTAssertTrue(ExploitSupportPolicy.isPatchedWorseQueryBuild("24D100"))
        XCTAssertTrue(ExploitSupportPolicy.isPatchedWorseQueryBuild("25A300"))
    }

    // MARK: - Variant retry policy

    func testRetryPolicyOnlyRetriesMissingTargets() {
        // Retried: a missing target is exactly what the other flags fix.
        XCTAssertTrue(WorseQuery.shouldRetryAnyPath(-255))

        // NOT retried any more. iOS 26/27 device logs show both variants
        // returning -6 for every tree root, so a second attempt only pays for a
        // second filesystem swap + daemon round-trip for the same answer.
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(-5))
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(-6))

        // Not retried: flags cannot fix these.
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(-1))
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(-2))
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(-3))
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(-4))
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(-7))

        // Unknown negatives are not retried either (fail fast, no double swap).
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(-42))
        XCTAssertFalse(WorseQuery.shouldRetryAnyPath(0))
    }

    // MARK: - Variant selection

    func testVariantOppositeAndLabels() {
        XCTAssertEqual(WorseQuery.Variant.primary.opposite, .anyPath)
        XCTAssertEqual(WorseQuery.Variant.anyPath.opposite, .primary)
        XCTAssertEqual(WorseQuery.Variant.primary.rawValue, 0)
        XCTAssertEqual(WorseQuery.Variant.anyPath.rawValue, 1)
        XCTAssertEqual(WorseQuery.Variant.primary.label, "primary")
        XCTAssertEqual(WorseQuery.Variant.anyPath.label, "any_path")
    }

    // MARK: - Ancestor resolution

    func testNearestExistingAncestorWalksUpMissingSubtree() throws {
        let existingDir = root.appendingPathComponent("container/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

        let missingLeaf = existingDir
            .appendingPathComponent("Resources/1.64.1/Patch/Hero.bytes")
        XCTAssertEqual(
            URL(fileURLWithPath: SandboxGrantRouter.nearestExistingAncestor(of: missingLeaf.path)).standardizedFileURL.path,
            existingDir.standardizedFileURL.path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: SandboxGrantRouter.nearestExistingAncestor(of: existingDir.path + "/")).standardizedFileURL.path,
            existingDir.standardizedFileURL.path
        )
    }

    // MARK: - Startup health check (pure decisions)

    func testHealthAccessState() {
        XCTAssertEqual(StartupHealthCheck.accessState(opened: 0, sampled: 0), .skipped)
        XCTAssertEqual(StartupHealthCheck.accessState(opened: 0, sampled: 8), .failed)
        XCTAssertEqual(StartupHealthCheck.accessState(opened: 3, sampled: 8), .warning)
        XCTAssertEqual(StartupHealthCheck.accessState(opened: 4, sampled: 8), .ok)
    }

    func testHealthNamesState() {
        XCTAssertEqual(
            StartupHealthCheck.namesState(namesLoaded: false, knownName: false, labeled: 0, sampled: 8),
            .warning
        )
        XCTAssertEqual(
            StartupHealthCheck.namesState(namesLoaded: true, knownName: false, labeled: 8, sampled: 8),
            .warning
        )
        XCTAssertEqual(
            StartupHealthCheck.namesState(namesLoaded: true, knownName: true, labeled: 3, sampled: 8),
            .warning
        )
        XCTAssertEqual(
            StartupHealthCheck.namesState(namesLoaded: true, knownName: true, labeled: 4, sampled: 8),
            .ok
        )
    }

    func testHealthWorstState() {
        let checks = [
            HealthCheck(key: "a", state: .ok, detail: ""),
            HealthCheck(key: "b", state: .warning, detail: ""),
            HealthCheck(key: "c", state: .failed, detail: "")
        ]
        XCTAssertEqual(StartupHealthCheck.worst(checks), .failed)
        XCTAssertEqual(StartupHealthCheck.worst([]), .ok)
    }

    func testHealthSampleExcludesOwnHome() {
        let paths = (0..<20).map { "/private/var/mobile/Containers/Data/Application/\($0)" }
        let sampled = StartupHealthCheck.sample(paths, home: paths[3], count: 5)
        XCTAssertEqual(sampled.count, 5)
        XCTAssertFalse(sampled.contains(paths[3]))
    }

    // MARK: - Scan checkpoint / slot decisions (pure)

    func testScanCheckpointFreshness() {
        let now = Date().timeIntervalSince1970
        XCTAssertTrue(ContainerScanCoordinator.isFresh(fullAt: now - 3_600, now: now))
        XCTAssertFalse(ContainerScanCoordinator.isFresh(fullAt: now - 8 * 24 * 3_600, now: now))
        XCTAssertFalse(ContainerScanCoordinator.isFresh(fullAt: now + 10, now: now))
    }

    func testScanProbeAndSlotTTL() {
        XCTAssertFalse(ContainerScanCoordinator.probeIsUsable(0, current: 100))
        XCTAssertFalse(ContainerScanCoordinator.probeIsUsable(200, current: 100))
        XCTAssertTrue(ContainerScanCoordinator.probeIsUsable(50, current: 100))
        let now = Date().timeIntervalSinceReferenceDate
        XCTAssertTrue(ContainerScanCoordinator.slotIsFresh(at: now - 10, now: now))
        XCTAssertFalse(ContainerScanCoordinator.slotIsFresh(at: now - 601, now: now))
    }
}
