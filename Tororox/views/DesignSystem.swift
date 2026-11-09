import SwiftUI
import UniformTypeIdentifiers

// MARK: - Totorox Modern Light Design System

enum TotoroxTheme {
    /// Mint Green primary accent (#5BB9A8)
    static let mintAccent = Color(red: 0.357, green: 0.725, blue: 0.659)
    /// Very soft lavender / pastel purple for search bar (#F4F3FD)
    static let searchBackground = Color(red: 0.957, green: 0.953, blue: 0.992)
    /// Pure white / off-white background (#F9FAFC)
    static let pageBackground = Color(red: 0.976, green: 0.980, blue: 0.988)
    /// Card background (#FFFFFF)
    static let cardBackground = Color.white
    /// Peach badge background (#FFEFEA)
    static let badgeBackground = Color(red: 1.000, green: 0.937, blue: 0.918)
    /// Orange / Salmon badge text (#FF7A59)
    static let badgeText = Color(red: 1.000, green: 0.478, blue: 0.349)
    /// Neutral text colors
    static let textPrimary = Color(red: 0.12, green: 0.14, blue: 0.18)
    static let textSecondary = Color(red: 0.55, green: 0.58, blue: 0.64)
    static let dividerColor = Color(red: 0.92, green: 0.93, blue: 0.96)
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
            .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
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

// MARK: - Reusable Search Bar Component

struct TotoroxSearchBar: View {
    @Binding var text: String
    var placeholder: String = "Tìm container hoặc tệp..."
    var onFilterTapped: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TotoroxTheme.textSecondary)

            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .foregroundStyle(TotoroxTheme.textPrimary)

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
            .background(isEnabled ? TotoroxTheme.mintAccent : Color.gray.opacity(0.3))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: isEnabled ? TotoroxTheme.mintAccent.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
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
    static var consoleBackground: Color { Color(red: 0.12, green: 0.14, blue: 0.18) }
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

