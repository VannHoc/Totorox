import Foundation
import SwiftUI

// MARK: - Response Model

struct BootstrapResponse: Decodable {
    let status: String
    let force_update: Bool
    let min_build: Int?
    let download_url: String?
    let message: String?
}

// MARK: - BootstrapManager

/// Kiểm tra phiên bản build với server khi app khởi động.
/// Nếu server trả về force_update == true → khoá toàn bộ giao diện.
@MainActor
final class BootstrapManager: ObservableObject {
    static let shared = BootstrapManager()
    private init() {}

    // MARK: Published state
    @Published var mustUpdate: Bool = false
    @Published var updateMessage: String = "Phiên bản này đã cũ. Vui lòng tải bản mới để tiếp tục sử dụng."
    @Published var updateURL: String = ""
    /// false → đang chờ kết quả check; true → đã check xong (dù pass hay fail)
    @Published var bootstrapChecked: Bool = false

    // MARK: Build number (CFBundleVersion, integer)
    private var currentBuild: Int {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return Int(raw) ?? 1
    }

    // MARK: - Public API

    /// Gọi một lần duy nhất từ App.swift khi app khởi động.
    func checkBootstrap() async {
        defer { bootstrapChecked = true }

        guard let url = URL(string: "https://api.totorox.io.vn/api/v1/bootstrap") else { return }

        var urlRequest = URLRequest(url: url, timeoutInterval: 10)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("\(currentBuild)", forHTTPHeaderField: "X-App-Build")

        do {
            let (data, _) = try await URLSession.shared.data(for: urlRequest)
            let res = try JSONDecoder().decode(BootstrapResponse.self, from: data)
            if res.force_update {
                updateMessage = res.message ?? updateMessage
                updateURL = res.download_url ?? ""
                mustUpdate = true
            }
        } catch {
            // Nếu không kết nối được server: cho phép tiếp tục (không khoá người dùng offline)
            // Muốn chặn offline: set mustUpdate = true tại đây
            log("bootstrap: check failed — \(error.localizedDescription), allowing offline mode")
        }
    }
}
