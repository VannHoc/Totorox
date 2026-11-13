import SwiftUI

/// Khối "Cấu hình máy chủ" dùng chung cho `ActivationView` và `SettingsView`.
///
/// Bấm vào hàng tiêu đề để mở ô nhập URL backend; URL hợp lệ được lưu vào
/// `UserDefaults` (xem `APIService.setBaseURL(_:)`) và áp dụng ngay cho mọi request sau đó.
struct ServerConfigView: View {
    @Environment(\.appLanguage) private var language

    @State private var isExpanded = false
    @State private var urlInput = ""
    @State private var errorMessage: String?
    @State private var didSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                editor
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .totoroxCard()
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
                if isExpanded {
                    urlInput = APIService.shared.baseURL.absoluteString
                    errorMessage = nil
                    didSave = false
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 16))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("server.config_btn"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textPrimary)

                    Text(APIService.shared.baseURL.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12))
                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.text("server.config_hint"))
                .font(.system(size: 11))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(language.text("server.config_placeholder"), text: $urlInput)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if didSave {
                Text(language.text("server.config_saved"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
            }

            TotoroxPrimaryButton(
                title: language.text("server.config_save"),
                icon: "checkmark.circle.fill",
                isEnabled: !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                save()
            }

            Button {
                APIService.shared.resetBaseURL()
                urlInput = APIService.shared.baseURL.absoluteString
                errorMessage = nil
                didSave = false
            } label: {
                Text(language.text("server.config_reset"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TotoroxTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func save() {
        if APIService.shared.updateBaseURL(urlInput) {
            urlInput = APIService.shared.baseURL.absoluteString
            errorMessage = nil
            didSave = true
        } else {
            errorMessage = language.text("server.config_invalid")
            didSave = false
        }
    }
}
