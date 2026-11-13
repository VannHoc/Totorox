import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
    @ObservedObject private var license = LicenseManager.shared
    @State private var showSettings: Bool = false
    @State private var showLogs: Bool = false

    var body: some View {
        Group {
            if license.status.isActive {
                mainAppBody
            } else {
                activationBody
            }
        }
        .background(TotoroxTheme.pageBackground)
    }

    /// Chưa có license hợp lệ thì chỉ hiện màn hình kích hoạt.
    private var activationBody: some View {
        ActivationView()
    }

    private var mainAppBody: some View {
        VStack(spacing: 0) {
            TotoroxTopHeader {
                showSettings = true
            }

            ZStack {
                switch navCoordinator.selectedTab {
                case .overwrite:
                    OverwriteFileView()
                case .folders:
                    FolderExplorerView()
                case .patch:
                    PatchConverterView()
                case .merge:
                    MergeFileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TotoroxTabBar(selectedTab: $navCoordinator.selectedTab)
        }
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
            AppContainerScanner.shared.prewarmOnLaunch()
        }
    }
}
