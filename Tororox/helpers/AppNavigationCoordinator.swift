import SwiftUI

@MainActor
final class AppNavigationCoordinator: ObservableObject {
    static let shared = AppNavigationCoordinator()

    @Published var selectedTab: TotoroxTab = .overwrite
    @Published var folderExplorerTargetURL: URL? = nil

    init() {}

    func navigateToFolder(url: URL) {
        self.folderExplorerTargetURL = url
        self.selectedTab = .folders
    }
}
