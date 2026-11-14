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
        let expiresAt: Date?
        let remaining: Int?
        let dailyQuota: Int?
    }

    static let shared = LicenseManager()

    enum Keys {
        static let licenseKey = "totorox.licenseKey"
        static let licenseSnapshot = "totorox.licenseSnapshot"
    }

    @Published private(set) var status: Status = .unlicensed
    @Published private(set) var licenseKey: String = ""
    @Published private(set) var deviceIdentifier: String

    private let api: APIService
    private let defaults: UserDefaults
    private let keyReader: () -> String?
    private let keyWriter: (String) -> Void
    private let keyRemover: () -> Void

    init(
        api: APIService = .shared,
        defaults: UserDefaults = .standard,
        keyReader: @escaping () -> String? = { KeychainHelper.string(for: Keys.licenseKey) },
        keyWriter: @escaping (String) -> Void = { KeychainHelper.set($0, for: Keys.licenseKey) },
        keyRemover: @escaping () -> Void = { KeychainHelper.remove(Keys.licenseKey) },
        deviceIdentifierProvider: () -> String = { DeviceIDManager.shared.identifier },
        autoRefresh: Bool = true
    ) {
        self.api = api
        self.defaults = defaults
        self.keyReader = keyReader
        self.keyWriter = keyWriter
        self.keyRemover = keyRemover
        self.deviceIdentifier = deviceIdentifierProvider()

        let normalizedStoredKey = Self.normalizeKey(keyReader() ?? "")
        self.licenseKey = normalizedStoredKey
        if !normalizedStoredKey.isEmpty {
            if let snapshot = loadSnapshot(), snapshot.licenseKey == normalizedStoredKey {
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
                // Key đã lưu từ trước khi có snapshot: vào thẳng màn hình chính không nháy ActivationView,
                // sau đó xác minh ngầm ở nền.
                self.status = .active(expiresAt: nil, remaining: nil, dailyQuota: nil)
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

        status = .activating
        switch await api.activate(licenseKey: key, hwid: deviceIdentifier) {
        case .success(let activation):
            licenseKey = key
            keyWriter(key)
            saveSnapshot(
                CachedLicenseSnapshot(
                    licenseKey: key,
                    expiresAt: activation.expiresAt,
                    remaining: nil,
                    dailyQuota: nil
                )
            )
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
        guard !licenseKey.isEmpty else {
            clearSnapshot()
            status = .unlicensed
            return
        }
        switch await api.verify(licenseKey: licenseKey, hwid: deviceIdentifier) {
        case .success(let resp):
            if resp.error != nil || resp.status != 200 {
                clearSnapshot()
                status = .unlicensed
            } else {
                saveSnapshot(
                    CachedLicenseSnapshot(
                        licenseKey: licenseKey,
                        expiresAt: resp.expiresAt,
                        remaining: resp.remaining,
                        dailyQuota: resp.dailyQuota
                    )
                )
                status = .active(
                    expiresAt: resp.expiresAt,
                    remaining: resp.remaining,
                    dailyQuota: resp.dailyQuota
                )
            }
        case .failure(let error):
            if Self.isAuthorizationRejection(error) {
                clearSnapshot()
                status = .rejected(error.localizedDescription)
            } else if !status.isActive {
                status = .rejected(error.localizedDescription)
            }
        }
    }

    func deactivate() {
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
