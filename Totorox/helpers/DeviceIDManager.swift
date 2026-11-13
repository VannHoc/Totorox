import Foundation

/// Quản lý HWID dùng cho backend: ưu tiên UUID cố định nằm ngoài sandbox
/// (`/var/mobile/Library/Preferences/.totorox_device_id`), fallback xuống
/// `UserDefaults` dùng chung ứng dụng nếu không thể đọc/ghi vùng đó.
///
/// Không phụ thuộc vào Keychain.
final class DeviceIDManager {
    static let shared = DeviceIDManager()

    private enum Keys {
        static let fileID = ".totorox_device_id"
        static let userDefaultsKey = "totorox.deviceIdentifier"
    }

    private let preferencesDirectory = URL(fileURLWithPath: "/var/mobile/Library/Preferences")

    private var _identifier: String?
    var identifier: String {
        if let cached = _identifier { return cached }
        let stable = loadOrCreateIdentifier()
        _identifier = stable
        return stable
    }

    private init() {}

    private var fileURL: URL {
        preferencesDirectory.appendingPathComponent(Keys.fileID)
    }

    // MARK: - Storage

    private func loadOrCreateIdentifier() -> String {
        if let existing = readFromFile() {
            return existing
        }
        if let existing = storedFallback() {
            return existing
        }

        let fresh = UUID().uuidString
        // Ưu tiên ghi ra ngoài sandbox; nếu không được thì lưu UserDefaults.
        do {
            try fresh.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            UserDefaults.standard.set(fresh, forKey: Keys.userDefaultsKey)
        }
        return fresh
    }

    private func readFromFile() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func storedFallback() -> String? {
        guard let stored = UserDefaults.standard.string(forKey: Keys.userDefaultsKey),
              !stored.isEmpty else { return nil }
        return stored
    }
}
