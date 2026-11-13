import SwiftUI

@MainActor
final class AppNavigationCoordinator: ObservableObject {
    static let shared = AppNavigationCoordinator()

    @Published var selectedTab: TotoroxTab = .overwrite
    @Published var folderExplorerTargetURL: URL? = nil
    @Published var pendingOverwritePatchURL: URL? = nil
    @Published var pendingOverwriteBundleID: String? = nil

    init() {}

    func navigateToFolder(url: URL) {
        self.folderExplorerTargetURL = url
        self.selectedTab = .folders
    }

    func navigateToOverwrite(patchURL: URL, bundleID: String = "com.garena.game.kgvn") {
        self.pendingOverwritePatchURL = patchURL
        self.pendingOverwriteBundleID = bundleID
        self.selectedTab = .overwrite
    }

    /// Xử lý mở file hoặc URL Scheme từ ứng dụng khác (AirDrop, Tệp, Safari, Chia sẻ...)
    func handleIncomingURL(_ incomingURL: URL) {
        log("app: incoming open URL: \(incomingURL)")

        // 1. Nếu là File cục bộ được app khác chia sẻ (AirDrop, Document Picker, Files app...)
        if incomingURL.isFileURL {
            let accessing = incomingURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    incomingURL.stopAccessingSecurityScopedResource()
                }
            }

            // Copy tệp sang thư mục tạm của app để đảm bảo quyền truy cập đọc/ghi ổn định
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("InboxImports", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let destinationURL = tempDir.appendingPathComponent(incomingURL.lastPathComponent)

            try? FileManager.default.removeItem(at: destinationURL)
            do {
                try FileManager.default.copyItem(at: incomingURL, to: destinationURL)
                navigateToOverwrite(patchURL: destinationURL)
            } catch {
                log("app: failed to copy incoming file to inbox: \(error.localizedDescription)")
                navigateToOverwrite(patchURL: incomingURL)
            }
            return
        }

        // 2. Custom URL Scheme: totorox://
        guard let scheme = incomingURL.scheme?.lowercased(), scheme == "totorox" else {
            return
        }

        let host = incomingURL.host?.lowercased() ?? ""
        let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)

        switch host {
        case "overwrite", "import":
            if let remoteString = components?.queryItems?.first(where: { $0.name == "url" })?.value,
               let remoteURL = URL(string: remoteString),
               remoteURL.scheme?.lowercased() == "https" || remoteURL.scheme?.lowercased() == "http" {
                Task {
                    if let downloaded = await downloadRemotePatch(from: remoteURL) {
                        await MainActor.run {
                            self.navigateToOverwrite(patchURL: downloaded)
                        }
                    }
                }
            } else {
                self.selectedTab = .overwrite
            }
        case "merge":
            self.selectedTab = .merge
        case "patch", "convert":
            self.selectedTab = .patch
        case "folders", "explorer":
            self.selectedTab = .folders
        default:
            self.selectedTab = .overwrite
        }
    }

    private func downloadRemotePatch(from url: URL) async -> URL? {
        do {
            let (tempLocalURL, _) = try await URLSession.shared.download(from: url)
            let ext = url.pathExtension.isEmpty ? "zip" : url.pathExtension
            let targetURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RemoteImport_\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: tempLocalURL, to: targetURL)
            return targetURL
        } catch {
            log("app: downloadRemotePatch failed: \(error.localizedDescription)")
            return nil
        }
    }
}
