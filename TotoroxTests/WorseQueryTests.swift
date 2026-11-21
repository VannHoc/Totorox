import XCTest
@testable import Totorox

/// Tests for the Tier 4 (`worse_query`) path helpers and the Tier 1 -> Tier 4
/// fallback state machine.
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

    // MARK: - bad_query access verification

    func testBadQueryAccessErrorFlagsOnlySandboxDenials() {
        XCTAssertEqual(SandboxGrantRouter.badQueryAccessError(forErrno: EPERM), -Int64(EPERM))
        XCTAssertEqual(SandboxGrantRouter.badQueryAccessError(forErrno: EACCES), -Int64(EACCES))
        XCTAssertEqual(SandboxGrantRouter.badQueryAccessError(forErrno: ENOENT), 0)
        XCTAssertEqual(SandboxGrantRouter.badQueryAccessError(forErrno: ENOTDIR), 0)
        XCTAssertEqual(SandboxGrantRouter.badQueryAccessError(forErrno: 0), 0)
    }

    func testPermissionDeniedKeepsTierOneUnmemoizedUntilTierFourSucceeds() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-Int64(EACCES))

        XCTAssertFalse(state.badQueryBlocked)
        XCTAssertEqual(state.lastBadQueryError, -Int64(EACCES))
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.badQuery, .worseQuery])

        state.noteWorseQuerySuccess()
        XCTAssertTrue(state.badQueryBlocked)
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.worseQuery, .badQuery])
    }

    // MARK: - Tier state machine

    func testTierOneFailureAloneDoesNotBlockTierOne() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-5)

        XCTAssertFalse(state.badQueryBlocked)
        XCTAssertEqual(state.lastBadQueryError, -5)
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.badQuery, .worseQuery])
    }

    func testTierOneIsMemoizedAfterTierFourSucceeds() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-5)
        state.noteWorseQuerySuccess()

        XCTAssertTrue(state.badQueryBlocked)
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.worseQuery, .badQuery])
    }

    func testMemoStaysOffWhenTierFourAlsoFails() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-5)

        // No noteWorseQuerySuccess() -> Tier 1 keeps being tried.
        XCTAssertFalse(state.badQueryBlocked)
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.badQuery, .worseQuery])
    }

    func testTierFourAbsentKeepsTierOneOnly() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-5)
        state.noteWorseQuerySuccess()

        // Memo is on, but with Tier 4 unusable Tier 1 is the only option left:
        // the grant must still be attempted instead of failing outright.
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: false), [.badQuery])
    }

    func testTierOneSuccessClearsStaleFailureEvidence() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-5)
        XCTAssertEqual(state.lastBadQueryError, -5)

        // A later path worked with Tier 1, so the old failure must not be blamed
        // on a future Tier 4 success.
        state.noteBadQuerySuccess()
        XCTAssertEqual(state.lastBadQueryError, 0)

        state.noteWorseQuerySuccess()
        XCTAssertFalse(state.badQueryBlocked)
    }

    func testResetClearsMemo() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-5)
        state.noteWorseQuerySuccess()
        XCTAssertTrue(state.badQueryBlocked)

        state.reset()
        XCTAssertFalse(state.badQueryBlocked)
        XCTAssertEqual(state.lastBadQueryError, 0)
    }

    func testForceBadQueryBlockedFlipsMemoDirectly() {
        var state = SandboxTierState()
        XCTAssertFalse(state.badQueryBlocked)
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.badQuery, .worseQuery])

        state.forceBadQueryBlocked()
        XCTAssertTrue(state.badQueryBlocked)
        XCTAssertEqual(state.lastBadQueryError, 0)
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.worseQuery, .badQuery])
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

    // MARK: - Memo strictness

    func testAncestorOnlySuccessDoesNotBlockTierOne() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-3)
        state.noteWorseQuerySuccess(strict: false)

        // The grant only covered an existing ancestor, so Tier 1 keeps its turn.
        XCTAssertFalse(state.badQueryBlocked)
        XCTAssertEqual(state.lastBadQueryError, 0)
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.badQuery, .worseQuery])
    }

    func testStrictTierFourSuccessStillBlocksTierOne() {
        var state = SandboxTierState()
        state.noteBadQueryFailure(-3)
        state.noteWorseQuerySuccess(strict: true)

        XCTAssertTrue(state.badQueryBlocked)
        XCTAssertEqual(state.attemptOrder(worseQueryUsable: true), [.worseQuery, .badQuery])
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
}
