import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
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
                switch navCoordinator.selectedTab {
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
            TotoroxTabBar(selectedTab: $navCoordinator.selectedTab)
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
        .onAppear {
            Task.detached(priority: .userInitiated) {
                // Pre-warm UUID to Bundle ID mappings
                ContainerStore.refreshUUIDMap()
                _ = await AppContainerScanner.shared.scanAllContainers(forceRefresh: false)
            }
        }
    }
}
