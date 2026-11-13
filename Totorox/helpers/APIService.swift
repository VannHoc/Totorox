import Foundation

enum APIServiceError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case payloadTooLarge
    case serverRejected(status: Int, message: String?)
    case invalidResponse
    case transport(String)
    case ioFailure(String)

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
        }
    }
}

struct LicenseActivation: Equatable, Sendable {
    let expiresAt: Date?
    let plan: String?
}

/// Thin client for the Totorox backend.
///
/// Phase 1 only provides the transport: the app still performs conversion and merging on-device,
/// so nothing breaks while the server is being built. Every request carries the license key and
/// the device identifier (HWID) required by the backend.
final class APIService {
    static let shared = APIService()

    /// Base URL of the Totorox backend. Change this once the server is deployed.
    static let defaultBaseURL = URL(string: "https://api.totorox.app")!

    /// Large mods stay on-device for now, so only reasonably small payloads are uploaded.
    /// Raise this once the server is able to handle bigger files.
    static let maximumUploadBytes: Int64 = 64 * 1024 * 1024

    private let session: URLSession
    private(set) var baseURL: URL

    init(baseURL: URL = APIService.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func setBaseURL(_ url: URL) {
        baseURL = url
    }

    // MARK: - License

    func activate(
        licenseKey: String,
        hwid: String
    ) async -> Result<LicenseActivation, APIServiceError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/activate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, licenseKey: licenseKey, hwid: hwid)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["hwid": hwid])

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

            let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let expiresAt = (payload["expires_at"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            return .success(LicenseActivation(expiresAt: expiresAt, plan: payload["plan"] as? String))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: - Conversion & merge (server-side, phase 2)

    func convert(
        fileURL: URL,
        mode: String,
        licenseKey: String,
        hwid: String
    ) async -> Result<URL, APIServiceError> {
        await upload(
            path: "api/v1/convert",
            fileURLs: [fileURL],
            fields: ["mode": mode],
            licenseKey: licenseKey,
            hwid: hwid,
            resultExtension: mode == "zip_to_3105" ? "3105" : "zip"
        )
    }

    func merge(
        fileURLs: [URL],
        licenseKey: String,
        hwid: String
    ) async -> Result<URL, APIServiceError> {
        await upload(
            path: "api/v1/merge",
            fileURLs: fileURLs,
            fields: [:],
            licenseKey: licenseKey,
            hwid: hwid,
            resultExtension: "3105"
        )
    }

    // MARK: - Internals

    private func upload(
        path: String,
        fileURLs: [URL],
        fields: [String: String],
        licenseKey: String,
        hwid: String,
        resultExtension: String
    ) async -> Result<URL, APIServiceError> {
        var totalBytes: Int64 = 0
        for url in fileURLs {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += Int64(size)
        }
        guard totalBytes > 0, totalBytes <= Self.maximumUploadBytes else {
            return .failure(.payloadTooLarge)
        }

        let boundary = "Totorox-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        do {
            try Self.writeMultipartBody(
                to: bodyURL,
                boundary: boundary,
                fields: fields,
                fileURLs: fileURLs
            )
        } catch {
            return .failure(.ioFailure(error.localizedDescription))
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        applyAuthHeaders(to: &request, licenseKey: licenseKey, hwid: hwid)

        do {
            let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.serverRejected(
                    status: http.statusCode,
                    message: Self.errorMessage(from: data)
                ))
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ServerResult-\(UUID().uuidString).\(resultExtension)")
            try data.write(to: outputURL, options: .atomic)
            return .success(outputURL)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    private func applyAuthHeaders(to request: inout URLRequest, licenseKey: String, hwid: String) {
        request.setValue(licenseKey, forHTTPHeaderField: "X-License-Key")
        request.setValue(hwid, forHTTPHeaderField: "X-HWID")
        request.timeoutInterval = 120
    }

    /// Streams the multipart body into a temporary file so a large payload is never held in memory.
    private static func writeMultipartBody(
        to bodyURL: URL,
        boundary: String,
        fields: [String: String],
        fileURLs: [URL]
    ) throws {
        _ = FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let bodyHandle = try FileHandle(forWritingTo: bodyURL)
        defer { try? bodyHandle.close() }

        func write(_ string: String) throws {
            guard let data = string.data(using: .utf8) else { return }
            try bodyHandle.write(contentsOf: data)
        }

        for (name, value) in fields {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try write("\(value)\r\n")
        }

        for fileURL in fileURLs {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"files\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
            try write("Content-Type: application/octet-stream\r\n\r\n")

            let sourceHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? sourceHandle.close() }
            while let chunk = try sourceHandle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try bodyHandle.write(contentsOf: chunk)
            }
            try write("\r\n")
        }

        try write("--\(boundary)--\r\n")
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["detail"] as? String) ?? (object["message"] as? String)
    }
}
