import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var showLogs = false
    @State private var showClearCacheAlert = false
    @State private var cacheClearedMessage = false

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

                            Text("Phiên bản 1.0 (Build 1)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TotoroxTheme.textSecondary)

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(TotoroxTheme.mintAccent)
                                    .frame(width: 8, height: 8)
                                Text("Engine: Totorox Ready")
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

                    // Project & Identity Information
                    VStack(alignment: .leading, spacing: 14) {
                        Text("THÔNG TIN DỰ ÁN")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        settingsRow(label: "Người sáng lập", value: "VannHoc", icon: "person.crop.circle.fill", isAccent: true)
                        Divider()
                        settingsRow(label: "Tên ứng dụng", value: "Totorox", icon: "app.badge.fill")
                        Divider()
                        settingsRow(label: "Bundle Identifier", value: "com.apple.mobile.MobileHouseArrest", icon: "barcode", isVertical: true)
                        Divider()
                        settingsRow(label: "Hệ thống hỗ trợ", value: "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))", icon: "iphone", isVertical: true)
                    }
                    .totoroxCard()

                    // Engine & Sandbox Diagnostics
                    VStack(alignment: .leading, spacing: 14) {
                        Text("ENGINE & QUYỀN TRUY CẬP")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        settingsRow(label: "MCM Container Access", value: "Active", icon: "checkmark.shield.fill", isAccent: true)
                        Divider()
                        settingsRow(label: "Quy tắc File I/O", value: "Chuẩn Windows", icon: "bolt.fill")
                        Divider()
                        settingsRow(label: "Chế độ Giao diện", value: "Light Mode", icon: "sun.max.fill")
                    }
                    .totoroxCard()

                    // Maintenance & Diagnostics Actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("BẢO TRÌ & CHẨN ĐOÁN")
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
                                Text("Dọn dẹp bộ nhớ tạm & Cache")
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
                                Text("Xem nhật ký hệ thống (Logs)")
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
                        Text("TÁC GIẢ & BẢN QUYỀN")
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
                            title: "Telegram tác giả",
                            subtitle: "@milototoro"
                        )

                        Divider()

                        // Link 3: Đối tác Telegram
                        TotoroxLinkRow(
                            urlString: "https://t.me/DucThaiAOV",
                            title: "Telegram đối tác",
                            subtitle: "Mod IOS"
                        )

                        Divider()

                        // Dòng bản quyền
                        Text("@2026 Totorox. Được phát triển bởi VannHoc.")
                            .font(.system(size: 11))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    }
                    .totoroxCard()
                }
                .padding(16)
            }
            .background(TotoroxTheme.pageBackground)
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                        .fontWeight(.bold)
                        .foregroundColor(TotoroxTheme.mintAccent)
                }
            }
            .sheet(isPresented: $showLogs) {
                LogView()
            }
            .alert("Xác nhận dọn dẹp cache?", isPresented: $showClearCacheAlert) {
                Button("Dọn dẹp", role: .destructive) {
                    clearTemporaryCache()
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Xóa toàn bộ các tệp giải nén tạm, bộ nhớ đệm chuyển đổi patch để giải phóng dung lượng.")
            }
            .alert("Đã dọn dẹp cache thành công", isPresented: $cacheClearedMessage) {
                Button("OK", role: .cancel) {}
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
            PatchWorkspaceService.cleanupGhostDuplicateWorkspaces(fileManager: fm)
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