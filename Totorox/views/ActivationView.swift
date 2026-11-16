import SwiftUI

/// Màn hình Đăng nhập / Đăng ký tài khoản — hiện khi `LicenseManager.status.isAuthenticated == false`.
struct ActivationView: View {
    private enum AuthMode: String, CaseIterable, Identifiable {
        case login
        case register

        var id: String { rawValue }
    }

    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.appLanguage) private var language

    @State private var authMode: AuthMode = .login
    @State private var usernameInput: String = ""
    @State private var passwordInput: String = ""
    @State private var confirmPasswordInput: String = ""
    @State private var showPassword: Bool = false
    @State private var localError: String? = nil

    private var isBusy: Bool {
        if case .authenticating = license.status { return true }
        return false
    }

    private var activeErrorMessage: String? {
        if let localError, !localError.isEmpty {
            return localError
        }
        if case .rejected(let msg) = license.status {
            return msg
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                headerSection

                authCard

                supportLinksSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
        }
        .background(TotoroxTheme.pageBackground.ignoresSafeArea())
        .onChange(of: authMode) { _ in
            localError = nil
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            AppLogo(size: 72)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

            Text(authMode == .login ? language.text("auth.title_login") : language.text("auth.title_register"))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(TotoroxTheme.textPrimary)

            Text(authMode == .login ? language.text("auth.subtitle_login") : language.text("auth.subtitle_register"))
                .font(.system(size: 14))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.top, 12)
    }

    // MARK: - Login / Register Card

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $authMode) {
                Text(language.text("auth.mode_login")).tag(AuthMode.login)
                Text(language.text("auth.mode_register")).tag(AuthMode.register)
            }
            .pickerStyle(.segmented)

            // Username
            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("auth.username_label"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textSecondary)

                HStack(spacing: 10) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                    TextField(language.text("auth.username_placeholder"), text: $usernameInput)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Password
            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("auth.password_label"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textSecondary)

                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                    Group {
                        if showPassword {
                            TextField(language.text("auth.password_placeholder"), text: $passwordInput)
                        } else {
                            SecureField(language.text("auth.password_placeholder"), text: $passwordInput)
                        }
                    }
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Confirm Password (Register only)
            if authMode == .register {
                VStack(alignment: .leading, spacing: 6) {
                    Text(language.text("auth.confirm_password_label"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textSecondary)

                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                        Group {
                            if showPassword {
                                TextField(language.text("auth.confirm_password_placeholder"), text: $confirmPasswordInput)
                            } else {
                                SecureField(language.text("auth.confirm_password_placeholder"), text: $confirmPasswordInput)
                            }
                        }
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if let errorMessage = activeErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            TotoroxPrimaryButton(
                title: authMode == .login ? language.text("auth.login_button") : language.text("auth.register_button"),
                icon: authMode == .login ? "arrow.right.circle.fill" : "person.badge.plus",
                isLoading: isBusy,
                isEnabled: !isBusy && canSubmit
            ) {
                submitAuth()
            }
        }
        .totoroxCard()
    }

    private var canSubmit: Bool {
        let userOK = !usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let passOK = !passwordInput.isEmpty
        if authMode == .register {
            return userOK && passOK && !confirmPasswordInput.isEmpty
        }
        return userOK && passOK
    }

    // MARK: - Support Cards

    private var supportLinksSection: some View {
        VStack(spacing: 12) {
            supportLinkCard(
                url: URL(string: "https://totorox.io.vn")!,
                icon: "globe",
                accentColor: TotoroxTheme.mintAccent,
                title: language.text("activation.web_store_title"),
                subtitle: language.text("activation.web_store_subtitle")
            )

            supportLinkCard(
                url: URL(string: "https://t.me/milototoro")!,
                icon: "paperplane.fill",
                accentColor: .blue,
                title: language.text("activation.buy_support_title"),
                subtitle: language.text("activation.buy_support_subtitle")
            )
        }
    }

    private func supportLinkCard(
        url: URL,
        icon: String,
        accentColor: Color,
        title: String,
        subtitle: String
    ) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accentColor.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.textSecondary)
            }
            .totoroxCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func submitAuth() {
        localError = nil
        let cleanUser = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUser.count >= 3 else {
            localError = language.text("auth.error.username_short")
            return
        }
        guard passwordInput.count >= 6 else {
            localError = language.text("auth.error.password_short")
            return
        }
        if authMode == .register && passwordInput != confirmPasswordInput {
            localError = language.text("auth.error.password_mismatch")
            return
        }

        Task {
            if authMode == .login {
                _ = await license.login(username: cleanUser, password: passwordInput)
            } else {
                _ = await license.register(username: cleanUser, password: passwordInput)
            }
        }
    }
}

/// Modal Nhập mã kích hoạt (Redeem Code) dùng chung cho thanh trạng thái & SettingsView.
struct RedeemCodeSheet: View {
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language

    @State private var codeInput: String = ""
    @State private var isRedeeming: Bool = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "ticket.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(language.text("redeem.title"))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(TotoroxTheme.textPrimary)
                                Text("@\(license.username)")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                            }
                        }

                        Text(language.text("redeem.subtitle"))
                            .font(.system(size: 13))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .totoroxCard()

                    if !license.isDeviceVerified {
                        DeviceVerificationCard(compact: false)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(language.text("redeem.input_label"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        TextField(language.text("redeem.input_placeholder"), text: $codeInput)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        if let errorMessage {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.red)
                                Text(errorMessage)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.red)
                            }
                        }

                        if let successMessage {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                Text(successMessage)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                            }
                        }

                        TotoroxPrimaryButton(
                            title: language.text("redeem.submit_button"),
                            icon: "bolt.shield.fill",
                            isLoading: isRedeeming,
                            isEnabled: license.isDeviceVerified
                                && !isRedeeming
                                && !codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            submitRedeem()
                        }
                    }
                    .totoroxCard()
                }
                .padding(18)
                .animation(.easeInOut(duration: 0.2), value: license.isDeviceVerified)
            }
            .background(TotoroxTheme.pageBackground.ignoresSafeArea())
            .navigationTitle(language.text("redeem.nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.close")) { dismiss() }
                }
            }
            .alert(item: $license.udidVerificationAlert) { alertItem in
                Alert(
                    title: Text(alertItem.title),
                    message: Text(alertItem.message),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
        }
    }

    private func submitRedeem() {
        let clean = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isRedeeming = true
        errorMessage = nil
        successMessage = nil
        Task {
            let res = await license.redeem(code: clean)
            isRedeeming = false
            switch res {
            case .success(let payload):
                codeInput = ""
                let days = payload.addedDays ?? 0
                if (payload.addedUses ?? 0) == -1 || license.isUnlimited {
                    successMessage = language.text("redeem.success_unlimited", days)
                } else {
                    successMessage = language.text("redeem.success_finite", days, payload.addedUses ?? 0)
                }
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
    }
}
