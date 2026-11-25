import SwiftUI
import UIKit

@main
struct TotoroxApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var bootstrapManager = BootstrapManager.shared
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.systemDefault.rawValue
    @State private var showOnboarding = OnboardingStore.shouldShow()
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        #if !DEBUG
        totorox_harden_runtime()
        #endif
        setupLogCapture()
        log("app: Totorox launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
        ThemeManager.shared.applyToAllWindows()
        AppState.runEarlyPrivilegeInit()
        Task { await LicenseManager.shared.refresh() } // xác minh license ngay từ đầu
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .systemDefault
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // ContentView tự chặn cổng: chưa kích hoạt thì chỉ hiện ActivationView.
                ContentView()
                    .environmentObject(appState)
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .opacity(showOnboarding ? 0 : 1)
                    .allowsHitTesting(!showOnboarding)

                if showOnboarding {
                    OnboardingView {
                        Task { await LicenseManager.shared.refresh() }
                        OnboardingStore.markCompleted()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                            showOnboarding = false
                        }
                        appState.detectSupport()
                        checkForUpdate()
                    }
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
                    .zIndex(1)
                }
            }
            .preferredColorScheme(themeManager.mode.colorScheme)
            .tint(TotoroxTheme.mintAccent)
            // --- Force Update Kill Switch ---
            // Gọi bootstrap ngay khi app xuất hiện; chặn toàn màn hình nếu server yêu cầu.
            .task {
                await bootstrapManager.checkBootstrap()
            }
            .fullScreenCover(isPresented: $bootstrapManager.mustUpdate) {
                ForceUpdateView(
                    message: bootstrapManager.updateMessage,
                    downloadURL: bootstrapManager.updateURL
                )
            }
            // --------------------------------
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version)),
                    primaryButton: .default(Text(language.text("update.agree"))) {
                        UIApplication.shared.open(offer.url)
                    },
                    secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                        AppUpdateChecker.dismiss(version: offer.version)
                    }
                )
            }
            .onAppear {
                themeManager.applyToAllWindows()
                if OnboardingStore.shouldShow() {
                    showOnboarding = true
                } else {
                    appState.detectSupport()
                    checkForUpdate()
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    themeManager.applyToAllWindows()
                }
                guard phase == .active, !showOnboarding else { return }
                appState.detectSupport()
                Task {
                    await LicenseManager.shared.refresh()
                }
            }
            .onOpenURL { url in
                let isUDIDCallback = url.scheme?.lowercased() == "totorox"
                    && url.host?.lowercased() == "udid-verified"
                let hasSession = !LicenseManager.shared.authToken.isEmpty
                    || LicenseManager.shared.status.isAuthenticated
                if isUDIDCallback {
                    guard hasSession else { return }
                    AppNavigationCoordinator.shared.handleIncomingURL(url)
                    return
                }
                // Chưa đăng nhập tài khoản thì không xử lý deep link điều hướng / import file.
                guard LicenseManager.shared.status.isAuthenticated else { return }
                AppNavigationCoordinator.shared.handleIncomingURL(url)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false
    private static var didRunEarlyInit = false
    private static let earlyInitLock = NSLock()

    private static let exploitFinishLock = NSLock()
    private static var kernelExploitDidFinish = false
    static var kernelExploitFinished: Bool {
        exploitFinishLock.lock()
        defer { exploitFinishLock.unlock() }
        return kernelExploitDidFinish
    }
    private static func markKernelExploitFinished() {
        exploitFinishLock.lock()
        kernelExploitDidFinish = true
        exploitFinishLock.unlock()
    }

    static func runEarlyPrivilegeInit() {
        earlyInitLock.lock()
        guard !didRunEarlyInit else {
            earlyInitLock.unlock()
            return
        }
        didRunEarlyInit = true
        earlyInitLock.unlock()

        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Repair a stale <AppGroup>/Library/Caches symlink left by a crash
            // in the middle of a Tier 4 (worse_query) grant, then log what
            // Tier 4 can actually do on this device.
            WorseQuery.logProbe()
            WorseQuery.recoverAllGroups()
            let hasAccess = KernelExploit.hasSandboxAccess()
            log("app: early sandbox access status: \(hasAccess ? "ACTIVE" : "MHA-C2")")
            // Log-only health check (logic ported from WQHealth); no UI changes.
            // Reports patched builds / missing App Group / dead sandbox access
            // with a reason instead of leaving the user with an empty app list.
            StartupHealthCheck.run()

            // iOS 16–18 cần kernel exploit trước khi đọc được container khác.
            // Nếu exploit còn đang chạy, hoãn quét — completion của exploit sẽ
            // gọi prewarm. iOS 26+ dùng Tier 4 nên quét ngay như cũ.
            let v = AppInfo.versionTuple
            let exploitApplicable = KernelExploit.isApplicable(
                major: v.major, minor: v.minor, patch: v.patch, build: AppInfo.osBuild
            )
            if !exploitApplicable || AppState.kernelExploitFinished {
                AppContainerScanner.shared.prewarmOnLaunch()
            } else {
                log("app: postpone container scan until kernel exploit finishes")
            }
        }
    }

    init() {
        detectSupport()
    }

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else {
            if !exploitStatus.isSuccess {
                exploitStatus = .success(method: "MHA-C2")
            }
            return
        }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                AppState.markKernelExploitFinished()
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
                // Giờ kernel R/W đã sẵn sàng — mới quét container (đã hoãn ở early init).
                AppContainerScanner.shared.prewarmOnLaunch()
            }
        }
    }
}
