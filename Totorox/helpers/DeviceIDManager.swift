import Foundation

/// Quản lý định danh thiết bị dùng cho backend & bảo hành key:
/// Ưu tiên đọc **UDID phần cứng** (`UniqueDeviceID` qua MobileGestalt);
/// chỉ fallback sang tệp ngoài sandbox (`/var/mobile/Library/Preferences/.totorox_device_id`)
/// hoặc `UserDefaults` khi môi trường không cho phép đọc UDID thật (ví dụ Simulator).
///
/// Không phụ thuộc vào Keychain.
final class DeviceIDManager {
    static let shared = DeviceIDManager()

    private enum Keys {
        static let fileID = ".totorox_device_id"
        static let userDefaultsKey = "totorox.deviceIdentifier"
    }

    private let preferencesDirectory = URL(fileURLWithPath: "/var/mobile/Library/Preferences")
    private let hardwareUDIDProvider: () -> String?
    private let defaults: UserDefaults
    private let customFileURL: URL?
    private let persistHardwareUDID: Bool

    private var _identifier: String?
    var identifier: String {
        if let cached = _identifier { return cached }
        let stable = loadOrCreateIdentifier()
        _identifier = stable
        return stable
    }

    var isHardwareUDID: Bool {
        normalizedNonEmpty(hardwareUDIDProvider()) != nil
    }

    init(
        hardwareUDIDProvider: @escaping () -> String? = { TotoroxCopyHardwareUDID() },
        defaults: UserDefaults = .standard,
        fileURL: URL? = nil,
        persistHardwareUDID: Bool = true
    ) {
        self.hardwareUDIDProvider = hardwareUDIDProvider
        self.defaults = defaults
        self.customFileURL = fileURL
        self.persistHardwareUDID = persistHardwareUDID
    }

    private var fileURL: URL {
        customFileURL ?? preferencesDirectory.appendingPathComponent(Keys.fileID)
    }

    // MARK: - Storage

    private func loadOrCreateIdentifier() -> String {
        if let udid = normalizedNonEmpty(hardwareUDIDProvider()) {
            if persistHardwareUDID {
                if readFromFile() != udid {
                    try? udid.write(to: fileURL, atomically: true, encoding: .utf8)
                }
                if defaults.string(forKey: Keys.userDefaultsKey) != udid {
                    defaults.set(udid, forKey: Keys.userDefaultsKey)
                }
            }
            return udid
        }
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
            defaults.set(fresh, forKey: Keys.userDefaultsKey)
        }
        return fresh
    }

    private func normalizedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func readFromFile() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return normalizedNonEmpty(raw)
    }

    private func storedFallback() -> String? {
        return normalizedNonEmpty(defaults.string(forKey: Keys.userDefaultsKey))
    }
}
