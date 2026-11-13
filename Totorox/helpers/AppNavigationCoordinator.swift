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
            // The copy runs on a background task: a large patch would otherwise block the main
            // thread, and the security-scoped access has to stay open until the copy finishes.
            Task {
                let importedURL = await self.importSharedFile(incomingURL)
                self.navigateToOverwrite(patchURL: importedURL)
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
               remoteURL.scheme?.lowercased() == "https" {
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

    /// Copies a file shared by another app into the app inbox without blocking the main thread.
    private func importSharedFile(_ incomingURL: URL) async -> URL {
        await Task.detached(priority: .userInitiated) { () -> URL in
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
                return destinationURL
            } catch {
                log("app: failed to copy incoming file to inbox: \(error.localizedDescription)")
                return incomingURL
            }
        }.value
    }

    private func downloadRemotePatch(from url: URL) async -> URL? {
        do {
            let (tempLocalURL, response) = try await URLSession.shared.download(from: url)

            // Stop an oversized download as soon as the server declares it, instead of filling the disk.
            let declaredSize = response.expectedContentLength
            if declaredSize > 0, PatchPackageLimits.exceedsExpandedLimit(declaredSize) {
                log("app: downloadRemotePatch rejected: declared \(declaredSize) bytes exceeds the 3.6 GB limit")
                try? FileManager.default.removeItem(at: tempLocalURL)
                return nil
            }

            let ext = url.pathExtension.isEmpty ? "zip" : url.pathExtension
            let targetURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RemoteImport_\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: tempLocalURL, to: targetURL)

            let attributes = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)) ?? [:]
            let downloadedSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if PatchPackageLimits.exceedsExpandedLimit(downloadedSize) {
                log("app: downloadRemotePatch rejected: \(downloadedSize) bytes exceeds the 3.6 GB limit")
                try? FileManager.default.removeItem(at: targetURL)
                return nil
            }
            return targetURL
        } catch {
            log("app: downloadRemotePatch failed: \(error.localizedDescription)")
            return nil
        }
    }
}
