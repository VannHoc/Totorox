import Foundation

/// Owns the activation state and the device identifier (HWID).
///
/// Phase 1: nothing in the app requires activation yet, so an unlicensed app keeps working.
/// Once the backend is deployed, gate the UI on `status.isActive` (see HANDOFF_TO_NEW_AGENT.md).
@MainActor
final class LicenseManager: ObservableObject {
    enum Status: Equatable {
        case unlicensed
        case activating
        case active(expiresAt: Date?)
        case rejected(String)

        var isActive: Bool {
            if case .active = self {
                return true
            }
            return false
        }
    }

    static let shared = LicenseManager()

    private enum Account {
        static let licenseKey = "licenseKey"
        static let deviceIdentifier = "deviceIdentifier"
    }

    @Published private(set) var status: Status = .unlicensed
    @Published private(set) var licenseKey: String = ""

    /// Stable identifier for this device, generated once and kept in the Keychain.
    let deviceIdentifier: String

    private let api: APIService

    init(api: APIService = .shared) {
        self.api = api
        self.deviceIdentifier = KeychainHelper.value(for: Account.deviceIdentifier) {
            UUID().uuidString
        }
        self.licenseKey = KeychainHelper.string(for: Account.licenseKey) ?? ""
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
            KeychainHelper.set(key, for: Account.licenseKey)
            status = .active(expiresAt: activation.expiresAt)
        case .failure(let error):
            status = .rejected(error.localizedDescription)
        }
    }

    /// Re-checks the stored key with the server. Call this when the app becomes active.
    func refresh() async {
        guard !licenseKey.isEmpty else {
            status = .unlicensed
            return
        }
        await activate(licenseKey)
    }

    func deactivate() {
        licenseKey = ""
        KeychainHelper.remove(Account.licenseKey)
        status = .unlicensed
    }
}
