import Foundation

/// Quản lý **UDID phần cứng thật** của iPhone sau khi xác minh qua hồ sơ Safari `.mobileconfig`.
///
/// Không tạo UUID ngẫu nhiên dự phòng. Khi thiết bị chưa xác minh (hoặc đã bị Admin Reset UDID),
/// `verifiedUDID` trả về `nil` và `identifier` trả về chuỗi rỗng `""`.
final class DeviceIDManager {
    static let shared = DeviceIDManager()

    private enum Keys {
        static let keychainUDIDAccount = "totorox.verifiedHardwareUDID"
        static let legacyFileID = ".totorox_device_id"
        static let legacyDefaultsKey = "totorox.deviceIdentifier"
    }

    private let preferencesDirectory = URL(fileURLWithPath: "/var/mobile/Library/Preferences")
    private let defaults: UserDefaults
    private let customFileURL: URL?
    private let udidReader: () -> String?
    private let udidWriter: (String) -> Bool
    private let udidRemover: () -> Bool

    private var cachedUDID: String?

    /// UDID phần cứng thật đã được Apple OTA xác minh và lưu trong Keychain.
    var verifiedUDID: String? {
        if let cached = normalizedNonEmpty(cachedUDID) {
            return cached
        }
        let stored = normalizedNonEmpty(udidReader())
        cachedUDID = stored
        return stored
    }

    /// Giá trị gửi lên header `X-HWID` (chuỗi rỗng nếu thiết bị chưa xác minh UDID thật).
    var identifier: String {
        verifiedUDID ?? ""
    }

    /// `true` khi thiết bị đã xác minh và đang giữ UDID phần cứng thật.
    var isHardwareUDID: Bool {
        verifiedUDID != nil
    }

    init(
        defaults: UserDefaults = .standard,
        fileURL: URL? = nil,
        udidReader: @escaping () -> String? = { KeychainHelper.string(for: Keys.keychainUDIDAccount) },
        udidWriter: @escaping (String) -> Bool = { KeychainHelper.set($0, for: Keys.keychainUDIDAccount) },
        udidRemover: @escaping () -> Bool = { KeychainHelper.remove(Keys.keychainUDIDAccount) }
    ) {
        self.defaults = defaults
        self.customFileURL = fileURL
        self.udidReader = udidReader
        self.udidWriter = udidWriter
        self.udidRemover = udidRemover
        cleanupLegacyFallback()
    }

    // MARK: - Storage

    @discardableResult
    func saveVerifiedUDID(_ rawUDID: String) -> Bool {
        guard let clean = normalizedNonEmpty(rawUDID) else { return false }
        cachedUDID = clean
        _ = udidWriter(clean)
        cleanupLegacyFallback()
        return true
    }

    func clearVerifiedUDID() {
        cachedUDID = nil
        _ = udidRemover()
        cleanupLegacyFallback()
    }

    private var legacyFileURL: URL {
        customFileURL ?? preferencesDirectory.appendingPathComponent(Keys.legacyFileID)
    }

    private func cleanupLegacyFallback() {
        if defaults.object(forKey: Keys.legacyDefaultsKey) != nil {
            defaults.removeObject(forKey: Keys.legacyDefaultsKey)
        }
        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try? FileManager.default.removeItem(at: legacyFileURL)
        }
    }

    private func normalizedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
