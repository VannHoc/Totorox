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

    static let shared = LicenseManager()

    enum Keys {
        static let licenseKey = "totorox.licenseKey"
    }

    @Published private(set) var status: Status = .unlicensed
    @Published private(set) var licenseKey: String = ""
    @Published private(set) var deviceIdentifier: String = DeviceIDManager.shared.identifier

    private let api: APIService

    init(api: APIService = .shared) {
        self.api = api
        self.licenseKey = Self.storedKey() ?? ""
        if !self.licenseKey.isEmpty {
            self.status = .unlicensed // chưa xác minh lại với server
            Task.detached(priority: .background) {
                await self?.refresh()
            }
        }
    }

    var hasStoredKey: Bool {
        !licenseKey.isEmpty
    }

    func activate(_ rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = .rejected("Vui lòng nhập License Key.")
            return
        }

        status = .activating
        switch await api.activate(licenseKey: key, hwid: deviceIdentifier) {
        case .success(let activation):
            licenseKey = key
            Self.saveKey(key)
            status = .active(
                expiresAt: activation.expiresAt,
                remaining: nil,
                dailyQuota: nil
            )
            await refresh()
        case .failure(let error):
            status = .rejected(error.localizedDescription ?? "Không kích hoạt được.")
        }
    }

    func refresh() async {
        guard !licenseKey.isEmpty else {
            status = .unlicensed
            return
        }
        switch await api.verify(licenseKey: licenseKey, hwid: deviceIdentifier) {
        case .success(let resp):
            if resp.error != nil || resp.status != 200 {
                status = .unlicensed
            } else {
                status = .active(
                    expiresAt: resp.expiresAt,
                    remaining: resp.remaining,
                    dailyQuota: resp.dailyQuota
                )
            }
        case .failure(let error):
            status = .rejected(error.localizedDescription ?? "Không kết nối được server.")
        }
    }

    func deactivate() {
        licenseKey = ""
        Self.clearKey()
        status = .unlicensed
    }

    private static func storedKey() -> String? {
        KeychainHelper.string(for: Keys.licenseKey)
    }

    private static func saveKey(_ key: String) {
        KeychainHelper.set(key, for: Keys.licenseKey)
    }

    private static func clearKey() {
        KeychainHelper.remove(Keys.licenseKey)
    }
}
