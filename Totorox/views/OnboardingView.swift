import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case language = 0
    case versions = 1

    var next: OnboardingStep? { Self(rawValue: rawValue + 1) }
    var prev: OnboardingStep? { Self(rawValue: rawValue - 1) }
}

private enum OnboardingNavigationDirection {
    case forward
    case backward
}

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.systemDefault.rawValue
    @State private var step: OnboardingStep = .language
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    var onComplete: () -> Void

    private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? .english }
    private var motionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                pageContent
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls
        }
        .tint(AppTheme.accent)
    }

    // MARK: - Progress (2 bars only)

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? AppTheme.accent : TotoroxTheme.textSecondary.opacity(0.22))
                    .frame(height: 4)
                    .frame(maxWidth: s == step ? 36 : 22)
                    .animation(motionAnimation, value: step)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: 200)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(AppTheme.pageBackground)
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                if s == step {
                    ScrollView(.vertical, showsIndicators: false) {
                        page(for: s)
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 28)
                    }
                    .transition(pageTransition)
                    .id(s.rawValue)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertionEdge: Edge = navigationDirection == .forward ? .trailing : .leading
        let removalEdge: Edge = navigationDirection == .forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private func page(for s: OnboardingStep) -> some View {
        switch s {
        case .language: languagePage
        case .versions: versionsPage
        }
    }

    // MARK: - Step 1: Language

    private var languagePage: some View {
        VStack(spacing: 26) {
            AppLogo(size: 72)

            VStack(spacing: 8) {
                Text(language.text("onboarding.language_title"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(language.text("onboarding.language_subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                ForEach(AppLanguage.allCases) { option in
                    let isSelected = languageCode == option.rawValue
                    Button {
                        languageCode = option.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Text(option.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? AppTheme.accent : TotoroxTheme.textSecondary.opacity(0.5))
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(TotoroxTheme.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(isSelected ? AppTheme.accent : TotoroxTheme.cardBorderColor, lineWidth: 1)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .animation(motionAnimation, value: languageCode)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Step 2: Supported iOS

    private var versionsPage: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(language.text("onboarding.versions_title"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(language.text("onboarding.versions_subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                versionRow(title: "iOS 16", value: "Full", badge: true)
                Divider().overlay(TotoroxTheme.dividerColor)
                versionRow(title: "iOS 17", value: "17.0 – 17.7")
                Divider().overlay(TotoroxTheme.dividerColor)
                versionRow(title: "iOS 18", value: "18.0 – 18.7.1")
                Divider().overlay(TotoroxTheme.dividerColor)
                versionRow(title: "iOS 26+", value: "26.0 – 27.3 Beta 1")
            }
            .frame(maxWidth: .infinity, alignment: .stretch)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TotoroxTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(TotoroxTheme.cardBorderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)

            Text(language.text("onboarding.versions_footer"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func versionRow(title: String, value: String, badge: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(TotoroxTheme.textPrimary)
            Spacer(minLength: 8)
            if badge {
                Text(value == "Full" ? language.text("onboarding.full") : value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
            } else {
                Text(value)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(TotoroxTheme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                controlButtons
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(TotoroxTheme.cardBackground)
        .overlay(alignment: .top) {
            Divider().overlay(TotoroxTheme.dividerColor)
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        if step != .language {
            Button {
                guard let previousStep = step.prev else { return }
                navigate(to: previousStep, direction: .backward)
            } label: {
                Text(language.text("common.back"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }

        Button {
            if let nextStep = step.next {
                navigate(to: nextStep, direction: .forward)
            } else {
                onComplete()
            }
        } label: {
            Text(language.text(step == .versions ? "onboarding.get_started" : "onboarding.continue"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func navigate(to destination: OnboardingStep, direction: OnboardingNavigationDirection) {
        withAnimation(motionAnimation) {
            navigationDirection = direction
            step = destination
        }
    }
}

enum OnboardingStore {
    static let completedVersionKey = "onboarding.completedVersion"
    static let completedFingerprintKey = "onboarding.completedFingerprint"

    static var currentVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    /// Per-install token: executable mtime changes on every overwrite even if version stays the same.
    static var bundleToken: String {
        if let exe = Bundle.main.executablePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe),
           let date = attrs[.modificationDate] as? Date {
            return String(Int(date.timeIntervalSince1970))
        }
        if let attrs = FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
           let date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) {
            return String(Int(date.timeIntervalSince1970))
        }
        return "0"
    }

    static var currentFingerprint: String { "\(currentVersion)#\(bundleToken)" }

    static var completedVersion: String? {
        UserDefaults.standard.string(forKey: completedVersionKey)
    }

    static var completedFingerprint: String? {
        UserDefaults.standard.string(forKey: completedFingerprintKey)
    }

    static func shouldShow() -> Bool {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--skip-onboarding") { return false }
        if ProcessInfo.processInfo.arguments.contains("--reset-onboarding") { return true }
#endif
        let fp = currentFingerprint
        if let stored = completedFingerprint, !stored.isEmpty {
            return stored != fp
        }
        // Migration: old installs only have completedVersion
        if let completed = completedVersion, !completed.isEmpty {
            if completed == currentVersion {
                // Same version, migrate silently — next overwrite will be detected via fingerprint
                UserDefaults.standard.set(fp, forKey: completedFingerprintKey)
                return false
            }
            return true
        }
        return true
    }

    static func markCompleted() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
        UserDefaults.standard.set(currentFingerprint, forKey: completedFingerprintKey)
    }
}
