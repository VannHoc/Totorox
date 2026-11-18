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
/// Handles stay cached by `ContainerStore.activeGrantHandles`; this router never
/// keeps its own handle cache.
enum SandboxGrantRouter {

    private static let stateLock = NSLock()
    private static var state = SandboxTierState()
    private static var lastBackendValue: SandboxBackend?

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
        stateLock.unlock()
        WorseQuery.invalidateGroupCache()
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
        guard !path.isEmpty else { return -1 }

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
                switch attemptBadQuery(path: path, requireWrite: requireWrite) {
                case .granted(let handle):
                    return handle
                case .failed(let code):
                    failure = code
                }
            case .worseQuery:
                guard let group = group else { continue }
                switch attemptWorseQuery(path: path, group: group, requireWrite: requireWrite) {
                case .granted(let handle):
                    return handle
                case .failed(let code):
                    failure = code
                }
            }
        }

        return failure != 0 ? failure : -1
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

    private static func attemptWorseQuery(path: String, group: String, requireWrite: Bool) -> Attempt {
        var variant: Int32 = -1
        let handle = WorseQuery.grantRaw(path: path, group: group, usedVariant: &variant)
        guard handle >= 0 else {
            log("grant: worse_query failed path=\(path) group=\(group) " +
                "code=\(handle) \(WorseQuery.errorName(handle)) detail=\(WorseQuery.lastError())")
            return .failed(handle)
        }

        // A consumed extension is not proof either: when the daemon resolves the
        // group container from its own cache it hands back a token for
        // `<group>` instead of the swapped target. Verifying here keeps a
        // useless handle out of `ContainerStore.activeGrantHandles`.
        let accessError = verifyAccess(path: path, requireWrite: requireWrite)
        guard accessError == 0 else {
            release(handle)
            log("grant: worse_query handle=\(handle) variant=\(variant) group=\(group) " +
                "does not cover path=\(path) requireWrite=\(requireWrite) errno=\(-accessError) — next tier")
            return .failed(accessError)
        }

        stateLock.lock()
        let wasBlocked = state.badQueryBlocked
        state.noteWorseQuerySuccess()
        let nowBlocked = state.badQueryBlocked
        stateLock.unlock()
        if !wasBlocked && nowBlocked {
            log("grant: bad_query marked BLOCKED for this session " +
                "(tier 4 works, tier 1 does not)")
        }
        record(backend: .worseQuery, handle: handle, variant: variant, group: group)
        return .granted(handle)
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
