import SwiftUI

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
            // Circular Avatar
            ZStack {
                Circle()
                    .fill(TotoroxTheme.searchBackground)
                    .frame(width: 44, height: 44)
                
                if let avatarImg = UIImage(named: "AppAvatar") ?? UIImage(named: "avatar") ?? UIImage(named: "AppIcon") {
                    Image(uiImage: avatarImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(TotoroxTheme.mintAccent)
                }
            }
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)

            // Title and Engine status
            VStack(alignment: .leading, spacing: 2) {
                Text("Engine: 3105 Ready")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TotoroxTheme.textSecondary)

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

// MARK: - Share Sheet Helper

struct ActivityViewControllerWrapper: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
