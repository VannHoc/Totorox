import SwiftUI
import UIKit

/// Màn hình kích hoạt license.
///
/// Khi server backend sẵn sàng, màn hình này được hiển thị thay cho giao diện chính
/// nếu `LicenseManager.status.isActive == false`.
struct ActivationView: View {
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @State private var keyInput: String = ""

    /// Cấu hình server ẩn: chỉ hiện khi chạm 3 lần vào logo Totoro.
    @State private var isServerConfigVisible = false
    @State private var serverURLInput = ""
    @State private var serverConfigError: String?
    @State private var serverConfigSaved = false

    var onActivated: (() -> Void)? = nil

    /// Màn hình kích hoạt license — hiện khi `LicenseManager.status.isActive == false`.
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                header

                if isServerConfigVisible {
                    serverConfigCard
                        .padding(.horizontal, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(spacing: 12) {
                    TextField("TOTOROX-XXXX-XXXX-XXXX", text: $keyInput)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .keyboardType(.asciiCapable)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if case .rejected(let message) = license.status {
                        errorBanner(message)
                    }

                    TotoroxPrimaryButton(
                        title: "Kích hoạt thiết bị",
                        icon: "key.fill",
                        isLoading: license.status == .activating,
                        isEnabled: !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        activate()
                    }

                    if license.status.isActive {
                        activatedBanner
                    }
                }
                .totoroxCard()
                .padding(.horizontal, 16)

                deviceCard
            }
            .padding(.bottom, 24)
        }
        .background(TotoroxTheme.pageBackground)
    }

    private var header: some View {
        VStack(spacing: 10) {
            AppLogo(size: 72)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
                .onTapGesture(count: 3) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isServerConfigVisible.toggle()
                        if isServerConfigVisible {
                            serverURLInput = APIService.shared.baseURL.absoluteString
                            serverConfigError = nil
                            serverConfigSaved = false
                        }
                    }
                }

            Text("Kích hoạt Totorox")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(TotoroxTheme.textPrimary)

            Text("Nhập License Key để sử dụng các tính năng máy chủ.")
                .font(.system(size: 13))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, 28)
    }

    private var activatedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(TotoroxTheme.mintAccent)
            Text("Thiết bị này đã được kích hoạt.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TotoroxTheme.textPrimary)
            Spacer()
        }
        .padding(12)
        .background(TotoroxTheme.mintAccent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var serverConfigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.mintAccent)

                Text(language.text("server.config_btn"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.textPrimary)

                Spacer()
            }

            Text(language.text("server.config_hint"))
                .font(.system(size: 11))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(language.text("server.config_placeholder"), text: $serverURLInput)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let serverConfigError = serverConfigError {
                Text(serverConfigError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if serverConfigSaved {
                Text(language.text("server.config_saved"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
            }

            TotoroxPrimaryButton(
                title: language.text("server.config_save"),
                icon: "checkmark.circle.fill",
                isEnabled: !serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                saveServerURL()
            }
        }
        .totoroxCard()
    }

    private func saveServerURL() {
        if APIService.shared.updateBaseURL(serverURLInput) {
            serverURLInput = APIService.shared.baseURL.absoluteString
            serverConfigError = nil
            serverConfigSaved = true
        } else {
            serverConfigError = language.text("server.config_invalid")
            serverConfigSaved = false
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mã thiết bị (HWID)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TotoroxTheme.textSecondary)

            Text(license.deviceIdentifier)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(TotoroxTheme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .totoroxCard(padding: 12)
        .padding(.horizontal, 16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.red)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func activate() {
        Task {
            await license.activate(keyInput)
            if license.status.isActive {
                keyInput = ""
                onActivated?()
            }
        }
    }
}
