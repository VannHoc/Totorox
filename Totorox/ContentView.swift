import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
    @ObservedObject private var license = LicenseManager.shared
    @State private var showSettings: Bool = false
    @State private var showLogs: Bool = false
    @State private var showRedeemSheet: Bool = false
    @State private var showLogoutConfirm: Bool = false
    @Environment(\.appLanguage) private var language

    var body: some View {
        Group {
            if license.status.isAuthenticated {
                mainAppBody
            } else {
                activationBody
            }
        }
        .background(TotoroxTheme.pageBackground)
    }

    /// Chưa đăng nhập tài khoản thì chỉ hiện màn hình Đăng nhập / Đăng ký.
    private var activationBody: some View {
        ActivationView()
    }

    private var mainAppBody: some View {
        VStack(spacing: 0) {
            TotoroxTopHeader {
                showSettings = true
            }

            AccountStatusBar(
                onRedeemTapped: { showRedeemSheet = true },
                onLogoutTapped: { showLogoutConfirm = true }
            )

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
        .sheet(isPresented: $showRedeemSheet) {
            RedeemCodeSheet()
                .preferredColorScheme(.light)
        }
        .alert(language.text("account.logout_confirm_title"), isPresented: $showLogoutConfirm) {
            Button(language.text("account.logout_button"), role: .destructive) {
                Task { await license.logout() }
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("account.logout_confirm_msg"))
        }
        .onAppear {
            AppContainerScanner.shared.prewarmOnLaunch()
        }
    }
}
