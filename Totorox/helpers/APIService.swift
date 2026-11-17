import CryptoKit
import Foundation
import Security

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

    /// Base URL mặc định của Totorox backend (ẩn bằng XOR). Ghi đè khi machine có server riêng.
    static let defaultBaseURL = URL(string: ObfuscatedStrings.baseURL)!

    /// Khoá `UserDefaults` lưu base URL động do người dùng cấu hình.
    static let baseURLDefaultsKey = "totorox.api.baseURL"

    /// Giới hạn tổng kích thước upload cho `convert-header` (khớp mặc định 100 MB của server).
    static let maximumUploadBytes: Int64 = 100 * 1024 * 1024

    /// Giới hạn cho `merge-plan`: chừa dư địa cho `config_json` và multipart header
    /// để toàn bộ HTTP request body luôn nằm gọn dưới trần 100 MB của Cloudflare.
    static let maximumMergeBundleBytes: Int64 = 92 * 1024 * 1024

    /// Kích thước mỗi mảnh khi chia nhỏ upload `config_bundle.zip` (1 MiB để máy mạng yếu/chậm không vượt timeout).
    static let mergeChunkBytes: Int = 1 * 1024 * 1024

    /// Ngưỡng tối đa ưu tiên upload từ `Data` trong bộ nhớ (tránh bug chậm `fromFile:` trên một số bản CFNetwork).
    private static let directMemoryUploadLimit: Int64 = 16 * 1024 * 1024

    /// Timeout cho request metadata thông thường.
    static let requestTimeout: TimeInterval = 60

    /// Timeout cho `merge-plan` — server phải chạy toàn bộ pipeline UnityFS/MSES/HeroSkin.
    static let mergeTimeout: TimeInterval = 300

    /// Delegate kiểm tra SSL Pinning (SPKI SHA-256) cho `api.totorox.io.vn`.
    private static let pinningDelegate = SSLPinningDelegate()

    /// Session mặc định: timeout theo từng request, bật SSL Pinning cho `api.totorox.io.vn`.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = mergeTimeout
        return URLSession(configuration: configuration, delegate: pinningDelegate, delegateQueue: nil)
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
    func deviceProfileURL(username: String, claim: String? = nil) -> URL? {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty,
              var components = URLComponents(
                  url: baseURL.appendingPathComponent(ObfuscatedStrings.deviceProfile),
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        var items = [URLQueryItem(name: "username", value: cleanUser)]
        if let cleanClaim = claim?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanClaim.isEmpty {
            items.append(URLQueryItem(name: "claim", value: cleanClaim))
        }
        components.queryItems = items
        return components.url
    }

    /// Lấy UDID đã xác minh qua Apple OTA bằng `claim` token một lần (không phụ thuộc URL scheme).
    func claimDeviceUDID(
        claim: String,
        token: String,
        hwid: String
    ) async -> Result<String?, APIServiceError> {
        let cleanClaim = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanClaim.isEmpty,
              var components = URLComponents(
                  url: baseURL.appendingPathComponent("api/v1/device/claim"),
                  resolvingAgainstBaseURL: false
              ) else {
            return .success(nil)
        }
        components.queryItems = [URLQueryItem(name: "claim", value: cleanClaim)]
        guard let url = components.url else { return .success(nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, token: token, hwid: hwid)
        signRequest(&request)

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
            struct ClaimResponse: Decodable {
                let ok: Bool
                let udid: String?
            }
            let decoded = try parseJSON(ClaimResponse.self, from: data)
            let cleanUDID = decoded.udid?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success((decoded.ok && cleanUDID?.isEmpty == false) ? cleanUDID : nil)
        } catch {
            return .failure(Self.failure(from: error))
        }
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
        return await postJSON(ObfuscatedStrings.authRegister, body: body)
    }

    func login(
        username: String,
        password: String,
        udid: String
    ) async -> Result<AuthSessionResponse, APIServiceError> {
        let body = AuthCredentialsRequest(username: username, password: password, udid: udid)
        return await postJSON(ObfuscatedStrings.authLogin, body: body)
    }

    func logout(token: String, hwid: String) async {
        guard !token.isEmpty else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent(ObfuscatedStrings.authLogout))
        request.httpMethod = "POST"
        applyAuthHeaders(to: &request, token: token, hwid: hwid)
        signRequest(&request)
        _ = try? await session.data(for: request)
    }

    func redeem(
        code: String,
        token: String,
        hwid: String
    ) async -> Result<RedeemCodeResponse, APIServiceError> {
        let body = RedeemCodeRequest(code: code, udid: hwid.isEmpty ? nil : hwid)
        let result: Result<RedeemCodeResponse, APIServiceError> = await postJSON(
            ObfuscatedStrings.authRedeem,
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
        var request = URLRequest(url: baseURL.appendingPathComponent(ObfuscatedStrings.authMe))
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, token: token, hwid: hwid)
        signRequest(&request)

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
            ObfuscatedStrings.overwritePlan,
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
        let path = ObfuscatedStrings.convertHeader
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
            signRequest(&request)

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
        let path = ObfuscatedStrings.mergePlan
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
            signRequest(&request)

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

    enum MergeQueueStage: Sendable {
        case uploadingChunk(index: Int, total: Int)
        case queued(position: Int, queueLength: Int)
        case processing
        case downloadingResult
    }

    /// Gửi tác vụ gộp vào hàng đợi bất đồng bộ trên server rồi poll trạng thái tới khi xong,
    /// giúp miễn nhiễm hoàn toàn giới hạn timeout 100s của Cloudflare và tải thẳng binary ZIP.
    /// Khi `config_bundle.zip` > 4 MiB, tự động chia thành các mảnh 4 MiB (upload trực tiếp từ Data,
    /// tránh bug `fromFile:` chậm trên iOS) kèm retry từng mảnh.
    func mergePlanWithQueue(
        fileURL: URL?,
        configJSON: String?,
        token: String,
        hwid: String,
        onStage: @escaping @Sendable (MergeQueueStage) -> Void
    ) async -> Result<MergePlanExecutionResult, APIServiceError> {
        let submitPath = ObfuscatedStrings.mergePlanJobs
        do {
            var fileSize: Int64 = 0
            if let fileURL,
               let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                fileSize = Int64(size)
                if fileSize > APIService.maximumMergeBundleBytes {
                    return .failure(.payloadTooLarge)
                }
            }

            var fields = [
                "config_json": configJSON ?? "{}",
            ]
            if !hwid.isEmpty {
                fields["udid"] = hwid
            }

            var attachedFileURL: URL? = fileURL
            if let fileURL, fileSize > Int64(APIService.mergeChunkBytes) {
                let uploadID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                switch await uploadMergeChunks(
                    fileURL: fileURL,
                    fileSize: fileSize,
                    uploadID: uploadID,
                    token: token,
                    hwid: hwid,
                    onStage: onStage
                ) {
                case .success(let totalChunks):
                    if let totalChunks {
                        fields["upload_id"] = uploadID
                        fields["total_chunks"] = String(totalChunks)
                        attachedFileURL = nil
                    }
                case .failure(let err):
                    return .failure(err)
                }
            }

            let body = try buildMultipartBody(
                fields: fields,
                fileURLs: attachedFileURL.map { [$0] } ?? [],
                fileFieldName: "file"
            )

            var submitReq = URLRequest(url: baseURL.appendingPathComponent(submitPath))
            submitReq.httpMethod = "POST"
            submitReq.setValue(
                "multipart/form-data; boundary=\(body.boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            applyAuthHeaders(to: &submitReq, token: token, hwid: hwid)
            submitReq.timeoutInterval = APIService.mergeTimeout
            signRequest(&submitReq)

            let (submitData, submitResp) = try await upload(submitReq, body: body)
            guard let submitHTTP = submitResp as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            if submitHTTP.statusCode == 404 {
                switch await mergePlan(fileURL: fileURL, configJSON: configJSON, token: token, hwid: hwid) {
                case .success(let legacy):
                    return .success(MergePlanExecutionResult(response: legacy, resultBundleData: nil))
                case .failure(let err):
                    return .failure(err)
                }
            }
            guard (200..<300).contains(submitHTTP.statusCode) else {
                let msg = Self.errorMessage(from: submitData)
                if submitHTTP.statusCode == 401 {
                    notifyUnauthorized(msg)
                }
                return .failure(.serverRejected(status: submitHTTP.statusCode, message: msg))
            }

            let submitted = try parseJSON(MergeJobSubmitBody.self, from: submitData)
            guard submitted.ok, !submitted.jobId.isEmpty else {
                return .failure(.invalidResponse)
            }

            let initialPos = max(1, submitted.position ?? 1)
            let initialQLen = max(initialPos, submitted.queueLength ?? initialPos)
            if submitted.status == "processing" {
                onStage(.processing)
            } else {
                onStage(.queued(position: initialPos, queueLength: initialQLen))
            }

            let pollIntervalNs = UInt64(max(800, submitted.pollIntervalMs ?? 1500)) * 1_000_000
            let deadline = Date().addingTimeInterval(600)
            var transientFailures = 0

            while Date() < deadline {
                try await Task.sleep(nanoseconds: pollIntervalNs)

                switch await fetchMergeJobStatus(jobID: submitted.jobId, token: token, hwid: hwid) {
                case .success(let statusBody):
                    transientFailures = 0
                    switch statusBody.status {
                    case "queued":
                        onStage(.queued(
                            position: max(1, statusBody.position ?? 1),
                            queueLength: max(1, statusBody.queueLength ?? 1)
                        ))
                    case "processing":
                        onStage(.processing)
                    case "failed":
                        return .failure(.serverRejected(
                            status: statusBody.errorCode ?? 400,
                            message: statusBody.detail
                        ))
                    case "done":
                        var bundleData: Data? = nil
                        if statusBody.hasResultZip == true {
                            onStage(.downloadingResult)
                            switch await downloadMergeJobResult(jobID: submitted.jobId, token: token, hwid: hwid) {
                            case .success(let raw):
                                bundleData = raw
                            case .failure(let err):
                                return .failure(err)
                            }
                        }
                        if let user = statusBody.user {
                            notifyUserProfileUpdated(user)
                        }
                        let response = MergePlanResponse(
                            ok: statusBody.ok,
                            acceptedBytes: statusBody.acceptedBytes ?? 0,
                            mergePlan: statusBody.mergePlan,
                            configFiles: statusBody.configFiles,
                            zipBytesB64: statusBody.zipBytesB64,
                            note: statusBody.note,
                            user: statusBody.user
                        )
                        return .success(MergePlanExecutionResult(response: response, resultBundleData: bundleData))
                    default:
                        return .failure(.invalidResponse)
                    }
                case .failure(let err):
                    if case .transport = err, transientFailures < 5 {
                        transientFailures += 1
                        continue
                    }
                    return .failure(err)
                }
            }

            return .failure(.transport("Quá thời gian chờ máy chủ xử lý tác vụ gộp."))
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    private func fetchMergeJobStatus(
        jobID: String,
        token: String,
        hwid: String
    ) async -> Result<MergeJobStatusBody, APIServiceError> {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(ObfuscatedStrings.mergePlanJobs),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "job_id", value: jobID)]
        guard let url = components?.url else {
            return .failure(.invalidConfiguration)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, token: token, hwid: hwid)
        signRequest(&request)
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
            return .success(try parseJSON(MergeJobStatusBody.self, from: data))
        } catch {
            return .failure(Self.failure(from: error))
        }
    }

    private func downloadMergeJobResult(
        jobID: String,
        token: String,
        hwid: String
    ) async -> Result<Data, APIServiceError> {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(ObfuscatedStrings.mergePlanJobResult),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "job_id", value: jobID)]
        guard let url = components?.url else {
            return .failure(.invalidConfiguration)
        }
        var lastError: APIServiceError = .invalidResponse
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyAuthHeaders(to: &request, token: token, hwid: hwid)
            request.timeoutInterval = APIService.mergeTimeout
            signRequest(&request)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = .invalidResponse
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    let msg = Self.errorMessage(from: data)
                    if http.statusCode == 401 {
                        notifyUnauthorized(msg)
                    }
                    return .failure(.serverRejected(status: http.statusCode, message: msg))
                }
                return .success(data)
            } catch {
                lastError = Self.failure(from: error)
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        return .failure(lastError)
    }

    private func uploadMergeChunks(
        fileURL: URL,
        fileSize: Int64,
        uploadID: String,
        token: String,
        hwid: String,
        onStage: @escaping @Sendable (MergeQueueStage) -> Void
    ) async -> Result<Int?, APIServiceError> {
        let chunkSize = APIService.mergeChunkBytes
        let totalChunks = Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize))
        guard totalChunks > 0 else { return .success(nil) }

        let hasScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { fileURL.stopAccessingSecurityScopedResource() }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            return .failure(.ioFailure(error.localizedDescription))
        }
        defer { try? handle.close() }

        let chunksPath = ObfuscatedStrings.mergePlanChunks
        for index in 0..<totalChunks {
            let chunkData: Data
            do {
                chunkData = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return .failure(.ioFailure(error.localizedDescription))
            }
            guard !chunkData.isEmpty else { break }

            onStage(.uploadingChunk(index: index + 1, total: totalChunks))

            let boundary = "Totorox-\(UUID().uuidString)"
            var payload = Data()
            let fields: [(String, String)] = [
                ("upload_id", uploadID),
                ("chunk_index", String(index)),
                ("total_chunks", String(totalChunks)),
                ("udid", hwid),
            ]
            for (name, value) in fields where !value.isEmpty {
                payload.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            payload.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"chunk\"; filename=\"part_\(index).bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            payload.append(chunkData)
            payload.append(Data("\r\n--\(boundary)--\r\n".utf8))

            var sent = false
            var lastError: APIServiceError = .invalidResponse
            for attempt in 0..<3 {
                var request = URLRequest(url: baseURL.appendingPathComponent(chunksPath))
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                applyAuthHeaders(to: &request, token: token, hwid: hwid)
                request.timeoutInterval = 180
                signRequest(&request)

                do {
                    let (data, response) = try await upload(
                        request,
                        body: MultipartBody(boundary: boundary, fileURL: nil, data: payload)
                    )
                    guard let http = response as? HTTPURLResponse else {
                        lastError = .invalidResponse
                        continue
                    }
                    if http.statusCode == 404 {
                        // Server chưa bật chunked upload -> fallback về luồng gửi thẳng 1 cục.
                        return .success(nil)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let msg = Self.errorMessage(from: data)
                        if http.statusCode == 401 {
                            notifyUnauthorized(msg)
                        }
                        return .failure(.serverRejected(status: http.statusCode, message: msg))
                    }
                    sent = true
                    break
                } catch {
                    lastError = Self.failure(from: error)
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                    }
                }
            }
            if !sent {
                return .failure(lastError)
            }
        }
        return .success(totalChunks)
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
        signRequest(&request)
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
        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }
    }

    // MARK: - HMAC-SHA256 Request Signing

    private static let hmacMaskBytes: [UInt8] = [
        0x46, 0xdf, 0xaf, 0x0b, 0x94, 0xcc, 0x07, 0x07, 0x9b, 0x7e, 0x5e, 0x77,
        0x0a, 0x65, 0xff, 0x05, 0xf0, 0x4d, 0x5a, 0x57, 0xbd, 0xe0, 0x86, 0x2c,
        0xfe, 0x4e, 0x3f, 0x19, 0x45, 0x4f, 0x5c, 0x5a, 0xb1, 0x02, 0x89, 0x0e,
        0x05, 0x1e, 0x54, 0xad, 0xa0, 0xc3, 0x4c, 0x77, 0xb2, 0x4b, 0x16, 0x27
    ]

    private static let hmacXordBytes: [UInt8] = [
        0x22, 0xef, 0xcd, 0x39, 0xa0, 0xf8, 0x31, 0x35, 0xa3, 0x1c, 0x6a, 0x13,
        0x69, 0x52, 0xc7, 0x60, 0x94, 0x7d, 0x3c, 0x33, 0x8a, 0xd0, 0xbf, 0x1b,
        0x98, 0x7f, 0x07, 0x21, 0x26, 0x2d, 0x6d, 0x3e, 0xd2, 0x63, 0xbe, 0x6d,
        0x30, 0x7c, 0x6c, 0x9b, 0x94, 0xf7, 0x2f, 0x16, 0x8a, 0x7f, 0x72, 0x15
    ]

    static func hmacSecretData() -> Data {
        var out = [UInt8]()
        out.reserveCapacity(hmacMaskBytes.count)
        for (m, x) in zip(hmacMaskBytes, hmacXordBytes) {
            out.append(m ^ x)
        }
        return Data(out)
    }

    static func computeHMACSignature(
        method: String,
        path: String,
        timestamp: String,
        nonce: String,
        hwid: String = "",
        authorization: String = ""
    ) -> String {
        let canonical = [
            method.uppercased(),
            path,
            timestamp.trimmingCharacters(in: .whitespacesAndNewlines),
            nonce.trimmingCharacters(in: .whitespacesAndNewlines),
            hwid.trimmingCharacters(in: .whitespacesAndNewlines),
            authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\n")
        let key = SymmetricKey(data: hmacSecretData())
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func signRequest(
        _ request: inout URLRequest,
        now: Date = Date(),
        nonce: String = UUID().uuidString.lowercased()
    ) {
        let method = (request.httpMethod ?? "GET").uppercased()
        let rawPath = request.url?.path ?? ""
        let path = rawPath.isEmpty ? "/" : rawPath
        let timestamp = String(Int(now.timeIntervalSince1970))
        let hwid = request.value(forHTTPHeaderField: "X-HWID") ?? ""
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let signature = Self.computeHMACSignature(
            method: method,
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            hwid: hwid,
            authorization: auth
        )
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
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

    private func writeMultipart(
        fields: [String: String],
        fileURLs: [URL],
        fileFieldName: String,
        boundary: String,
        emit: (Data) throws -> Void,
        emitFile: (URL) throws -> Void
    ) throws {
        for (name, value) in fields {
            try emit(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        for fileURL in fileURLs {
            // URL lấy từ DocumentPicker là security-scoped: phải mở quyền trước khi đọc.
            let hasScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasScope { fileURL.stopAccessingSecurityScopedResource() }
            }
            let filename = fileURL.lastPathComponent
            try emit(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            try emitFile(fileURL)
            try emit(Data("\r\n".utf8))
        }
        try emit(Data("--\(boundary)--\r\n".utf8))
    }

    private func buildMultipartBody(
        fields: [String: String],
        fileURLs: [URL],
        fileFieldName: String
    ) throws -> MultipartBody {
        let boundary = "Totorox-\(UUID().uuidString)"
        let tempDirectory = FileManager.default.temporaryDirectory
        let tempURL = tempDirectory.appendingPathComponent("totorox-\(UUID().uuidString).tmp")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }

            try writeMultipart(
                fields: fields,
                fileURLs: fileURLs,
                fileFieldName: fileFieldName,
                boundary: boundary,
                emit: { try handle.write(contentsOf: $0) },
                emitFile: { url in
                    let inputHandle = try FileHandle(forReadingFrom: url)
                    defer { try? inputHandle.close() }
                    let chunkSize = 1024 * 1024
                    while true {
                        let chunk = try inputHandle.read(upToCount: chunkSize) ?? Data()
                        if chunk.isEmpty { break }
                        try handle.write(contentsOf: chunk)
                    }
                }
            )
            return MultipartBody(boundary: boundary, fileURL: tempURL, data: Data())
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            var body = Data()
            try writeMultipart(
                fields: fields,
                fileURLs: fileURLs,
                fileFieldName: fileFieldName,
                boundary: boundary,
                emit: { body.append($0) },
                emitFile: { body.append(try Data(contentsOf: $0)) }
            )
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

        var tunedRequest = request
        if #available(iOS 14.5, *) {
            tunedRequest.assumesHTTP3Capable = false
        }

        if let fileURL = body.fileURL {
            let fileSize = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if fileSize > 0, fileSize <= APIService.directMemoryUploadLimit,
               let memData = try? Data(contentsOf: fileURL) {
                return try await session.upload(for: tunedRequest, from: memData)
            }
            return try await session.upload(for: tunedRequest, fromFile: fileURL)
        }
        return try await session.upload(for: tunedRequest, from: body.data)
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

// MARK: - String Obfuscation (XOR)

private enum ObfuscatedStrings {
    static func decode(_ encoded: [UInt8], _ mask: [UInt8]) -> String {
        String(decoding: zip(encoded, mask).map(^), as: UTF8.self)
    }

    static var baseURL: String {
        decode(
            [0x06, 0xb8, 0xdb, 0x30, 0x7b, 0x15, 0xf0, 0x1c, 0x5c, 0x20, 0x34, 0xf5, 0xfc, 0x26, 0x1c, 0x50, 0xe9, 0xa2, 0x31, 0x7c, 0xe9, 0xb6, 0x68, 0x7b, 0x85],
            [0x6e, 0xcc, 0xaf, 0x40, 0x08, 0x2f, 0xdf, 0x33, 0x3d, 0x50, 0x5d, 0xdb, 0x88, 0x49, 0x68, 0x3f, 0x9b, 0xcd, 0x49, 0x52, 0x80, 0xd9, 0x46, 0x0d, 0xeb]
        )
    }

    static var pinnedHost: String {
        decode(
            [0x57, 0x95, 0xb9, 0x37, 0x9b, 0x52, 0x0d, 0xf2, 0xa7, 0xb1, 0x28, 0x3f, 0x2b, 0x7e, 0xac, 0x63, 0xcf],
            [0x36, 0xe5, 0xd0, 0x19, 0xef, 0x3d, 0x79, 0x9d, 0xd5, 0xde, 0x50, 0x11, 0x42, 0x11, 0x82, 0x15, 0xa1]
        )
    }

    static var deviceProfile: String {
        decode(
            [0xac, 0x6b, 0x32, 0x30, 0x01, 0x70, 0x83, 0xe0, 0xd2, 0xb2, 0x65, 0x4c, 0xeb, 0xb5, 0x23, 0xe8, 0xca, 0x3d, 0x07, 0xb8, 0xaa],
            [0xcd, 0x1b, 0x5b, 0x1f, 0x77, 0x41, 0xac, 0x84, 0xb7, 0xc4, 0x0c, 0x2f, 0x8e, 0x9a, 0x53, 0x9a, 0xa5, 0x5b, 0x6e, 0xd4, 0xcf]
        )
    }

    static var authRegister: String {
        decode(
            [0xa8, 0x86, 0x16, 0xf0, 0xf9, 0xb4, 0xf4, 0x5b, 0xf1, 0x1c, 0xb6, 0xe2, 0x16, 0x66, 0x8c, 0x51, 0x49, 0xec, 0x04, 0x91],
            [0xc9, 0xf6, 0x7f, 0xdf, 0x8f, 0x85, 0xdb, 0x3a, 0x84, 0x68, 0xde, 0xcd, 0x64, 0x03, 0xeb, 0x38, 0x3a, 0x98, 0x61, 0xe3]
        )
    }

    static var authLogin: String {
        decode(
            [0xf1, 0xdb, 0x8d, 0xdf, 0xbf, 0xe6, 0x23, 0xcc, 0x6b, 0x34, 0x98, 0xa4, 0x6c, 0xba, 0x84, 0x87, 0x00],
            [0x90, 0xab, 0xe4, 0xf0, 0xc9, 0xd7, 0x0c, 0xad, 0x1e, 0x40, 0xf0, 0x8b, 0x00, 0xd5, 0xe3, 0xee, 0x6e]
        )
    }

    static var authLogout: String {
        decode(
            [0x07, 0xef, 0xe2, 0xdc, 0x1c, 0x55, 0xb0, 0x76, 0xf1, 0x9f, 0x98, 0x60, 0xdb, 0xd7, 0x81, 0xac, 0x5c, 0xe4],
            [0x66, 0x9f, 0x8b, 0xf3, 0x6a, 0x64, 0x9f, 0x17, 0x84, 0xeb, 0xf0, 0x4f, 0xb7, 0xb8, 0xe6, 0xc3, 0x29, 0x90]
        )
    }

    static var authRedeem: String {
        decode(
            [0x27, 0xd8, 0xf1, 0x04, 0x72, 0x2f, 0x5b, 0xad, 0x40, 0x1a, 0xdb, 0x49, 0xc4, 0xa5, 0x7a, 0x13, 0x5b, 0xf0],
            [0x46, 0xa8, 0x98, 0x2b, 0x04, 0x1e, 0x74, 0xcc, 0x35, 0x6e, 0xb3, 0x66, 0xb6, 0xc0, 0x1e, 0x76, 0x3e, 0x9d]
        )
    }

    static var authMe: String {
        decode(
            [0xb4, 0x75, 0xb1, 0x25, 0x77, 0x18, 0x19, 0x92, 0xf8, 0x26, 0x5a, 0xa8, 0x62, 0xe6],
            [0xd5, 0x05, 0xd8, 0x0a, 0x01, 0x29, 0x36, 0xf3, 0x8d, 0x52, 0x32, 0x87, 0x0f, 0x83]
        )
    }

    static var overwritePlan: String {
        decode(
            [0x19, 0x41, 0x4f, 0x0c, 0xbd, 0x13, 0x78, 0xd5, 0xc9, 0xee, 0xef, 0xfa, 0x15, 0xd3, 0x9e, 0xb7, 0x44, 0x46, 0x65, 0xba, 0x3b],
            [0x78, 0x31, 0x26, 0x23, 0xcb, 0x22, 0x57, 0xba, 0xbf, 0x8b, 0x9d, 0x8d, 0x67, 0xba, 0xea, 0xd2, 0x69, 0x36, 0x09, 0xdb, 0x55]
        )
    }

    static var convertHeader: String {
        decode(
            [0xec, 0x39, 0xd0, 0x58, 0xef, 0x56, 0xb2, 0x3b, 0x02, 0x19, 0x26, 0x19, 0x8b, 0xed, 0x18, 0x99, 0x2a, 0x3c, 0x30, 0x1c, 0xee],
            [0x8d, 0x49, 0xb9, 0x77, 0x99, 0x67, 0x9d, 0x58, 0x6d, 0x77, 0x50, 0x7c, 0xf9, 0x99, 0x35, 0xf1, 0x4f, 0x5d, 0x54, 0x79, 0x9c]
        )
    }

    static var mergePlan: String {
        decode(
            [0xb4, 0x4e, 0x2d, 0xe1, 0xa8, 0xb2, 0x73, 0x56, 0x98, 0xe4, 0x31, 0xaa, 0x95, 0x1f, 0xe7, 0x0d, 0xf6],
            [0xd5, 0x3e, 0x44, 0xce, 0xde, 0x83, 0x5c, 0x3b, 0xfd, 0x96, 0x56, 0xcf, 0xb8, 0x6f, 0x8b, 0x6c, 0x98]
        )
    }

    static var mergePlanJobs: String {
        decode(
            [0x5b, 0x33, 0xd2, 0x6a, 0x2d, 0x8b, 0xb8, 0xd6, 0x51, 0xdf, 0x04, 0xf7, 0xb3, 0x64, 0x9d, 0x92, 0xac, 0x34, 0xcc, 0xfb, 0xc0, 0x9d, 0xe3],
            [0x74, 0x52, 0xa2, 0x03, 0x02, 0xfd, 0x89, 0xf9, 0x3c, 0xba, 0x76, 0x90, 0xd6, 0x49, 0xed, 0xfe, 0xcd, 0x5a, 0xe3, 0x91, 0xaf, 0xff, 0x90]
        )
    }

    static var mergePlanJobResult: String {
        decode(
            [0x5c, 0xaa, 0x67, 0x43, 0x83, 0x49, 0x96, 0x0c, 0xf1, 0x7a, 0xa3, 0xda, 0x13, 0xcb, 0xdc, 0xe6, 0xae, 0x73, 0x4c, 0x90, 0xa1, 0x42, 0x52, 0x6d, 0x9b, 0x19, 0x9e, 0xe8, 0x38, 0x03],
            [0x73, 0xcb, 0x17, 0x2a, 0xac, 0x3f, 0xa7, 0x23, 0x9c, 0x1f, 0xd1, 0xbd, 0x76, 0xe6, 0xac, 0x8a, 0xcf, 0x1d, 0x63, 0xfa, 0xce, 0x20, 0x21, 0x42, 0xe9, 0x7c, 0xed, 0x9d, 0x54, 0x77]
        )
    }

    static var mergePlanChunks: String {
        decode(
            [0x7d, 0x41, 0x54, 0x9a, 0x62, 0xdd, 0xc5, 0xe5, 0x3c, 0x59, 0xd4, 0xe4, 0xd9, 0x65, 0x16, 0xf0, 0x8f, 0xbb, 0x09, 0x75, 0xf3, 0x28, 0xfb, 0xc7, 0x34],
            [0x52, 0x20, 0x24, 0xf3, 0x4d, 0xab, 0xf4, 0xca, 0x51, 0x3c, 0xa6, 0x83, 0xbc, 0x48, 0x66, 0x9c, 0xee, 0xd5, 0x26, 0x16, 0x9b, 0x5d, 0x95, 0xac, 0x47]
        )
    }
}

// MARK: - SSL Pinning (SPKI SHA-256 cho api.totorox.io.vn qua Cloudflare)

final class SSLPinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let pinnedHost = ObfuscatedStrings.pinnedHost

    /// Danh sách SPKI SHA-256 (Base64) của Intermediate/Root CA được phép cho `api.totorox.io.vn`
    /// (Let's Encrypt / ISRG, Google Trust Services, SSL.com, DigiCert — hỗ trợ Cloudflare rotation,
    /// đồng thời chặn các MITM Root CA tự ký của Proxyman / Charles / mitmproxy).
    static let pinnedSPKIHashes: Set<String> = [
        // Let's Encrypt / ISRG
        "s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y=", // Let's Encrypt YE2
        "sCkq5UWXjg+7mKu9lMhhYF5bGLsy7VI/UNW3tccdR7w=", // ISRG Root YE
        "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=", // ISRG Root X2
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=", // ISRG Root X1
        // Google Trust Services (Cloudflare Universal SSL)
        "hxqRlPTu1bMS/0DITB1SSu0vd4u/8l8TjPgfaAp63Gc=", // GTS Root R1
        "QXnt2YHvdHR3tJYmQIr0Paosp6t/nggsEGD4QJZ3Q0g=", // GTS Root R3
        "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=", // GTS Root R4
        // SSL.com & DigiCert (Cloudflare backup CAs)
        "K89VOmb1cJAN3TK6bf4ezAbJGC1mLcG2Dh97dnwr3VQ=", // SSL.com TLS RSA Root CA 2022
        "G/ANXI8TwJTdF+AFBM8IiIUPEv0Gf6H5LA/b9guG4yE=", // SSL.com TLS ECC Root CA 2022
        "0cRTd+vc1hjNFlHcLgLCHXUeWqn80bNDH/bs9qMTSPo=", // SSL.com Root Certification Authority RSA
        "oyD01TTXvpfBro3QSZc1vIlcMjrdLTiL/M9mLCPX+Zo=", // SSL.com Root Certification Authority ECC
        "i7WTqTvh0OioIruIfFR4kMPnBqrS2rdiVPl/s2uC/CY=", // DigiCert Global Root G2
        "uUwZgwDOxcBXrQcntwu+kYFpkiVkOaezL0WYEZ3anJc="  // DigiCert Global Root G3
    ]

    private static let ecP256SPKIHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
    ]

    private static let ecP384SPKIHeader: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
    ]

    private static let rsaAlgorithmIdentifier: [UInt8] = [
        0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00
    ]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host.lowercased()
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard host == Self.pinnedHost else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(serverTrust, policy)

        var trustError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &trustError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !chain.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let chainHashes = chain.compactMap(Self.spkiSHA256Base64(for:))
        guard Self.matchesPinnedHash(chainHashes) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    static func matchesPinnedHash(_ chainHashes: [String]) -> Bool {
        chainHashes.contains { pinnedSPKIHashes.contains($0) }
    }

    static func spkiSHA256Base64(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let keySizeBits = attributes[kSecAttrKeySizeInBits as String] as? Int,
              let rawKey = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let spki = spkiData(fromRawKey: rawKey, keyType: keyType, keySizeBits: keySizeBits) else {
            return nil
        }
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    static func spkiData(fromRawKey rawKey: Data, keyType: String, keySizeBits: Int) -> Data? {
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) || keyType == (kSecAttrKeyTypeEC as String) {
            if keySizeBits == 256 {
                var data = Data(ecP256SPKIHeader)
                data.append(rawKey)
                return data
            }
            if keySizeBits == 384 {
                var data = Data(ecP384SPKIHeader)
                data.append(rawKey)
                return data
            }
            return nil
        }

        if keyType == (kSecAttrKeyTypeRSA as String) {
            var bitString = Data([0x03])
            bitString.append(derLength(1 + rawKey.count))
            bitString.append(0x00)
            bitString.append(rawKey)

            var spki = Data([0x30])
            spki.append(derLength(rsaAlgorithmIdentifier.count + bitString.count))
            spki.append(contentsOf: rsaAlgorithmIdentifier)
            spki.append(bitString)
            return spki
        }

        return nil
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
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

struct MergePlanExecutionResult {
    let response: MergePlanResponse
    let resultBundleData: Data?
}

struct MergeJobSubmitBody: Decodable {
    let ok: Bool
    let jobId: String
    let status: String
    let position: Int?
    let queueLength: Int?
    let pollIntervalMs: Int?

    private enum CodingKeys: String, CodingKey {
        case ok
        case jobId = "job_id"
        case status
        case position
        case queueLength = "queue_length"
        case pollIntervalMs = "poll_interval_ms"
    }
}

struct MergeJobStatusBody: Decodable {
    let ok: Bool
    let jobId: String?
    let status: String
    let position: Int?
    let queueLength: Int?
    let errorCode: Int?
    let detail: String?
    let hasResultZip: Bool?
    let acceptedBytes: Int?
    let mergePlan: MergePlanBody?
    let configFiles: [String]?
    let zipBytesB64: String?
    let note: String?
    let user: UserProfile?

    private enum CodingKeys: String, CodingKey {
        case ok
        case jobId = "job_id"
        case status
        case position
        case queueLength = "queue_length"
        case errorCode = "error_code"
        case detail
        case hasResultZip = "has_result_zip"
        case acceptedBytes = "accepted_bytes"
        case mergePlan = "merge_plan"
        case configFiles = "config_files"
        case zipBytesB64 = "zip_bytes_b64"
        case note
        case user
    }
}
