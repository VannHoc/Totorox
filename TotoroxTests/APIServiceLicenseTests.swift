import Security
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
            XCTAssertNotNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Timestamp"))
            XCTAssertNotNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Nonce"))
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Signature")?.count, 64)
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
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-HWID"), "TEST-UDID")
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
          "accepted_bytes": 4,
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
            XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-HWID"), "TEST-UDID")
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

    func testDeviceIDManagerStoresVerifiedHardwareUDIDWithoutRandomFallback() throws {
        let suiteName = "DeviceIDManagerTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("udid_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try "LEGACY-UUID-HWID".write(to: tempFile, atomically: true, encoding: .utf8)
        defaults.set("LEGACY-UUID-HWID", forKey: "totorox.deviceIdentifier")

        var storedUDID: String? = nil
        let manager = DeviceIDManager(
            defaults: defaults,
            fileURL: tempFile,
            udidReader: { storedUDID },
            udidWriter: {
                storedUDID = $0
                return true
            },
            udidRemover: {
                storedUDID = nil
                return true
            }
        )
        XCTAssertFalse(manager.isHardwareUDID)
        XCTAssertNil(manager.verifiedUDID)
        XCTAssertEqual(manager.identifier, "")
        XCTAssertNil(defaults.object(forKey: "totorox.deviceIdentifier"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))

        XCTAssertTrue(manager.saveVerifiedUDID("  00008110-001C12345678901E \n"))
        XCTAssertTrue(manager.isHardwareUDID)
        XCTAssertEqual(manager.identifier, "00008110-001C12345678901E")
        XCTAssertEqual(storedUDID, "00008110-001C12345678901E")

        manager.clearVerifiedUDID()
        XCTAssertFalse(manager.isHardwareUDID)
        XCTAssertEqual(manager.identifier, "")
        XCTAssertNil(storedUDID)
    }

    func testAPIServiceFixedPublicBaseURLAndDeviceProfileURL() {
        UserDefaults.standard.set("https://stale.example.invalid", forKey: APIService.baseURLDefaultsKey)
        let api = APIService()
        XCTAssertEqual(api.baseURL.absoluteString, "https://api.totorox.io.vn")
        XCTAssertNil(UserDefaults.standard.object(forKey: APIService.baseURLDefaultsKey))

        let profileURL = api.deviceProfileURL(username: "totorox user")
        XCTAssertEqual(
            profileURL?.absoluteString,
            "https://api.totorox.io.vn/api/v1/device/profile?username=totorox%20user"
        )
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

    @MainActor
    func testLicenseManagerPackageStatesAndUDIDVerificationCallback() async throws {
        let suiteName = "PackageAndUDIDTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var storedToken: String? = nil
        var savedUDID: String? = "00008110-OLD-STALE"

        // Login returns exhausted finite quota and is_udid_verified=false (simulating Admin Reset UDID)
        let exhaustedSession = StubURLProtocol.makeSession(
            statusCode: 200,
            body: #"""
            {
              "ok": true,
              "token": "tok_pkg_1",
              "user": {
                "id": 22,
                "username": "modder01",
                "expires_at": 4102444800,
                "max_uses": 5,
                "used_count": 5,
                "remaining_uses": 0,
                "has_active_plan": false,
                "udid": null,
                "is_udid_verified": false
              }
            }
            """#
        )
        let api1 = APIService(baseURL: URL(string: "https://example.test")!, session: exhaustedSession)
        let manager = LicenseManager(
            api: api1,
            defaults: defaults,
            keyReader: { storedToken },
            keyWriter: { storedToken = $0 },
            keyRemover: { storedToken = nil },
            deviceIdentifierProvider: { savedUDID ?? "" },
            deviceIdentifierSaver: { savedUDID = $0 },
            deviceIdentifierClearer: { savedUDID = nil },
            autoRefresh: false,
            observeAPINotifications: false
        )

        let ok = await manager.login(username: "modder01", password: "password123")
        XCTAssertTrue(ok)
        XCTAssertFalse(manager.hasActivePackage, "Hết lượt dùng thì hasActivePackage phải là false")
        XCTAssertFalse(manager.isDeviceVerified, "Server báo is_udid_verified=false phải xóa UDID cũ")
        XCTAssertNil(savedUDID)
        XCTAssertEqual(manager.deviceIdentifier, "")

        // Conflict callback shows alert without saving UDID
        await manager.handleUDIDVerificationCallback(udid: "", status: "conflict")
        XCTAssertFalse(manager.isDeviceVerified)
        XCTAssertNotNil(manager.udidVerificationAlert)

        // Successful OTA verification callback updates savedUDID + currentUser immediately and triggers refresh
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Stub(
                statusCode: 200,
                body: #"""
                {
                  "ok": true,
                  "user": {
                    "id": 22,
                    "username": "modder01",
                    "expires_at": 4102444800,
                    "max_uses": 5,
                    "used_count": 2,
                    "remaining_uses": 3,
                    "has_active_plan": true,
                    "udid": "00008110-001C12345678901E",
                    "is_udid_verified": true
                  }
                }
                """#
            )
        }
        await manager.handleUDIDVerificationCallback(udid: "00008110-001C12345678901E", status: "ok")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-HWID"), "00008110-001C12345678901E")
        XCTAssertEqual(savedUDID, "00008110-001C12345678901E")
        XCTAssertEqual(manager.deviceIdentifier, "00008110-001C12345678901E")
        XCTAssertTrue(manager.isDeviceVerified)
        XCTAssertTrue(manager.hasActivePackage)
    }

    func testHMACSecretAndSignatureMatchBackendReferenceVector() async throws {
        XCTAssertEqual(
            String(decoding: APIService.hmacSecretData(), as: UTF8.self),
            "d0b244628b4dc78ed0fd7097f188cb1dca7c5b8644ca84d2"
        )
        let refSig = APIService.computeHMACSignature(
            method: "POST",
            path: "/api/v1/auth/login",
            timestamp: "1794835200",
            nonce: "test-nonce-1234",
            hwid: "TEST-UDID",
            authorization: "Bearer tok_123"
        )
        XCTAssertEqual(refSig, "ffc879d62726b79bde3c26820a4d7be1e3f113e30d8b79d94849bed928bccf0f")

        let session = StubURLProtocol.makeSession(
            statusCode: 200,
            body: #"{"ok":true,"user":{"id":1,"username":"u","expires_at":null,"max_uses":0,"used_count":0,"remaining_uses":0,"has_active_plan":false}}"#
        )
        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)
        _ = await api.fetchMe(token: "tok_xyz", hwid: "TEST-UDID")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        let ts = try XCTUnwrap(req.value(forHTTPHeaderField: "X-Timestamp"))
        let nonce = try XCTUnwrap(req.value(forHTTPHeaderField: "X-Nonce"))
        let sig = try XCTUnwrap(req.value(forHTTPHeaderField: "X-Signature"))
        let expected = APIService.computeHMACSignature(
            method: "GET",
            path: "/api/v1/auth/me",
            timestamp: ts,
            nonce: nonce,
            hwid: "TEST-UDID",
            authorization: "Bearer tok_xyz"
        )
        XCTAssertEqual(sig, expected)
    }

    func testSSLPinningMatchesOfficialRootsAndRejectsMITM() throws {
        XCTAssertTrue(SSLPinningDelegate.matchesPinnedHash(["leaf_unpinned", "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M="]))
        XCTAssertTrue(SSLPinningDelegate.matchesPinnedHash(["s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y="]))
        XCTAssertTrue(SSLPinningDelegate.matchesPinnedHash(["mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c="]))
        XCTAssertFalse(SSLPinningDelegate.matchesPinnedHash(["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="]))
        XCTAssertFalse(SSLPinningDelegate.matchesPinnedHash([]))

        let p256Raw = Data(repeating: 0x04, count: 65)
        let p256SPKI = try XCTUnwrap(
            SSLPinningDelegate.spkiData(
                fromRawKey: p256Raw,
                keyType: kSecAttrKeyTypeECSECPrimeRandom as String,
                keySizeBits: 256
            )
        )
        XCTAssertEqual(p256SPKI.count, 26 + 65)

        let p384Raw = Data(repeating: 0x04, count: 97)
        let p384SPKI = try XCTUnwrap(
            SSLPinningDelegate.spkiData(
                fromRawKey: p384Raw,
                keyType: kSecAttrKeyTypeECSECPrimeRandom as String,
                keySizeBits: 384
            )
        )
        XCTAssertEqual(p384SPKI.count, 23 + 97)

        let rsaRaw = Data(repeating: 0x30, count: 270)
        let rsaSPKI = try XCTUnwrap(
            SSLPinningDelegate.spkiData(
                fromRawKey: rsaRaw,
                keyType: kSecAttrKeyTypeRSA as String,
                keySizeBits: 2048
            )
        )
        XCTAssertEqual(rsaSPKI.prefix(2), Data([0x30, 0x82]))
        XCTAssertTrue(rsaSPKI.suffix(270) == rsaRaw)
    }

    func testMergePlanWithQueuePollsAndDownloadsBinaryResult() async {
        let bundlePayload = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0x00, count: 18))
        var pollCount = 0
        var seenStages: [String] = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path == "/api/v1/merge-plan/jobs" && req.httpMethod == "POST" {
                return StubURLProtocol.Stub(
                    statusCode: 200,
                    data: Data(#"{"ok":true,"job_id":"job_abc12345","status":"queued","position":2,"queue_length":2,"poll_interval_ms":800}"#.utf8)
                )
            }
            if path == "/api/v1/merge-plan/jobs" && req.httpMethod == "GET" {
                pollCount += 1
                if pollCount == 1 {
                    return StubURLProtocol.Stub(
                        statusCode: 200,
                        data: Data(#"{"ok":true,"job_id":"job_abc12345","status":"processing","position":0,"queue_length":1}"#.utf8)
                    )
                }
                return StubURLProtocol.Stub(
                    statusCode: 200,
                    data: Data(#"{"ok":true,"job_id":"job_abc12345","status":"done","has_result_zip":true,"accepted_bytes":128,"note":"done"}"#.utf8)
                )
            }
            if path == "/api/v1/merge-plan/jobs/result" && req.httpMethod == "GET" {
                return StubURLProtocol.Stub(statusCode: 200, data: bundlePayload)
            }
            return StubURLProtocol.Stub(statusCode: 404, data: Data())
        }

        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)
        let res = await api.mergePlanWithQueue(
            fileURL: nil,
            configJSON: #"{"mods":[]}"#,
            token: "tok_queue",
            hwid: "TEST-UDID"
        ) { stage in
            switch stage {
            case .uploadingChunk(let i, let t): seenStages.append("chunk:\(i)/\(t)")
            case .queued(let pos, _): seenStages.append("queued:\(pos)")
            case .processing: seenStages.append("processing")
            case .downloadingResult: seenStages.append("downloading")
            }
        }

        switch res {
        case .success(let exec):
            XCTAssertTrue(exec.response.ok)
            XCTAssertEqual(exec.response.acceptedBytes, 128)
            XCTAssertEqual(exec.resultBundleData, bundlePayload)
            XCTAssertEqual(seenStages, ["queued:2", "processing", "downloading"])
        case .failure(let err):
            XCTFail("Expected queue success, got \(err.localizedDescription)")
        }
    }

    func testMergePlanWithQueueUploadsLargeFileInChunks() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk_test_\(UUID().uuidString).zip")
        let fileData = Data(repeating: 0x41, count: APIService.mergeChunkBytes + 512)
        try fileData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var chunkPathsSeen = 0
        var seenStages: [String] = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path == "/api/v1/merge-plan/chunks" && req.httpMethod == "POST" {
                chunkPathsSeen += 1
                return StubURLProtocol.Stub(
                    statusCode: 200,
                    data: Data(#"{"ok":true,"upload_id":"0123456789abcdef0123456789abcdef","chunk_index":0,"received_bytes":100}"#.utf8)
                )
            }
            if path == "/api/v1/merge-plan/jobs" && req.httpMethod == "POST" {
                return StubURLProtocol.Stub(
                    statusCode: 200,
                    data: Data(#"{"ok":true,"job_id":"job_chunk_001","status":"processing","position":0,"queue_length":1,"poll_interval_ms":800}"#.utf8)
                )
            }
            if path == "/api/v1/merge-plan/jobs" && req.httpMethod == "GET" {
                return StubURLProtocol.Stub(
                    statusCode: 200,
                    data: Data(#"{"ok":true,"job_id":"job_chunk_001","status":"done","has_result_zip":false,"accepted_bytes":4194816}"#.utf8)
                )
            }
            return StubURLProtocol.Stub(statusCode: 404, data: Data())
        }

        let api = APIService(baseURL: URL(string: "https://example.test")!, session: session)
        let res = await api.mergePlanWithQueue(
            fileURL: tempFile,
            configJSON: #"{"mods":[]}"#,
            token: "tok_chunk",
            hwid: "TEST-UDID"
        ) { stage in
            switch stage {
            case .uploadingChunk(let i, let t): seenStages.append("chunk:\(i)/\(t)")
            case .queued(let pos, _): seenStages.append("queued:\(pos)")
            case .processing: seenStages.append("processing")
            case .downloadingResult: seenStages.append("downloading")
            }
        }

        switch res {
        case .success(let exec):
            XCTAssertTrue(exec.response.ok)
            XCTAssertEqual(chunkPathsSeen, 2)
            XCTAssertEqual(seenStages, ["chunk:1/2", "chunk:2/2", "processing"])
        case .failure(let err):
            XCTFail("Expected chunked queue success, got \(err.localizedDescription)")
        }
    }
}

// MARK: - URLProtocol stub

private final class StubURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data

        init(statusCode: Int, body: String) {
            self.statusCode = statusCode
            self.data = Data(body.utf8)
        }

        init(statusCode: Int, data: Data) {
            self.statusCode = statusCode
            self.data = data
        }
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
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
