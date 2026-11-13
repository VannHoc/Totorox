import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.systemDefault.rawValue
    @State private var showLogs = false
    @State private var showClearCacheAlert = false
    @State private var cacheClearedMessage = false

    private var appVersionDisplay: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(language.text("common.version", version)) (Build \(build))"
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

                    // Language Selection
                    VStack(alignment: .leading, spacing: 14) {
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
                        settingsRow(label: language.text("settings.theme_mode"), value: language.text("settings.theme_mode_value"), icon: "sun.max.fill")
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
                            subtitle: "Founder & Lead Developer"
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
        }
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