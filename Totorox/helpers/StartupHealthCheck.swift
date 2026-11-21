import Foundation

/// Startup health-check, port phần logic của WQFiles 0.9.19 (`WQHealth.m`).
///
/// Không có giao diện: chỉ trả danh sách check và ghi log. Mục đích là biến
/// những ca "danh sách app rỗng / iOS đã vá / thiếu App Group" thành một dòng
/// log có lý do cụ thể, thay vì để người dùng đoán.
///
/// Các hàm `accessState`, `namesState`, `worst`, `sample` là thuần dữ liệu để
/// unit test mà không cần thiết bị thật.
enum HealthState: Int {
    case ok = 0
    case skipped = 1
    case warning = 2
    case failed = 3

    var label: String {
        switch self {
        case .ok: return "ok"
        case .skipped: return "skipped"
        case .warning: return "warning"
        case .failed: return "FAILED"
        }
    }
}

struct HealthCheck {
    let key: String
    let state: HealthState
    let detail: String
}

enum StartupHealthCheck {

    // MARK: - Pure decisions

    static func worst(_ checks: [HealthCheck]) -> HealthState {
        checks.reduce(HealthState.ok) { current, check in
            check.state.rawValue > current.rawValue ? check.state : current
        }
    }

    /// Một vài folder của app khác có thể bị từ chối vì lý do riêng; đa số phải mở được.
    static func accessState(opened: Int, sampled: Int) -> HealthState {
        guard sampled > 0 else { return .skipped }
        if opened == 0 { return .failed }
        return opened * 2 >= sampled ? .ok : .warning
    }

    static func namesState(namesLoaded: Bool, knownName: Bool, labeled: Int, sampled: Int) -> HealthState {
        guard namesLoaded, knownName else { return .warning }
        if sampled > 0, labeled * 2 < sampled { return .warning }
        return .ok
    }

    /// Lấy tối đa `count` folder rải đều, bỏ folder của chính app.
    static func sample(_ containers: [String], home: String, count: Int = 8) -> [String] {
        guard count > 0 else { return [] }
        let own = home.hasSuffix("/") ? String(home.dropLast()) : home
        let others = containers.filter {
            let path = $0.hasSuffix("/") ? String($0.dropLast()) : $0
            return path != own
        }
        guard others.count > count else { return others }
        return (0..<count).map { others[$0 * others.count / count] }
    }

    // MARK: - Run

    @discardableResult
    static func run() -> [HealthCheck] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let patchHint = WorseQuery.isPatchedBuild
        let group = WorseQuery.grantGroup
        // WQFiles/worse_query chỉ áp dụng iOS 26+. Trên iOS 16–18 lấy danh sách
        // bằng DarkSword kernel exploit / MHA-C2; thiếu App Group ở đây KHÔNG
        // phải lỗi (và kernel exploit thực sự không hỗ trợ 18.7.2–18.7.10).
        let tier4Expected = os.majorVersion >= 26
        var checks: [HealthCheck] = []

        // 1. App Group — chỉ đánh giá trên iOS 26+.
        let groupState: HealthState = !tier4Expected ? .skipped
            : group == nil ? .failed : .ok
        let groupDetail: String = !tier4Expected
            ? "Tier 4 (worse_query) chỉ dùng iOS 26+; iOS \(osText) dùng kernel exploit/MHA-C2"
            : group ?? "thiếu: bản ký đã bỏ entitlement/provisioning group"
        checks.append(HealthCheck(key: "App Group", state: groupState, detail: groupDetail))

        // 2. Folder của app khác — lấy từ CM class 1…14 (không cần token).
        let allPaths = Array(ContainerStore.containerManagerPairs().values)
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        let sample = Self.sample(allPaths, home: home, count: 8)
        let foldersState: HealthState = !tier4Expected ? .skipped
            : group == nil ? .skipped
            : allPaths.isEmpty ? .failed
            : sample.isEmpty ? .failed
            : .ok
        let foldersDetail = !tier4Expected
            ? "iOS \(osText): danh sách phụ thuộc kernel exploit (\(allPaths.count) container từ MCM)"
            : group == nil ? "cần App Group"
            : allPaths.isEmpty ? "không tìm thấy container nào trên thiết bị"
            : "\(allPaths.count) container"
        checks.append(HealthCheck(key: "Other apps' folders",
                                  state: foldersState, detail: foldersDetail))

        // 3. Sandbox access — thử mở thật từng folder mẫu.
        var opened = 0
        for path in sample where SandboxGrantRouter.verifyAccess(path: path) == 0 {
            opened += 1
        }
        let access = Self.accessState(opened: opened, sampled: sample.count)
        let accessDetail: String
        if access == .skipped {
            accessDetail = "không có folder để thử"
        } else if access == .failed && patchHint {
            accessDetail = "\(opened)/\(sample.count) mở được; iOS \(osText) đã vá worse_query từ 27.3 beta 2"
        } else if access == .failed {
            accessDetail = "\(opened)/\(sample.count) mở được; kiểm tra access cache / App Group dùng chung"
        } else {
            accessDetail = "\(opened)/\(sample.count) folder mẫu mở được"
        }
        checks.append(HealthCheck(key: "Sandbox access", state: access, detail: accessDetail))

        // 4. App names — dùng cache csstore có sẵn, không tải mới ở đây.
        let store = ContainerMetadataCache.shared.cachedLSStore
        let namesLoaded = store != nil
        let knownName = store?.displayNameByBundleID["com.apple.mobilesafari"] != nil
        let labeled = sample.filter { store?.bundleIDByContainerPath[$0] != nil }.count
        let names: HealthState = !tier4Expected ? .skipped
            : access == .failed || group == nil ? .skipped
            : Self.namesState(namesLoaded: namesLoaded, knownName: knownName,
                              labeled: labeled, sampled: sample.count)
        let namesDetail = names == .skipped
            ? (!tier4Expected ? "csstore/WQFiles chỉ dùng iOS 26+" : "cần sandbox access")
            : names == .ok ? "\(labeled)/\(sample.count) folder mẫu có tên"
            : "csstore chưa tải hoặc layout chưa nhận diện (\(labeled)/\(sample.count))"
        checks.append(HealthCheck(key: "App names", state: names, detail: namesDetail))

        // 5. Phiên bản iOS.
        let tested = (os.majorVersion == 26 || os.majorVersion == 27) && !patchHint
        let versionDetail = patchHint
            ? "iOS \(osText): Apple đã vá worse_query ở 27.3 beta 2"
            : tested ? osText
            : os.majorVersion == 18 && os.minorVersion == 7 && os.patchVersion >= 2
                ? "iOS \(osText): kernel exploit không hỗ trợ 18.7.2–18.7.10 (danh sách app bị giới hạn)"
                : "iOS \(osText) chưa được xác minh với bản này"
        checks.append(HealthCheck(key: "iOS version",
                                  state: tested ? .ok : .warning,
                                  detail: versionDetail))

        let summary = checks.map { "\($0.key)=\($0.state.label)" }.joined(separator: ", ")
        log("health: iOS \(osText): \(summary) [worst=\(worst(checks).label)]")
        for check in checks where check.state == .failed || check.state == .warning {
            log("health: \(check.key) — \(check.detail)")
        }
        return checks
    }
}
