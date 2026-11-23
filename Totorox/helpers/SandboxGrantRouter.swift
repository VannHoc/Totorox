import Foundation
import Darwin

/// Chooses which sandbox backend grants access to a container path.
///
/// Chain depends on the OS:
///   - iOS 26.0–26.6.1: Tier 1 `bad_query` → Tier 4 `worse_query` → give up.
///   - iOS 26.6.2+ and all of iOS 27: **Tier 4 only** — `bad_query` answers
///     `-3 BQ_ERR_NO_RESULT` for every path on these builds (27.2.1 device log),
///     so calling it only burns three daemon round-trips per file. See
///     `badQueryUsable` below.
///
/// `bad_query` is attempted first, in both of its scopes, only where it works:
/// `systemgroup.com.apple.mobilegestaltcache` (class 13) and our own App Group
/// (class 7). Container enumeration itself uses MCM / csstore / traversal
/// grants; `fsgetpath` is only used to verify cached paths in
/// `ContainerScanCoordinator` (the WQFiles 0.9.19 checkpoint mechanism).
///
/// A returned handle is not trusted on its own: iOS 26/27 can hand back a token
/// while ignoring the `../../..` traversal, which leaves the real target blocked.
/// Every successful handle (from either tier) is therefore confirmed with a real
/// `open(2)` on the path — `access(2)` alone reports success on iOS 27 for paths
/// that `open`/`readdir` still deny, which used to latch a fake "granted" mask
/// and made every later file operation fail silently.
///
/// If Tier 1 fails *and* `worse_query` then succeeds, the failure is remembered
/// in RAM for the rest of the session (`badQueryBlocked`), so every following
/// file jumps straight to Tier 4 instead of paying for a doomed `bad_query`
/// round-trip. While that memo is on, Tier 1 is kept as the *last* attempt for
/// each new path, so a later Tier 4 regression degrades instead of breaking.
///
/// Two guards keep the hot path cheap on iOS 26/27, where the device logs show
/// whole tree roots (`/var`, `/var/mobile`, `/Applications`, …) failing forever:
/// 1. a missing target is rejected before either tier runs (the reference
///    `_wq_grant` does the same) — granting it only yields the App-Group token;
/// 2. a path that failed both tiers is not retried for 60 s (`negativeGrants`).
///
/// Handles stay cached by `ContainerStore.activeGrantHandles`; this router never
/// keeps its own handle cache.
enum SandboxGrantRouter {

    private static let stateLock = NSLock()
    private static var state = SandboxTierState()
    private static var lastBackendValue: SandboxBackend?

    /// Whether Tier 1 (`bad_query`) is used at all on this device.
    ///
    /// Project policy: bad_query belongs ONLY to iOS 26.0–26.6.1, where the
    /// kernel-exploit fallback keeps it alive. Everything above that (26.6.2+
    /// and all of iOS 27) is worse_query-only — the 27.2.1 device log shows
    /// `-3 BQ_ERR_NO_RESULT` for every path, so calling Tier 1 only burns three
    /// daemon round-trips per file.
    ///
    /// There is deliberately no session-wide Tier-4 kill switch: WQFiles only
    /// retries/repairs, and blocks builds where Apple patched the exploit.
    static var badQueryUsable: Bool {
        let v = AppInfo.versionTuple
        guard v.major == 26 else { return false }
        return v.minor < 6 || (v.minor == 6 && v.patch <= 1)
    }

    /// Recent failures per `canonical path|mode`. Re-attempting them costs two
    /// filesystem swaps plus two daemon round-trips each time, while the answer
    /// cannot change within a minute.
    private struct NegativeEntry {
        let code: Int64
        let expiresAt: Date
    }
    private static var negativeGrants: [String: NegativeEntry] = [:]
    /// Short enough that a new app install, a daemon restart or a fresh grant
    /// heals by itself.
    private static let negativeTTL: TimeInterval = 60

    /// Ancestors that never carry a usable token (they are where the iOS 26/27
    /// logs show `-6 WQ_ERR_NO_TOKEN` for both variants).
    private static let unGrantableAncestors: Set<String> = [
        "/", "/private", "/var", "/private/var",
        "/var/mobile", "/private/var/mobile",
        "/var/containers", "/private/var/containers",
        "/var/mobile/Containers", "/private/var/mobile/Containers",
        "/var/mobile/Containers/Data", "/private/var/mobile/Containers/Data",
        "/var/mobile/Containers/Shared", "/private/var/mobile/Containers/Shared",
        "/Applications", "/System", "/usr", "/private/etc", "/etc"
    ]

    // MARK: - Diagnostics

    static var badQueryBlocked: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.badQueryBlocked
    }

    static var lastBadQueryError: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.lastBadQueryError
    }

    static var lastBackend: SandboxBackend? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastBackendValue
    }

    /// Drop the memo (used when the user toggles Tier 4, and by tests).
    static func resetBlockedState() {
        stateLock.lock()
        state.reset()
        lastBackendValue = nil
        negativeGrants.removeAll()
        stateLock.unlock()
        WorseQuery.invalidateGroupCache()
    }

    /// Force Tier 1 (`bad_query`) to be treated as insufficient for the rest of
    /// the session, so traversal falls through to Tier 4 (`worse_query`).
    ///
    /// Used as an enumeration-level fallback (Approach B): on iOS 26+ builds
    /// where `bad_query` hands back a handle that passes the open probe but does
    /// not unlock traversal of the app-data root, MCM returns 0/1 containers.
    /// Calling this flips the `badQueryBlocked` memo without requiring a prior
    /// Tier 4 success, so `worse_query` is tried first for every following path.
    /// Only meaningful when `WorseQuery.grantGroup != nil`.
    static func forceBadQueryBlockedForEnumeration() {
        guard badQueryUsable else { return } // WQ-only builds: Tier 1 is already out
        stateLock.lock()
        let wasBlocked = state.badQueryBlocked
        state.forceBadQueryBlocked()
        let nowBlocked = state.badQueryBlocked
        stateLock.unlock()
        if !wasBlocked && nowBlocked {
            log("grant: bad_query marked BLOCKED for this session " +
                "(enumeration returned <= 1 container; tier 4 preferred)")
        }
    }

    // MARK: - Negative cache

    private static func negativeKey(_ path: String, requireWrite: Bool) -> String {
        let canonical = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        return requireWrite ? canonical + "|w" : canonical + "|r"
    }

    private static func cachedFailure(path: String, requireWrite: Bool) -> Int64? {
        let key = negativeKey(path, requireWrite: requireWrite)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let entry = negativeGrants[key] else { return nil }
        if entry.expiresAt > Date() { return entry.code }
        negativeGrants.removeValue(forKey: key)
        return nil
    }

    private static func rememberFailure(_ code: Int64, path: String, requireWrite: Bool) {
        guard code < 0 else { return }
        let key = negativeKey(path, requireWrite: requireWrite)
        stateLock.lock()
        // A full scan can fail on thousands of existing-but-denied folders, so
        // keep the map bounded instead of growing for the whole session.
        if negativeGrants.count > 4096 {
            let now = Date()
            negativeGrants = negativeGrants.filter { $0.value.expiresAt > now }
        }
        negativeGrants[key] = NegativeEntry(
            code: code,
            // "No token" failures are stable for the whole build: on the 27.2.1
            // device log every root and every nested folder answered -3/-4/-5/-6
            // again after a minute, so the short TTL only re-paid a swap plus a
            // daemon round-trip while the user was browsing.
            expiresAt: Date().addingTimeInterval(
                code == -3 || code == -4
                    || code == Int64(WQ_ERR_NO_RESULT) || code == Int64(WQ_ERR_NO_TOKEN)
                    ? 600 : negativeTTL
            )
        )
        stateLock.unlock()
    }

    /// `stat` that treats a sandbox denial as "exists": inside a strict sandbox
    /// `stat` on another app's container can fail with `EPERM`/`EACCES` even
    /// when the entry is there (same reason `WQSwapCachesAtPath` tolerates it).
    private static func targetExists(_ path: String) -> Bool {
        var st = stat()
        errno = 0
        if stat(path, &st) == 0 { return true }
        return errno == EPERM || errno == EACCES
    }

    private static func isGrantableAncestor(_ ancestor: String) -> Bool {
        guard ancestor.count > 1 else { return false }
        return !unGrantableAncestors.contains(ancestor)
    }

    // MARK: - Grant

    /// Grant access to `path`. Returns a handle `>= 0` on success, `< 0` on failure.
    ///
    /// The attempt order comes from `SandboxTierState.attemptOrder`:
    ///
    /// | Tier 1 usable | memo | Tier 4 usable | order                        |
    /// |---------------|------|---------------|------------------------------|
    /// | no            | any  | yes           | worse_query                  |
    /// | no            | any  | no            | (none — return -1)           |
    /// | yes           | off  | yes           | bad_query (system, group) → worse_query |
    /// | yes           | off  | no            | bad_query                    |
    /// | yes           | on   | yes           | worse_query → bad_query      |
    /// | yes           | on   | no            | bad_query (last resort)      |
    ///
    /// The last two rows keep the router alive when the memo is on but Tier 4
    /// has no App Group (wiped container, user toggled it off): without them the
    /// memo would make every following grant fail instead of degrading to Tier 1.
    /// On WQ-only builds the first two rows apply. There is no session-wide
    /// "disable Tier 4" switch — WQFiles only retries/repairs and blocks builds
    /// where Apple patched the exploit (`WorseQuery.isPatchedBuild`).
    static func grant(path: String, requireWrite: Bool = false) -> Int64 {
        grantImpl(path: path, requireWrite: requireWrite, didRotateGroup: false, didRepairCache: false)
    }

    private static func grantImpl(path: String,
                                  requireWrite: Bool,
                                  didRotateGroup: Bool,
                                  didRepairCache: Bool) -> Int64 {
        guard path.count > 1, path.hasPrefix("/") else { return -1 }

        // iOS 16–18: chỉ dùng DarkSword kernel exploit / MHA-C2 + truy cập
        // trực tiếp. Không gọi bad_query lẫn WQFiles tier nào ở các bản này.
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            return -1
        }

        // The reference `_wq_grant` refuses a target that `lstat` cannot find.
        // iOS 26/27 still answer with the App-Group token for variant 1, which
        // looks like success (device logs: the same handle repeated for
        // Library/Caches/Snapshots, Library/Cookies, …) but unlocks nothing.
        let exists = targetExists(path)

        if !exists && !requireWrite {
            // Reading something that is not there stays ENOENT with or without
            // a sandbox extension: skip both tiers, quietly.
            return -1
        }

        if let cached = cachedFailure(path: path, requireWrite: requireWrite) {
            return cached
        }

        // Writing into a not-yet-created file: grant the closest existing
        // ancestor so the caller can create it (the reference grants the parent
        // folder as well). Granting the leaf itself only returns a group token.
        var grantPath = path
        if !exists {
            let ancestor = nearestExistingAncestor(of: path)
            guard isGrantableAncestor(ancestor) else {
                log("grant: skip write target with no grantable ancestor \(path) -> \(ancestor)")
                rememberFailure(-1, path: path, requireWrite: requireWrite)
                return -1
            }
            grantPath = ancestor
        }

        // Resolved lazily on purpose: while Tier 1 keeps working this call uses
        // the cached group and costs a lock + a dictionary lookup. On iOS <= 25
        // the first grant pays for SecTask/containerURL once, not per path.
        let group = WorseQuery.grantGroup

        let tier1Usable = badQueryUsable
        stateLock.lock()
        let tier4Usable = (group != nil)
        let order = state.attemptOrder(worseQueryUsable: tier4Usable,
                                       badQueryUsable: tier1Usable)
        stateLock.unlock()
        if order.isEmpty { return -1 }

        var failure: Int64 = 0

        for backend in order {
            switch backend {
            case .badQuery:
                switch attemptBadQuery(path: grantPath, requireWrite: requireWrite) {
                case .granted(let handle):
                    return handle
                case .failed(let code):
                    failure = code
                }
            case .worseQuery:
                guard let group = group else { continue }
                switch attemptWorseQuery(path: grantPath,
                                         group: group,
                                         requireWrite: requireWrite,
                                         targetExists: exists) {
                case .granted(let handle):
                    return handle
                case .failed(let code):
                    failure = code
                }
            }
        }

        let result = failure != 0 ? failure : -1
        // WQ Files README: when EVERY folder is refused, the App Group Caches
        // swap is likely broken (interrupted swap or another app sharing the
        // group). WQ repairs it automatically — do the same before giving up.
        if result == Int64(WQ_ERR_NO_TOKEN), !didRepairCache,
           let currentGroup = WorseQuery.grantGroup,
           WorseQuery.resetAccessCache(group: currentGroup) {
            return grantImpl(path: path,
                             requireWrite: requireWrite,
                             didRotateGroup: didRotateGroup,
                             didRepairCache: true)
        }
        // Nếu repair không giúp, thử group khác (tên group không quan trọng
        // với worse_query — chỉ cần group có entitlement).
        if result == Int64(WQ_ERR_NO_TOKEN), !didRotateGroup,
           WorseQuery.rotateGrantGroup() {
            return grantImpl(path: path,
                             requireWrite: requireWrite,
                             didRotateGroup: true,
                             didRepairCache: didRepairCache)
        }
        rememberFailure(result, path: path, requireWrite: requireWrite)
        return result
    }

    /// Release a handle obtained from either backend.
    static func release(_ handle: Int64) {
        WorseQuery.release(handle)
    }

    // MARK: - Internals

    /// Outcome of a single backend attempt.
    private enum Attempt {
        case granted(Int64)
        case failed(Int64)
    }

    /// Tier 1 has two scopes and both are tried before Tier 4.
    ///
    /// * `nil` — the reference `_wq_grant` path: class 13 query on
    ///   `systemgroup.com.apple.mobilegestaltcache` plus a `../` walk out of the
    ///   container part. This is what worked up to iOS 26.
    /// * our own App Group — class 7 query, the one scope iOS 27 still answers.
    ///   The iOS 27.2.1 device log shows `bad_query` returning `-3`
    ///   (`[bad_query] daemon returned no result`) for every path on the class-13
    ///   scope while the class-7 group query in `worse_query` keeps returning a
    ///   result for the same session, so the group scope is the only Tier 1
    ///   shape left on that build.
    private static func attemptBadQuery(path: String, requireWrite: Bool) -> Attempt {
        let group = WorseQuery.grantGroup
        var failure = Int64(WQ_ERR_NO_RESULT)

        // Try all scopes starting with system class 13 (mobilegestaltcache), which is
        // the canonical traversal path for bad_query on iOS <= 26, followed by App Group scopes.
        let scopes = badQueryScopes(group: group)

        for scope in scopes {
            let handle = callBadQuery(path: path, scope: scope)
            guard handle >= 0 else {
                failure = handle
                noteBadQueryFailure(handle)
                log("grant: bad_query[\(scope.label)] failed path=\(path) " +
                    "code=\(handle) \(badQueryErrorName(handle))")
                continue
            }

            let accessError = verifyAccess(path: path, requireWrite: requireWrite)
            if accessError == 0 {
                noteBadQuerySuccess()
                record(backend: .badQuery, handle: handle, group: scope.group)
                return .granted(handle)
            }

            // The token exists but does not cover `path` (iOS 26 ignores the
            // traversal and hands out the cache container token instead, or only
            // granted read-only when write is required). Release it and move on.
            release(handle)
            noteBadQueryFailure(accessError)
            log("grant: bad_query[\(scope.label)] handle=\(handle) " +
                "does not cover path=\(path) requireWrite=\(requireWrite) " +
                "errno=\(-accessError) — next scope/tier")
        }

        return .failed(failure)
    }

    /// One Tier-1 shape: which container the traversal query is aimed at and the
    /// operation flags it uses.
    private struct BadQueryScope {
        let group: String?
        let flags: UInt64
        let label: String
    }

    private static let badQueryFlagPrimary: UInt64 = 0x0000_0080_0000_0000 // 1 << 39
    private static let badQueryFlagAnyPath: UInt64 = 0x0000_0008_0000_0000 // 1 << 35
    /// WQ Files' "standard flags": flags = 0. On iOS 26.6.1 this is what turns
    /// the App Group token into a token covering a real container (lsd /
    /// InternalDaemon), so the csstore path can be found without an MCM class-10
    /// lookup tied to the app's bundle ID.
    private static let badQueryFlagStandard: UInt64 = 0

    /// Class-13 first, then our App Group with the flag variants the probe says
    /// work, and finally `flags = 0` for both scopes (the WQ bridge).
    private static func badQueryScopes(group: String?) -> [BadQueryScope] {
        var scopes = [BadQueryScope(group: nil, flags: badQueryFlagPrimary, label: "system")]

        func appendStandardScopes(_ group: String?) {
            scopes.append(BadQueryScope(group: nil, flags: badQueryFlagStandard, label: "system-standard"))
            if let group {
                scopes.append(BadQueryScope(group: group, flags: badQueryFlagStandard, label: "group-standard"))
            }
        }

        guard let group = group, !group.isEmpty else {
            appendStandardScopes(nil)
            return scopes
        }

        if let probe = WorseQuery.probeTokenFlags(group: group) {
            if probe.primary && !probe.anyPath {
                scopes.append(BadQueryScope(group: group, flags: badQueryFlagPrimary, label: "group"))
                appendStandardScopes(group)
                return scopes
            }
            if probe.anyPath && !probe.primary {
                scopes.append(BadQueryScope(group: group, flags: badQueryFlagAnyPath, label: "group-any"))
                appendStandardScopes(group)
                return scopes
            }
        }
        scopes.append(BadQueryScope(group: group, flags: badQueryFlagPrimary, label: "group"))
        scopes.append(BadQueryScope(group: group, flags: badQueryFlagAnyPath, label: "group-any"))
        appendStandardScopes(group)
        return scopes
    }

    private static func attemptWorseQuery(path: String,
                                         group: String,
                                         requireWrite: Bool,
                                         targetExists: Bool) -> Attempt {
        // iOS < 27 prefers 1<<35, iOS >= 27 prefers 1<<39; a variant that once
        // produced a verified handle stays pinned (reference `_wq_grant` keeps
        // the same per-process memo). A real no-path probe overrides the
        // OS-version heuristic only when exactly one flag actually works;
        // otherwise the historical order stays as the fallback.
        var variant = WorseQuery.preferredVariant
        if let probe = WorseQuery.tokenProbe {
            if probe.primary && !probe.anyPath { variant = .primary }
            if probe.anyPath && !probe.primary { variant = .anyPath }
        }
        var lastCode = Int64(WQ_ERR_NO_TOKEN)

        // Vòng cuối thử flags = 0 — chế độ "standard flags" của WQ Files, tạo
        // token container từ token app-group mà không cần MCM class 10 (vốn bị
        // từ chối khi app được ký với bundle ID khác).
        for round in 0..<3 {
            if round == 2, variant != .standard { variant = .standard }
            let handle = WorseQuery.grantVariant(path: path, group: group, variant: variant)
            guard handle >= 0 else {
                lastCode = handle
                log("grant: worse_query failed path=\(path) group=\(group) " +
                    "variant=\(variant.label) code=\(handle) \(WorseQuery.errorName(handle)) " +
                    "detail=\(WorseQuery.lastError())")

                // Reference: khi cache không dùng được (-5 trong WQFiles) thì sửa
                // rồi hỏi lại cùng variant một lần trước khi đổi flags.
                if handle == Int64(WQ_ERR_CACHE_UNUSABLE), round == 0 {
                    let repaired = WorseQuery.resetAccessCache(group: group)
                    log("grant: access cache repaired automatically" +
                        (repaired ? "" : " — FAILED: " + WorseQuery.lastError()))
                    if repaired { continue }
                }

                // Chỉ thử flags kia khi lỗi có thể do flags gây ra. -6/-5 cho cả
                // hai variant trên iOS 27 (log thiết bị) nên không tốn swap thứ 2.
                // Dù không retryable vẫn thử flags = 0 — đây là đường WQ Files dùng
                // khi bundle ID không còn quyền MCM class 10.
                if round == 0 {
                    if WorseQuery.shouldRetryAnyPath(handle) {
                        variant = variant.opposite
                    } else {
                        variant = .standard
                    }
                    continue
                }
                if round == 1, variant != .standard {
                    variant = .standard
                    continue
                }
                return .failed(handle)
            }

            // A consumed extension is not proof either: when the daemon resolves
            // the group container from its own cache it hands back a token for
            // `<group>` instead of the swapped target. Verifying here keeps a
            // useless handle out of `ContainerStore.activeGrantHandles`.
            let accessError = verifyAccess(path: path, requireWrite: requireWrite)
            if accessError == 0 {
                WorseQuery.noteVariant(variant.rawValue)
                noteWorseQuerySuccess(strict: targetExists)
                record(backend: .worseQuery,
                       handle: handle,
                       variant: variant.rawValue,
                       group: group)
                return .granted(handle)
            }

            release(handle)
            lastCode = accessError
            log("grant: worse_query handle=\(handle) variant=\(variant.label) group=\(group) " +
                "does not cover path=\(path) requireWrite=\(requireWrite) " +
                "errno=\(-accessError)")
            // Consumed but denied: exactly the case the reference retries with
            // the other flags ("trying the other flags").
            // Reference: chỉ EPERM là "token không giúp được"; EACCES là quyền
            // POSIX thường (container root-owned) nên verify ở trên đã coi là OK.
            if round == 0 && accessError == -Int64(EPERM) {
                variant = variant.opposite
                continue
            }
            if round == 1, variant != .standard {
                variant = .standard
                continue
            }
            return .failed(accessError)
        }

        return .failed(lastCode)
    }

    private static func noteBadQueryFailure(_ code: Int64) {
        stateLock.lock()
        state.noteBadQueryFailure(code)
        stateLock.unlock()
    }

    private static func noteBadQuerySuccess() {
        stateLock.lock()
        state.noteBadQuerySuccess()
        stateLock.unlock()
    }

    /// Flip the `badQueryBlocked` memo only for a *strict* success (the token
    /// covered the requested path itself). A grant that only covered an existing
    /// ancestor says nothing about Tier 1 and must not disable it session-wide.
    private static func noteWorseQuerySuccess(strict: Bool) {
        stateLock.lock()
        let wasBlocked = state.badQueryBlocked
        state.noteWorseQuerySuccess(strict: strict)
        let nowBlocked = state.badQueryBlocked
        stateLock.unlock()
        if !wasBlocked && nowBlocked {
            log("grant: bad_query marked BLOCKED for this session " +
                "(tier 4 works, tier 1 does not)")
        }
    }

    /// `bad_query` has its own code table; `WQ_ERR_*` (-4 = symlink swap) does
    /// not apply to it (-4 = the daemon result carried no sandbox token).
    /// Logging the wrong name sent earlier sessions after a symlink bug that was
    /// never there.
    private static func badQueryErrorName(_ code: Int64) -> String {
        switch code {
        case -1: return "BQ_ERR_NO_GROUP"
        case -2: return "BQ_ERR_API_UNAVAILABLE"
        case -3: return "BQ_ERR_NO_RESULT"
        case -4: return "BQ_ERR_NO_TOKEN"
        case -5: return "BQ_ERR_DENIED"
        case -254: return "BQ_ERR_GROUP_LOOKUP"
        case -255: return "BQ_ERR_INVALID_PATH"
        default: return "BQ_ERR_\(code)"
        }
    }

    private static func callBadQuery(path: String, scope: BadQueryScope) -> Int64 {
        #if targetEnvironment(simulator)
        return -255
        #else
        var pathC = path.utf8CString.map { Int8($0) }
        if let group = scope.group, !group.isEmpty {
            return group.withCString { groupPtr in
                bad_query_with_flags(
                    &pathC,
                    true,
                    UnsafeMutablePointer(mutating: groupPtr),
                    scope.flags
                )
            }
        }
        return bad_query_with_flags(&pathC, true, nil, scope.flags)
        #endif
    }

    /// Walks upward from `path` until it finds the closest existing filesystem entry.
    /// Used so `verifyAccess` and `ContainerStore.ensureContainerAccess` can
    /// detect sandbox denials (`EPERM`/`EACCES`) even when the target file/folder
    /// does not exist yet (where `access(path, ...)` would otherwise return `ENOENT`).
    static func nearestExistingAncestor(of path: String) -> String {
        var current = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        guard !current.isEmpty else { return "/" }
        var st = stat()
        while current.count > 1 {
            if lstat(current, &st) == 0 {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current {
                return "/"
            }
            current = parent
        }
        return "/"
    }

    /// Confirms that a freshly granted sandbox extension actually unlocks `path`
    /// with the requested mode (`R_OK` or `R_OK | W_OK`).
    ///
    /// Returns `0` when the path (or its nearest existing container ancestor when
    /// `path` has not been created yet) passes `access(2)`, otherwise a negative
    /// `-errno` code (`-EPERM` / `-EACCES`).
    ///
    /// Exposed `static` (internal) so unit tests can verify ancestor & write checks.
    static func verifyAccess(path: String, requireWrite: Bool = false) -> Int64 {
        #if targetEnvironment(simulator)
        return 0
        #else
        let mode: Int32 = requireWrite ? (R_OK | W_OK) : R_OK
        // Always verify the real path spelling; /var/... is a symlink and a token
        // issued for it may never cover the /private/var/... node itself.
        let checkedPath = ContainerDiscoveryMerger.canonicalPath(path)
        var resolvedPath = checkedPath

        errno = 0
        if access(checkedPath, mode) != 0 {
            let initialErrno = errno
            if initialErrno == ENOENT {
                let ancestor = nearestExistingAncestor(of: checkedPath)
                guard ancestor != "/", ancestor != "/private",
                      ancestor != "/var", ancestor != "/private/var" else {
                    return badQueryAccessError(forErrno: initialErrno)
                }
                errno = 0
                if access(ancestor, mode) != 0 {
                    return badQueryAccessError(forErrno: errno)
                }
                resolvedPath = ancestor
            } else if requireWrite && (initialErrno == EACCES || initialErrno == EPERM) {
                // If `path` is an existing regular file with read-only POSIX mode bits (e.g. 0444),
                // FileIOEngine atomically stages a new file in the parent directory and renames it.
                // Only parent directory W_OK is required; don't misclassify POSIX 0444 as a sandbox block.
                var st = stat()
                let parent = (checkedPath as NSString).deletingLastPathComponent
                guard lstat(checkedPath, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFREG,
                      (st.st_mode & 0o222) == 0,
                      access(checkedPath, R_OK) == 0,
                      !parent.isEmpty, parent != "/", parent != "/private",
                      parent != "/var", parent != "/private/var" else {
                    return badQueryAccessError(forErrno: initialErrno)
                }
                errno = 0
                if access(parent, mode) != 0 {
                    return badQueryAccessError(forErrno: errno)
                }
                resolvedPath = parent
            } else {
                return badQueryAccessError(forErrno: initialErrno)
            }
        }

        // access(2) is not proof of a usable grant on iOS 26/27. The 27.2.1 device
        // log shows the POSIX permission check passing for a freshly consumed
        // handle while open(2)/readdir(3) on the same path keep returning EPERM —
        // the daemon hands out a token that does not cover the target, but
        // `access` only evaluates mode bits. Verifying with a real `open` is what
        // makes a useless handle fail here instead of later, and it keeps the
        // `grantedAccessMask` latch (and the negative cache) honest.
        return openProbeError(resolvedPath, requireWrite: requireWrite)
        #endif
    }

    /// Opens the path for real and closes it again.
    /// Returns `0` on success, `-errno` (never `0`) on failure.
    private static func openProbeError(_ path: String, requireWrite: Bool = false) -> Int64 {
        var st = stat()
        let isDir = (lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR)
        var flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        if isDir {
            flags |= O_DIRECTORY
        } else if requireWrite {
            flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        }
        errno = 0
        let fd = open(path, flags)
        if fd >= 0 {
            close(fd)
            return 0
        }
        let code = errno
        // wq_grant_opens: EACCES là quyền POSIX của file/folder root-owned,
        // token không thay đổi được → không coi là lỗi sandbox (reference).
        if code == EACCES { return 0 }
        return -Int64(code == 0 ? EPERM : code)
    }

    /// Maps a failed `access(2)` errno to the synthetic error code the router
    /// reports, or `0` when the failure is not sandbox related.
    static func badQueryAccessError(forErrno code: Int32) -> Int64 {
        switch code {
        case EPERM, EACCES:
            return -Int64(code)
        default:
            return 0
        }
    }

    private static func record(backend: SandboxBackend,
                               handle: Int64,
                               variant: Int32 = -1,
                               group: String? = nil) {
        stateLock.lock()
        lastBackendValue = backend
        stateLock.unlock()

        switch backend {
        case .badQuery:
            log("grant: backend=bad_query scope=\(group == nil ? "system" : "group") " +
                "handle=\(handle)")
        case .worseQuery:
            log("grant: backend=worse_query variant=\(variant) group=\(group ?? "-") handle=\(handle)")
        }
    }
}
