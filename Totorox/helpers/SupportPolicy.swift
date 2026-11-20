import Foundation

enum ExploitSupportPolicy {
    static let verifiedIOS16Range = "16.0–16.7.x (MHA-C2, cần TrollStore)"
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26Range = "26.0–26.0.1"
    static let verifiedWorseQueryRange = "26.0.2–27.2.1"

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

    /// Returns true for iOS versions that use the kernel exploit + bad_query path.
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
    /// kernel exploit on 17/18/26.0-26.0.1, worse_query on 26.0.2+).
    /// Includes worse_query range: iOS 26.0.2–27.2.1.
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

        // worse_query range: iOS 26.0.2+ (everything not covered by the
        // kernel exploit above).
        if major == 26 {
            guard minor >= 0, patch >= 0 else { return false }
            // 26.0.0–26.0.1 use the kernel exploit instead.
            if minor == 0 && patch <= 1 { return false }
            return true
        }

        // worse_query range: iOS 27.0–27.2 release versions
        if major == 27 {
            // Beta builds already handled by supportsKernelExploit above
            if iOS27BetaNumber(for: build) != nil {
                return true
            }
            // Release versions covered by worse_query: 27.0.x, 27.1.x, 27.2.0–27.2.1
            if minor == 0 || minor == 1 { return true }
            if minor == 2 && patch <= 1 { return true }
            return false
        }

        return false
    }

}