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
