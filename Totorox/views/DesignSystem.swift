import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - App Theme Mode & Window Style Synchronization

enum AppThemeMode: String, CaseIterable, Identifiable, Sendable {
    case light = "light"
    case dark = "dark"

    static let storageKey = "totorox.appearance.themeMode"

    var id: String { rawValue }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var uiInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var iconName: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    func displayTitle(for language: AppLanguage) -> String {
        switch self {
        case .light: return language.text("settings.theme_light")
        case .dark: return language.text("settings.theme_dark")
        }
    }
}

/// Quản lý giao diện Sáng / Tối đồng bộ trên toàn bộ `UIWindow` và SwiftUI view tree.
/// Chặn hoàn toàn lỗi iOS bật sẵn Dark Mode làm `TextField` / `Alert` / `Sheet` bị lệch màu chữ.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var mode: AppThemeMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: AppThemeMode.storageKey)
            if applyToUIKitWindows {
                applyToAllWindows()
            }
        }
    }

    private let defaults: UserDefaults
    private let applyToUIKitWindows: Bool
    private var windowObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, applyToUIKitWindows: Bool = true) {
        self.defaults = defaults
        self.applyToUIKitWindows = applyToUIKitWindows
        let raw = defaults.string(forKey: AppThemeMode.storageKey) ?? AppThemeMode.light.rawValue
        self.mode = AppThemeMode(rawValue: raw) ?? .light

        if applyToUIKitWindows {
            applyToAllWindows()
            registerWindowObservers()
        }
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func toggle() {
        withAnimation(.easeInOut(duration: 0.22)) {
            mode = (mode == .light) ? .dark : .light
        }
    }

    func applyToAllWindows() {
        let targetStyle = mode.uiInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != targetStyle {
                window.overrideUserInterfaceStyle = targetStyle
            }
        }
    }

    private func registerWindowObservers() {
        let names: [Notification.Name] = [
            UIScene.willConnectNotification,
            UIWindow.didBecomeVisibleNotification,
            UIWindow.didBecomeKeyNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyToAllWindows()
                }
            }
            windowObservers.append(token)
        }
    }
}

// MARK: - Totorox Adaptive Design System (Light & Dark)

enum TotoroxTheme {
    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// Mint Green primary accent (#5BB9A8 light / #4EC9B5 dark)
    static let mintAccent = dynamicColor(
        light: UIColor(red: 0.357, green: 0.725, blue: 0.659, alpha: 1.0),
        dark: UIColor(red: 0.306, green: 0.788, blue: 0.710, alpha: 1.0)
    )

    /// Input / Search / Secondary container surface (#F4F3FD light / #212836 dark)
    static let searchBackground = dynamicColor(
        light: UIColor(red: 0.957, green: 0.953, blue: 0.992, alpha: 1.0),
        dark: UIColor(red: 0.129, green: 0.157, blue: 0.212, alpha: 1.0)
    )

    /// Root page canvas (#F9FAFC light / #0D1117 dark)
    static let pageBackground = dynamicColor(
        light: UIColor(red: 0.976, green: 0.980, blue: 0.988, alpha: 1.0),
        dark: UIColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1.0)
    )

    /// Elevated card surface (#FFFFFF light / #161B24 dark)
    static let cardBackground = dynamicColor(
        light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0),
        dark: UIColor(red: 0.086, green: 0.106, blue: 0.141, alpha: 1.0)
    )

    /// Peach badge background (#FFEFEA light / #3D211B dark)
    static let badgeBackground = dynamicColor(
        light: UIColor(red: 1.000, green: 0.937, blue: 0.918, alpha: 1.0),
        dark: UIColor(red: 0.239, green: 0.129, blue: 0.106, alpha: 1.0)
    )

    /// Salmon badge text (#FF7A59 light / #FF8F73 dark)
    static let badgeText = dynamicColor(
        light: UIColor(red: 1.000, green: 0.478, blue: 0.349, alpha: 1.0),
        dark: UIColor(red: 1.000, green: 0.561, blue: 0.451, alpha: 1.0)
    )

    /// High-contrast primary text (WCAG AAA)
    static let textPrimary = dynamicColor(
        light: UIColor(red: 0.118, green: 0.141, blue: 0.188, alpha: 1.0),
        dark: UIColor(red: 0.945, green: 0.961, blue: 0.976, alpha: 1.0)
    )

    /// Readable secondary text (WCAG AA+)
    static let textSecondary = dynamicColor(
        light: UIColor(red: 0.431, green: 0.467, blue: 0.529, alpha: 1.0),
        dark: UIColor(red: 0.580, green: 0.639, blue: 0.722, alpha: 1.0)
    )

    /// Hairline divider
    static let dividerColor = dynamicColor(
        light: UIColor(red: 0.918, green: 0.925, blue: 0.949, alpha: 1.0),
        dark: UIColor(red: 0.145, green: 0.180, blue: 0.243, alpha: 1.0)
    )

    /// Subtle card border (crisp edge definition in Dark Mode)
    static let cardBorderColor = dynamicColor(
        light: UIColor(white: 0.0, alpha: 0.04),
        dark: UIColor(red: 0.196, green: 0.247, blue: 0.337, alpha: 0.72)
    )

    /// Disabled CTA button fill & foreground
    static let disabledBackground = dynamicColor(
        light: UIColor(red: 0.906, green: 0.918, blue: 0.949, alpha: 1.0),
        dark: UIColor(red: 0.157, green: 0.192, blue: 0.255, alpha: 1.0)
    )

    static let disabledText = dynamicColor(
        light: UIColor(red: 0.520, green: 0.557, blue: 0.624, alpha: 1.0),
        dark: UIColor(red: 0.451, green: 0.510, blue: 0.600, alpha: 1.0)
    )

    /// Card elevation shadow
    static let shadowColor = dynamicColor(
        light: UIColor(white: 0.0, alpha: 0.04),
        dark: UIColor(white: 0.0, alpha: 0.26)
    )
}

// MARK: - Card Styling Modifier

struct TotoroxCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(TotoroxTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(TotoroxTheme.cardBorderColor, lineWidth: 0.8)
            )
            .shadow(color: TotoroxTheme.shadowColor, radius: 8, x: 0, y: 3)
    }
}

extension View {
    func totoroxCard(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(TotoroxCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Reusable Header Component

struct TotoroxTopHeader: View {
    var onSettingsTapped: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Official App Logo with standard iOS squircle corner radius
            AppLogo(size: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 42 * 0.22, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)

            // App Title
            VStack(alignment: .leading, spacing: 2) {
                Text("Totorox")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
            }

            Spacer()

            // Settings Gear Button
            Button(action: onSettingsTapped) {
                ZStack {
                    Circle()
                        .fill(TotoroxTheme.searchBackground)
                        .frame(width: 40, height: 40)
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Account Status Strip

struct AccountStatusBar: View {
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.appLanguage) private var language

    var onRedeemTapped: () -> Void
    var onLogoutTapped: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Username + Expiry + Quota
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(license.hasActivePlan ? TotoroxTheme.mintAccent : Color.orange)

                Text(license.username.isEmpty ? "—" : license.username)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .lineLimit(1)

                Text("•")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))

                Text(license.formattedExpiry(language: language, short: true))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(license.hasActivePlan ? TotoroxTheme.textSecondary : Color.orange)
                    .lineLimit(1)

                Text(license.formattedRemainingUses(language: language))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(license.hasActivePlan ? TotoroxTheme.mintAccent : Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((license.hasActivePlan ? TotoroxTheme.mintAccent : Color.orange).opacity(0.12))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onRedeemTapped) {
                HStack(spacing: 3) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(language.text("account.status_redeem"))
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(TotoroxTheme.mintAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onLogoutTapped) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(6)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("account.logout_button"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(TotoroxTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TotoroxTheme.dividerColor, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Hardware UDID Verification Card

struct DeviceVerificationCard: View {
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.appLanguage) private var language
    @Environment(\.openURL) private var openURL

    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: compact ? 34 : 38, height: compact ? 34 : 38)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("udid.verify.title"))
                        .font(.system(size: compact ? 13 : 14, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                    Text(language.text("udid.verify.subtitle"))
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !compact {
                VStack(alignment: .leading, spacing: 5) {
                    stepRow(number: "1", text: language.text("udid.verify.step1"))
                    stepRow(number: "2", text: language.text("udid.verify.step2"))
                    stepRow(number: "3", text: language.text("udid.verify.step3"))
                }
                .padding(10)
                .background(TotoroxTheme.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                guard let url = license.prepareDeviceProfileURL() else { return }
                openURL(url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "safari.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(language.text("udid.verify.button"))
                        .font(.system(size: compact ? 13 : 14, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 38 : 44)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.15, green: 0.39, blue: 0.92), Color(red: 0.23, green: 0.51, blue: 0.96)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(license.deviceProfileURL() == nil)
        }
        .padding(compact ? 12 : 16)
        .background(TotoroxTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.orange)
                .frame(width: 18, height: 18)
                .background(Color.orange.opacity(0.14))
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Reusable Search Bar Component

struct TotoroxSearchBar: View {
    @Binding var text: String
    var placeholder: String? = nil
    var onFilterTapped: (() -> Void)? = nil
    @Environment(\.appLanguage) private var language

    var body: some View {
        let promptText = placeholder ?? language.text("search.default_placeholder")
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TotoroxTheme.textSecondary)

            TextField(
                "",
                text: $text,
                prompt: Text(promptText).foregroundColor(TotoroxTheme.textSecondary)
            )
            .font(.system(size: 15))
            .foregroundStyle(TotoroxTheme.textPrimary)
            .tint(TotoroxTheme.mintAccent)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
            }

            if let onFilter = onFilterTapped {
                Button(action: onFilter) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(TotoroxTheme.searchBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - Reusable Pill Badge Component

struct TotoroxBadge: View {
    let title: String
    var isAccent: Bool = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isAccent ? .white : TotoroxTheme.badgeText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isAccent ? TotoroxTheme.mintAccent : TotoroxTheme.badgeBackground)
            .clipShape(Capsule())
    }
}

// MARK: - Reusable Primary Button

struct TotoroxPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        let activeAppearance = isEnabled || isLoading
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.9)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(activeAppearance ? TotoroxTheme.mintAccent : TotoroxTheme.disabledBackground)
            .foregroundColor(activeAppearance ? .white : TotoroxTheme.disabledText)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: activeAppearance ? TotoroxTheme.mintAccent.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
        }
        .disabled(!isEnabled || isLoading)
        .buttonStyle(.plain)
    }
}

// MARK: - Reusable Pill Selector

struct TotoroxPillSelector<T: Hashable>: View {
    let items: [T]
    @Binding var selected: T
    let titleProvider: (T) -> String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                let isSelected = (item == selected)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selected = item
                    }
                }) {
                    Text(titleProvider(item))
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .white : TotoroxTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Legacy Compatibility Shims (AppTheme, AppCardBorder, AppRowIcon, AppSearchField, AppLogo)

enum AppTheme {
    static var accent: Color { TotoroxTheme.mintAccent }
    static var pageBackground: Color { TotoroxTheme.pageBackground }
    static var consoleBackground: Color { TotoroxTheme.pageBackground }
    static let pageInset: CGFloat = 16
    static let rowIconSize: CGFloat = 17
    static let rowIconFrame: CGFloat = 28
    static let fileRowIconSize: CGFloat = 17
    static let fileRowIconFrame: CGFloat = 30
    static let fileRowHeight: CGFloat = 60
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 18
    static let contentCardCornerRadius: CGFloat = 20
    static let contentCardInset: CGFloat = 16
    static let contentCardPadding: CGFloat = 16
}

struct AppCardBorder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.contentCardCornerRadius, style: .continuous)
            .strokeBorder(Color(uiColor: .separator).opacity(0.22), lineWidth: 0.5)
            .accessibilityHidden(true)
    }
}

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var clearLabel: String = "Clear search"

    init(text: Binding<String>, placeholder: String = "Search", clearLabel: String = "Clear search") {
        self._text = text
        self.placeholder = placeholder
        self.clearLabel = clearLabel
    }

    init(text: Binding<String>, prompt: String, clearLabel: String = "Clear search") {
        self._text = text
        self.placeholder = prompt
        self.clearLabel = clearLabel
    }

    var body: some View {
        TotoroxSearchBar(text: $text, placeholder: placeholder)
    }
}

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = UIImage(named: "AppAvatar") ?? UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Share Sheet Helper

struct ActivityViewControllerWrapper: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Document Picker Helper

struct DocumentPickerWrapper: UIViewControllerRepresentable {
    var allowedContentTypes: [UTType] = [.data, .item]
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let first = urls.first {
                onPick(first)
            }
        }
    }
}

