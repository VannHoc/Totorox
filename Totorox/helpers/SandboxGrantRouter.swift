import Foundation
import Darwin

/// Chooses which sandbox backend grants access to a container path.
///
/// Chain (cheapest first, matching the project design):
///   Tier 1 `bad_query`  →  Tier 4 `worse_query`  →  give up.
///
/// `bad_query` is always attempted first. A returned handle is not trusted on
/// its own: iOS 26+ can hand back a valid `mobilegestaltcache` token while
/// ignoring the `../../..` traversal, which leaves the real target blocked.
/// Every successful handle (from either tier) is therefore confirmed with
/// `access(path, R_OK)` before the router reports success.
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
            expiresAt: Date().addingTimeInterval(negativeTTL)
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
    /// | off  | yes           | bad_query → worse_query      |
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
        let order = state.attemptOrder(worseQueryUsable: group != nil)
        stateLock.unlock()

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

    private static func attemptBadQuery(path: String, requireWrite: Bool) -> Attempt {
        let handle = callBadQuery(path: path)
        guard handle >= 0 else {
            noteBadQueryFailure(handle)
            log("grant: bad_query failed path=\(path) code=\(handle) " +
                "\(WorseQuery.errorName(handle))")
            return .failed(handle)
        }

        let accessError = verifyAccess(path: path, requireWrite: requireWrite)
        if accessError == 0 {
            noteBadQuerySuccess()
            record(backend: .badQuery, handle: handle)
            return .granted(handle)
        }

        // The token exists but does not cover `path` (iOS 26 ignores the
        // traversal and hands out the cache container token instead, or only
        // granted read-only when write is required). Release it so the next tier runs.
        release(handle)
        noteBadQueryFailure(accessError)
        log("grant: bad_query handle=\(handle) does not cover path=\(path) " +
            "requireWrite=\(requireWrite) errno=\(-accessError) — next tier")
        return .failed(accessError)
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
                if round == 0 && handle == Int64(WQ_ERR_INVALID_PATH) {
                    variant = variant.opposite
                    continue
                }
                // Reference `_wq_grant`: -5 means the daemon could not answer at
                // all (usually an access cache left broken by a killed swap).
                // Repair it once per minute and retry the same flags.
                if round == 0,
                   handle == Int64(WQ_ERR_NO_RESULT),
                   repairAccessCacheIfNeeded(group: group) {
                    continue
                }
                return .failed(handle)
            }

            // A consumed extension is not proof either: when the daemon resolves
            // the group container from its own cache it hands back a token for
            // `<group>` instead of the swapped target. Verifying here keeps a
            // useless handle out of `ContainerStore.activeGrantHandles`.
            let accessError = verifyGrant(path: path, requireWrite: requireWrite)
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

    private static func callBadQuery(path: String) -> Int64 {
        #if targetEnvironment(simulator)
        return -255
        #else
        var pathC = path.utf8CString.map { Int8($0) }
        return bad_query(&pathC, true, nil, false)
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
        errno = 0
        if access(path, mode) == 0 {
            return 0
        }
        let initialErrno = errno
        if initialErrno == ENOENT {
            let ancestor = nearestExistingAncestor(of: path)
            if ancestor != "/" && ancestor != "/private" && ancestor != "/var" && ancestor != "/private/var" {
                errno = 0
                if access(ancestor, mode) == 0 {
                    return 0
                }
                return badQueryAccessError(forErrno: errno)
            }
        } else if requireWrite && (initialErrno == EACCES || initialErrno == EPERM) {
            // If `path` is an existing regular file with read-only POSIX mode bits (e.g. 0444),
            // FileIOEngine atomically stages a new file in the parent directory and renames it.
            // Only parent directory W_OK is required; don't misclassify POSIX 0444 as a sandbox block.
            var st = stat()
            if lstat(path, &st) == 0,
               (st.st_mode & S_IFMT) == S_IFREG,
               (st.st_mode & 0o222) == 0,
               access(path, R_OK) == 0 {
                let parent = (path as NSString).deletingLastPathComponent
                if !parent.isEmpty && parent != "/" && parent != "/private" && parent != "/var" && parent != "/private/var" {
                    errno = 0
                    if access(parent, R_OK | W_OK) == 0 {
                        return 0
                    }
                    return badQueryAccessError(forErrno: errno)
                }
            }
        }
        return badQueryAccessError(forErrno: initialErrno)
        #endif
    }

    /// Confirms a **consumed** Tier 4 extension with the same rule the reference
    /// `_wq_grant` uses: only `EPERM` from `open(2)` means "the token does not
    /// cover the target".
    ///
    /// `EACCES` is a POSIX mode-bit answer (an unreadable file still belongs to
    /// the container we were granted), and `ENOENT` says nothing about the token.
    /// Treating those as a denial is what made iOS 27 log false failures while
    /// the extension was in fact valid, so they must not veto the grant.
    static func verifyGrant(path: String, requireWrite: Bool = false) -> Int64 {
        #if targetEnvironment(simulator)
        return 0
        #else
        var st = stat()
        let knownDirectory = stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        var flags: Int32 = O_RDONLY | O_CLOEXEC | O_NONBLOCK
        if knownDirectory { flags |= O_DIRECTORY }

        errno = 0
        let fd = open(path, flags)
        if fd >= 0 {
            close(fd)
        } else {
            let code = errno
            if code == EPERM { return -Int64(EPERM) }
            // ENOENT/EACCES/anything else: not a statement about the token.
            if code != ENOENT && code != EACCES { return 0 }
            if code == ENOENT { return verifyAccess(path: path, requireWrite: requireWrite) }
        }

        guard requireWrite else { return 0 }

        errno = 0
        if access(path, W_OK) == 0 { return 0 }
        if errno == EPERM { return -Int64(EPERM) }
        // Read-only POSIX bits are staged by FileIOEngine through the parent
        // directory, so let the ancestor-aware check decide.
        return verifyAccess(path: path, requireWrite: true)
        #endif
    }

    private static var lastAccessCacheRepair: Date?
    private static let repairLock = NSLock()

    /// `_wq_grant` rate-limits the access-cache repair to once a minute: on a
    /// patched build every query returns -5, and without the limit each grant
    /// would rebuild the whole App Group cache.
    private static func repairAccessCacheIfNeeded(group: String) -> Bool {
        repairLock.lock()
        if let last = lastAccessCacheRepair, Date().timeIntervalSince(last) < 60 {
            repairLock.unlock()
            return false
        }
        lastAccessCacheRepair = Date()
        repairLock.unlock()

        let repaired = WorseQuery.repairAccessCache(group: group)
        log("grant: worse_query -5, access cache repair \(repaired ? "ok" : "failed") group=\(group)")
        return repaired
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
            log("grant: backend=bad_query handle=\(handle)")
        case .worseQuery:
            log("grant: backend=worse_query variant=\(variant) group=\(group ?? "-") handle=\(handle)")
        }
    }
}
