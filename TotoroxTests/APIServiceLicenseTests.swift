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

    func testRegisterAndLoginDecodeUserProfileAndToken() async {
        let body = #"""
        {
          "ok": true,
          "message": "Đăng nhập thành công",
          "token": "tok_session_123",
          "user": {
            "id": 42,
            "username": "player1",
            "expires_at": 1794736390,
            "max_uses": 5,
            "used_count": 1,
            "remaining_uses": 4,
            "has_active_plan": true,
            "daily_used": 1,
            "daily_cap": null,
            "hwid": "TEST-UDID",
            "is_banned": false
          }
        }
        """#
        let session = StubURLProtocol.makeSession(statusCode: 200, body: body)
        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)

        switch await api.register(username: "player1", password: "secret123", udid: "TEST-UDID") {
        case .success(let auth):
            XCTAssertEqual(auth.token, "tok_session_123")
            XCTAssertEqual(auth.user.username, "player1")
            XCTAssertEqual(auth.user.remainingUses, 4)
            XCTAssertNil(auth.user.dailyCap)
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/v1/auth/register")
        case .failure(let error):
            XCTFail("Register phải giải mã được payload tài khoản: \(error.localizedDescription)")
        }

        switch await api.login(username: "player1", password: "secret123", udid: "TEST-UDID") {
        case .success(let auth):
            XCTAssertTrue(auth.user.hasActivePlan)
            XCTAssertEqual(auth.user.expiresDate, Date(timeIntervalSince1970: 1794736390))
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/v1/auth/login")
        case .failure(let error):
            XCTFail("Login phải giải mã được payload tài khoản: \(error.localizedDescription)")
        }
    }

    func testRedeemAndFetchMeIncludeBearerTokenHeader() async {
        let redeemBody = #"""
        {
          "ok": true,
          "message": "Nạp thành công",
          "code": "TOTOROX-ABCD-1234",
          "added_days": 30,
          "added_uses": -1,
          "user": {
            "id": 42,
            "username": "player1",
            "expires_at": 1794736390,
            "max_uses": -1,
            "used_count": 0,
            "remaining_uses": -1,
            "has_active_plan": true,
            "daily_used": 0,
            "daily_cap": 300,
            "hwid": "TEST-UDID",
            "is_banned": false
          }
        }
        """#
        let apiRedeem = APIService(
            baseURL: URL(string: "https://example.test")!,
            session: StubURLProtocol.makeSession(statusCode: 200, body: redeemBody)
        )
        switch await apiRedeem.redeem(code: "TOTOROX-ABCD-1234", token: "tok_abc", hwid: "TEST-UDID") {
        case .success(let resp):
            XCTAssertEqual(resp.addedDays, 30)
            XCTAssertTrue(resp.user.isUnlimited)
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Device-ID"), "TEST-UDID")
        case .failure(let error):
            XCTFail("Redeem failed: \(error.localizedDescription)")
        }

        let meBody = #"""
        {
          "ok": true,
          "user": {
            "id": 42,
            "username": "player1",
            "expires_at": 1794736390,
            "max_uses": 30,
            "used_count": 2,
            "remaining_uses": 28,
            "has_active_plan": true,
            "daily_used": 2,
            "daily_cap": null
          }
        }
        """#
        let apiMe = APIService(
            baseURL: URL(string: "https://example.test")!,
            session: StubURLProtocol.makeSession(statusCode: 200, body: meBody)
        )
        switch await apiMe.fetchMe(token: "tok_xyz", hwid: "TEST-UDID") {
        case .success(let me):
            XCTAssertEqual(me.user.expiresDate, Date(timeIntervalSince1970: 1794736390))
            XCTAssertEqual(me.user.remainingUses, 28)
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/v1/auth/me")
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok_xyz")
        case .failure(let error):
            XCTFail("fetchMe phải giải mã được payload có null: \(error.localizedDescription)")
        }
    }

    func testOverwritePlanSendsBearerHeaderAndDecodesMappings() async {
        let body = #"""
        {
          "ok": true,
          "mappings": [
            {"source": "1.64.1/Databin/Client/HeroSkin.bytes", "destination": "Resources/1.64.1/Databin/Client/HeroSkin.bytes"}
          ],
          "skipped": ["README.txt"],
          "detected_source_version": "1.64.1",
          "resolved_target_version": "1.64.1",
          "note": "ok"
        }
        """#
        let session = StubURLProtocol.makeSession(statusCode: 200, body: body)
        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)
        let req = OverwritePlanRequest(
            sourcePaths: ["1.64.1/Databin/Client/HeroSkin.bytes", "README.txt"],
            targetPaths: ["Resources/1.64.1/Databin/Client/"],
            targetBundleId: "com.garena.game.kgvn",
            targetSubfolder: "Documents",
            sourceSizes: ["1.64.1/Databin/Client/HeroSkin.bytes": 128]
        )

        switch await api.overwritePlan(req, token: "tok_ovw", hwid: "TEST-UDID") {
        case .success(let plan):
            XCTAssertEqual(plan.mappings.count, 1)
            XCTAssertEqual(plan.mappings.first?.destination, "Resources/1.64.1/Databin/Client/HeroSkin.bytes")
            XCTAssertEqual(plan.resolvedTargetVersion, "1.64.1")
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/v1/overwrite-plan")
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok_ovw")
        case .failure(let error):
            XCTFail("overwritePlan failed: \(error.localizedDescription)")
        }
    }

    func testConvertHeaderSendsBearerTokenHeader() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hdr_\(UUID().uuidString).zip")
        try Data("PK\u{03}\u{04}".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let body = #"""
        {
          "ok": true,
          "mode": "zip_to_3105",
          "password_protected": false,
          "header": {"schemaVersion": 9},
          "toc": [],
          "note": "ok"
        }
        """#
        let session = StubURLProtocol.makeSession(statusCode: 200, body: body)
        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)
        switch await api.convertHeader(fileURL: tmp, mode: "zip_to_3105", password: nil, token: "tok_conv", hwid: "TEST-UDID") {
        case .success(let resp):
            XCTAssertTrue(resp.ok)
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/v1/convert-header")
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok_conv")
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Device-ID"), "TEST-UDID")
        case .failure(let error):
            XCTFail("convertHeader failed: \(error.localizedDescription)")
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
    func testLicenseManagerColdLaunchWithCachedSessionSurvivesOfflineAndEvictsOn401() async throws {
        let suiteName = "LicenseManagerTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedToken: String? = nil
        let loginSession = StubURLProtocol.makeSession(
            statusCode: 200,
            body: #"""
            {
              "ok": true,
              "token": "tok_active_1",
              "user": {
                "id": 10,
                "username": "tester",
                "expires_at": 4102444800,
                "max_uses": 30,
                "used_count": 1,
                "remaining_uses": 29,
                "has_active_plan": true,
                "daily_used": 1,
                "daily_cap": null
              }
            }
            """#
        )
        let api = APIService(baseURL: URL(string: "https://example.test")!, session: loginSession)

        let initialManager = LicenseManager(
            api: api,
            defaults: defaults,
            keyReader: { storedToken },
            keyWriter: { storedToken = $0 },
            keyRemover: { storedToken = nil },
            deviceIdentifierProvider: { "TEST-UDID-001" },
            autoRefresh: false,
            observeAPINotifications: false
        )
        XCTAssertFalse(initialManager.isAuthenticated)

        let loggedIn = await initialManager.login(username: "tester", password: "password123")
        XCTAssertTrue(loggedIn)
        XCTAssertTrue(initialManager.isAuthenticated)
        XCTAssertEqual(storedToken, "tok_active_1")
        XCTAssertEqual(initialManager.username, "tester")
        XCTAssertEqual(initialManager.remainingUses, 29)

        // Cold relaunch with transient 503 must preserve cached session offline
        let offlineSession = StubURLProtocol.makeSession(statusCode: 503, body: #"{"error":"unavailable"}"#)
        let relaunched = LicenseManager(
            api: APIService(baseURL: URL(string: "https://example.test")!, session: offlineSession),
            defaults: defaults,
            keyReader: { storedToken },
            keyWriter: { storedToken = $0 },
            keyRemover: { storedToken = nil },
            deviceIdentifierProvider: { "TEST-UDID-001" },
            autoRefresh: false,
            observeAPINotifications: false
        )
        XCTAssertTrue(relaunched.isAuthenticated)
        await relaunched.refresh()
        XCTAssertTrue(relaunched.isAuthenticated, "Lỗi tạm thời 5xx/mất mạng không được đăng xuất người dùng")

        // Server 401 eviction (signed in elsewhere) must clear session token and kick back to login
        let evictedSession = StubURLProtocol.makeSession(statusCode: 401, body: #"{"detail":"Tài khoản đã đăng nhập trên thiết bị khác"}"#)
        let evictedManager = LicenseManager(
            api: APIService(baseURL: URL(string: "https://example.test")!, session: evictedSession),
            defaults: defaults,
            keyReader: { storedToken },
            keyWriter: { storedToken = $0 },
            keyRemover: { storedToken = nil },
            deviceIdentifierProvider: { "TEST-UDID-001" },
            autoRefresh: false,
            observeAPINotifications: false
        )
        await evictedManager.refresh()
        XCTAssertFalse(evictedManager.isAuthenticated)
        XCTAssertNil(storedToken, "Token bị đá phiên (401) phải bị xóa khỏi Keychain")
        XCTAssertEqual(evictedManager.authToken, "")
    }

    @MainActor
    func testLicenseManagerFreshInstallPurgesOrphanTokenAndDeviceSwitchRequiresReauth() async throws {
        let suiteName = "LicenseManagerFreshTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedToken: String? = "orphan_token_999"
        let offlineSession = StubURLProtocol.makeSession(statusCode: 503, body: #"{"error":"offline"}"#)
        let offlineAPI = APIService(baseURL: URL(string: "https://example.test")!, session: offlineSession)

        // Simulates fresh install (UserDefaults wiped) while Keychain still retained old token
        let freshInstall = LicenseManager(
            api: offlineAPI,
            defaults: defaults,
            keyReader: { storedToken },
            keyWriter: { storedToken = $0 },
            keyRemover: { storedToken = nil },
            deviceIdentifierProvider: { "NEW-UDID-999" },
            autoRefresh: false,
            clearOrphanedKeyOnFreshDefaults: true,
            observeAPINotifications: false
        )
        XCTAssertFalse(freshInstall.isAuthenticated)
        XCTAssertNil(storedToken, "Phải xóa token mồ côi còn sót trong Keychain khi cài mới")

        // Login succeeds on device A, switching to device B must invalidate cached snapshot
        let okSession = StubURLProtocol.makeSession(
            statusCode: 200,
            body: #"""
            {
              "ok": true,
              "token": "tok_dev_a",
              "user": {
                "id": 11,
                "username": "tester",
                "expires_at": 4102444800,
                "max_uses": 5,
                "used_count": 0,
                "remaining_uses": 5,
                "has_active_plan": true
              }
            }
            """#
        )
        let activeManager = LicenseManager(
            api: APIService(baseURL: URL(string: "https://example.test")!, session: okSession),
            defaults: defaults,
            keyReader: { storedToken },
            keyWriter: { storedToken = $0 },
            keyRemover: { storedToken = nil },
            deviceIdentifierProvider: { "OLD-UUID-111" },
            autoRefresh: false,
            observeAPINotifications: false
        )
        _ = await activeManager.login(username: "tester", password: "password123")
        XCTAssertTrue(activeManager.isAuthenticated)

        let changedDeviceManager = LicenseManager(
            api: offlineAPI,
            defaults: defaults,
            keyReader: { storedToken },
            keyWriter: { storedToken = $0 },
            keyRemover: { storedToken = nil },
            deviceIdentifierProvider: { "NEW-UDID-222" },
            autoRefresh: false,
            observeAPINotifications: false
        )
        XCTAssertFalse(changedDeviceManager.isAuthenticated, "Đổi từ UUID cũ sang UDID mới không được vào thẳng không cần xác minh")
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
    private static var _lastRequest: URLRequest?

    static var lastRequest: URLRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastRequest
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _lastRequest = newValue
        }
    }

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
        lastRequest = nil
        handler = { _ in Stub(statusCode: statusCode, body: body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
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
