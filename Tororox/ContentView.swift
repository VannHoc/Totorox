import SwiftUI
import UIKit

struct ContentView: View {
    @State private var selectedTab: TotoroxTab = .overwrite
    @State private var showSettings: Bool = false
    @State private var showLogs: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Main Top Bar (Avatar + Engine Status + Title + Gear Button)
            TotoroxTopHeader {
                showSettings = true
            }

            // Tab View Body
            ZStack {
                switch selectedTab {
                case .overwrite:
                    OverwriteFileView()
                case .folders:
                    FolderExplorerView()
                case .patch:
                    PatchConverterView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Custom Clean White TabBar with Indicator
            TotoroxTabBar(selectedTab: $selectedTab)
        }
        .background(TotoroxTheme.pageBackground)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .preferredColorScheme(.light)
        }
        .sheet(isPresented: $showLogs) {
            LogView()
                .preferredColorScheme(.light)
        }
    }
}

// MARK: - Restore iOS Interactive Pop Gesture when NavigationBar is hidden
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return viewControllers.count > 1
    }
}
