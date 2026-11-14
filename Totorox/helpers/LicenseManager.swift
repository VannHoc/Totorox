import Foundation
import SwiftUI

/// Quản lý trạng thái kích hoạt license.
///
/// - Nếu có key hợp lệ đã kích hoạt: `status.isActive == true`.
/// - Nếu chưa có key hoặc key bị hủy: `.unlicensed`.
/// - Nếu key bị từ chối server: `.rejected(String)`.
@MainActor
final class LicenseManager: ObservableObject {
    enum Status: Equatable {
        case unlicensed
        case activating
        case active(expiresAt: Date?, remaining: Int?, dailyQuota: Int?)
        case rejected(String)

        var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    private struct CachedLicenseSnapshot: Codable, Equatable {
        let licenseKey: String
        let deviceIdentifier: String?
        let expiresAt: Date?
        let remaining: Int?
        let dailyQuota: Int?
    }

    static let shared = LicenseManager()

    enum Keys {
        static let licenseKey = "totorox.licenseKey"
        static let licenseSnapshot = "totorox.licenseSnapshot"
        static let installInitialized = "totorox.licenseInstallInitialized"
    }

    @Published private(set) var status: Status = .unlicensed
    @Published private(set) var licenseKey: String = ""
    @Published private(set) var deviceIdentifier: String
    @Published private(set) var isRefreshing: Bool = false

    private let api: APIService
    private let defaults: UserDefaults
    private let keyReader: () -> String?
    private let keyWriter: (String) -> Void
    private let keyRemover: () -> Void
    private var inFlightRefreshTask: Task<Void, Never>?

    init(
        api: APIService = .shared,
        defaults: UserDefaults = .standard,
        keyReader: @escaping () -> String? = { KeychainHelper.string(for: Keys.licenseKey) },
        keyWriter: @escaping (String) -> Void = { KeychainHelper.set($0, for: Keys.licenseKey) },
        keyRemover: @escaping () -> Void = { KeychainHelper.remove(Keys.licenseKey) },
        deviceIdentifierProvider: () -> String = { DeviceIDManager.shared.identifier },
        autoRefresh: Bool = true,
        clearOrphanedKeyOnFreshDefaults: Bool? = nil
    ) {
        self.api = api
        self.defaults = defaults
        self.keyReader = keyReader
        self.keyWriter = keyWriter
        self.keyRemover = keyRemover
        self.deviceIdentifier = deviceIdentifierProvider()

        let rawStoredKey = Self.normalizeKey(keyReader() ?? "")
        let snapshot = loadSnapshot()
        let hasPriorState = snapshot != nil
            || defaults.bool(forKey: Keys.installInitialized)
            || defaults.object(forKey: "totorox.deviceIdentifier") != nil
            || defaults.object(forKey: "onboarding.completedVersion") != nil
        defaults.set(true, forKey: Keys.installInitialized)

        let shouldPurgeOrphan = clearOrphanedKeyOnFreshDefaults ?? (defaults === UserDefaults.standard)
        if shouldPurgeOrphan && !rawStoredKey.isEmpty && !hasPriorState {
            // Fresh container/UserDefaults install (app was deleted & reinstalled):
            // clear orphaned Keychain license key so ActivationView is shown again.
            keyRemover()
            self.licenseKey = ""
        } else {
            self.licenseKey = rawStoredKey
        }

        if !self.licenseKey.isEmpty {
            if let snapshot,
               snapshot.licenseKey == self.licenseKey,
               snapshot.deviceIdentifier == nil || snapshot.deviceIdentifier == self.deviceIdentifier {
                if let expiresAt = snapshot.expiresAt, expiresAt <= Date() {
                    self.status = .unlicensed
                } else {
                    self.status = .active(
                        expiresAt: snapshot.expiresAt,
                        remaining: snapshot.remaining,
                        dailyQuota: snapshot.dailyQuota
                    )
                }
            } else {
                // No valid cached snapshot for this key + UDID: require server verification before entering main UI.
                self.status = .unlicensed
            }
            if autoRefresh {
                Task(priority: .background) { [weak self] in
                    await self?.refresh()
                }
            }
        }
    }

    var hasStoredKey: Bool {
        !licenseKey.isEmpty
    }

    func activate(_ rawKey: String) async {
        let key = Self.normalizeKey(rawKey)
        guard !key.isEmpty else {
            status = .rejected("Vui lòng nhập License Key.")
            return
        }

        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
        isRefreshing = false
        status = .activating
        switch await api.activate(licenseKey: key, hwid: deviceIdentifier) {
        case .success(let activation):
            licenseKey = key
            keyWriter(key)
            saveSnapshot(
                CachedLicenseSnapshot(
                    licenseKey: key,
                    deviceIdentifier: deviceIdentifier,
                    expiresAt: activation.expiresAt,
                    remaining: nil,
                    dailyQuota: nil
                )
            )
            defaults.set(true, forKey: Keys.installInitialized)
            status = .active(
                expiresAt: activation.expiresAt,
                remaining: nil,
                dailyQuota: nil
            )
            await refresh()
        case .failure(let error):
            status = .rejected(error.localizedDescription)
        }
    }

    func refresh() async {
        if let existing = inFlightRefreshTask {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            await self?.performRefresh()
        }
        inFlightRefreshTask = task
        isRefreshing = true
        await task.value
        inFlightRefreshTask = nil
        isRefreshing = false
    }

    private func performRefresh() async {
        let keyAtStart = licenseKey
        let hwidAtStart = deviceIdentifier
        guard !keyAtStart.isEmpty else {
            clearSnapshot()
            status = .unlicensed
            return
        }

        switch await api.verify(licenseKey: keyAtStart, hwid: hwidAtStart) {
        case .success(let resp):
            guard !Task.isCancelled, licenseKey == keyAtStart else { return }
            if resp.error != nil || resp.status != 200 {
                clearSnapshot()
                keyRemover()
                licenseKey = ""
                if let message = resp.error, !message.isEmpty {
                    status = .rejected(message)
                } else {
                    status = .unlicensed
                }
            } else {
                saveSnapshot(
                    CachedLicenseSnapshot(
                        licenseKey: keyAtStart,
                        deviceIdentifier: hwidAtStart,
                        expiresAt: resp.expiresAt,
                        remaining: resp.remaining,
                        dailyQuota: resp.dailyQuota
                    )
                )
                defaults.set(true, forKey: Keys.installInitialized)
                status = .active(
                    expiresAt: resp.expiresAt,
                    remaining: resp.remaining,
                    dailyQuota: resp.dailyQuota
                )
            }
        case .failure(let error):
            guard !Task.isCancelled, licenseKey == keyAtStart else { return }
            if Self.isAuthorizationRejection(error) {
                clearSnapshot()
                keyRemover()
                licenseKey = ""
                status = .rejected(error.localizedDescription)
            } else if !status.isActive {
                status = .rejected(error.localizedDescription)
            }
        }
    }

    func deactivate() {
        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
        isRefreshing = false
        licenseKey = ""
        keyRemover()
        clearSnapshot()
        status = .unlicensed
    }

    private static func normalizeKey(_ rawKey: String) -> String {
        rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isAuthorizationRejection(_ error: APIServiceError) -> Bool {
        if case .serverRejected(let statusCode, _) = error {
            return (400..<500).contains(statusCode)
        }
        return false
    }

    private func loadSnapshot() -> CachedLicenseSnapshot? {
        guard let data = defaults.data(forKey: Keys.licenseSnapshot) else { return nil }
        return try? JSONDecoder().decode(CachedLicenseSnapshot.self, from: data)
    }

    private func saveSnapshot(_ snapshot: CachedLicenseSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.licenseSnapshot)
    }

    private func clearSnapshot() {
        defaults.removeObject(forKey: Keys.licenseSnapshot)
    }
}
