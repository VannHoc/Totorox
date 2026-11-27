import SwiftUI
import UIKit

/// Bảng màu đồng bộ Light/Dark cho từng màn hình con trong Tab Danh mục:
/// rõ chữ, dịu mắt, không rối nền nhưng nhận diện đúng tông màu từng mục.
enum CatalogScreenPalette: Equatable, Sendable {
    case crimsonRed    // Mod Skin AOV (Đỏ Ruby đồng bộ thẻ Đỏ rực lửa)
    case blazingGold   // Gộp File (Vàng Hổ Phách đồng bộ thẻ Vàng rực lửa)
    case royalViolet   // Skin Vương Giả (Tím Hoàng Gia riêng biệt hoàn toàn với Đỏ & Vàng)
    case oceanBlue     // Cam xa / Update Mod Skin
    case emeraldMint   // Mod map / Fix lag
    case sunsetOrange  // PUBG / Free Fire

    func accent(isDark: Bool) -> Color {
        switch self {
        case .crimsonRed:
            return isDark
                ? Color(red: 0.96, green: 0.36, blue: 0.38)
                : Color(red: 0.78, green: 0.13, blue: 0.17)
        case .blazingGold:
            return isDark
                ? Color(red: 0.97, green: 0.70, blue: 0.18)
                : Color(red: 0.72, green: 0.41, blue: 0.02)
        case .royalViolet:
            return isDark
                ? Color(red: 0.71, green: 0.53, blue: 0.99)
                : Color(red: 0.45, green: 0.18, blue: 0.84)
        case .oceanBlue:
            return isDark
                ? Color(red: 0.36, green: 0.70, blue: 0.99)
                : Color(red: 0.11, green: 0.45, blue: 0.86)
        case .emeraldMint:
            return TotoroxTheme.mintAccent
        case .sunsetOrange:
            return isDark
                ? Color(red: 0.97, green: 0.54, blue: 0.25)
                : Color(red: 0.82, green: 0.36, blue: 0.08)
        }
    }

    var primaryButtonGradient: LinearGradient {
        let colors: [Color]
        switch self {
        case .crimsonRed:
            colors = [Color(red: 0.77, green: 0.12, blue: 0.16), Color(red: 0.90, green: 0.23, blue: 0.19)]
        case .blazingGold:
            colors = [Color(red: 0.76, green: 0.42, blue: 0.03), Color(red: 0.89, green: 0.56, blue: 0.06)]
        case .royalViolet:
            colors = [Color(red: 0.44, green: 0.17, blue: 0.82), Color(red: 0.60, green: 0.26, blue: 0.91)]
        case .oceanBlue:
            colors = [Color(red: 0.11, green: 0.46, blue: 0.88), Color(red: 0.18, green: 0.62, blue: 0.95)]
        case .emeraldMint:
            colors = [TotoroxTheme.mintAccent, Color(red: 0.10, green: 0.66, blue: 0.54)]
        case .sunsetOrange:
            colors = [Color(red: 0.82, green: 0.35, blue: 0.08), Color(red: 0.93, green: 0.48, blue: 0.16)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    /// Nền màu tĩnh cực dịu phủ dưới các luồng sáng động để 2 tab chính không bị trắng toát / đen tuyền.
    func ambientCanvasBase(isDark: Bool) -> Color {
        switch self {
        case .crimsonRed:
            return isDark
                ? Color(red: 0.095, green: 0.052, blue: 0.068)
                : Color(red: 0.994, green: 0.962, blue: 0.964)
        case .blazingGold:
            return isDark
                ? Color(red: 0.095, green: 0.073, blue: 0.045)
                : Color(red: 0.996, green: 0.978, blue: 0.942)
        case .royalViolet:
            return isDark
                ? Color(red: 0.075, green: 0.058, blue: 0.115)
                : Color(red: 0.976, green: 0.965, blue: 0.998)
        default:
            return TotoroxTheme.pageBackground
        }
    }

    func ambientPrimaryOrb(isDark: Bool) -> Color {
        switch self {
        case .crimsonRed:
            return isDark
                ? Color(red: 0.92, green: 0.20, blue: 0.26).opacity(0.24)
                : Color(red: 0.95, green: 0.28, blue: 0.32).opacity(0.18)
        case .blazingGold:
            return isDark
                ? Color(red: 0.96, green: 0.62, blue: 0.10).opacity(0.24)
                : Color(red: 0.98, green: 0.68, blue: 0.14).opacity(0.20)
        case .royalViolet:
            return isDark
                ? Color(red: 0.60, green: 0.32, blue: 0.96).opacity(0.22)
                : Color(red: 0.62, green: 0.38, blue: 0.96).opacity(0.15)
        default:
            return accent(isDark: isDark).opacity(isDark ? 0.16 : 0.11)
        }
    }

    func ambientSecondaryOrb(isDark: Bool) -> Color {
        switch self {
        case .crimsonRed:
            return isDark
                ? Color(red: 0.98, green: 0.44, blue: 0.24).opacity(0.17)
                : Color(red: 1.00, green: 0.56, blue: 0.38).opacity(0.14)
        case .blazingGold:
            return isDark
                ? Color(red: 1.00, green: 0.80, blue: 0.28).opacity(0.17)
                : Color(red: 1.00, green: 0.84, blue: 0.36).opacity(0.16)
        case .royalViolet:
            return isDark
                ? Color(red: 0.42, green: 0.50, blue: 0.98).opacity(0.16)
                : Color(red: 0.52, green: 0.58, blue: 0.98).opacity(0.12)
        default:
            return accent(isDark: isDark).opacity(isDark ? 0.12 : 0.08)
        }
    }
}

/// Nền hoạt ảnh chuyển động êm dịu theo tông màu chủ đạo của 2 tab chính (`Mod Skin AOV` đỏ ruby dịu,
/// `Gộp File` vàng hổ phách dịu) cho cả Light Mode và Dark Mode, giữ độ tương phản chữ sắc nét.
struct CatalogAmbientBackground: View {
    let palette: CatalogScreenPalette

    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phaseSeed: Double {
        switch palette {
        case .crimsonRed: return 0.0
        case .blazingGold: return 1.85
        case .royalViolet: return 3.40
        default: return 0.9
        }
    }

    var body: some View {
        let isDark = (themeManager.mode == .dark)
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
            let slowA = sin(t * 0.55 + phaseSeed)
            let slowB = cos(t * 0.43 + phaseSeed * 0.7)
            let pulse = 0.5 + 0.5 * sin(t * 0.72 + phaseSeed)

            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let h = max(geo.size.height, 1)
                let maxDim = max(w, h)

                ZStack {
                    palette.ambientCanvasBase(isDark: isDark)

                    // Vùng hào quang dịu phía trên trôi nhẹ
                    RadialGradient(
                        colors: [
                            palette.ambientPrimaryOrb(isDark: isDark),
                            palette.ambientPrimaryOrb(isDark: isDark).opacity(0.38),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: maxDim * 0.62
                    )
                    .frame(width: maxDim * 1.15, height: maxDim * 1.15)
                    .scaleEffect(0.95 + 0.08 * pulse)
                    .position(
                        x: w * (0.26 + 0.22 * CGFloat(slowA)),
                        y: h * (0.16 + 0.10 * CGFloat(slowB))
                    )

                    // Vùng hào quang dịu phía dưới đối xứng
                    RadialGradient(
                        colors: [
                            palette.ambientSecondaryOrb(isDark: isDark),
                            palette.ambientSecondaryOrb(isDark: isDark).opacity(0.32),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: maxDim * 0.58
                    )
                    .frame(width: maxDim * 1.08, height: maxDim * 1.08)
                    .scaleEffect(1.02 - 0.07 * pulse)
                    .position(
                        x: w * (0.76 - 0.20 * CGFloat(slowB)),
                        y: h * (0.78 - 0.12 * CGFloat(slowA))
                    )
                }
            }
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
}

struct ModStoreSectionConfig: Equatable, Sendable {
    let titleKey: String
    let subtitleKey: String
    let iconName: String
    let serverCategoryQuery: String
    let showCategoryFilterPills: Bool
    let palette: CatalogScreenPalette
    let targetBundleID: String

    static let aovModSkin = ModStoreSectionConfig(
        titleKey: "catalog.aov.hero.mod_skin",
        subtitleKey: "modstore.header.subtitle",
        iconName: "flame.fill",
        serverCategoryQuery: "skin,button,bundle",
        showCategoryFilterPills: true,
        palette: .crimsonRed,
        targetBundleID: "com.garena.game.kgvn"
    )

    static let hokSkin = ModStoreSectionConfig(
        titleKey: "catalog.sub.hok_skin",
        subtitleKey: "catalog.sub.hok_skin.desc",
        iconName: "crown.fill",
        serverCategoryQuery: "hok_skin",
        showCategoryFilterPills: false,
        palette: .royalViolet,
        targetBundleID: "com.garena.game.kgvn"
    )

    static let camXa = ModStoreSectionConfig(
        titleKey: "catalog.sub.cam_xa",
        subtitleKey: "catalog.sub.cam_xa.desc",
        iconName: "viewfinder",
        serverCategoryQuery: "cam_xa",
        showCategoryFilterPills: false,
        palette: .oceanBlue,
        targetBundleID: "com.garena.game.kgvn"
    )

    static let modMap = ModStoreSectionConfig(
        titleKey: "catalog.sub.mod_map",
        subtitleKey: "catalog.sub.mod_map.desc",
        iconName: "map.fill",
        serverCategoryQuery: "mod_map",
        showCategoryFilterPills: false,
        palette: .emeraldMint,
        targetBundleID: "com.garena.game.kgvn"
    )

    static let fixLag = ModStoreSectionConfig(
        titleKey: "catalog.sub.fix_lag",
        subtitleKey: "catalog.sub.fix_lag.desc",
        iconName: "bolt.shield.fill",
        serverCategoryQuery: "fix_lag",
        showCategoryFilterPills: false,
        palette: .emeraldMint,
        targetBundleID: "com.garena.game.kgvn"
    )

    static func battleRoyale(game: CatalogGameID, feature: CatalogSubFeatureID) -> ModStoreSectionConfig {
        let isPUBG = (game == .pubg)
        let cat: String
        if feature == .brModSkin {
            cat = isPUBG ? "pubg_skin" : "ff_skin"
        } else {
            cat = isPUBG ? "pubg_fix_lag" : "ff_fix_lag"
        }
        return ModStoreSectionConfig(
            titleKey: feature == .brModSkin ? "catalog.sub.br_mod_skin" : "catalog.sub.fix_lag",
            subtitleKey: feature == .brModSkin ? "catalog.sub.br_mod_skin.desc" : "catalog.sub.fix_lag.desc",
            iconName: feature.iconName,
            serverCategoryQuery: cat,
            showCategoryFilterPills: false,
            palette: .sunsetOrange,
            targetBundleID: game.bundleCandidates.first ?? "com.garena.game.kgvn"
        )
    }
}

enum CatalogGateAction: String, Sendable {
    case modDownload = "mod_download"
    case mergePlan = "merge_plan"
    case modUpdate = "mod_update"
}

enum CatalogGateError: LocalizedError {
    case cancelled
    case notAuthenticated
    case failed(String)

    var errorDescription: String? {
        let lang = AppLanguage.current
        switch self {
        case .cancelled:
            return lang.text("gate.error.cancelled")
        case .notAuthenticated:
            return lang.text("modupdater.error.not_authenticated")
        case .failed(let msg):
            return msg
        }
    }
}

struct ActiveCatalogGatePrompt: Identifiable {
    let id: String // gateID
    let action: CatalogGateAction
    let featureTitle: String
    let shortURL: URL
    let providerName: String
    let accentColor: Color
}

/// Quản lý luồng vượt Link4m tập trung cho toàn bộ tính năng trong Tab Danh mục.
/// Khi người dùng vượt xong Link4m, trình duyệt redirect về `totorox://gate-verified?gate_id=...`
/// (hoặc App tự kiểm tra trạng thái khi quay lại màn hình) và tiếp tục tải/xử lý tệp ngay lập tức
/// trực tiếp từ Server Totorox — không bao giờ lộ link Google Drive hay repo gốc.
@MainActor
final class CatalogLinkGateManager: ObservableObject {
    static let shared = CatalogLinkGateManager()

    @Published var activePrompt: ActiveCatalogGatePrompt? = nil
    @Published var isCheckingStatus: Bool = false
    @Published var statusHint: String? = nil

    private var continuation: CheckedContinuation<String?, Error>? = nil

    private init() {}

    /// Bắt buộc xác minh vượt Link4m trước khi thực hiện hành động trên Server.
    /// Trả về `gateID` dùng 1 lần (hoặc `nil` nếu Server tắt chế độ vượt link).
    func requireVerifiedGate(
        action: CatalogGateAction,
        featureTitle: String,
        accentColor: Color = TotoroxTheme.mintAccent
    ) async throws -> String? {
        let token = LicenseManager.shared.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw CatalogGateError.notAuthenticated
        }
        let hwid = LicenseManager.shared.deviceIdentifier

        let startResult = await APIService.shared.startCatalogGate(
            action: action.rawValue,
            token: token,
            hwid: hwid
        )
        switch startResult {
        case .failure(let err):
            throw CatalogGateError.failed(err.localizedDescription)
        case .success(let resp):
            guard resp.ok else {
                throw CatalogGateError.failed(AppLanguage.current.text("gate.error.create_failed"))
            }
            if !resp.required {
                return nil
            }
            guard let gateID = resp.gateID, !gateID.isEmpty,
                  let rawURL = resp.shortURL, let shortURL = URL(string: rawURL) else {
                throw CatalogGateError.failed(AppLanguage.current.text("gate.error.create_failed"))
            }

            // Hủy prompt cũ nếu có
            cancelActiveGate()

            let prompt = ActiveCatalogGatePrompt(
                id: gateID,
                action: action,
                featureTitle: featureTitle,
                shortURL: shortURL,
                providerName: (resp.provider ?? "Link4m").capitalized,
                accentColor: accentColor
            )
            self.statusHint = nil
            self.isCheckingStatus = false
            self.activePrompt = prompt

            return try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
            }
        }
    }

    func openShortURLInBrowser() {
        guard let url = activePrompt?.shortURL else { return }
        statusHint = AppLanguage.current.text("gate.hint.waiting_browser")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func handleDeepLinkVerified(gateID: String?) {
        guard let prompt = activePrompt else { return }
        if let incoming = gateID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !incoming.isEmpty,
           incoming != prompt.id.lowercased() {
            return
        }
        Task {
            await checkVerificationNow(silentPending: false)
        }
    }

    func checkVerificationNow(silentPending: Bool = true) async {
        guard let prompt = activePrompt, !isCheckingStatus else { return }
        let token = LicenseManager.shared.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let hwid = LicenseManager.shared.deviceIdentifier

        isCheckingStatus = true
        defer { isCheckingStatus = false }

        let res = await APIService.shared.checkCatalogGateStatus(
            gateID: prompt.id,
            token: token,
            hwid: hwid
        )
        switch res {
        case .success(let st):
            switch st.status {
            case "verified":
                let cont = continuation
                continuation = nil
                activePrompt = nil
                statusHint = nil
                cont?.resume(returning: prompt.id)
            case "expired", "consumed":
                let cont = continuation
                continuation = nil
                activePrompt = nil
                statusHint = nil
                cont?.resume(throwing: CatalogGateError.failed(AppLanguage.current.text("gate.error.expired")))
            default:
                if !silentPending {
                    statusHint = AppLanguage.current.text("gate.hint.not_completed_yet")
                }
            }
        case .failure(let err):
            if !silentPending {
                statusHint = err.localizedDescription
            }
        }
    }

    func cancelActiveGate() {
        let cont = continuation
        continuation = nil
        activePrompt = nil
        statusHint = nil
        isCheckingStatus = false
        cont?.resume(throwing: CatalogGateError.cancelled)
    }
}

// MARK: - Link4m Gate Modal Sheet (Crisp Light & Dark Contrast)

struct CatalogLinkGateSheetView: View {
    let prompt: ActiveCatalogGatePrompt
    @ObservedObject var manager = CatalogLinkGateManager.shared
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(TotoroxTheme.textSecondary.opacity(0.28))
                .frame(width: 40, height: 5)
                .padding(.top, 10)

            ZStack {
                Circle()
                    .fill(prompt.accentColor.opacity(0.16))
                    .frame(width: 62, height: 62)
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(prompt.accentColor)
            }

            VStack(spacing: 6) {
                Text(language.text("gate.sheet.title"))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(prompt.featureTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(prompt.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(prompt.accentColor.opacity(0.13))
                    .clipShape(Capsule())
            }

            Text(language.text("gate.sheet.subtitle", prompt.providerName))
                .font(.system(size: 13.5))
                .lineSpacing(3.5)
                .foregroundStyle(TotoroxTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)

            if let hint = manager.statusHint {
                HStack(spacing: 8) {
                    if manager.isCheckingStatus {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(prompt.accentColor)
                    }
                    Text(hint)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(11)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(spacing: 10) {
                Button {
                    manager.openShortURLInBrowser()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "safari.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text(language.text("gate.sheet.open_btn", prompt.providerName))
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(prompt.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        await manager.checkVerificationNow(silentPending: false)
                    }
                } label: {
                    HStack(spacing: 7) {
                        if manager.isCheckingStatus {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 14, weight: .bold))
                        }
                        Text(language.text("gate.sheet.verify_btn"))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(manager.isCheckingStatus)

                Button {
                    manager.cancelActiveGate()
                } label: {
                    Text(language.text("common.cancel"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .background(TotoroxTheme.cardBackground.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task {
                await manager.checkVerificationNow(silentPending: true)
            }
        }
    }
}
