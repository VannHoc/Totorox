import Foundation

/// Tier 4 of the container-access chain: `worse_query`.
///
/// `worse_query` grants a sandbox extension for an arbitrary absolute path by
/// temporarily pointing `<AppGroup>/Library/Caches` at that path and asking
/// MobileContainerManager for the App Group token.
///
/// It only works when **all** of the following are true:
/// 1. the code signature declares `com.apple.security.application-groups`;
/// 2. the provisioning profile used to sign the app contains that group, so
///    `containerURL(forSecurityApplicationGroupIdentifier:)` returns a URL;
/// 3. the private ContainerManager symbols still exist on this iOS build;
/// 4. the user has not turned the tier off in Settings.
///
/// It is never the first choice: `SandboxGrantRouter` always tries `bad_query`
/// (Tier 1) first and only falls back here when Tier 1 is blocked.
enum WorseQuery {

    /// User toggle. Default ON: when the signature is right, Tier 4 is the only
    /// thing that works on iOS 26+ sideloads; when it is wrong every attempt
    /// fails fast with a clear log line.
    static let enabledDefaultsKey = "totorox.useWorseQuery"

    /// Optional override when the signature declares more than one group and the
    /// first one is not the usable one. Useful for sideload profiles.
    static let groupOverrideDefaultsKey = "totorox.worseQueryGroup"

    // MARK: - Eligibility

    /// Version gate, mirroring `worseQueryEligible` in the reference app
    /// (`operatingSystemVersion.majorVersion > 25`).
    static func isEligible(majorVersion: Int) -> Bool {
        majorVersion >= 26
    }

    static var isEligibleOnThisDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return isEligible(majorVersion: major)
        #endif
    }

    /// True when the private API table resolved on this iOS build.
    static var isAPIAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return worse_query_available()
        #endif
    }

    /// True when this iOS build has patched `worse_query` (iOS 27.3 beta 2+),
    /// so Tier 4 cannot grant anything and must stay disabled.
    static var isPatchedBuild: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return worse_query_is_patched_build()
        #endif
    }

    /// Toggle value, defaulting to ON when the user never touched it.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Every group declared in the code signature (empty when the entitlement
    /// is missing — that is a signing problem, not a code problem).
    static var declaredGroups: [String] {
        #if targetEnvironment(simulator)
        return []
        #else
        return WQSignatureAppGroups()
        #endif
    }

    // MARK: - Group resolution

    private static let groupLock = NSLock()
    private static var cachedGrantGroup: String?
    private static var didResolveGrantGroup = false

    /// Group that will actually be used for grants, or `nil` when Tier 4 cannot
    /// run on this device/session. Cached after the first resolution.
    ///
    /// Hot path: once resolved, the answer comes from the cache without touching
    /// `UserDefaults` or `worse_query_available()` (this is called for every
    /// container grant). `invalidateGroupCache()` is what re-runs the gates —
    /// `SettingsView` calls it whenever the toggle or the group override changes.
    static var grantGroup: String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        groupLock.lock()
        if didResolveGrantGroup {
            let cached = cachedGrantGroup
            groupLock.unlock()
            return cached
        }
        groupLock.unlock()

        guard isEligibleOnThisDevice, isEnabled, isAPIAvailable, !isPatchedBuild else { return nil }

        groupLock.lock()
        defer { groupLock.unlock() }
        if didResolveGrantGroup { return cachedGrantGroup }
        didResolveGrantGroup = true
        cachedGrantGroup = resolveGrantGroup()
        return cachedGrantGroup
        #endif
    }

    static func invalidateGroupCache() {
        groupLock.lock()
        didResolveGrantGroup = false
        cachedGrantGroup = nil
        groupLock.unlock()
        #if !targetEnvironment(simulator)
        worse_query_clear_cache()
        #endif
    }

    /// WQ Files and Totorox can be signed with the SAME App Group. Both briefly
    /// swap `<group>/Library/Caches` to obtain tokens; when the other app owns
    /// the swap, every grant fails with WQ_ERR_NO_TOKEN (see WQ Files README,
    /// "another app signed with the same App Group is changing it"). The group
    /// name is irrelevant to worse_query, so move to the next declared group.
    static func rotateGrantGroup() -> Bool {
        groupLock.lock()
        let current = cachedGrantGroup
        groupLock.unlock()
        let usable = usableGroups()
        guard usable.count > 1, let current,
              let index = usable.firstIndex(of: current) else { return false }
        let next = usable[(index + 1) % usable.count]
        guard next != current else { return false }
        groupLock.lock()
        cachedGrantGroup = next
        groupLock.unlock()
        // Nhớ lựa chọn này sang các lần mở app sau — không phải đợi WQ Files
        // mở trước rồi mới tự sửa trong từng phiên.
        UserDefaults.standard.set(next, forKey: groupOverrideDefaultsKey)
        #if !targetEnvironment(simulator)
        worse_query_clear_cache()
        #endif
        log("worse_query: grant group rotated \(current) -> \(next) " +
            "(NO_TOKEN — shared App Group swap conflict? saved for next launch)")
        return true
    }

    /// Groups that are declared *and* whose container actually exists.
    static func usableGroups() -> [String] {
        declaredGroups.filter(hasContainer)
    }

    static func hasContainer(_ group: String) -> Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
        ) != nil
    }

    private static func resolveGrantGroup() -> String? {
        if let override = UserDefaults.standard.string(forKey: groupOverrideDefaultsKey),
           !override.isEmpty,
           hasContainer(override) {
            return override
        }
        let usable = usableGroups()
        // Các app khác (vd WQ Files) thường lấy group ĐẦU TIÊN trong profile.
        // Chọn group CUỐI để tránh đụng chung chỗ swap Library/Caches ngay từ
        // lần chạy đầu — không phụ thuộc vào app nào được mở trước.
        if let chosen = usable.last {
            if usable.count > 1, chosen != usable.first {
                log("worse_query: using App Group \(chosen) " +
                    "(declared=\(usable) — avoiding the first group used by other sideloaded apps)")
            }
            return chosen
        }
        let declared = declaredGroups
        if declared.isEmpty {
            log("worse_query: signature declares NO app group — Tier 4 unavailable " +
                "(add com.apple.security.application-groups and re-sign)")
        } else {
            log("worse_query: declared groups \(declared) have no container " +
                "— the provisioning profile does not include them " +
                "(or the signature has no app-group entitlement)")
        }
        return nil
    }

    // MARK: - Grant / release

    /// Operation-flags variant used by `worse_query`.
    enum Variant: Int32 {
        /// Flags `1 << 39` — the reference "traversal" set. The target must
        /// already exist. This is what iOS 27+ honors.
        case primary = 0
        /// Flags `1 << 35` — "create if missing" set. iOS < 27 prefers it.
        case anyPath = 1
        /// Flags `0` — WQ Files' "standard flags", the app-group → container
        /// token bridge on iOS 26.6.1.
        case standard = 2

        var opposite: Variant {
            switch self {
            case .primary: return .anyPath
            case .anyPath: return .primary
            case .standard: return .primary
            }
        }

        var label: String {
            switch self {
            case .primary: return "primary"
            case .anyPath: return "any_path"
            case .standard: return "standard"
            }
        }
    }

    /// Result of the no-path daemon probe (WQ Files style). Unlike the OS-version
    /// heuristic this is an actual answer from the daemon for this build/session.
    struct TokenProbe {
        var primary: Bool
        var anyPath: Bool
        /// WQ Files' "standard flags" (flags = 0) — the app-group → container
        /// token bridge. Works on iOS 26.6.1 even when other flags are denied.
        var standard: Bool
        var covered: String
        var mask: Int32
    }

    private static let tokenProbeLock = NSLock()
    private static var tokenProbeCache: TokenProbe?

    /// Query the daemon for a token with NO target path and read the covered
    /// folder from the token itself. The token is never consumed, so this is safe
    /// to call at launch. Result is cached for the session.
    static func probeTokenFlags(group providedGroup: String? = nil) -> TokenProbe? {
        guard let group = (providedGroup ?? grantGroup), !group.isEmpty else { return nil }
        tokenProbeLock.lock()
        if let cached = tokenProbeCache {
            tokenProbeLock.unlock()
            return cached
        }
        tokenProbeLock.unlock()

        #if targetEnvironment(simulator)
        return nil
        #else
        var covered = [CChar](repeating: 0, count: 1024)
        let mask = group.withCString { wq_probe_token_flags($0, &covered, UInt64(covered.count)) }
        guard mask >= 0 else {
            log("worse_query: token probe FAILED code=\(mask) \(errorName(Int64(mask)))")
            return nil
        }
        let coveredText = covered.withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
        }
        let probe = TokenProbe(
            primary: (mask & Int32(WQ_PROBE_FLAG_PRIMARY)) != 0,
            anyPath: (mask & Int32(WQ_PROBE_FLAG_ANY_PATH)) != 0,
            standard: (mask & Int32(WQ_PROBE_FLAG_STANDARD)) != 0,
            covered: coveredText,
            mask: mask
        )
        tokenProbeLock.lock()
        tokenProbeCache = probe
        tokenProbeLock.unlock()
        log("worse_query: token probe flags=0x\(String(mask, radix: 16)) " +
            "primary=\(probe.primary) any_path=\(probe.anyPath) " +
            "standard=\(probe.standard) covered=\(probe.covered)")
        return probe
        #endif
    }

    /// Lazily resolved probe used by the grant router. Nil when Tier 4 is not
    /// eligible or the daemon refused both flags — callers keep their old fallback.
    static var tokenProbe: TokenProbe? {
        tokenProbeLock.lock()
        let cached = tokenProbeCache
        tokenProbeLock.unlock()
        return cached ?? probeTokenFlags()
    }

    /// Variant to try first, mirroring the reference `_wq_grant`:
    /// iOS < 27 → `.anyPath`, iOS >= 27 → `.primary`. Once a variant produced a
    /// verified handle it is pinned for the session by `noteVariant(_:)`.
    static var preferredVariant: Variant {
        #if targetEnvironment(simulator)
        return .primary
        #else
        return Variant(rawValue: worse_query_preferred_variant()) ?? .primary
        #endif
    }

    /// Remember the variant that actually unlocked the target (call only after
    /// the handle was verified with `access(2)`).
    static func noteVariant(_ used: Int32) {
        #if !targetEnvironment(simulator)
        worse_query_note_variant(used)
        #endif
    }

    /// Grant with one explicit variant. Returns a handle `>= 0` or a `WQ_ERR_*`.
    static func grantVariant(path: String, group: String, variant: Variant) -> Int64 {
        #if targetEnvironment(simulator)
        return Int64(WQ_ERR_API_UNAVAILABLE)
        #else
        return path.withCString { pathPtr in
            group.withCString { groupPtr in
                worse_query(pathPtr, groupPtr, variant.rawValue)
            }
        }
        #endif
    }

    /// Raw grant. Returns a handle `>= 0` on success, or a negative `WQ_ERR_*`.
    static func grantRaw(path: String, group: String, usedVariant: inout Int32) -> Int64 {
        usedVariant = -1
        #if targetEnvironment(simulator)
        return Int64(WQ_ERR_API_UNAVAILABLE)
        #else
        return path.withCString { pathPtr in
            group.withCString { groupPtr in
                worse_query_try_both(pathPtr, groupPtr, &usedVariant)
            }
        }
        #endif
    }

    /// `sandbox_extension_release` wrapper. Safe for negative handles, and valid
    /// for handles produced by `bad_query` too (both are plain sandbox extensions).
    static func release(_ handle: Int64) {
        guard handle >= 0 else { return }
        worse_query_release(handle)
    }

    /// Port of `wq_reset_access_cache`: dời lock lạ sang quarantine rồi đưa
    /// `Library/Caches` về thư mục thường (rename, không xoá dữ liệu).
    /// Reference chỉ tự sửa tối đa một lần mỗi phút — giữ cùng nhịp ở đây.
    private static let repairLock = NSLock()
    private static var lastRepairAt: Date?

    static func resetAccessCache(group: String) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        repairLock.lock()
        let now = Date()
        if let last = lastRepairAt, now.timeIntervalSince(last) < 60 {
            repairLock.unlock()
            return false
        }
        lastRepairAt = now
        repairLock.unlock()
        let ok = group.withCString { worse_query_reset_access_cache($0) }
        log("worse_query: access cache reset \(ok ? "ok" : "FAILED: " + lastError())")
        return ok
        #endif
    }

    /// Mirrors the retry policy inside `worse_query_try_both` so the decision is
    /// unified across C and Swift callers and covered by unit tests in all build configurations.
    static func shouldRetryAnyPath(_ code: Int64) -> Bool {
        worse_query_should_retry_any_path(code)
    }

    // MARK: - Self-heal

    /// One-line diagnostics at launch. This is the first thing to read when a
    /// device says "Tier 4 does nothing": it prints eligibility, API presence,
    /// the groups declared in the signature and which one is usable.
    static func logProbe() {
        #if targetEnvironment(simulator)
        return
        #else
        let p = probe()
        log("worse_query: probe eligible=\(p.eligible) api=\(p.apiAvailable) " +
            "enabled=\(p.enabled) grantGroup=\(p.grantGroup ?? "-") " +
            "declared=\(p.declaredGroups) usable=\(p.usableGroups)")
        #endif
    }

    /// Repair `<group>/Library/Caches` if a crash left a symlink behind.
    /// Cheap no-op when the directory is healthy; call once at launch.
    static func recoverAllGroups() {
        #if targetEnvironment(simulator)
        return
        #else
        // Respect the user toggle: when Tier 4 is disabled, do not touch any
        // group's `Library/Caches` (including the recovery sweep), so a disabled
        // tier leaves no `worse_query` trace in the log.
        guard isEligibleOnThisDevice, isEnabled, !isPatchedBuild else { return }
        let groups = usableGroups()
        guard !groups.isEmpty else { return }
        for group in groups {
            let ok = group.withCString { worse_query_recover($0) }
            if !ok {
                log("worse_query: recover failed for group \(group)")
            } else {
                log("worse_query: recover ok for group \(group)")
            }
        }
        #endif
    }

    // MARK: - Diagnostics

    struct Probe {
        var eligible: Bool
        var apiAvailable: Bool
        var enabled: Bool
        var declaredGroups: [String]
        var usableGroups: [String]
        var grantGroup: String?
        var lastError: String
    }

    static func probe() -> Probe {
        var resolved: String?
        // Use the unlocked resolution path so probing does not depend on cache state.
        if isEligibleOnThisDevice, isEnabled, isAPIAvailable {
            let usable = usableGroups()
            resolved = UserDefaults.standard.string(forKey: groupOverrideDefaultsKey)
                .flatMap { !$0.isEmpty && hasContainer($0) ? $0 : nil } ?? usable.first
        }
        return Probe(
            eligible: isEligibleOnThisDevice,
            apiAvailable: isAPIAvailable,
            enabled: isEnabled,
            declaredGroups: declaredGroups,
            usableGroups: usableGroups(),
            grantGroup: resolved,
            lastError: lastError()
        )
    }

    static func lastError() -> String {
        // Pure C accessor for a thread-local buffer — safe on the simulator.
        guard let raw = worse_query_last_error() else { return "" }
        return String(cString: raw)
    }

    static func errorName(_ code: Int64) -> String {
        // Pure C switch, no private API involved.
        guard let raw = worse_query_error_name(code) else { return "WQ_ERR_UNKNOWN" }
        return String(cString: raw)
    }

    /// Localization key describing the current Tier 4 state, for Settings.
    ///
    /// `enabled` is passed in by the caller (the `@AppStorage` value) instead of
    /// being read from `UserDefaults` here, so the subtitle re-renders as soon
    /// as the toggle flips. `grantGroup` would otherwise keep reading the
    /// stored value through `isEnabled`.
    static func statusLocalizationKey(enabled: Bool) -> String {
        guard isEligibleOnThisDevice else { return "settings.worse_query_not_needed" }
        guard enabled else { return "settings.worse_query_disabled" }
        guard isAPIAvailable else { return "settings.worse_query_api_missing" }
        if grantGroup == nil { return "settings.worse_query_missing_group" }
        return "settings.worse_query_ready"
    }
}

// MARK: - Tier state machine (pure, unit-testable)

enum SandboxBackend: String {
    case badQuery = "bad_query"
    case worseQuery = "worse_query"
}

/// Remembers, for the lifetime of the process only (RAM), that Tier 1 is blocked.
///
/// The memo is flipped **only after Tier 4 succeeded for the same path**, so a
/// path-specific `bad_query` failure can never disable Tier 1 session-wide.
/// From the second file on, `bad_query` is skipped entirely — but it stays as
/// the last attempt, so a Tier 4 regression can never leave the app without a
/// grant.
struct SandboxTierState {
    private(set) var badQueryBlocked = false
    private(set) var lastBadQueryError: Int64 = 0

    mutating func noteBadQueryFailure(_ code: Int64) {
        guard code < 0 else { return }
        lastBadQueryError = code
    }

    /// Tier 1 worked for this path; drop stale failure evidence so a later
    /// Tier 4 success is only blamed on a failure that just happened.
    mutating func noteBadQuerySuccess() {
        lastBadQueryError = 0
    }

    /// Tier 4 produced a handle for this path.
    ///
    /// `strict == false` means the extension only covered the closest existing
    /// *ancestor* of the requested path (write into a file that does not exist
    /// yet). That says nothing about Tier 1, so the memo must not flip; the
    /// stale failure evidence is dropped instead.
    mutating func noteWorseQuerySuccess(strict: Bool = true) {
        guard strict else {
            lastBadQueryError = 0
            return
        }
        guard !badQueryBlocked, lastBadQueryError < 0 else { return }
        badQueryBlocked = true
        lastBadQueryError = 0
    }

    mutating func reset() {
        badQueryBlocked = false
        lastBadQueryError = 0
    }

    /// Force the memo on without requiring a prior Tier 4 success or a Tier 1
    /// failure code. Used by the enumeration fallback when `bad_query` hands
    /// back a usable handle but does not unlock traversal of the app-data root.
    mutating func forceBadQueryBlocked() {
        badQueryBlocked = true
        lastBadQueryError = 0
    }

    /// Attempt order for the next grant.
    ///
    /// - Tier 1 disabled by OS policy (26.6.2+ / iOS 27): `worse_query` only,
    ///   or nothing at all when Tier 4 is also unusable. Never fall back to a
    ///   `bad_query` that returns `-3` for every path.
    /// - memo off: `bad_query` first (the documented order).
    /// - memo on: `worse_query` first, `bad_query` last.
    /// - memo on but Tier 4 unusable: Tier 1 is the only option left, so it is
    ///   still attempted instead of failing the grant outright.
    func attemptOrder(worseQueryUsable: Bool,
                      badQueryUsable: Bool = true) -> [SandboxBackend] {
        guard badQueryUsable else { return worseQueryUsable ? [.worseQuery] : [] }
        guard worseQueryUsable else { return [.badQuery] }
        return badQueryBlocked ? [.worseQuery, .badQuery] : [.badQuery, .worseQuery]
    }
}

#if DEBUG
// MARK: - Test support
//
// Thin wrappers so `TotoroxTests` can exercise the path-only C helpers without
// the test target importing the app bridging header. None of these touch the
// private ContainerManager API.

extension WorseQuery {
    static func swapCaches(at cachesPath: String,
                           to targetPath: String,
                           requireTargetExists: Bool) -> Bool {
        cachesPath.withCString { cachesPtr in
            targetPath.withCString { targetPtr in
                WQSwapCachesAtPath(cachesPtr, targetPtr, requireTargetExists)
            }
        }
    }

    static func restoreCaches(at cachesPath: String) -> Bool {
        cachesPath.withCString { WQRestoreCachesAtPath($0) }
    }

    static func recoverCaches(at cachesPath: String) -> Bool {
        cachesPath.withCString { WQRecoverCachesAtPath($0) }
    }
}
#endif
