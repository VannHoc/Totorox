import SwiftUI

enum TotoroxTab: Int, CaseIterable, Identifiable {
    case overwrite = 0
    case folders = 1
    case patch = 2
    case merge = 3
    case mods = 4
    case catalog = 5

    /// Các tab hiển thị trên thanh điều hướng IPA 3.0 (Gộp file nằm gọn bên trong Danh mục -> Liên Quân Mobile).
    static let visibleTabs: [TotoroxTab] = [.overwrite, .folders, .patch, .catalog]

    var id: Int { rawValue }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .overwrite: return language.text("tab.overwrite")
        case .folders: return language.text("tab.folders")
        case .patch: return language.text("tab.patch")
        case .merge: return language.text("tab.merge")
        case .mods: return language.text("tab.mods")
        case .catalog: return language.text("tab.catalog")
        }
    }

    var title: String {
        title(for: .vietnamese)
    }

    var iconName: String {
        switch self {
        case .overwrite: return "bolt.fill"
        case .folders: return "folder.fill"
        case .patch: return "arrow.triangle.2.circlepath"
        case .merge: return "square.stack.3d.up.fill"
        case .mods: return "shippingbox.fill"
        case .catalog: return "square.grid.2x2.fill"
        }
    }
}

struct TotoroxTabBar: View {
    @Binding var selectedTab: TotoroxTab
    @Environment(\.appLanguage) private var language
    @ObservedObject private var wallpaper = WallpaperManager.shared

    var body: some View {
        let _ = wallpaper.hasWallpaper
        VStack(spacing: 0) {
            Divider()
                .overlay(TotoroxTheme.dividerColor)

            HStack(spacing: 0) {
                ForEach(TotoroxTab.visibleTabs) { tab in
                    let isSelected = (selectedTab == tab) || (tab == .catalog && selectedTab == .merge)

                    Button {
                        if tab == .folders {
                            AppNavigationCoordinator.shared.folderExplorerTargetURL = URL(fileURLWithPath: ContainerStore.appDataRoot)
                        } else if tab == .catalog && (selectedTab == .catalog || selectedTab == .merge) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                AppNavigationCoordinator.shared.catalogRoute = .root
                            }
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 4) {
                            // Top indicator line/bar
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(TotoroxTheme.mintAccent)
                                        .frame(width: 28, height: 3)
                                } else {
                                    Color.clear
                                        .frame(width: 28, height: 3)
                                }
                            }
                            .frame(height: 3)
                            .padding(.bottom, 4)

                            // Tab Icon
                            Image(systemName: tab.iconName)
                                .font(.system(size: 19, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)

                            // Tab Label
                            Text(tab.title(for: language))
                                .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundColor(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 2)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 58)
            .background(TotoroxTheme.activeCardBackground)
        }
        .background(TotoroxTheme.activeCardBackground.ignoresSafeArea(edges: .bottom))
        .shadow(color: TotoroxTheme.shadowColor, radius: 6, x: 0, y: -2)
    }
}
