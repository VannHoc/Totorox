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
}
