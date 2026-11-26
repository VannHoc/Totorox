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

enum CatalogRoute: Equatable, Hashable, Sendable {
    case root
    case game(CatalogGameID)
    case aovMerge
}

// MARK: - Lightweight Installed Icon Loader

@MainActor
private final class CatalogIconStore: ObservableObject {
    static let shared = CatalogIconStore()

    @Published private(set) var icons: [CatalogGameID: UIImage] = [:]
    private var didLoad = false

    private init() {}

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        let games = CatalogGameID.allCases
        Task.detached(priority: .utility) {
            var resolved: [CatalogGameID: UIImage] = [:]
            for game in games {
                for bundleID in game.bundleCandidates {
                    if let img = iconForBundleID(bundleID) {
                        resolved[game] = img
                        break
                    }
                }
            }
            guard !resolved.isEmpty else { return }
            let snapshot = resolved
            await MainActor.run {
                self.icons.merge(snapshot) { _, new in new }
            }
        }
    }
}

// MARK: - CatalogView (Tab 4: Danh mục)

struct CatalogView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
    @ObservedObject private var iconStore = CatalogIconStore.shared
    @State private var selectedGenre: CatalogGenre = .all

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
            case .aovMerge:
                aovMergeContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TotoroxTheme.pageBackground)
        .onAppear {
            if navCoordinator.selectedTab == .merge {
                navCoordinator.catalogRoute = .aovMerge
                navCoordinator.selectedTab = .catalog
            }
        }
        .task {
            iconStore.loadIfNeeded()
        }
    }

    // MARK: - Root Game List

    private var catalogRootContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                genreFilterStrip

                VStack(spacing: 10) {
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
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
            HStack(spacing: 13) {
                gameIconView(for: game, size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title(for: language))
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)

                    Text(game.genre.title(for: language))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusPill(for: game)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.55))
            }
            .totoroxCard(cornerRadius: 16, padding: 13)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusPill(for game: CatalogGameID) -> some View {
        if game.hasDedicatedTools {
            Text(language.text("catalog.badge.merge"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(TotoroxTheme.mintAccent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(TotoroxTheme.mintAccent.opacity(0.12))
                .clipShape(Capsule())
        } else {
            Text(language.text("catalog.badge.soon"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(TotoroxTheme.searchBackground)
                .clipShape(Capsule())
        }
    }

    // MARK: - Per-Game Tool Hub

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
                VStack(spacing: 10) {
                    if game == .aov {
                        toolRowButton(
                            icon: "square.stack.3d.up.fill",
                            tint: TotoroxTheme.mintAccent,
                            title: language.text("tab.merge"),
                            subtitle: language.text("catalog.tool.merge_sub")
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                navCoordinator.catalogRoute = .aovMerge
                            }
                        }
                    }

                    toolRowButton(
                        icon: "bolt.fill",
                        tint: game.symbolTint,
                        title: language.text("tab.overwrite"),
                        subtitle: language.text("catalog.tool.overwrite_sub")
                    ) {
                        navCoordinator.navigateToGameOverwrite(bundleCandidates: game.bundleCandidates)
                    }

                    if !game.hasDedicatedTools {
                        upcomingToolsNotice
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    private func toolRowButton(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.55))
            }
            .totoroxCard(cornerRadius: 16, padding: 13)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var upcomingToolsNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TotoroxTheme.textSecondary)

            Text(language.text("catalog.tool.upcoming"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(TotoroxTheme.searchBackground.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Embedded AOV Merge View

    private var aovMergeContent: some View {
        VStack(spacing: 0) {
            compactSubheader(
                backTitle: CatalogGameID.aov.title(for: language),
                trailingGame: nil
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    navCoordinator.catalogRoute = .game(.aov)
                }
            }

            MergeFileView(isEmbedded: true)
        }
    }

    // MARK: - Shared Minimal Components

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
                HStack(spacing: 7) {
                    gameIconView(for: game, size: 24)
                    Text(game.title(for: language))
                        .font(.system(size: 14, weight: .semibold))
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
        let radius = size * 0.23
        if let uiImage = iconStore.icons[game] {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(TotoroxTheme.cardBorderColor, lineWidth: 0.6)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(game.symbolTint.opacity(0.13))
                Image(systemName: game.fallbackSymbol)
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(game.symbolTint)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(game.symbolTint.opacity(0.18), lineWidth: 0.6)
            )
        }
    }
}
