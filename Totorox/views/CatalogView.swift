import SwiftUI
import UIKit

// MARK: - Catalog Domain Models

enum CatalogGenre: String, CaseIterable, Identifiable, Sendable {
    case all
    case moba
    case battleRoyale

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .all: return language.text("catalog.genre.all")
        case .moba: return language.text("catalog.genre.moba")
        case .battleRoyale: return language.text("catalog.genre.br")
        }
    }
}

enum CatalogGameID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case aov
    case pubg
    case freeFire

    var id: String { rawValue }

    var genre: CatalogGenre {
        switch self {
        case .aov: return .moba
        case .pubg, .freeFire: return .battleRoyale
        }
    }

    var assetLogoName: String {
        switch self {
        case .aov: return "GameLogoAOV"
        case .pubg: return "GameLogoPUBG"
        case .freeFire: return "GameLogoFreeFire"
        }
    }

    var bundleCandidates: [String] {
        switch self {
        case .aov:
            return ["com.garena.game.kgvn", "com.garena.game.kgtw", "com.ngame.allstar.eu"]
        case .pubg:
            return ["com.vng.pubgmobile", "com.tencent.ig"]
        case .freeFire:
            return ["com.dts.freefireth", "com.dts.freefiremax"]
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .aov: return "shield.lefthalf.filled"
        case .pubg: return "scope"
        case .freeFire: return "flame.fill"
        }
    }

    var symbolTint: Color {
        switch self {
        case .aov: return TotoroxTheme.mintAccent
        case .pubg: return Color(red: 0.91, green: 0.62, blue: 0.18)
        case .freeFire: return Color(red: 0.94, green: 0.39, blue: 0.31)
        }
    }

    var hasDedicatedTools: Bool {
        switch self {
        case .aov: return true
        case .pubg, .freeFire: return false
        }
    }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .aov: return language.text("catalog.game.aov")
        case .pubg: return language.text("catalog.game.pubg")
        case .freeFire: return language.text("catalog.game.freefire")
        }
    }

    static func fromQueryValue(_ raw: String?) -> CatalogGameID? {
        guard let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !cleaned.isEmpty else {
            return nil
        }
        switch cleaned {
        case "aov", "lienquan", "kgvn": return .aov
        case "pubg", "pubgm": return .pubg
        case "freefire", "ff": return .freeFire
        default: return nil
        }
    }
}

enum CatalogSubFeatureID: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Liên Quân Mobile secondary pills
    case hokSkin
    case updateModSkin
    case camXa
    case modMap
    case fixLag

    // PUBG / Free Fire upcoming pills
    case brModSkin
    case brFixLag

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .hokSkin: return "crown.fill"
        case .updateModSkin: return "arrow.triangle.2.circlepath.circle.fill"
        case .camXa: return "viewfinder"
        case .modMap: return "map.fill"
        case .fixLag, .brFixLag: return "bolt.shield.fill"
        case .brModSkin: return "sparkles"
        }
    }

    /// Only `Skin Vương Giả` gets elevated semi-highlight styling among secondary pills.
    var isSemiHighlighted: Bool {
        self == .hokSkin
    }

    var accentColor: Color {
        switch self {
        case .hokSkin:
            // Tím Hoàng Gia riêng biệt hoàn toàn với 2 tab chính Đỏ (Mod Skin AOV) & Vàng (Gộp File)
            return Color(red: 0.56, green: 0.30, blue: 0.94)
        case .updateModSkin:
            return Color(red: 0.16, green: 0.56, blue: 0.96)
        case .camXa:
            return Color(red: 0.24, green: 0.63, blue: 0.95)
        case .modMap:
            return TotoroxTheme.mintAccent
        case .fixLag, .brFixLag:
            return Color(red: 0.32, green: 0.76, blue: 0.52)
        case .brModSkin:
            return Color(red: 0.94, green: 0.50, blue: 0.24)
        }
    }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .hokSkin: return language.text("catalog.sub.hok_skin")
        case .updateModSkin: return language.text("catalog.sub.update_mod")
        case .camXa: return language.text("catalog.sub.cam_xa")
        case .modMap: return language.text("catalog.sub.mod_map")
        case .fixLag, .brFixLag: return language.text("catalog.sub.fix_lag")
        case .brModSkin: return language.text("catalog.sub.br_mod_skin")
        }
    }

    func detailSubtitle(for language: AppLanguage) -> String {
        switch self {
        case .hokSkin: return language.text("catalog.sub.hok_skin.desc")
        case .updateModSkin: return language.text("catalog.sub.update_mod.desc")
        case .camXa: return language.text("catalog.sub.cam_xa.desc")
        case .modMap: return language.text("catalog.sub.mod_map.desc")
        case .fixLag, .brFixLag: return language.text("catalog.sub.fix_lag.desc")
        case .brModSkin: return language.text("catalog.sub.br_mod_skin.desc")
        }
    }

    static func pills(for game: CatalogGameID) -> [CatalogSubFeatureID] {
        switch selfGame(game) {
        case .aov:
            return [.hokSkin, .updateModSkin, .camXa, .modMap, .fixLag]
        case .pubg, .freeFire:
            return [.brModSkin, .brFixLag]
        }
    }

    private static func selfGame(_ game: CatalogGameID) -> CatalogGameID { game }
}

enum CatalogRoute: Equatable, Hashable, Sendable {
    case root
    case game(CatalogGameID)
    case aovModSkin
    case aovMerge
    case aovUpdateModSkin
    case subFeature(game: CatalogGameID, feature: CatalogSubFeatureID)
}

// MARK: - Fiery Hero Card Style (Opaque Solid + Medium Animated Fire Glow)

private enum FieryHeroPalette {
    case crimsonRed   // Mod Skin AOV (Đỏ rực lửa)
    case blazingGold  // Gộp File (Vàng rực lửa)

    var phaseOffset: Double {
        switch self {
        case .crimsonRed: return 0.0
        case .blazingGold: return 1.65
        }
    }

    var solidBackingColor: Color {
        switch self {
        case .crimsonRed:
            return Color(red: 0.42, green: 0.05, blue: 0.08)
        case .blazingGold:
            return Color(red: 0.46, green: 0.22, blue: 0.02)
        }
    }

    var baseGradient: [Color] {
        switch self {
        case .crimsonRed:
            return [
                Color(red: 0.50, green: 0.05, blue: 0.09),
                Color(red: 0.85, green: 0.14, blue: 0.13),
                Color(red: 0.98, green: 0.30, blue: 0.14)
            ]
        case .blazingGold:
            return [
                Color(red: 0.54, green: 0.26, blue: 0.02),
                Color(red: 0.89, green: 0.52, blue: 0.04),
                Color(red: 1.00, green: 0.78, blue: 0.10)
            ]
        }
    }

    var emberGlowColor: Color {
        switch self {
        case .crimsonRed:
            return Color(red: 1.00, green: 0.50, blue: 0.20)
        case .blazingGold:
            return Color(red: 1.00, green: 0.92, blue: 0.42)
        }
    }

    var rimColors: [Color] {
        switch self {
        case .crimsonRed:
            return [
                Color(red: 1.00, green: 0.30, blue: 0.20),
                Color(red: 1.00, green: 0.70, blue: 0.24),
                Color(red: 0.72, green: 0.09, blue: 0.11),
                Color(red: 1.00, green: 0.44, blue: 0.16),
                Color(red: 1.00, green: 0.30, blue: 0.20)
            ]
        case .blazingGold:
            return [
                Color(red: 1.00, green: 0.76, blue: 0.12),
                Color(red: 1.00, green: 0.96, blue: 0.56),
                Color(red: 0.82, green: 0.44, blue: 0.04),
                Color(red: 1.00, green: 0.84, blue: 0.20),
                Color(red: 1.00, green: 0.76, blue: 0.12)
            ]
        }
    }

    var shadowColor: Color {
        switch self {
        case .crimsonRed:
            return Color(red: 0.94, green: 0.18, blue: 0.14)
        case .blazingGold:
            return Color(red: 0.96, green: 0.62, blue: 0.06)
        }
    }
}

private struct FieryHeroCardButton: View {
    let title: String
    let icon: String
    let palette: FieryHeroPalette
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let t = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
                let wave = 0.5 + 0.5 * sin(t * 2.35 + palette.phaseOffset)
                let spinAngle = (t * 78.0 + palette.phaseOffset * 55.0)
                    .truncatingRemainder(dividingBy: 360.0)
                let spark1Progress = ((t * 0.42 + palette.phaseOffset * 0.23)
                    .truncatingRemainder(dividingBy: 1.0))
                let spark2Progress = ((t * 0.34 + 0.52 + palette.phaseOffset * 0.17)
                    .truncatingRemainder(dividingBy: 1.0))

                ZStack(alignment: .bottomLeading) {
                    // 1. 100% Opaque Solid Base (never translucent even over custom wallpaper)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(palette.solidBackingColor)

                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: palette.baseGradient,
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )

                    // 2. Medium-Intensity Animated Molten Ember Core + Rising Sparks
                    GeometryReader { geo in
                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            palette.emberGlowColor.opacity(0.26 + 0.28 * wave),
                                            palette.emberGlowColor.opacity(0.0)
                                        ],
                                        center: .center,
                                        startRadius: 4,
                                        endRadius: max(geo.size.width, geo.size.height) * 0.74
                                    )
                                )
                                .frame(width: geo.size.width * 1.15, height: geo.size.width * 1.15)
                                .offset(
                                    x: geo.size.width * (0.06 + 0.18 * wave),
                                    y: -geo.size.height * (0.08 + 0.16 * wave)
                                )

                            // Subtle flame crest watermark at top-right
                            Image(systemName: "flame.fill")
                                .font(.system(size: 62, weight: .black))
                                .foregroundStyle(Color.white.opacity(0.08 + 0.06 * wave))
                                .rotationEffect(.degrees(-5.0 + 9.0 * wave))
                                .scaleEffect(0.96 + 0.10 * wave)
                                .position(x: geo.size.width - 26, y: 34)

                            // Gentle drifting ember sparks (medium fiery ambience)
                            Circle()
                                .fill(palette.emberGlowColor.opacity(0.65 * (1.0 - spark1Progress)))
                                .frame(width: 5, height: 5)
                                .blur(radius: 0.6)
                                .position(
                                    x: geo.size.width * 0.68 + CGFloat(sin(t * 2.8)) * 7,
                                    y: geo.size.height * (0.86 - 0.64 * spark1Progress)
                                )

                            Circle()
                                .fill(Color.white.opacity(0.55 * (1.0 - spark2Progress)))
                                .frame(width: 3.8, height: 3.8)
                                .blur(radius: 0.4)
                                .position(
                                    x: geo.size.width * 0.83 - CGFloat(cos(t * 2.2)) * 6,
                                    y: geo.size.height * (0.82 - 0.60 * spark2Progress)
                                )

                            // Bottom contrast scrim so extra-bold white title stays razor sharp
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.black.opacity(0.24)
                                ],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .allowsHitTesting(false)

                    // 3. Crisp Icon Badge + Extra-Bold Title ONLY (zero subtitle)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.black.opacity(0.26))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .stroke(Color.white.opacity(0.34), lineWidth: 0.9)
                                    )

                                Image(systemName: icon)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(color: Color.black.opacity(0.28), radius: 2, x: 0, y: 1)
                            }

                            Spacer(minLength: 4)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(Color.white.opacity(0.90))
                                .padding(7)
                                .background(Color.black.opacity(0.22))
                                .clipShape(Circle())
                        }

                        Spacer(minLength: 14)

                        Text(title)
                            .font(.system(size: 17.5, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .shadow(color: Color.black.opacity(0.38), radius: 3, x: 0, y: 1)
                    }
                    .padding(15)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .overlay(
                    // 4. Animated Fiery Rim Border
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(colors: palette.rimColors),
                                center: .center,
                                angle: .degrees(spinAngle)
                            ),
                            lineWidth: 2.2
                        )
                )
                .shadow(
                    color: palette.shadowColor.opacity(0.26 + 0.18 * wave),
                    radius: 7 + 5 * wave,
                    x: 0,
                    y: 5
                )
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .buttonStyle(CatalogScalePressStyle())
    }
}

private struct CatalogScalePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - CatalogView (Tab 4: Danh mục)

struct CatalogView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var gateManager = CatalogLinkGateManager.shared
    @State private var selectedGenre: CatalogGenre = .all

    private let twoColumnPillGrid: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var filteredGames: [CatalogGameID] {
        guard selectedGenre != .all else { return CatalogGameID.allCases }
        return CatalogGameID.allCases.filter { $0.genre == selectedGenre }
    }

    var body: some View {
        ZStack {
            switch navCoordinator.catalogRoute {
            case .root:
                catalogRootContent
                    .transition(.opacity)
            case .game(let game):
                gameDetailContent(for: game)
                    .transition(.opacity)
            case .aovModSkin:
                aovModSkinContent
                    .transition(.opacity)
            case .aovMerge:
                aovMergeContent
                    .transition(.opacity)
            case .aovUpdateModSkin:
                aovUpdateModSkinContent
                    .transition(.opacity)
            case .subFeature(let game, let feature):
                subFeatureDetailContent(game: game, feature: feature)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TotoroxTheme.tabCanvasBackground)
        .onAppear {
            if navCoordinator.selectedTab == .merge {
                navCoordinator.catalogRoute = .aovMerge
                navCoordinator.selectedTab = .catalog
            }
        }
        .sheet(item: $gateManager.activePrompt, onDismiss: {
            if gateManager.activePrompt != nil {
                gateManager.cancelActiveGate()
            }
        }) { prompt in
            CatalogLinkGateSheetView(prompt: prompt)
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
                .preferredColorScheme(themeManager.mode.colorScheme)
        }
    }

    // MARK: - 1. Root Game List (Official Bundled Game Logos)

    private var catalogRootContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                genreFilterStrip

                VStack(spacing: 11) {
                    ForEach(filteredGames) { game in
                        gameRowButton(for: game)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }

    private var genreFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CatalogGenre.allCases) { genre in
                    let isSelected = (selectedGenre == genre)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedGenre = genre
                        }
                    } label: {
                        Text(genre.title(for: language))
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .white : TotoroxTheme.textSecondary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 7.5)
                            .background(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func gameRowButton(for game: CatalogGameID) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                navCoordinator.catalogRoute = .game(game)
            }
        } label: {
            HStack(spacing: 14) {
                gameIconView(for: game, size: 52)

                Text(game.title(for: language))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                statusPill(for: game)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.55))
            }
            .totoroxCard(cornerRadius: 18, padding: 13)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(CatalogScalePressStyle())
    }

    @ViewBuilder
    private func statusPill(for game: CatalogGameID) -> some View {
        if game.hasDedicatedTools {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10.5, weight: .bold))
                Text(language.text("catalog.badge.aov_hub"))
                    .font(.system(size: 11.5, weight: .bold))
            }
            .foregroundStyle(TotoroxTheme.mintAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(TotoroxTheme.mintAccent.opacity(0.14))
            .clipShape(Capsule())
        } else {
            Text(language.text("catalog.badge.soon"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(TotoroxTheme.searchBackground)
                .clipShape(Capsule())
        }
    }

    // MARK: - 2. Per-Game Hub (Titles Only — Zero Subtitles, Zero Overwrite Row)

    private func gameDetailContent(for game: CatalogGameID) -> some View {
        VStack(spacing: 0) {
            compactSubheader(
                backTitle: language.text("tab.catalog"),
                trailingGame: game
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    navCoordinator.catalogRoute = .root
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if game == .aov {
                        // Top Primary Section: 2 Largest, Solid Opaque Fiery Hero Cards
                        HStack(spacing: 12) {
                            FieryHeroCardButton(
                                title: language.text("catalog.aov.hero.mod_skin"),
                                icon: "flame.fill",
                                palette: .crimsonRed
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    navCoordinator.catalogRoute = .aovModSkin
                                }
                            }

                            FieryHeroCardButton(
                                title: language.text("catalog.aov.hero.merge"),
                                icon: "square.stack.3d.up.fill",
                                palette: .blazingGold
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    navCoordinator.catalogRoute = .aovMerge
                                }
                            }
                        }
                    }

                    // Bottom Secondary Section: 2-Column Capsule Pills (multi-row expandable)
                    LazyVGrid(columns: twoColumnPillGrid, spacing: 10) {
                        ForEach(CatalogSubFeatureID.pills(for: game)) { subItem in
                            secondaryCapsulePill(for: subItem) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if game == .aov && subItem == .updateModSkin {
                                        navCoordinator.catalogRoute = .aovUpdateModSkin
                                    } else {
                                        navCoordinator.catalogRoute = .subFeature(game: game, feature: subItem)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    /// Compact capsule pill ("khung viên thuốc"): title + icon ONLY (no subtitle).
    /// `Skin Vương Giả` (`isSemiHighlighted == true`) stands out over standard pills
    /// via a warm royal-gold tint & border, while staying clearly subordinate to the
    /// two top Fiery Hero Cards.
    private func secondaryCapsulePill(
        for item: CatalogSubFeatureID,
        action: @escaping () -> Void
    ) -> some View {
        let isHighlighted = item.isSemiHighlighted
        let isDark = (themeManager.mode == .dark)

        let royalFill = LinearGradient(
            colors: isDark
                ? [
                    Color(red: 0.21, green: 0.12, blue: 0.34).opacity(0.95),
                    Color(red: 0.14, green: 0.10, blue: 0.24).opacity(0.95)
                ]
                : [
                    Color(red: 0.96, green: 0.93, blue: 1.00).opacity(0.96),
                    Color(red: 0.91, green: 0.87, blue: 1.00).opacity(0.96)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(
                            isHighlighted
                                ? item.accentColor.opacity(isDark ? 0.28 : 0.18)
                                : item.accentColor.opacity(0.13)
                        )
                        .frame(width: 30, height: 30)

                    Image(systemName: item.iconName)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(item.accentColor)
                }

                Text(item.title(for: language))
                    .font(.system(size: 13.5, weight: isHighlighted ? .bold : .semibold))
                    .foregroundStyle(
                        isHighlighted
                            ? (isDark ? Color(red: 0.86, green: 0.77, blue: 1.00) : Color(red: 0.36, green: 0.14, blue: 0.68))
                            : TotoroxTheme.textPrimary
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                Spacer(minLength: 2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(
                        isHighlighted
                            ? item.accentColor.opacity(0.85)
                            : TotoroxTheme.textSecondary.opacity(0.45)
                    )
            }
            .padding(.leading, 9)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                if isHighlighted {
                    Capsule().fill(royalFill)
                } else {
                    Capsule().fill(TotoroxTheme.activeCardBackground)
                }
            }
            .overlay(
                Capsule()
                    .strokeBorder(
                        isHighlighted
                            ? item.accentColor.opacity(isDark ? 0.68 : 0.58)
                            : TotoroxTheme.cardBorderColor,
                        lineWidth: isHighlighted ? 1.3 : 0.8
                    )
            )
            .shadow(
                color: isHighlighted ? item.accentColor.opacity(0.16) : TotoroxTheme.shadowColor,
                radius: isHighlighted ? 6 : 4,
                x: 0,
                y: 2
            )
            .contentShape(Capsule())
        }
        .buttonStyle(CatalogScalePressStyle())
    }

    // MARK: - 3. Embedded Feature Screens (Descriptions & Full Controls Appear Here)

    private var aovModSkinContent: some View {
        ZStack {
            CatalogAmbientBackground(palette: .crimsonRed)

            VStack(spacing: 0) {
                compactSubheader(
                    backTitle: CatalogGameID.aov.title(for: language),
                    trailingGame: .aov
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        navCoordinator.catalogRoute = .game(.aov)
                    }
                }

                ModStoreView(isEmbedded: true, config: .aovModSkin)
            }
        }
    }

    private var aovMergeContent: some View {
        ZStack {
            CatalogAmbientBackground(palette: .blazingGold)

            VStack(spacing: 0) {
                compactSubheader(
                    backTitle: CatalogGameID.aov.title(for: language),
                    trailingGame: .aov
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        navCoordinator.catalogRoute = .game(.aov)
                    }
                }

                MergeFileView(isEmbedded: true)
            }
        }
    }

    private var aovUpdateModSkinContent: some View {
        VStack(spacing: 0) {
            compactSubheader(
                backTitle: CatalogGameID.aov.title(for: language),
                trailingGame: .aov
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    navCoordinator.catalogRoute = .game(.aov)
                }
            }

            UpdateModSkinView(isEmbedded: true)
        }
    }

    private func subFeatureDetailContent(
        game: CatalogGameID,
        feature: CatalogSubFeatureID
    ) -> some View {
        let storeConfig: ModStoreSectionConfig = {
            if game == .aov {
                switch feature {
                case .hokSkin: return .hokSkin
                case .camXa: return .camXa
                case .modMap: return .modMap
                case .fixLag: return .fixLag
                default: return .aovModSkin
                }
            }
            return .battleRoyale(game: game, feature: feature)
        }()

        return VStack(spacing: 0) {
            compactSubheader(
                backTitle: game.title(for: language),
                trailingGame: game
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    navCoordinator.catalogRoute = .game(game)
                }
            }

            // Mọi mục phụ trong Tab Danh mục đều kết nối trực tiếp kho Server + vượt Link4m
            ModStoreView(isEmbedded: true, config: storeConfig)
        }
    }

    // MARK: - Shared Header & Bundled Game Icon View

    private func compactSubheader(
        backTitle: String,
        trailingGame: CatalogGameID?,
        onBack: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                    Text(backTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(TotoroxTheme.mintAccent)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if let game = trailingGame {
                HStack(spacing: 8) {
                    gameIconView(for: game, size: 26)
                    Text(game.title(for: language))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func gameIconView(for game: CatalogGameID, size: CGFloat) -> some View {
        let radius = size * 0.225
        if let bundled = UIImage(named: game.assetLogoName) {
            Image(uiImage: bundled)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1.5)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(game.symbolTint.opacity(0.14))
                Image(systemName: game.fallbackSymbol)
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(game.symbolTint)
            }
            .frame(width: size, height: size)
        }
    }
}
