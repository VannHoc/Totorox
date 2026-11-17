import Foundation
import SwiftUI

/// Quản lý phiên tài khoản (Bearer token) và trạng thái gói / lượt dùng.
@MainActor
final class LicenseManager: ObservableObject {
    enum Status: Equatable {
        case signedOut
        case authenticating
        case authenticated(user: UserProfile)
        case rejected(String)

        var isAuthenticated: Bool {
            if case .authenticated = self { return true }
            return false
        }
    }

    struct UDIDVerificationAlert: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private struct CachedSessionSnapshot: Codable, Equatable {
        let token: String
        let deviceIdentifier: String?
        let user: UserProfile
    }

    static let shared = LicenseManager()

    enum Keys {
        static let authToken = "totorox.authToken"
        static let userSnapshot = "totorox.userSnapshot"
        static let installInitialized = "totorox.accountInstallInitialized"
        static let pendingUDIDClaim = "totorox.pendingUDIDClaim"
        // Legacy keys cleaned up on migration/reinstall
        static let legacyLicenseKey = "totorox.licenseKey"
        static let legacySnapshot = "totorox.licenseSnapshot"
    }

    @Published private(set) var status: Status = .signedOut
    @Published private(set) var authToken: String = ""
    @Published private(set) var currentUser: UserProfile?
    @Published private(set) var deviceIdentifier: String
    @Published private(set) var isRefreshing: Bool = false
    @Published var udidVerificationAlert: UDIDVerificationAlert?

    private let api: APIService
    private let defaults: UserDefaults
    private let tokenReader: () -> String?
    private let tokenWriter: (String) -> Void
    private let tokenRemover: () -> Void
    private let deviceIdentifierSaver: (String) -> Void
    private let deviceIdentifierClearer: () -> Void
    private var inFlightRefreshTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        api: APIService = .shared,
        defaults: UserDefaults = .standard,
        keyReader: @escaping () -> String? = { KeychainHelper.string(for: Keys.authToken) },
        keyWriter: @escaping (String) -> Void = { KeychainHelper.set($0, for: Keys.authToken) },
        keyRemover: @escaping () -> Void = { KeychainHelper.remove(Keys.authToken) },
        deviceIdentifierProvider: () -> String = { DeviceIDManager.shared.identifier },
        deviceIdentifierSaver: @escaping (String) -> Void = { DeviceIDManager.shared.saveVerifiedUDID($0) },
        deviceIdentifierClearer: @escaping () -> Void = { DeviceIDManager.shared.clearVerifiedUDID() },
        autoRefresh: Bool = true,
        clearOrphanedKeyOnFreshDefaults: Bool? = nil,
        observeAPINotifications: Bool = true
    ) {
        self.api = api
        self.defaults = defaults
        self.tokenReader = keyReader
        self.tokenWriter = keyWriter
        self.tokenRemover = keyRemover
        self.deviceIdentifierSaver = deviceIdentifierSaver
        self.deviceIdentifierClearer = deviceIdentifierClearer
        self.deviceIdentifier = deviceIdentifierProvider()

        defaults.removeObject(forKey: Keys.legacySnapshot)
        if defaults === UserDefaults.standard {
            KeychainHelper.remove(Keys.legacyLicenseKey)
        }

        let rawStoredToken = (keyReader() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = loadSnapshot()
        let hasPriorState = snapshot != nil
            || defaults.bool(forKey: Keys.installInitialized)
            || defaults.object(forKey: "totorox.deviceIdentifier") != nil
            || defaults.object(forKey: "onboarding.completedVersion") != nil
        defaults.set(true, forKey: Keys.installInitialized)

        let shouldPurgeOrphan = clearOrphanedKeyOnFreshDefaults ?? (defaults === UserDefaults.standard)
        if shouldPurgeOrphan && !rawStoredToken.isEmpty && !hasPriorState {
            keyRemover()
            self.authToken = ""
        } else {
            self.authToken = rawStoredToken
        }

        if !self.authToken.isEmpty {
            if let snapshot,
               snapshot.token == self.authToken,
               snapshot.deviceIdentifier == nil || snapshot.deviceIdentifier == self.deviceIdentifier {
                self.currentUser = snapshot.user
                self.status = .authenticated(user: snapshot.user)
            } else {
                self.status = .signedOut
            }
            if autoRefresh {
                Task(priority: .background) { [weak self] in
                    await self?.refresh()
                }
            }
        }

        if observeAPINotifications {
            let unauthObserver = NotificationCenter.default.addObserver(
                forName: APIService.sessionUnauthorizedNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let message = note.object as? String
                Task { @MainActor [weak self] in
                    self?.handleSessionEvicted(message: message)
                }
            }
            let profileObserver = NotificationCenter.default.addObserver(
                forName: APIService.userProfileUpdatedNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let user = note.object as? UserProfile else { return }
                Task { @MainActor [weak self] in
                    self?.applyUserProfile(user)
                }
            }
            notificationObservers = [unauthObserver, profileObserver]
        }
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var hasStoredSession: Bool {
        !authToken.isEmpty
    }

    var isAuthenticated: Bool {
        !authToken.isEmpty && status.isAuthenticated
    }

    var username: String {
        currentUser?.username ?? ""
    }

    var expiresAt: Date? {
        currentUser?.expiresDate
    }

    var maxUses: Int {
        currentUser?.maxUses ?? 0
    }

    var usedCount: Int {
        currentUser?.usedCount ?? 0
    }

    var remainingUses: Int {
        guard hasActivePlan, let user = currentUser else { return 0 }
        return user.remainingUses
    }

    var isUnlimited: Bool {
        hasActivePackage && (currentUser?.isUnlimited ?? false)
    }

    /// Trạng thái kích hoạt gói: chỉ `true` khi tài khoản không bị khóa, gói chưa hết hạn
    /// (`expires_at`) và vẫn còn lượt dùng (`remaining_uses > 0`) hoặc gói vô hạn.
    var hasActivePackage: Bool {
        guard let user = currentUser else { return false }
        if user.isBanned == true { return false }
        guard user.hasActivePlan else { return false }
        guard let exp = user.expiresDate, exp > Date() else { return false }
        if user.maxUses == -1 || user.remainingUses == -1 {
            return true
        }
        return user.remainingUses > 0
    }

    var hasActivePlan: Bool {
        hasActivePackage
    }

    /// `true` khi thiết bị đang giữ UDID phần cứng thật khớp với tài khoản đã xác minh OTA.
    var isDeviceVerified: Bool {
        guard !deviceIdentifier.isEmpty, let user = currentUser else { return false }
        if user.isUdidVerified == false { return false }
        if let serverUDID = user.udid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverUDID.isEmpty {
            return serverUDID == deviceIdentifier
        }
        return user.isUdidVerified != true
    }

    func deviceProfileURL() -> URL? {
        api.deviceProfileURL(username: username)
    }

    func prepareDeviceProfileURL() -> URL? {
        let claim = UUID().uuidString.lowercased()
        defaults.set(claim, forKey: Keys.pendingUDIDClaim)
        return api.deviceProfileURL(username: username, claim: claim)
    }

    func formattedExpiry(language: AppLanguage, short: Bool = false) -> String {
        guard let user = currentUser else { return "—" }
        guard let exp = user.expiresDate else {
            return language.text("account.no_plan")
        }
        if exp <= Date() {
            return language.text("account.plan_expired")
        }
        if !hasActivePackage {
            return language.text("account.no_plan")
        }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = short ? .short : .medium
        formatter.timeStyle = .short
        return formatter.string(from: exp)
    }

    func formattedRemainingUses(language: AppLanguage) -> String {
        guard hasActivePlan, let user = currentUser else {
            return language.text("account.uses_none")
        }
        if user.isUnlimited {
            return language.text("account.uses_unlimited")
        }
        let remaining = max(0, user.remainingUses)
        let total = max(0, user.maxUses)
        return language.text("account.uses_remaining_fmt", remaining, total)
    }

    // MARK: - Auth Actions

    func register(username: String, password: String) async -> Bool {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else {
            status = .rejected(AppLanguage.current.text("auth.error.missing_credentials"))
            return false
        }
        cancelRefresh()
        status = .authenticating
        switch await api.register(username: cleanUser, password: password, udid: deviceIdentifier) {
        case .success(let session):
            storeAuthenticatedSession(token: session.token, user: session.user)
            return true
        case .failure(let error):
            status = .rejected(error.localizedDescription)
            return false
        }
    }

    func login(username: String, password: String) async -> Bool {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !password.isEmpty else {
            status = .rejected(AppLanguage.current.text("auth.error.missing_credentials"))
            return false
        }
        cancelRefresh()
        status = .authenticating
        switch await api.login(username: cleanUser, password: password, udid: deviceIdentifier) {
        case .success(let session):
            storeAuthenticatedSession(token: session.token, user: session.user)
            return true
        case .failure(let error):
            status = .rejected(error.localizedDescription)
            return false
        }
    }

    func redeem(code: String) async -> Result<RedeemCodeResponse, APIServiceError> {
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !authToken.isEmpty else {
            return .failure(.serverRejected(status: 401, message: AppLanguage.current.text("api.error.unauthorized")))
        }
        let result = await api.redeem(code: cleanCode, token: authToken, hwid: deviceIdentifier)
        if case .success(let resp) = result {
            applyUserProfile(resp.user)
        } else if case .failure(let err) = result, Self.isUnauthorized(err) {
            handleSessionEvicted(message: err.localizedDescription)
        }
        return result
    }

    func refresh() async {
        if let existing = inFlightRefreshTask {
            await existing.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        inFlightRefreshTask = task
        isRefreshing = true
        await task.value
        inFlightRefreshTask = nil
        isRefreshing = false
    }

    func logout() async {
        let tokenToRevoke = authToken
        let hwid = deviceIdentifier
        clearLocalSession(status: .signedOut)
        if !tokenToRevoke.isEmpty {
            await api.logout(token: tokenToRevoke, hwid: hwid)
        }
    }

    func deactivate() {
        Task {
            await logout()
        }
    }

    func applyUserProfile(_ user: UserProfile) {
        guard !authToken.isEmpty else { return }
        if user.isUdidVerified == false && !deviceIdentifier.isEmpty {
            deviceIdentifierClearer()
            deviceIdentifier = ""
        }
        currentUser = user
        saveSnapshot(
            CachedSessionSnapshot(
                token: authToken,
                deviceIdentifier: deviceIdentifier,
                user: user
            )
        )
        status = .authenticated(user: user)
    }

    /// Xử lý deep link trả về từ Safari sau khi cài `.mobileconfig`:
    /// `totorox://udid-verified?udid=...&status=...`
    func handleUDIDVerificationCallback(udid: String?, status rawStatus: String?) async {
        let lang = AppLanguage.current
        let cleanStatus = (rawStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanUDID = (udid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        switch cleanStatus {
        case "ok":
            guard !cleanUDID.isEmpty else {
                udidVerificationAlert = UDIDVerificationAlert(
                    title: lang.text("udid.verify.alert.error_title"),
                    message: lang.text("udid.verify.alert.invalid")
                )
                return
            }

            // Hủy refresh nền (ví dụ từ scenePhase == .active) để tránh gửi request cũ thiếu X-HWID.
            cancelRefresh()
            defaults.removeObject(forKey: Keys.pendingUDIDClaim)
            deviceIdentifierSaver(cleanUDID)
            deviceIdentifier = cleanUDID

            if let currentUser {
                applyUserProfile(currentUser.withVerifiedUDID(cleanUDID))
            }

            if !authToken.isEmpty {
                await refresh()
            }

            udidVerificationAlert = UDIDVerificationAlert(
                title: lang.text("udid.verify.alert.success_title"),
                message: lang.text("udid.verify.alert.success_fmt", cleanUDID)
            )
        case "conflict":
            udidVerificationAlert = UDIDVerificationAlert(
                title: lang.text("udid.verify.alert.error_title"),
                message: lang.text("udid.verify.alert.conflict")
            )
        case "mismatch":
            udidVerificationAlert = UDIDVerificationAlert(
                title: lang.text("udid.verify.alert.error_title"),
                message: lang.text("udid.verify.alert.mismatch")
            )
        default:
            udidVerificationAlert = UDIDVerificationAlert(
                title: lang.text("udid.verify.alert.error_title"),
                message: lang.text("udid.verify.alert.invalid")
            )
        }
    }

    // MARK: - Internal Helpers

    private func storeAuthenticatedSession(token: String, user: UserProfile) {
        authToken = token
        tokenWriter(token)
        defaults.set(true, forKey: Keys.installInitialized)
        applyUserProfile(user)
    }

    private func performRefresh() async {
        let tokenAtStart = authToken
        var hwidAtStart = deviceIdentifier
        guard !tokenAtStart.isEmpty else {
            clearLocalSession(status: .signedOut)
            return
        }

        if hwidAtStart.isEmpty,
           let pendingClaim = defaults.string(forKey: Keys.pendingUDIDClaim),
           !pendingClaim.isEmpty,
           case .success(let claimedUDID?) = await api.claimDeviceUDID(
               claim: pendingClaim,
               token: tokenAtStart,
               hwid: hwidAtStart
           ) {
            guard !Task.isCancelled, authToken == tokenAtStart else { return }
            defaults.removeObject(forKey: Keys.pendingUDIDClaim)
            deviceIdentifierSaver(claimedUDID)
            deviceIdentifier = claimedUDID
            hwidAtStart = claimedUDID
            udidVerificationAlert = UDIDVerificationAlert(
                title: AppLanguage.current.text("udid.verify.alert.success_title"),
                message: AppLanguage.current.text("udid.verify.alert.success_fmt", claimedUDID)
            )
        }

        switch await api.fetchMe(token: tokenAtStart, hwid: hwidAtStart) {
        case .success(let me):
            guard !Task.isCancelled, authToken == tokenAtStart else { return }
            applyUserProfile(me.user)
        case .failure(let error):
            guard !Task.isCancelled, authToken == tokenAtStart else { return }
            if Self.isSessionInvalidation(error) {
                clearLocalSession(status: .rejected(error.localizedDescription))
            } else if !status.isAuthenticated {
                status = .rejected(error.localizedDescription)
            }
        }
    }

    private func handleSessionEvicted(message: String?) {
        guard !authToken.isEmpty else { return }
        let msg = (message?.isEmpty == false ? message! : AppLanguage.current.text("api.error.unauthorized"))
        clearLocalSession(status: .rejected(msg))
    }

    private func clearLocalSession(status nextStatus: Status) {
        cancelRefresh()
        authToken = ""
        currentUser = nil
        tokenRemover()
        clearSnapshot()
        status = nextStatus
    }

    private func cancelRefresh() {
        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
        isRefreshing = false
    }

    private static func isUnauthorized(_ error: APIServiceError) -> Bool {
        if case .serverRejected(let code, _) = error {
            return code == 401
        }
        return false
    }

    private static func isSessionInvalidation(_ error: APIServiceError) -> Bool {
        if case .serverRejected(let statusCode, _) = error {
            // 401: bị đá phiên hoặc token hết hạn; 403 trên /auth/me: tài khoản bị khóa.
            return statusCode == 401 || statusCode == 403
        }
        return false
    }

    private func loadSnapshot() -> CachedSessionSnapshot? {
        guard let data = defaults.data(forKey: Keys.userSnapshot) else { return nil }
        return try? JSONDecoder().decode(CachedSessionSnapshot.self, from: data)
    }

    private func saveSnapshot(_ snapshot: CachedSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.userSnapshot)
    }

    private func clearSnapshot() {
        defaults.removeObject(forKey: Keys.userSnapshot)
    }
}
