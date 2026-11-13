import SwiftUI

/// License activation screen.
///
/// Phase 1: the screen exists and works against the backend, but it is **not** wired into
/// `App.swift` / `ContentView`, so the app keeps running without a server or a key.
/// When the server is live, present this view and gate the UI on `LicenseManager.status.isActive`.
struct ActivationView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var keyInput: String = ""
    @Environment(\.dismiss) private var dismiss

    var onActivated: (() -> Void)? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                header

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

                Text("Key được khoá theo thiết bị. Mỗi key chỉ dùng được trên một máy và không thể chuyển sang máy khác.")
                    .font(.system(size: 12))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .background(TotoroxTheme.pageBackground)
    }

    private var header: some View {
        VStack(spacing: 10) {
            AppLogo(size: 72)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

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
