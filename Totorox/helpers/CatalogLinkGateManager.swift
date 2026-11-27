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
                    Text(language.text("wallpaper.cancel"))
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
