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
        switch self {
        case .invalidConfiguration:
            return "Máy chủ chưa được cấu hình."
        case .payloadTooLarge:
            return "Tệp vượt quá giới hạn tải lên của máy chủ."
        case .serverRejected(let status, let message):
            if let message, !message.isEmpty {
                return "Máy chủ từ chối (\(status)): \(message)"
            }
            return "Máy chủ từ chối yêu cầu (\(status))."
        case .invalidResponse:
            return "Phản hồi từ máy chủ không hợp lệ."
        case .transport(let detail):
            return "Lỗi kết nối: \(detail)"
        case .ioFailure(let detail):
            return "Lỗi tệp: \(detail)"
        case .serverNotConfigured:
            return "Máy chủ chưa được cấu hình."
        }
    }
}

struct LicenseActivation: Equatable, Sendable {
    let expiresAt: Date?
    let plan: String?
}

/// Thin client gọi đúng schema API của `main.py` (Totorox-Backend).
///
/// Mọi request đều yêu cầu 2 header:
/// - `X-License-Key`
/// - `X-HWID`
///
/// Endpoint mapping:
/// - POST /api/v1/verify            (JSON body: X-License-Key/X-HWID trong header)
/// - POST /api/v1/activate          (JSON body: hwid, không gửi license key trong body)
/// - POST /api/v1/convert-header    (multipart/form-data: mode, password?, file?)
/// - POST /api/v1/merge-plan        (multipart/form-data: file?, config_json?)
///
/// Timeout mặc định cho request là 60 giây.
final class APIService {
    static let shared = APIService()

    /// Base URL mặc định của Totorox backend. Ghi đè khi machine có server riêng.
    static let defaultBaseURL = URL(string: "https://two-eos-galleries-excellence.trycloudflare.com")!

    /// Khoá `UserDefaults` lưu base URL động do người dùng cấu hình.
    static let baseURLDefaultsKey = "totorox.api.baseURL"

    /// Giới hạn tổng kích thước upload (server giới hạn 15 MB — giữ thấp để tránh upload thất bại).
    static let maximumUploadBytes: Int64 = 15 * 1024 * 1024

    /// Session mặc định: `timeoutIntervalForRequest = 60` giây cho mọi request.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    private(set) var baseURL: URL

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// - Parameter baseURL: `nil` để ưu tiên URL đã lưu trong `UserDefaults`, sau đó tới `defaultBaseURL`.
    init(baseURL: URL? = nil, session: URLSession = APIService.defaultSession) {
        self.baseURL = baseURL ?? APIService.storedBaseURL ?? APIService.defaultBaseURL
        self.session = session
    }

    /// Chuẩn hoá chuỗi URL người dùng nhập: bỏ khoảng trắng, thêm `https://` nếu thiếu scheme
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

    /// Base URL đang được lưu trong `UserDefaults` (nếu có và hợp lệ).
    static var storedBaseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: baseURLDefaultsKey) else { return nil }
        return normalizedBaseURL(from: raw)
    }

    /// Lưu base URL mới vào `UserDefaults` và dùng ngay cho các request tiếp theo.
    func setBaseURL(_ url: URL) {
        let normalized = APIService.normalizedBaseURL(from: url.absoluteString) ?? url
        baseURL = normalized
        UserDefaults.standard.set(normalized.absoluteString, forKey: APIService.baseURLDefaultsKey)
    }

    /// Áp dụng URL người dùng nhập. Trả `false` nếu chuỗi không phải URL http(s) hợp lệ.
    @discardableResult
    func updateBaseURL(_ raw: String) -> Bool {
        guard let url = APIService.normalizedBaseURL(from: raw) else { return false }
        setBaseURL(url)
        return true
    }

    /// Xoá cấu hình động và quay lại `defaultBaseURL`.
    func resetBaseURL() {
        UserDefaults.standard.removeObject(forKey: APIService.baseURLDefaultsKey)
        baseURL = APIService.defaultBaseURL
    }

    // MARK: - License

    func verify(
        licenseKey: String,
        hwid: String
    ) async -> Result<VerifyResponse, APIServiceError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/verify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, licenseKey: licenseKey, hwid: hwid)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.serverRejected(
                    status: http.statusCode,
                    message: Self.errorMessage(from: data) ?? "Không phản hồi hợp lệ."
                ))
            }
            let payload = try parseJSON([String: AnyCodable].self, from: data)
            return .success(VerifyResponse(
                status: http.statusCode,
                expiresAt: payload["expires_at"]?.date,
                dailyQuota: payload["daily_quota"]?.int,
                usedToday: payload["used_today"]?.int,
                remaining: payload["remaining"]?.int,
                error: payload["error"]?.string
            ))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    func activate(
        licenseKey: String,
        hwid: String
    ) async -> Result<LicenseActivation, APIServiceError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/activate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, licenseKey: licenseKey, hwid: hwid)
        let body = ["hwid": hwid]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.serverRejected(
                    status: http.statusCode,
                    message: Self.errorMessage(from: data)
                ))
            }
            let payload = try parseJSON([String: AnyCodable].self, from: data)
            let expiresAt = payload["expires_at"]?.double.map { Date(timeIntervalSince1970: $0) }
            return .success(LicenseActivation(
                expiresAt: expiresAt,
                plan: payload["plan"]?.string
            ))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: - Convert-header

    func convertHeader(
        fileURL: URL?,
        mode: String,
        password: String?,
        licenseKey: String,
        hwid: String
    ) async -> Result<ConvertHeaderResponse, APIServiceError> {
        let path = "api/v1/convert-header"
        do {
            let body = try buildMultipartBody(
                fields: [
                    "mode": mode,
                    "password": password ?? "",
                ],
                fileURLs: fileURL.map { [$0] } ?? [],
                fileFieldName: "file"
            )

            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue(
                "multipart/form-data; boundary=\(body.boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            applyAuthHeaders(to: &request, licenseKey: licenseKey, hwid: hwid)

            let (data, response) = try await upload(request, body: body)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.serverRejected(
                    status: http.statusCode,
                    message: Self.errorMessage(from: data)
                ))
            }

            let raw = try parseJSON(ConvertHeaderResponseBody.self, from: data)
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
                packageId: raw.packageId
            ))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: - Merge-plan

    func mergePlan(
        fileURL: URL?,
        configJSON: String?,
        licenseKey: String,
        hwid: String
    ) async -> Result<MergePlanResponse, APIServiceError> {
        let path = "api/v1/merge-plan"
        do {
            let body = try buildMultipartBody(
                fields: [
                    "config_json": configJSON ?? "{}",
                ],
                fileURLs: fileURL.map { [$0] } ?? [],
                fileFieldName: "file"
            )

            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue(
                "multipart/form-data; boundary=\(body.boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            applyAuthHeaders(to: &request, licenseKey: licenseKey, hwid: hwid)

            let (data, response) = try await upload(request, body: body)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.serverRejected(
                    status: http.statusCode,
                    message: Self.errorMessage(from: data)
                ))
            }

            let raw = try parseJSON(MergePlanResponseBody.self, from: data)
            return .success(MergePlanResponse(
                ok: raw.ok,
                acceptedBytes: raw.acceptedBytes,
                mergePlan: raw.mergePlan,
                configFiles: raw.configFiles,
                zipBytesB64: raw.zipBytesB64,
                note: raw.note
            ))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: - Auth headers trên mỗi request

    private func applyAuthHeaders(to request: inout URLRequest, licenseKey: String, hwid: String) {
        request.setValue(licenseKey, forHTTPHeaderField: "X-License-Key")
        request.setValue(hwid, forHTTPHeaderField: "X-HWID")
        request.timeoutInterval = 60
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
        if let bool = try? container.decode(Bool.self) {
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
    var double: Double? { value as? Double }
    var string: String? { value as? String }
    var date: Date? { value as? Date }
    var array: [Any]? { value as? [Any] }
    var dictionary: [String: Any]? { value as? [String: Any] }

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

struct VerifyResponse {
    let status: Int
    let expiresAt: Date?
    let dailyQuota: Int?
    let usedToday: Int?
    let remaining: Int?
    let error: String?
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
}

struct MergePlanResponseBody: Decodable {
    let ok: Bool
    let acceptedBytes: Int
    let mergePlan: MergePlanBody?
    let configFiles: [String]?
    let zipBytesB64: String?
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case acceptedBytes = "accepted_bytes"
        case mergePlan = "merge_plan"
        case configFiles = "config_files"
        case zipBytesB64 = "zip_bytes_b64"
        case note
    }
}

struct MergePlanBody: Decodable {
    let outputFilename: String?
    let fileCount: Int?
    let files: [MergePlanFile]?
    let loadedMods: [LoadedModBody]?
    let bundleVersions: [BundleVersionBody]?
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case outputFilename = "output_filename"
        case fileCount = "file_count"
        case files
        case loadedMods = "loaded_mods"
        case bundleVersions = "bundle_versions"
        case note
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
}
