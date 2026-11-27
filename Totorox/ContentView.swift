import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
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
        .preferredColorScheme(themeManager.mode.colorScheme)
    }

    /// Chưa đăng nhập tài khoản thì chỉ hiện màn hình Đăng nhập / Đăng ký.
    private var activationBody: some View {
        ActivationView()
    }

    private var mainAppBody: some View {
        ZStack {
            TotoroxTheme.pageBackground
                .ignoresSafeArea(.all)

            VStack(spacing: 0) {
                TotoroxTopHeader {
                    showSettings = true
                }

            if !license.hasActivePackage {
                AccountStatusBar(
                    onRedeemTapped: { showRedeemSheet = true },
                    onLogoutTapped: { showLogoutConfirm = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !license.isDeviceVerified {
                DeviceVerificationCard(compact: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                switch navCoordinator.selectedTab {
                case .overwrite:
                    OverwriteFileView()
                case .folders:
                    FolderExplorerView()
                case .patch:
                    PatchConverterView()
                case .catalog, .merge:
                    CatalogView()
                case .mods:
                    // Kho Mod đang để ở trạng thái nháp trên bản 3.0, fallback về Đè file.
                    OverwriteFileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TotoroxTabBar(selectedTab: $navCoordinator.selectedTab)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: license.hasActivePackage)
        .animation(.easeInOut(duration: 0.25), value: license.isDeviceVerified)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .sheet(isPresented: $showLogs) {
            LogView()
                .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .sheet(isPresented: $showRedeemSheet) {
            RedeemCodeSheet()
                .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .alert(language.text("account.logout_confirm_title"), isPresented: $showLogoutConfirm) {
            Button(language.text("account.logout_button"), role: .destructive) {
                Task { await license.logout() }
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("account.logout_confirm_msg"))
        }
        .alert(item: rootUDIDAlertBinding) { alertItem in
            Alert(
                title: Text(alertItem.title),
                message: Text(alertItem.message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
        .onAppear {
            Self.purgeLegacyCustomWallpaperIfNeeded()
            AppContainerScanner.shared.prewarmOnLaunch()
        }
    }

    private static func purgeLegacyCustomWallpaperIfNeeded() {
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let legacyDir = base.appendingPathComponent("TotoroxWallpaper", isDirectory: true)
            if fm.fileExists(atPath: legacyDir.path) {
                try? fm.removeItem(at: legacyDir)
            }
        }
    }

    private var rootUDIDAlertBinding: Binding<LicenseManager.UDIDVerificationAlert?> {
        Binding(
            get: { (!showSettings && !showRedeemSheet) ? license.udidVerificationAlert : nil },
            set: { newValue in
                if newValue == nil {
                    license.udidVerificationAlert = nil
                }
            }
        )
    }
}
