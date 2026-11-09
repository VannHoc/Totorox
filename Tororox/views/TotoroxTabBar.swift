import SwiftUI

enum TotoroxTab: Int, CaseIterable, Identifiable {
    case overwrite = 0
    case folders = 1
    case patch = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overwrite: return "Đè file"
        case .folders: return "Thư mục"
        case .patch: return "Patch"
        }
    }

    var iconName: String {
        switch self {
        case .overwrite: return "bolt.fill"
        case .folders: return "folder.fill"
        case .patch: return "arrow.triangle.2.circlepath"
        }
    }
}

struct TotoroxTabBar: View {
    @Binding var selectedTab: TotoroxTab

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(TotoroxTheme.dividerColor)

            HStack(spacing: 0) {
                ForEach(TotoroxTab.allCases) { tab in
                    let isSelected = (selectedTab == tab)
                    
                    Button {
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
                                        .frame(width: 32, height: 3)
                                } else {
                                    Color.clear
                                        .frame(width: 32, height: 3)
                                }
                            }
                            .frame(height: 3)
                            .padding(.bottom, 4)

                            // Tab Icon
                            Image(systemName: tab.iconName)
                                .font(.system(size: 20, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)

                            // Tab Label
                            Text(tab.title)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 58)
            .background(TotoroxTheme.cardBackground)
        }
        .background(TotoroxTheme.cardBackground.ignoresSafeArea(edges: .bottom))
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: -2)
    }
}
