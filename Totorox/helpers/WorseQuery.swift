import Foundation

/// Primary container-access backend on iOS 26+ (`worse_query`).
///
/// Grants a sandbox extension for an arbitrary absolute path through an
/// entitled App Group container via MobileContainerManager.
///
/// Active when **all** of the following are true:
/// 1. the code signature declares `com.apple.security.application-groups`;
/// 2. the provisioning profile used to sign the app contains that group, so
///    `containerURL(forSecurityApplicationGroupIdentifier:)` returns a URL;
/// 3. the private ContainerManager symbols still exist on this iOS build;
/// 4. the running build is not patched (`!isPatchedBuild`, i.e. <= iOS 27.3 beta 1).
enum WorseQuery {

    /// Optional override when the signature declares more than one group and a
    /// specific group was rotated & persisted due to a shared-group swap conflict.
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

    /// True when this iOS build has patched `worse_query` (iOS 27.3 beta 2+,
    /// or any `24C` build outside `24C5000..<24C5049`).
    static var isPatchedBuild: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return worse_query_is_patched_build()
        #endif
    }

    /// Always active on eligible unpatched iOS 26+ builds (no user toggle).
    static let isEnabled: Bool = true

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

    /// Group that will actually be used for grants, or `nil` when `worse_query`
    /// cannot run on this device/session (missing entitlement/profile, patched
    /// build, or unavailable API — in which case `SandboxGrantRouter.grant`
    /// returns `-1` immediately with no fallback backend).
    ///
    /// Hot path: cached after first resolution without touching `UserDefaults`
    /// or `worse_query_available()`. `invalidateGroupCache()` clears the cache
    /// when rotating App Groups or during tests.
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

    /// Lazily resolved probe used by `SandboxGrantRouter` to pick the working
    /// flag variant. `nil` when `worse_query` is ineligible or the probe failed,
    /// in which case the router falls back to `preferredVariant` heuristics.
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

    /// Releases a consumed extension handle (safe no-op for negative handles).
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
    /// Log the app's own bundle ID and the entitlements from the embedded
    /// provisioning profile. Needed when comparing a working signature with a
    /// re-signed one on device (no macOS/codesign available there).
    static func logSignatureDiagnostics() {
        log("app: bundleID=\(Bundle.main.bundleIdentifier ?? "-")")
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            log("app: embedded.mobileprovision not found")
            return
        }
        let text = String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .utf8) ?? ""
        guard let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex) else {
            log("app: embedded.mobileprovision has no XML plist")
            return
        }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let plist = (try? PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil
        )) as? [String: Any] else {
            log("app: embedded.mobileprovision plist parse failed")
            return
        }
        guard let entitlements = plist["Entitlements"] as? [String: Any] else {
            log("app: embedded.mobileprovision has no Entitlements dict")
            return
        }
        for key in entitlements.keys.sorted() {
            let raw = entitlements[key]
            let value: String
            if let array = raw as? [String] {
                value = array.joined(separator: ",")
            } else if let bool = raw as? Bool {
                value = bool ? "true" : "false"
            } else {
                value = String(describing: raw ?? "")
            }
            log("app: entitlement \(key)=\(value)")
        }
    }

    static func logProbe() {
        #if targetEnvironment(simulator)
        return
        #else
        logSignatureDiagnostics()
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
        guard isEligibleOnThisDevice, !isPatchedBuild else { return }
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
