import Foundation

enum APIServiceError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case payloadTooLarge
    case serverRejected(status: Int, message: String?)
    case invalidResponse
    case transport(String)
    case ioFailure(String)
    case serverNotConfigured

    var errorDescription: String? {
        let lang = AppLanguage.current
        switch self {
        case .invalidConfiguration:
            return lang.text("api.error.invalid_configuration")
        case .payloadTooLarge:
            return lang.text("api.error.payload_too_large")
        case .serverRejected(let status, let message):
            if let message, !message.isEmpty {
                return lang.text("api.error.server_rejected_detail", status, message)
            }
            if status == 401 {
                return lang.text("api.error.unauthorized")
            }
            if status == 403 {
                return lang.text("api.error.forbidden_plan")
            }
            if status == 429 {
                return lang.text("api.error.rate_limited")
            }
            return lang.text("api.error.server_rejected", status)
        case .invalidResponse:
            return lang.text("api.error.invalid_response")
        case .transport(let detail):
            return lang.text("api.error.transport", detail)
        case .ioFailure(let detail):
            return lang.text("api.error.io_failure", detail)
        case .serverNotConfigured:
            return lang.text("api.error.server_not_configured")
        }
    }
}

/// Thin client gọi đúng schema API của `main.py` (Totorox-Backend).
///
/// Xác thực bằng `Authorization: Bearer <token>` + `X-HWID`.
///
/// Endpoint mapping:
/// - POST /api/v1/auth/register     (JSON: username, password, udid)
/// - POST /api/v1/auth/login        (JSON: username, password, udid)
/// - POST /api/v1/auth/logout       (Bearer)
/// - POST /api/v1/auth/redeem       (Bearer + JSON: code)
/// - GET  /api/v1/auth/me           (Bearer)
/// - POST /api/v1/overwrite-plan    (Bearer + JSON: source_paths, target_paths, ...)
/// - POST /api/v1/convert-header    (Bearer + multipart/form-data: mode, password?, file?)
/// - POST /api/v1/merge-plan        (Bearer + multipart/form-data: file?, config_json?)
///
/// Timeout mặc định cho request là 60 giây.
final class APIService {
    static let shared = APIService()

    /// Base URL mặc định của Totorox backend. Ghi đè khi machine có server riêng.
    static let defaultBaseURL = URL(string: "https://api.totorox.io.vn")!

    /// Khoá `UserDefaults` lưu base URL động do người dùng cấu hình.
    static let baseURLDefaultsKey = "totorox.api.baseURL"

    /// Giới hạn tổng kích thước upload cho `convert-header` (khớp mặc định 100 MB của server).
    static let maximumUploadBytes: Int64 = 100 * 1024 * 1024

    /// Giới hạn cho `merge-plan`: `config_bundle.zip` chứa file cấu hình
    /// (`CommonActions` / `Databin` / `Thanos`); metadata RP/RV lớn nên khớp server 100 MB.
    static let maximumMergeBundleBytes: Int64 = 100 * 1024 * 1024

    /// Timeout cho request metadata thông thường.
    static let requestTimeout: TimeInterval = 60

    /// Timeout cho `merge-plan` — server phải chạy toàn bộ pipeline UnityFS/MSES/HeroSkin.
    static let mergeTimeout: TimeInterval = 300

    /// Session mặc định: timeout theo từng request, không chặn cứng ở 60 giây.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = mergeTimeout
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    private(set) var baseURL: URL

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// - Parameter baseURL: `nil` luôn trỏ cố định về `https://api.totorox.io.vn`.
    init(baseURL: URL? = nil, session: URLSession = APIService.defaultSession) {
        if baseURL == nil {
            UserDefaults.standard.removeObject(forKey: APIService.baseURLDefaultsKey)
        }
        self.baseURL = baseURL ?? APIService.defaultBaseURL
        self.session = session
    }

    /// Chuẩn hoá chuỗi URL: bỏ khoảng trắng, thêm `https://` nếu thiếu scheme
    /// và tự động cắt bỏ mọi dấu `/` thừa ở cuối.
    static func normalizedBaseURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed),
              let host = url.host,
              !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// Endpoint cố định luôn dùng `defaultBaseURL` (`https://api.totorox.io.vn`).
    static var storedBaseURL: URL? {
        nil
    }

    /// URL Safari `.mobileconfig` để xác minh UDID phần cứng thật qua Apple OTA.
    func deviceProfileURL(username: String) -> URL? {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty,
              var components = URLComponents(
                  url: baseURL.appendingPathComponent("api/v1/device/profile"),
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "username", value: cleanUser)]
        return components.url
    }

    /// Giữ API tương thích nội bộ nhưng luôn cố định về `defaultBaseURL`.
    func resetBaseURL() {
        UserDefaults.standard.removeObject(forKey: APIService.baseURLDefaultsKey)
        baseURL = APIService.defaultBaseURL
    }

    // MARK: - License

    static let sessionUnauthorizedNotification = Notification.Name("totorox.api.sessionUnauthorized")
    static let userProfileUpdatedNotification = Notification.Name("totorox.api.userProfileUpdated")

    // MARK: - Auth & Redeem Endpoints

    func register(
        username: String,
        password: String,
        udid: String
    ) async -> Result<AuthSessionResponse, APIServiceError> {
        let body = AuthCredentialsRequest(username: username, password: password, udid: udid)
        return await postJSON("api/v1/auth/register", body: body)
    }

    func login(
        username: String,
        password: String,
        udid: String
    ) async -> Result<AuthSessionResponse, APIServiceError> {
        let body = AuthCredentialsRequest(username: username, password: password, udid: udid)
        return await postJSON("api/v1/auth/login", body: body)
    }

    func logout(token: String, hwid: String) async {
        guard !token.isEmpty else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/logout"))
        request.httpMethod = "POST"
        applyAuthHeaders(to: &request, token: token, hwid: hwid)
        _ = try? await session.data(for: request)
    }

    func redeem(
        code: String,
        token: String,
        hwid: String
    ) async -> Result<RedeemCodeResponse, APIServiceError> {
        let body = RedeemCodeRequest(code: code, udid: hwid.isEmpty ? nil : hwid)
        let result: Result<RedeemCodeResponse, APIServiceError> = await postJSON(
            "api/v1/auth/redeem",
            body: body,
            token: token,
            hwid: hwid
        )
        if case .success(let response) = result {
            notifyUserProfileUpdated(response.user)
        }
        return result
    }

    func fetchMe(
        token: String,
        hwid: String
    ) async -> Result<UserMeResponse, APIServiceError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/me"))
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, token: token, hwid: hwid)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = Self.errorMessage(from: data)
                if http.statusCode == 401 {
                    notifyUnauthorized(msg)
                }
                return .failure(.serverRejected(status: http.statusCode, message: msg))
            }
            let decoded = try parseJSON(UserMeResponse.self, from: data)
            notifyUserProfileUpdated(decoded.user)
            return .success(decoded)
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    // MARK: - Overwrite-plan

    func overwritePlan(
        _ payload: OverwritePlanRequest,
        token: String,
        hwid: String
    ) async -> Result<OverwritePlanResponse, APIServiceError> {
        let effectivePayload = (payload.udid == nil && !hwid.isEmpty)
            ? OverwritePlanRequest(
                sourcePaths: payload.sourcePaths,
                targetPaths: payload.targetPaths,
                targetBundleId: payload.targetBundleId,
                targetSubfolder: payload.targetSubfolder,
                sourceSizes: payload.sourceSizes,
                udid: hwid
            )
            : payload
        let result: Result<OverwritePlanResponse, APIServiceError> = await postJSON(
            "api/v1/overwrite-plan",
            body: effectivePayload,
            token: token,
            hwid: hwid
        )
        if case .success(let resp) = result, let user = resp.user {
            notifyUserProfileUpdated(user)
        }
        return result
    }

    // MARK: - Convert-header

    func convertHeader(
        fileURL: URL?,
        mode: String,
        password: String?,
        token: String,
        hwid: String
    ) async -> Result<ConvertHeaderResponse, APIServiceError> {
        let path = "api/v1/convert-header"
        do {
            var fields = [
                "mode": mode,
                "password": password ?? "",
            ]
            if !hwid.isEmpty {
                fields["udid"] = hwid
            }
            let body = try buildMultipartBody(
                fields: fields,
                fileURLs: fileURL.map { [$0] } ?? [],
                fileFieldName: "file"
            )

            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue(
                "multipart/form-data; boundary=\(body.boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            applyAuthHeaders(to: &request, token: token, hwid: hwid)

            let (data, response) = try await upload(request, body: body)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = Self.errorMessage(from: data)
                if http.statusCode == 401 {
                    notifyUnauthorized(msg)
                }
                return .failure(.serverRejected(status: http.statusCode, message: msg))
            }

            let raw = try parseJSON(ConvertHeaderResponseBody.self, from: data)
            if let user = raw.user {
                notifyUserProfileUpdated(user)
            }
            return .success(ConvertHeaderResponse(
                ok: raw.ok,
                mode: raw.mode,
                passwordProtected: raw.passwordProtected,
                header: raw.header,
                toc: raw.toc,
                note: raw.note,
                acceptedBytes: raw.acceptedBytes,
                contentKeyB64: raw.contentKeyB64,
                keyFingerprint: raw.keyFingerprint,
                packageBytesB64: raw.packageBytesB64,
                payloadBytesB64: raw.payloadBytesB64,
                zipBytesB64: raw.zipBytesB64,
                packageId: raw.packageId,
                schemaVersion: raw.schemaVersion,
                kdfSaltB64: raw.kdfSaltB64,
                kdfIterations: raw.kdfIterations,
                wrappedContentKeyB64: raw.wrappedContentKeyB64,
                publicContentKeyB64: raw.publicContentKeyB64,
                user: raw.user
            ))
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    // MARK: - Merge-plan

    func mergePlan(
        fileURL: URL?,
        configJSON: String?,
        token: String,
        hwid: String
    ) async -> Result<MergePlanResponse, APIServiceError> {
        let path = "api/v1/merge-plan"
        do {
            if let fileURL,
               let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize),
               Int64(size) > APIService.maximumMergeBundleBytes {
                return .failure(.payloadTooLarge)
            }

            var fields = [
                "config_json": configJSON ?? "{}",
            ]
            if !hwid.isEmpty {
                fields["udid"] = hwid
            }
            let body = try buildMultipartBody(
                fields: fields,
                fileURLs: fileURL.map { [$0] } ?? [],
                fileFieldName: "file"
            )

            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue(
                "multipart/form-data; boundary=\(body.boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            applyAuthHeaders(to: &request, token: token, hwid: hwid)
            request.timeoutInterval = APIService.mergeTimeout

            let (data, response) = try await upload(request, body: body)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = Self.errorMessage(from: data)
                if http.statusCode == 401 {
                    notifyUnauthorized(msg)
                }
                return .failure(.serverRejected(status: http.statusCode, message: msg))
            }

            let raw = try parseJSON(MergePlanResponseBody.self, from: data)
            if let user = raw.user {
                notifyUserProfileUpdated(user)
            }
            return .success(MergePlanResponse(
                ok: raw.ok,
                acceptedBytes: raw.acceptedBytes,
                mergePlan: raw.mergePlan,
                configFiles: raw.configFiles,
                zipBytesB64: raw.zipBytesB64,
                note: raw.note,
                user: raw.user
            ))
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    // MARK: - JSON + Auth Helpers

    private func postJSON<Req: Encodable, Res: Decodable>(
        _ path: String,
        body: Req,
        token: String? = nil,
        hwid: String? = nil
    ) async -> Result<Res, APIServiceError> {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            applyAuthHeaders(to: &request, token: token, hwid: hwid ?? "")
        } else {
            request.timeoutInterval = APIService.requestTimeout
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg = Self.errorMessage(from: data)
                if token != nil, http.statusCode == 401 {
                    notifyUnauthorized(msg)
                }
                return .failure(.serverRejected(status: http.statusCode, message: msg))
            }
            return .success(try parseJSON(Res.self, from: data))
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    private func applyAuthHeaders(to request: inout URLRequest, token: String, hwid: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !hwid.isEmpty {
            request.setValue(hwid, forHTTPHeaderField: "X-HWID")
        }
        request.timeoutInterval = APIService.requestTimeout
    }

    private func notifyUnauthorized(_ message: String?) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: APIService.sessionUnauthorizedNotification,
                object: message
            )
        }
    }

    private func notifyUserProfileUpdated(_ user: UserProfile) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: APIService.userProfileUpdatedNotification,
                object: user
            )
        }
    }

    // MARK: - Multipart builder (nhẹ, dùng cho 1-2 file nhỏ)

    /// Body multipart: `fileURL` là bản ghi tạm dùng cho upload streaming;
    /// nếu ghi tệp thất bại thì `data` giữ body trong bộ nhớ làm phương án dự phòng.
    private struct MultipartBody {
        let boundary: String
        let fileURL: URL?
        let data: Data
    }

    private func buildMultipartBody(
        fields: [String: String],
        fileURLs: [URL],
        fileFieldName: String
    ) throws -> MultipartBody {
        let boundary = "Totorox-\(UUID().uuidString)"
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        for fileURL in fileURLs {
            // URL lấy từ DocumentPicker là security-scoped: phải mở quyền trước khi đọc.
            let hasScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasScope { fileURL.stopAccessingSecurityScopedResource() }
            }

            let filename = fileURL.lastPathComponent
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n")
            append("Content-Type: application/octet-stream\r\n\r\n")
            body.append(try Data(contentsOf: fileURL))
            append("\r\n")
        }

        append("--\(boundary)--\r\n")

        // Ưu tiên ghi ra tệp tạm để `upload(for:fromFile:)` stream thay vì giữ body trong RAM.
        let tempDirectory = FileManager.default.temporaryDirectory
        let tempURL = tempDirectory.appendingPathComponent("totorox-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try body.write(to: tempURL, options: .atomic)
            return MultipartBody(boundary: boundary, fileURL: tempURL, data: Data())
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return MultipartBody(boundary: boundary, fileURL: nil, data: body)
        }
    }

    /// Gửi body multipart (stream từ tệp tạm, fallback bộ nhớ).
    /// Tệp tạm chỉ bị xoá trong `defer`, tức sau khi `upload` chạy xong.
    private func upload(
        _ request: URLRequest,
        body: MultipartBody
    ) async throws -> (Data, URLResponse) {
        defer {
            if let fileURL = body.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        if let fileURL = body.fileURL {
            return try await session.upload(for: request, fromFile: fileURL)
        }
        return try await session.upload(for: request, from: body.data)
    }

    // MARK: - Parsing helpers

    private func parseJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Lỗi giải mã JSON có nghĩa là server đã trả 2xx nhưng body không khớp schema —
    /// báo "phản hồi không hợp lệ" thay vì gán nhầm thành lỗi mạng.
    private static func failure(from error: Error) -> APIServiceError {
        if error is DecodingError {
            return .invalidResponse
        }
        return .transport(error.localizedDescription)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = payload["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let message = payload["message"] as? String, !message.isEmpty {
            return message
        }
        return payload["error"] as? String
    }
}

// MARK: - Response models

struct AnyCodable: Codable, Equatable {
    let value: Any
    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Không giải mã được")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Không mã hóa được"))
        }
    }

    var bool: Bool? { value as? Bool }
    var int: Int? { value as? Int }
    var double: Double? {
        if let double = value as? Double { return double }
        return (value as? Int).map(Double.init)
    }
    var string: String? { value as? String }
    var array: [Any]? { value as? [Any] }
    var dictionary: [String: Any]? { value as? [String: Any] }

    /// Timestamp tính bằng giây kể từ 1970 trong JSON thường được giải mã thành
    /// `Int` hoặc `Double`, không bao giờ là `Date`.
    var timestamp: Date? {
        double.map { Date(timeIntervalSince1970: $0) }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        valuesEqual(lhs.value, rhs.value)
    }

    private static func valuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case (is NSNull, is NSNull):
            return true
        case let (left as Bool, right as Bool):
            return left == right
        case let (left as Int, right as Int):
            return left == right
        case let (left as Double, right as Double):
            return left == right
        case let (left as Int, right as Double):
            return Double(left) == right
        case let (left as Double, right as Int):
            return left == Double(right)
        case let (left as String, right as String):
            return left == right
        case let (left as [Any], right as [Any]):
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { pair in
                valuesEqual(pair.0, pair.1)
            }
        case let (left as [String: Any], right as [String: Any]):
            guard left.count == right.count else { return false }
            return left.allSatisfy { pair in
                guard let other = right[pair.key] else { return false }
                return valuesEqual(pair.value, other)
            }
        default:
            return false
        }
    }

    var nestedString: String? { value as? String }
}

struct AuthCredentialsRequest: Encodable, Equatable, Sendable {
    let username: String
    let password: String
    let udid: String
}

struct RedeemCodeRequest: Encodable, Equatable, Sendable {
    let code: String
    let udid: String?

    init(code: String, udid: String? = nil) {
        self.code = code
        self.udid = udid
    }
}

struct UserProfile: Codable, Equatable, Sendable {
    let id: Int
    let username: String
    let expiresAt: Int?
    let maxUses: Int
    let usedCount: Int
    let remainingUses: Int
    let hasActivePlan: Bool
    let dailyUsed: Int?
    let dailyCap: Int?
    let hwid: String?
    let udid: String?
    let isUdidVerified: Bool?
    let isBanned: Bool?

    enum CodingKeys: String, CodingKey {
        case id, username, hwid, udid
        case expiresAt = "expires_at"
        case maxUses = "max_uses"
        case usedCount = "used_count"
        case remainingUses = "remaining_uses"
        case hasActivePlan = "has_active_plan"
        case dailyUsed = "daily_used"
        case dailyCap = "daily_cap"
        case isUdidVerified = "is_udid_verified"
        case isBanned = "is_banned"
    }

    var expiresDate: Date? {
        guard let expiresAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }

    var isUnlimited: Bool {
        hasActivePlan && (maxUses == -1 || remainingUses == -1)
    }

    func withVerifiedUDID(_ verifiedUDID: String) -> UserProfile {
        UserProfile(
            id: id,
            username: username,
            expiresAt: expiresAt,
            maxUses: maxUses,
            usedCount: usedCount,
            remainingUses: remainingUses,
            hasActivePlan: hasActivePlan,
            dailyUsed: dailyUsed,
            dailyCap: dailyCap,
            hwid: verifiedUDID,
            udid: verifiedUDID,
            isUdidVerified: true,
            isBanned: isBanned
        )
    }
}

struct AuthSessionResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let message: String?
    let token: String
    let user: UserProfile
}

struct UserMeResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let user: UserProfile
}

struct RedeemCodeResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let message: String?
    let code: String?
    let addedDays: Int?
    let addedUses: Int?
    let user: UserProfile

    private enum CodingKeys: String, CodingKey {
        case ok, message, code, user
        case addedDays = "added_days"
        case addedUses = "added_uses"
    }
}

struct OverwritePlanRequest: Encodable, Equatable, Sendable {
    let sourcePaths: [String]
    let targetPaths: [String]
    let targetBundleId: String?
    let targetSubfolder: String?
    let sourceSizes: [String: Int]?
    let udid: String?

    init(
        sourcePaths: [String],
        targetPaths: [String],
        targetBundleId: String?,
        targetSubfolder: String?,
        sourceSizes: [String: Int]?,
        udid: String? = nil
    ) {
        self.sourcePaths = sourcePaths
        self.targetPaths = targetPaths
        self.targetBundleId = targetBundleId
        self.targetSubfolder = targetSubfolder
        self.sourceSizes = sourceSizes
        self.udid = udid
    }

    private enum CodingKeys: String, CodingKey {
        case sourcePaths = "source_paths"
        case targetPaths = "target_paths"
        case targetBundleId = "target_bundle_id"
        case targetSubfolder = "target_subfolder"
        case sourceSizes = "source_sizes"
        case udid
    }
}

struct OverwriteMapping: Decodable, Equatable, Sendable {
    let source: String
    let destination: String
}

struct OverwritePlanResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let mappings: [OverwriteMapping]
    let skipped: [String]?
    let detectedSourceVersion: String?
    let resolvedTargetVersion: String?
    let note: String?
    let user: UserProfile?

    private enum CodingKeys: String, CodingKey {
        case ok, mappings, skipped, note, user
        case detectedSourceVersion = "detected_source_version"
        case resolvedTargetVersion = "resolved_target_version"
    }
}

struct ConvertHeaderResponseBody: Decodable {
    let ok: Bool
    let mode: String
    let passwordProtected: Bool
    let header: [String: AnyCodable]
    let toc: [AnyCodable]
    let note: String?
    let acceptedBytes: Int
    let contentKeyB64: String?
    let keyFingerprint: String?
    let packageBytesB64: String?
    let payloadBytesB64: String?
    let zipBytesB64: String?
    let packageId: String?
    let schemaVersion: Int?
    let kdfSaltB64: String?
    let kdfIterations: Int?
    let wrappedContentKeyB64: String?
    let publicContentKeyB64: String?
    let user: UserProfile?

    private enum CodingKeys: String, CodingKey {
        case ok
        case mode
        case passwordProtected = "password_protected"
        case header
        case toc
        case note
        case acceptedBytes = "accepted_bytes"
        case contentKeyB64 = "content_key_b64"
        case keyFingerprint = "key_fingerprint"
        case packageBytesB64 = "package_bytes_b64"
        case payloadBytesB64 = "payload_bytes_b64"
        case zipBytesB64 = "zip_bytes_b64"
        case packageId = "package_id"
        case schemaVersion = "schema_version"
        case kdfSaltB64 = "kdf_salt_b64"
        case kdfIterations = "kdf_iterations"
        case wrappedContentKeyB64 = "wrapped_content_key_b64"
        case publicContentKeyB64 = "public_content_key_b64"
        case user
    }
}

struct ConvertHeaderResponse {
    let ok: Bool
    let mode: String
    let passwordProtected: Bool
    let header: [String: AnyCodable]
    let toc: [AnyCodable]
    let note: String?
    let acceptedBytes: Int
    let contentKeyB64: String?
    let keyFingerprint: String?
    let packageBytesB64: String?
    let payloadBytesB64: String?
    let zipBytesB64: String?
    let packageId: String?
    let schemaVersion: Int?
    let kdfSaltB64: String?
    let kdfIterations: Int?
    let wrappedContentKeyB64: String?
    let publicContentKeyB64: String?
    let user: UserProfile?
}

struct MergePlanResponseBody: Decodable {
    let ok: Bool
    let acceptedBytes: Int
    let mergePlan: MergePlanBody?
    let configFiles: [String]?
    let zipBytesB64: String?
    let note: String?
    let user: UserProfile?

    private enum CodingKeys: String, CodingKey {
        case ok
        case acceptedBytes = "accepted_bytes"
        case mergePlan = "merge_plan"
        case configFiles = "config_files"
        case zipBytesB64 = "zip_bytes_b64"
        case note
        case user
    }
}

struct MergePlanBody: Decodable {
    let outputFilename: String?
    let fileCount: Int?
    let conflicts: Int?
    let files: [MergePlanFile]?
    let loadedMods: [LoadedModBody]?
    let bundleVersions: [BundleVersionBody]?
    let note: String?
    let baseModIndex: Int?

    private enum CodingKeys: String, CodingKey {
        case outputFilename = "output_filename"
        case fileCount = "file_count"
        case conflicts
        case files
        case loadedMods = "loaded_mods"
        case bundleVersions = "bundle_versions"
        case note
        case baseModIndex = "base_mod_index"
    }
}

struct MergePlanFile: Decodable {
    let path: String
    let size: Int
}

struct LoadedModBody: Decodable {
    let name: String
    let explicitVersion: String?
    let heroIDs: [Int]?
    let skinIDs: [Int]?

    private enum CodingKeys: String, CodingKey {
        case name
        case explicitVersion = "explicit_ver"
        case heroIDs = "hero_ids"
        case skinIDs = "skin_ids"
    }
}

struct BundleVersionBody: Decodable {
    let modName: String?
    let detectedVersion: String?
    let versionTuple: [Int]?
    let buildNumber: Int?

    private enum CodingKeys: String, CodingKey {
        case modName = "mod_name"
        case detectedVersion = "detected_version"
        case versionTuple = "version_tuple"
        case buildNumber = "build_number"
    }
}

struct MergePlanResponse {
    let ok: Bool
    let acceptedBytes: Int
    let mergePlan: MergePlanBody?
    let configFiles: [String]?
    let zipBytesB64: String?
    let note: String?
    let user: UserProfile?
}
