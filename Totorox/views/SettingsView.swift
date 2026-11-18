import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.appLanguage) private var language
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.systemDefault.rawValue
    @AppStorage(WorseQuery.enabledDefaultsKey) private var useWorseQuery = true
    @State private var showLogs = false
    @State private var showClearCacheAlert = false
    @State private var cacheClearedMessage = false
    @State private var didCopyUDID = false
    @State private var showRedeemSheet = false
    @State private var showLogoutConfirm = false

    private var appVersionDisplay: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0"
        return language.text("common.version", version)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header Card with Totoro Logo & Title
                    VStack(spacing: 12) {
                        AppLogo(size: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: 80 * 0.22, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

                        VStack(spacing: 4) {
                            Text("Totorox")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)

                            Text(appVersionDisplay)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TotoroxTheme.textSecondary)

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(TotoroxTheme.mintAccent)
                                    .frame(width: 8, height: 8)
                                Text(language.text("settings.engine_status"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(TotoroxTheme.mintAccent.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .totoroxCard()

                    // License & Device UDID Card
                    licenseAndDeviceCard

                    if !license.isDeviceVerified {
                        DeviceVerificationCard(compact: false)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Appearance (Light / Dark Mode) & Language Selection
                    VStack(alignment: .leading, spacing: 14) {
                        Text(language.text("settings.section_appearance"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        HStack(spacing: 10) {
                            ForEach(AppThemeMode.allCases) { mode in
                                let isSelected = (themeManager.mode == mode)
                                Button {
                                    guard themeManager.mode != mode else { return }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        themeManager.mode = mode
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: mode.iconName)
                                            .font(.system(size: 15, weight: .semibold))
                                        Text(mode.displayTitle(for: language))
                                            .font(.system(size: 13.5, weight: .bold))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(isSelected ? .white : TotoroxTheme.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(
                                                isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.cardBorderColor,
                                                lineWidth: 1
                                            )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()

                        Text(language.text("settings.section_language"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .font(.system(size: 16))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                                .frame(width: 24)

                            Picker("", selection: $languageCode) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .totoroxCard()

                    // Project & Identity Information
                    VStack(alignment: .leading, spacing: 14) {
                        Text(language.text("settings.section_project"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        settingsRow(label: language.text("settings.founder_label"), value: "VannHoc", icon: "person.crop.circle.fill", isAccent: true)
                        Divider()
                        settingsRow(label: language.text("settings.app_name_label"), value: "Totorox", icon: "app.badge.fill")
                        Divider()
                        settingsRow(label: language.text("settings.bundle_id_label"), value: "com.apple.mobile.MobileHouseArrest", icon: "barcode", isVertical: true)
                        Divider()
                        settingsRow(label: language.text("settings.supported_system"), value: "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))", icon: "iphone", isVertical: true)
                    }
                    .totoroxCard()

                    // Engine & Sandbox Diagnostics
                    VStack(alignment: .leading, spacing: 14) {
                        Text(language.text("settings.section_engine"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        settingsRow(label: language.text("settings.container_access"), value: "Active", icon: "checkmark.shield.fill", isAccent: true)
                        Divider()
                        settingsRow(label: language.text("settings.file_io_rule"), value: language.text("settings.file_io_rule_value"), icon: "bolt.fill")
                        Divider()
                        settingsRow(
                            label: language.text("settings.theme_mode"),
                            value: themeManager.mode.displayTitle(for: language),
                            icon: themeManager.mode.iconName,
                            isAccent: true
                        )
                        Divider()
                        worseQueryRow
                    }
                    .totoroxCard()

                    // Maintenance & Diagnostics Actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text(language.text("settings.section_maintenance"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        // Clear Cache Button
                        Button {
                            showClearCacheAlert = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "trash.fill")
                                    .foregroundStyle(Color.orange)
                                    .frame(width: 24)
                                Text(language.text("settings.clear_cache_btn"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(TotoroxTheme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
                            }
                            .padding(.vertical, 4)
                        }

                        Divider()

                        // View System Logs Button
                        Button {
                            showLogs = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                    .frame(width: 24)
                                Text(language.text("settings.view_logs_btn"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(TotoroxTheme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .totoroxCard()

                    // Credits & Authors
                    VStack(alignment: .leading, spacing: 12) {
                        Text(language.text("settings.section_credits"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        // Link 1: Tác giả
                        TotoroxLinkRow(
                            urlString: "https://github.com/VannHoc",
                            title: "VannHoc",
                            subtitle: language.text("settings.founder_subtitle")
                        )

                        Divider()

                        // Link 2: Telegram tác giả
                        TotoroxLinkRow(
                            urlString: "https://t.me/milototoro",
                            title: language.text("settings.author_telegram"),
                            subtitle: "Phạm Văn Học"
                        )

                        Divider()

                        // Dòng bản quyền
                        Text(language.text("settings.copyright_footer"))
                            .font(.system(size: 11))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    }
                    .totoroxCard()
                }
                .padding(16)
                .animation(.easeInOut(duration: 0.25), value: license.hasActivePackage)
                .animation(.easeInOut(duration: 0.25), value: license.isDeviceVerified)
            }
            .background(TotoroxTheme.pageBackground)
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.bold)
                        .foregroundColor(TotoroxTheme.mintAccent)
                }
            }
            .sheet(isPresented: $showLogs) {
                LogView()
                    .preferredColorScheme(themeManager.mode.colorScheme)
            }
            .sheet(isPresented: $showRedeemSheet) {
                RedeemCodeSheet()
                    .preferredColorScheme(themeManager.mode.colorScheme)
            }
            .alert(language.text("settings.clear_cache_confirm_title"), isPresented: $showClearCacheAlert) {
                Button(language.text("common.delete"), role: .destructive) {
                    clearTemporaryCache()
                }
                Button(language.text("common.cancel"), role: .cancel) {}
            } message: {
                Text(language.text("settings.clear_cache_confirm_msg"))
            }
            .alert(language.text("settings.clear_cache_success"), isPresented: $cacheClearedMessage) {
                Button(language.text("common.ok"), role: .cancel) {}
            }
            .alert(language.text("account.logout_confirm_title"), isPresented: $showLogoutConfirm) {
                Button(language.text("account.logout_button"), role: .destructive) {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        await license.logout()
                    }
                }
                Button(language.text("common.cancel"), role: .cancel) {}
            } message: {
                Text(language.text("account.logout_confirm_msg"))
            }
            .alert(item: settingsUDIDAlertBinding) { alertItem in
                Alert(
                    title: Text(alertItem.title),
                    message: Text(alertItem.message),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
        }
    }

    private var settingsUDIDAlertBinding: Binding<LicenseManager.UDIDVerificationAlert?> {
        Binding(
            get: { !showRedeemSheet ? license.udidVerificationAlert : nil },
            set: { newValue in
                if newValue == nil {
                    license.udidVerificationAlert = nil
                }
            }
        )
    }

    private var licenseAndDeviceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(language.text("account.section_title"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textSecondary)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(license.hasActivePackage ? TotoroxTheme.mintAccent : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(license.hasActivePackage ? language.text("account.status_active_plan") : language.text("account.status_no_plan"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(license.hasActivePackage ? TotoroxTheme.mintAccent : Color.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((license.hasActivePackage ? TotoroxTheme.mintAccent : Color.orange).opacity(0.12))
                .clipShape(Capsule())
            }

            settingsRow(
                label: language.text("account.username_label"),
                value: license.username.isEmpty ? "—" : license.username,
                icon: "person.crop.circle.fill",
                isAccent: true
            )

            if license.hasActivePackage {
                Divider()

                settingsRow(
                    label: language.text("settings.license_expires_label"),
                    value: license.formattedExpiry(language: language, short: false),
                    icon: "calendar.badge.clock"
                )

                Divider()

                settingsRow(
                    label: language.text("settings.license_remaining_label"),
                    value: license.formattedRemainingUses(language: language),
                    icon: "speedometer",
                    isAccent: true
                )

                if license.isUnlimited,
                   let dailyUsed = license.currentUser?.dailyUsed,
                   let dailyCap = license.currentUser?.dailyCap {
                    Divider()
                    settingsRow(
                        label: language.text("account.daily_usage_label"),
                        value: "\(dailyUsed) / \(dailyCap)",
                        icon: "shield.checkered"
                    )
                }
            }

            Divider()

            // Redeem Code Button
            Button {
                showRedeemSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "ticket.fill")
                        .foregroundStyle(TotoroxTheme.mintAccent)
                        .frame(width: 24)
                    Text(license.hasActivePackage
                         ? language.text("account.redeem_more_button")
                         : language.text("account.redeem_button"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
                }
                .padding(.vertical, 4)
            }

            if license.hasActivePackage {
                Divider()

                if license.isDeviceVerified {
                    // Device Real Hardware UDID
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "cpu")
                                .font(.system(size: 16))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                                .frame(width: 24)

                            Text(language.text("activation.device_udid"))
                                .font(.system(size: 14))
                                .foregroundStyle(TotoroxTheme.textPrimary)

                            Spacer()

                            copyBadgeButton(
                                copied: didCopyUDID,
                                copiedLabel: language.text("activation.copied_udid")
                            ) {
                                copyToClipboard(license.deviceIdentifier)
                            }
                        }

                        Text(license.deviceIdentifier)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .padding(.leading, 34)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(language.text("settings.udid_verified_profile"))
                            .font(.system(size: 11))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                            .padding(.leading, 34)
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.orange)
                            .frame(width: 24)
                        Text(language.text("udid.verify.not_verified_short"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.orange)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }

                Divider()

                Button {
                    Task { await license.refresh() }
                } label: {
                    HStack(spacing: 12) {
                        if license.isRefreshing {
                            ProgressView()
                                .frame(width: 24)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(TotoroxTheme.mintAccent)
                                .frame(width: 24)
                        }
                        Text(language.text("settings.license_refresh_btn"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(license.isRefreshing)
            }

            Divider()

            // Logout row inside Account & Package card
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(Color.red)
                        .frame(width: 24)
                    Text(language.text("account.logout_button"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.red)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .totoroxCard()
    }

    private func copyBadgeButton(copied: Bool, copiedLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text(copied ? copiedLabel : language.text("logs.copy"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(TotoroxTheme.mintAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(TotoroxTheme.mintAccent.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func copyToClipboard(_ value: String) {
        UIPasteboard.general.string = value
        withAnimation(.easeInOut(duration: 0.2)) {
            didCopyUDID = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                didCopyUDID = false
            }
        }
    }

    private var worseQueryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 16))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("settings.worse_query_label"))
                    .font(.system(size: 14))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                Text(language.text(WorseQuery.statusLocalizationKey(enabled: useWorseQuery)))
                    .font(.system(size: 11))
                    .foregroundStyle(TotoroxTheme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $useWorseQuery)
                .labelsHidden()
                .tint(TotoroxTheme.mintAccent)
                .onChange(of: useWorseQuery) { _ in
                    // Re-evaluate Tier 4 immediately and forget the
                    // "bad_query is blocked" memo, so turning the toggle off
                    // restores the old behaviour without a relaunch.
                    // (`resetBlockedState` also drops the cached group.)
                    SandboxGrantRouter.resetBlockedState()
                }
        }
        .padding(.vertical, 2)
    }

    private func settingsRow(label: String, value: String, icon: String, isAccent: Bool = false, isVertical: Bool = false) -> some View {
        Group {
            if isVertical {
                // Bố cục 2 tầng cho các dòng có chữ dài (Bundle ID, Hệ thống)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.system(size: 16))
                            .foregroundStyle(isAccent ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)
                            .frame(width: 24)

                        Text(label)
                            .font(.system(size: 14))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                    }

                    Text(value)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(isAccent ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)
                        .padding(.leading, 34) // Thụt lề thẳng hàng với chữ nhãn
                        .textSelection(.enabled) // Cho phép nhấn giữ sao chép mã nếu cần
                }
                .padding(.vertical, 2)
            } else {
                // Bố cục 1 tầng ngang như cũ cho các dòng ngắn
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(isAccent ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)
                        .frame(width: 24)

                    Text(label)
                        .font(.system(size: 14))
                        .foregroundStyle(TotoroxTheme.textPrimary)

                    Spacer()

                    Text(value)
                        .font(.system(size: 13, weight: isAccent ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(isAccent ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func clearTemporaryCache() {
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory
            if let items = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                for item in items {
                    try? fm.removeItem(at: item)
                }
            }
            ContainerMetadataCache.shared.clear()
            ModStoreCache.shared.clearAll()
            await MainActor.run {
                self.cacheClearedMessage = true
            }
        }
    }
}

struct TotoroxLinkRow: View {
    var urlString: String
    var title: String
    var subtitle: String
    var icon: String? = nil // Thích thì truyền icon, không thì thôi
    
    var body: some View {
        if let validURL = URL(string: urlString) {
            Link(destination: validURL) {
                HStack(spacing: 12) {
                    if let iconName = icon {
                        Image(systemName: iconName)
                            .foregroundStyle(TotoroxTheme.mintAccent)
                            .frame(width: 20)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                }
            }
        }
    }
}