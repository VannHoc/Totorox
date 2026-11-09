import SwiftUI

@MainActor
public final class AppNavigationCoordinator: ObservableObject {
    public static let shared = AppNavigationCoordinator()

    @Published public var selectedTab: TotoroxTab = .overwrite
    @Published public var folderExplorerTargetURL: URL? = nil

    public init() {}

    public func navigateToFolder(url: URL) {
        self.folderExplorerTargetURL = url
        self.selectedTab = .folders
    }
}
