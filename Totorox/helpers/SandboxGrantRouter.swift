import Foundation
import Darwin

/// Chooses which sandbox backend grants access to a container path.
///
/// Chain (cheapest first, matching the project design):
///   Tier 1 `bad_query`  →  Tier 4 `worse_query`  →  give up.
///
/// `bad_query` is always attempted first, in both of its scopes:
/// `systemgroup.com.apple.mobilegestaltcache` (class 13, what worked up to
/// iOS 26) and our own App Group (class 7, the only scope iOS 27 still answers).
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

    /// Tier 4 (worse_query) is considered non-functional when it keeps returning
    /// WQ_ERR_NO_TOKEN for every path while Tier 1 (bad_query) still grants.
    /// Once that is observed repeatedly we stop paying for the doomed Tier 4
    /// round-trip and treat it as unusable for the rest of the session.
    private static var tier4ConsecutiveNoTokenFailures: Int = 0
    private static let tier4NoTokenThreshold: Int = 3
    private static var tier4Disabled: Bool = false

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
        tier4ConsecutiveNoTokenFailures = 0
        tier4Disabled = false
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

    /// Whether Tier 4 (worse_query) has been auto-disabled for this session
    /// because it kept returning `WQ_ERR_NO_TOKEN`. Read-only accessor for
    /// callers outside this type (e.g. AppContainerScanner).
    static var isTier4Disabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tier4Disabled
    }

    /// Disable Tier 4 (worse_query) for the rest of the session.
    ///
    /// Called when Tier 4 keeps returning `WQ_ERR_NO_TOKEN` while Tier 1
    /// (bad_query) still grants, i.e. Tier 4 is non-functional on this device.
    /// Thread-safe: acquires `stateLock`.
    static func disableTier4() {
        stateLock.lock()
        tier4Disabled = true
        tier4ConsecutiveNoTokenFailures = 0
        stateLock.unlock()
        log("grant: Tier 4 (worse_query) disabled for this session (repeated WQ_ERR_NO_TOKEN)")
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
    /// | memo | Tier 4 usable | order                        |
    /// |------|---------------|------------------------------|
    /// | off  | yes           | bad_query (system, then group) → worse_query |
    /// | off  | no            | bad_query                    |
    /// | on   | yes           | worse_query → bad_query      |
    /// | on   | no            | bad_query (last resort)      |
    ///
    /// The last two rows keep the router alive when the memo is on but Tier 4
    /// stops working mid-session (patched build, wiped group container, user
    /// toggled it off): without them the memo would make every following grant
    /// fail instead of degrading to Tier 1.
    static func grant(path: String, requireWrite: Bool = false) -> Int64 {
        guard path.count > 1, path.hasPrefix("/") else { return -1 }

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

        stateLock.lock()
        let tier4Usable = (group != nil) && !tier4Disabled
        let order = state.attemptOrder(worseQueryUsable: tier4Usable)
        stateLock.unlock()

        var failure: Int64 = 0
        var worseQueryFailedNoToken = false

        for backend in order {
            switch backend {
            case .badQuery:
                switch attemptBadQuery(path: grantPath, requireWrite: requireWrite) {
                case .granted(let handle):
                    // Tier 1 succeeded after Tier 4 failed with NO_TOKEN: Tier 4
                    // is non-functional on this device, stop using it.
                    if worseQueryFailedNoToken {
                        disableTier4()
                    }
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
                    stateLock.lock()
                    tier4ConsecutiveNoTokenFailures = 0
                    stateLock.unlock()
                    return handle
                case .failed(let code):
                    failure = code
                    if code == Int64(WQ_ERR_NO_TOKEN) {
                        worseQueryFailedNoToken = true
                        stateLock.lock()
                        tier4ConsecutiveNoTokenFailures += 1
                        let hitThreshold = tier4ConsecutiveNoTokenFailures >= tier4NoTokenThreshold
                        stateLock.unlock()
                        if hitThreshold {
                            disableTier4()
                        }
                    } else {
                        stateLock.lock()
                        tier4ConsecutiveNoTokenFailures = 0
                        stateLock.unlock()
                    }
                }
            }
        }

        let result = failure != 0 ? failure : -1
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

    /// Class-13 first (the documented order, still the only working one below
    /// iOS 26), then our own App Group with both flag variants — iOS 27 answers
    /// only the class-7 shape and prefers `1 << 39`, while `1 << 35` is what the
    /// older builds honoured.
    private static func badQueryScopes(group: String?) -> [BadQueryScope] {
        var scopes = [BadQueryScope(group: nil, flags: badQueryFlagPrimary, label: "system")]
        guard let group = group, !group.isEmpty else { return scopes }
        scopes.append(BadQueryScope(group: group, flags: badQueryFlagPrimary, label: "group"))
        scopes.append(BadQueryScope(group: group, flags: badQueryFlagAnyPath, label: "group-any"))
        return scopes
    }

    private static func attemptWorseQuery(path: String,
                                         group: String,
                                         requireWrite: Bool,
                                         targetExists: Bool) -> Attempt {
        // iOS < 27 prefers 1<<35, iOS >= 27 prefers 1<<39; a variant that once
        // produced a verified handle stays pinned (reference `_wq_grant` keeps
        // the same per-process memo).
        var variant = WorseQuery.preferredVariant
        var lastCode = Int64(WQ_ERR_NO_TOKEN)

        for round in 0..<2 {
            let handle = WorseQuery.grantVariant(path: path, group: group, variant: variant)
            guard handle >= 0 else {
                lastCode = handle
                log("grant: worse_query failed path=\(path) group=\(group) " +
                    "variant=\(variant.label) code=\(handle) \(WorseQuery.errorName(handle)) " +
                    "detail=\(WorseQuery.lastError())")
                // Only a missing target is worth the other flags. -6/-5 are the
                // same for both variants on iOS 27 (device logs), so retrying
                // there only burns a second swap + daemon round-trip.
                if round == 0 && WorseQuery.shouldRetryAnyPath(handle) {
                    variant = variant.opposite
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
            if round == 0 && (accessError == -Int64(EPERM) || accessError == -Int64(EACCES)) {
                variant = variant.opposite
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
        var resolvedPath = path

        errno = 0
        if access(path, mode) != 0 {
            let initialErrno = errno
            if initialErrno == ENOENT {
                let ancestor = nearestExistingAncestor(of: path)
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
                let parent = (path as NSString).deletingLastPathComponent
                guard lstat(path, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFREG,
                      (st.st_mode & 0o222) == 0,
                      access(path, R_OK) == 0,
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
        var flags = O_RDONLY | O_CLOEXEC
        if isDir {
            flags |= O_DIRECTORY
        } else if requireWrite {
            flags = O_RDWR | O_CLOEXEC
        }
        errno = 0
        let fd = open(path, flags)
        if fd >= 0 {
            close(fd)
            return 0
        }
        let code = errno
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
