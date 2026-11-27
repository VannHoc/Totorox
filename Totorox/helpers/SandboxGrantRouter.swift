import Foundation
import Darwin

/// Routes container path access requests on iOS 26+ exclusively through `worse_query`.
///
/// Architecture notes for maintainers / AI agents:
/// - Legacy `bad_query` has been completely removed from Totorox. Do NOT re-introduce it.
/// - There is NO fallback grant backend on iOS 26+: if `WorseQuery.grantGroup == nil`
///   (missing App Group entitlement/profile, patched build >= 27.3 beta 2, or missing API),
///   `grant()` returns `-1` immediately.
/// - iOS 16–18 do not use this router (`majorVersion < 26` returns `-1` immediately).
/// - iOS 26.0–27.3 beta 1 use `worse_query` exclusively, confirmed via a real `open(2)`
///   probe (`verifyAccess`) before any handle is cached in `ContainerStore.activeGrantHandles`.
enum SandboxGrantRouter {

    private static let stateLock = NSLock()
    private static var lastBackendValue: String?
    private static var hasVerifiedGrantThisSession: Bool = false
    private static var consecutiveNoTokenFailures: Int = 0
    private static var noTokenExhaustedForSession: Bool = false

    private struct NegativeEntry {
        let code: Int64
        let expiresAt: Date
    }
    private static var negativeGrants: [String: NegativeEntry] = [:]
    private static let negativeTTL: TimeInterval = 60

    /// System root ancestors that never carry a usable container token.
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

    static var lastBackend: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastBackendValue
    }

    static var isNoTokenExhaustedForSession: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return noTokenExhaustedForSession
    }

    static func resetSessionState() {
        stateLock.lock()
        negativeGrants.removeAll()
        consecutiveNoTokenFailures = 0
        noTokenExhaustedForSession = false
        stateLock.unlock()
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
        if negativeGrants.count > 4096 {
            let now = Date()
            negativeGrants = negativeGrants.filter { $0.value.expiresAt > now }
        }
        negativeGrants[key] = NegativeEntry(
            code: code,
            expiresAt: Date().addingTimeInterval(
                code == -3 || code == -4
                    || code == Int64(WQ_ERR_NO_RESULT) || code == Int64(WQ_ERR_NO_TOKEN)
                    ? 600 : negativeTTL
            )
        )
        stateLock.unlock()
    }

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

    /// Grants access to `path` via `worse_query`. Returns a handle `>= 0` on success, `< 0` on failure.
    static func grant(path: String, requireWrite: Bool = false) -> Int64 {
        grantImpl(path: path, requireWrite: requireWrite, didRotateGroup: false, didRepairCache: false)
    }

    private static func grantImpl(path: String,
                                  requireWrite: Bool,
                                  didRotateGroup: Bool,
                                  didRepairCache: Bool) -> Int64 {
        guard path.count > 1, path.hasPrefix("/") else { return -1 }

        // iOS 16–18 use direct container access / MHA-C2; do not invoke worse_query there.
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            return -1
        }

        if isNoTokenExhaustedForSession {
            return Int64(WQ_ERR_NO_TOKEN)
        }

        let exists = targetExists(path)
        if !exists && !requireWrite {
            return -1
        }

        if let cached = cachedFailure(path: path, requireWrite: requireWrite) {
            return cached
        }

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

        guard let group = WorseQuery.grantGroup else { return -1 }

        let result: Int64
        switch attemptWorseQuery(path: grantPath,
                                 group: group,
                                 requireWrite: requireWrite) {
        case .granted(let handle):
            stateLock.lock()
            hasVerifiedGrantThisSession = true
            consecutiveNoTokenFailures = 0
            noTokenExhaustedForSession = false
            stateLock.unlock()
            return handle
        case .failed(let code):
            result = code != 0 ? code : -1
        }

        if result == Int64(WQ_ERR_NO_TOKEN), !didRepairCache,
           let currentGroup = WorseQuery.grantGroup,
           WorseQuery.resetAccessCache(group: currentGroup) {
            return grantImpl(path: path,
                             requireWrite: requireWrite,
                             didRotateGroup: didRotateGroup,
                             didRepairCache: true)
        }

        if result == Int64(WQ_ERR_NO_TOKEN), !didRotateGroup,
           WorseQuery.rotateGrantGroup() {
            return grantImpl(path: path,
                             requireWrite: requireWrite,
                             didRotateGroup: true,
                             didRepairCache: didRepairCache)
        }

        if result == Int64(WQ_ERR_NO_TOKEN) {
            let groupBudget = max(WorseQuery.usableGroups().count, 3)
            var becameExhausted = false
            stateLock.lock()
            if !hasVerifiedGrantThisSession {
                consecutiveNoTokenFailures += 1
                if consecutiveNoTokenFailures >= groupBudget && !noTokenExhaustedForSession {
                    noTokenExhaustedForSession = true
                    becameExhausted = true
                }
            }
            stateLock.unlock()
            if becameExhausted {
                log("grant: worse_query returned WQ_ERR_NO_TOKEN across all usable groups — pausing symlink-swap grants until refresh")
            }
        }

        rememberFailure(result, path: path, requireWrite: requireWrite)
        return result
    }

    static func release(_ handle: Int64) {
        WorseQuery.release(handle)
    }

    // MARK: - Internals

    private enum Attempt {
        case granted(Int64)
        case failed(Int64)
    }

    private static func attemptWorseQuery(path: String,
                                          group: String,
                                          requireWrite: Bool) -> Attempt {
        var variant = WorseQuery.preferredVariant
        if let probe = WorseQuery.tokenProbe {
            if probe.primary && !probe.anyPath { variant = .primary }
            if probe.anyPath && !probe.primary { variant = .anyPath }
        }
        var lastCode = Int64(WQ_ERR_NO_TOKEN)

        for round in 0..<3 {
            if round == 2, variant != .standard { variant = .standard }
            let handle = WorseQuery.grantVariant(path: path, group: group, variant: variant)
            guard handle >= 0 else {
                lastCode = handle
                log("grant: worse_query failed path=\(path) group=\(group) " +
                    "variant=\(variant.label) code=\(handle) \(WorseQuery.errorName(handle)) " +
                    "detail=\(WorseQuery.lastError())")

                if handle == Int64(WQ_ERR_CACHE_UNUSABLE), round == 0 {
                    let repaired = WorseQuery.resetAccessCache(group: group)
                    log("grant: access cache repaired automatically" +
                        (repaired ? "" : " — FAILED: " + WorseQuery.lastError()))
                    if repaired { continue }
                }

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

            let accessError = verifyAccess(path: path, requireWrite: requireWrite)
            if accessError == 0 {
                WorseQuery.noteVariant(variant.rawValue)
                record(backend: "worse_query",
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

    /// Confirms that a granted extension unlocks `path` with `R_OK` or `R_OK | W_OK`.
    static func verifyAccess(path: String, requireWrite: Bool = false) -> Int64 {
        #if targetEnvironment(simulator)
        return 0
        #else
        let mode: Int32 = requireWrite ? (R_OK | W_OK) : R_OK
        let checkedPath = ContainerDiscoveryMerger.canonicalPath(path)
        var resolvedPath = checkedPath

        errno = 0
        if access(checkedPath, mode) != 0 {
            let initialErrno = errno
            if initialErrno == ENOENT {
                let ancestor = nearestExistingAncestor(of: checkedPath)
                guard ancestor != "/", ancestor != "/private",
                      ancestor != "/var", ancestor != "/private/var" else {
                    return accessDenialError(forErrno: initialErrno)
                }
                errno = 0
                if access(ancestor, mode) != 0 {
                    return accessDenialError(forErrno: errno)
                }
                resolvedPath = ancestor
            } else if requireWrite && (initialErrno == EACCES || initialErrno == EPERM) {
                var st = stat()
                let parent = (checkedPath as NSString).deletingLastPathComponent
                guard lstat(checkedPath, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFREG,
                      (st.st_mode & 0o222) == 0,
                      access(checkedPath, R_OK) == 0,
                      !parent.isEmpty, parent != "/", parent != "/private",
                      parent != "/var", parent != "/private/var" else {
                    return accessDenialError(forErrno: initialErrno)
                }
                errno = 0
                if access(parent, mode) != 0 {
                    return accessDenialError(forErrno: errno)
                }
                resolvedPath = parent
            } else {
                return accessDenialError(forErrno: initialErrno)
            }
        }

        return openProbeError(resolvedPath, requireWrite: requireWrite)
        #endif
    }

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
        if code == EACCES { return 0 }
        return -Int64(code == 0 ? EPERM : code)
    }

    /// Maps a failed `access(2)` errno to a negative code for permission denials, or `0` otherwise.
    static func accessDenialError(forErrno code: Int32) -> Int64 {
        switch code {
        case EPERM, EACCES:
            return -Int64(code)
        default:
            return 0
        }
    }

    private static func record(backend: String,
                               handle: Int64,
                               variant: Int32 = -1,
                               group: String? = nil) {
        stateLock.lock()
        lastBackendValue = backend
        stateLock.unlock()
        log("grant: backend=\(backend) variant=\(variant) group=\(group ?? "-") handle=\(handle)")
    }
}
