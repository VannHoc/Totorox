import XCTest
@testable import Totorox

/// Regression: server trả `"daily_cap": null` (khi key có giới hạn tổng lượt)
/// làm `AnyCodable` cũ ném lỗi giải mã, khiến app báo
/// "Không thể đọc dữ liệu vì dữ liệu có định dạng không đúng."
final class APIServiceLicenseTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testAnyCodableDecodesNullAndTimestamp() throws {
        let json = #"{"expires_at": 1794736390, "daily_cap": null, "remaining": -1}"#
        let payload = try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))

        XCTAssertEqual(payload["expires_at"]?.timestamp, Date(timeIntervalSince1970: 1794736390))
        XCTAssertTrue(payload["daily_cap"]?.value is NSNull)
        XCTAssertEqual(payload["remaining"]?.int, -1)
        XCTAssertNil(payload["missing"]?.value)
    }

    func testAnyCodableRoundTripsNull() throws {
        let payload = try JSONDecoder().decode([String: AnyCodable].self, from: Data(#"{"a": null}"#.utf8))
        let encoded = try JSONEncoder().encode(payload)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"a":null}"#)
    }

    func testActivateAcceptsNullDailyCap() async {
        let body = #"""
        {
          "status": "activated",
          "expires_at": 1794736390,
          "used_count": 0,
          "max_uses": 5,
          "remaining_uses": 5,
          "daily_used": 0,
          "daily_cap": null,
          "daily_quota": 5,
          "used_today": 0,
          "remaining": 5
        }
        """#
        let session = StubURLProtocol.makeSession(statusCode: 200, body: body)
        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)

        let result = await api.activate(licenseKey: "TEST-KEY", hwid: "TEST-HWID")

        switch result {
        case .success(let activation):
            XCTAssertEqual(activation.expiresAt, Date(timeIntervalSince1970: 1794736390))
        case .failure(let error):
            XCTFail("Activate phải giải mã được payload có null: \(error.localizedDescription)")
        }
    }

    func testVerifyUsesExpiresAtTimestamp() async {
        let body = #"{"status": 200, "expires_at": 1794736390, "daily_cap": null, "remaining": 5}"#
        let session = StubURLProtocol.makeSession(statusCode: 200, body: body)
        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)

        let result = await api.verify(licenseKey: "TEST-KEY", hwid: "TEST-HWID")

        switch result {
        case .success(let response):
            XCTAssertEqual(response.expiresAt, Date(timeIntervalSince1970: 1794736390))
            XCTAssertEqual(response.remaining, 5)
        case .failure(let error):
            XCTFail("Verify phải giải mã được payload có null: \(error.localizedDescription)")
        }
    }

    func testMergePlanBodyDecodesConflicts() throws {
        let json = """
        {
          "output_filename": "AOV_Mod_2Heroes_c611.zip",
          "file_count": 3,
          "conflicts": 2,
          "files": [{"path": "Resources/1.64.1/Databin/Client/HeroSkin.bytes", "size": 100}],
          "loaded_mods": [],
          "bundle_versions": [],
          "note": "ok"
        }
        """
        let body = try JSONDecoder().decode(MergePlanBody.self, from: Data(json.utf8))
        XCTAssertEqual(body.conflicts, 2)
        XCTAssertEqual(body.fileCount, 3)
    }

    func testLicenseKeyTotoroxFormat() {
        let key = "totorox-abcd-1234-ef56"
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        XCTAssertTrue(normalized.hasPrefix("TOTOROX-"))
        XCTAssertEqual(normalized, "TOTOROX-ABCD-1234-EF56")
    }

    func testDeviceIDManagerPrefersHardwareUDIDOverStoredFallback() throws {
        let suiteName = "DeviceIDManagerTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("udid_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try "LEGACY-UUID-HWID".write(to: tempFile, atomically: true, encoding: .utf8)
        defaults.set("LEGACY-UUID-HWID", forKey: "totorox.deviceIdentifier")

        let managerWithUDID = DeviceIDManager(
            hardwareUDIDProvider: { "  00008110-001C12345678901E \n" },
            defaults: defaults,
            fileURL: tempFile
        )
        XCTAssertTrue(managerWithUDID.isHardwareUDID)
        XCTAssertEqual(managerWithUDID.identifier, "00008110-001C12345678901E")

        let managerFallback = DeviceIDManager(
            hardwareUDIDProvider: { nil },
            defaults: defaults,
            fileURL: tempFile
        )
        XCTAssertFalse(managerFallback.isHardwareUDID)
        XCTAssertEqual(managerFallback.identifier, "00008110-001C12345678901E")
    }

    @MainActor
    func testLicenseManagerColdLaunchWithCachedSnapshotHasZeroFlashAndSurvivesOffline() async throws {
        let suiteName = "LicenseManagerTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedKey: String? = nil
        let session = StubURLProtocol.makeSession(
            statusCode: 200,
            body: #"{"status":"activated","expires_at":4102444800,"remaining":9,"daily_quota":10}"#
        )
        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)

        let initialManager = LicenseManager(
            api: api,
            defaults: defaults,
            keyReader: { storedKey },
            keyWriter: { storedKey = $0 },
            keyRemover: { storedKey = nil },
            deviceIdentifierProvider: { "TEST-UDID-001" },
            autoRefresh: false
        )
        XCTAssertFalse(initialManager.status.isActive)

        await initialManager.activate("totorox-abcd-1234-ef56")
        XCTAssertTrue(initialManager.status.isActive)
        XCTAssertEqual(storedKey, "TOTOROX-ABCD-1234-EF56")

        // Cold relaunch with transient 503 should start immediately active (no flash) and stay active on refresh error
        let offlineSession = StubURLProtocol.makeSession(statusCode: 503, body: #"{"error":"unavailable"}"#)
        let offlineAPI = APIService(baseURL: URL(string: "https://example.test")!, session: offlineSession)
        let relaunched = LicenseManager(
            api: offlineAPI,
            defaults: defaults,
            keyReader: { storedKey },
            keyWriter: { storedKey = $0 },
            keyRemover: { storedKey = nil },
            deviceIdentifierProvider: { "TEST-UDID-001" },
            autoRefresh: false
        )
        XCTAssertTrue(relaunched.status.isActive, "Phải active ngay lập tức lúc khởi động lại, không nháy màn hình nhập key")

        await relaunched.refresh()
        XCTAssertTrue(relaunched.status.isActive, "Lỗi tạm thời 5xx/mất mạng không được đá người dùng ra màn hình nhập key")

        // Server 403 rejection must deactivate and show rejected
        let rejectedSession = StubURLProtocol.makeSession(statusCode: 403, body: #"{"detail":"Sai thiết bị"}"#)
        let rejectedAPI = APIService(baseURL: URL(string: "https://example.test")!, session: rejectedSession)
        let revokedManager = LicenseManager(
            api: rejectedAPI,
            defaults: defaults,
            keyReader: { storedKey },
            keyWriter: { storedKey = $0 },
            keyRemover: { storedKey = nil },
            deviceIdentifierProvider: { "TEST-UDID-001" },
            autoRefresh: false
        )
        await revokedManager.refresh()
        XCTAssertFalse(revokedManager.status.isActive)
    }
}

// MARK: - URLProtocol stub

private final class StubURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: String
    }

    private static let lock = NSLock()
    private static var _handler: ((URLRequest) -> Stub)?

    static var handler: ((URLRequest) -> Stub)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _handler = newValue
        }
    }

    static func makeSession(statusCode: Int, body: String) -> URLSession {
        handler = { _ in Stub(statusCode: statusCode, body: body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
