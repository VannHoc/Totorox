import Foundation

enum ExploitSupportPolicy {
    static let verifiedIOS16Range = "16.0–16.7.x (TrollStore)"
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26Range = "26.0–26.0.1"
    static let verifiedWorseQueryRange = "26.0.2–27.3 beta 1"

    static let verifiedIOS27Builds: [(beta: Int, publicBeta: Int?, build: String)] = [
        (1, nil, "24A5355q"),
        (2, nil, "24A5370h"),
        (3, 1, "24A5380h"),
        (4, 2, "24A5390f")
    ]

    static func iOS27BetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.beta
    }

    static func iOS27PublicBetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.publicBeta
    }

    /// Returns true for iOS versions that support the direct kernel path:
    /// iOS 17.0–17.7, 18.0–18.7.1, 26.0–26.0.1, and iOS 27.0 beta builds
    /// (public beta 1-2, dev beta 1-4).
    static func supportsKernelExploit(major: Int, minor: Int, patch: Int, build: String = "") -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        if major == 17 {
            return minor <= 7
        }

        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 1)
        }

        if major == 26 {
            // Kernel exploit (darkside offsets) only supports 26.0.0–26.0.1.
            return minor == 0 && patch <= 1
        }

        if major == 27 {
            // Only specific beta builds support kernel exploit:
            // iOS 27.0 public beta 1-2, dev beta 1-4
            return iOS27BetaNumber(for: build) != nil
        }

        return false
    }

    /// Returns true for all supported iOS versions (MHA-C2 on iOS 16 via TrollStore,
    /// direct kernel path on 17/18/26.0-26.0.1, worse_query on 26.0.2–27.3 beta 1).
    /// Includes worse_query range: iOS 26.0.2–27.3 beta 1.
    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        // iOS 16: only the MHA-C2 tier (entitlements + MCM) is available,
        // which requires TrollStore / fake-signing to honor the private
        // entitlements. No kernel exploit path exists for iOS 16.
        if major == 16 {
            return true
        }

        if supportsKernelExploit(major: major, minor: minor, patch: patch, build: build) {
            return true
        }

        // Reject any build string that `worse_query_is_patched_build()` flags as patched
        // (e.g. any `24C` build outside `5000..<5049`, `24D+`, or major > 24).
        if !build.isEmpty && isPatchedWorseQueryBuild(build) {
            return false
        }

        // worse_query range: iOS 26.0.2+ (everything not covered by the
        // kernel path above).
        if major == 26 {
            guard minor >= 0, patch >= 0 else { return false }
            if minor == 0 && patch <= 1 { return false }
            return true
        }

        // worse_query range: iOS 27.0–27.3 beta 1 (patched in 27.3 beta 2 / 24C5049d+ and 24C release)
        if major == 27 {
            if iOS27BetaNumber(for: build) != nil {
                return true
            }
            if minor == 0 || minor == 1 { return true }
            if minor == 2 && patch <= 1 { return true }
            if minor == 3 && patch == 0 {
                return isIOS273Beta1Build(build)
            }
            return false
        }

        return false
    }

    /// Exact Swift mirror of `worse_query_is_patched_build()` in `worse_query.m`:
    /// - `major < 24` (e.g. `23x` iOS 26): unpatched (`false`)
    /// - `major > 24`: patched (`true`)
    /// - `major == 24`:
    ///   - `train < 'C'` (`24A` = 27.0, `24B` = 27.1/27.2): unpatched (`false`)
    ///   - `train > 'C'` (`24D+`): patched (`true`)
    ///   - `train == 'C'` (`24C` = 27.3): ONLY `5000..<5049` (27.3 beta 1) is unpatched;
    ///     release `24C` builds (e.g. `24C101`) and beta 2+ (`24C5049d+`) are patched (`true`).
    static func isPatchedWorseQueryBuild(_ build: String) -> Bool {
        var idx = build.startIndex
        var major = 0
        var majorDigits = 0
        while idx < build.endIndex, let d = build[idx].wholeNumberValue, build[idx].isASCII {
            major = major * 10 + d
            majorDigits += 1
            idx = build.index(after: idx)
        }
        guard majorDigits > 0, idx < build.endIndex else { return false }
        let train = build[idx]
        guard train.isASCII, train >= "A", train <= "Z" else { return false }
        idx = build.index(after: idx)

        var number = 0
        var numDigits = 0
        while idx < build.endIndex, numDigits < 6, let d = build[idx].wholeNumberValue, build[idx].isASCII {
            number = number * 10 + d
            numDigits += 1
            idx = build.index(after: idx)
        }
        guard numDigits > 0 else { return false }

        if major != 24 { return major > 24 }
        if train != "C" { return train > "C" }
        return !(number >= 5000 && number < 5049)
    }

    static func isIOS273Beta1Build(_ build: String) -> Bool {
        guard build.hasPrefix("24C") else { return false }
        return !isPatchedWorseQueryBuild(build)
    }

}