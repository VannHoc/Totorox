import SwiftUI
import UIKit

// MARK: - Filter & Sort Models

enum ModCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case skin
    case button
    case bundle
    case cached

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .skin: return "person.crop.square.fill"
        case .button: return "gamecontroller.fill"
        case .bundle: return "square.stack.3d.up.fill"
        case .cached: return "checkmark.seal.fill"
        }
    }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .all: return language.text("modstore.filter.all")
        case .skin: return language.text("modstore.filter.skin")
        case .button: return language.text("modstore.filter.button")
        case .bundle: return language.text("modstore.filter.bundle")
        case .cached: return language.text("modstore.filter.cached")
        }
    }
}

enum ModSortOption: String, CaseIterable, Identifiable {
    case newest
    case popular
    case nameAsc
    case sizeAsc

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .newest: return language.text("modstore.sort.newest")
        case .popular: return language.text("modstore.sort.popular")
        case .nameAsc: return language.text("modstore.sort.name_asc")
        case .sizeAsc: return language.text("modstore.sort.size_asc")
        }
    }
}

private struct ModShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private enum ModDestinationAction {
    case overwrite
    case merge
    case share
}

// MARK: - ModStoreView (Tab 5: Kho Mod Skin Trực Tuyến)

struct ModStoreView: View {
    var isEmbedded: Bool = false
    var config: ModStoreSectionConfig = .aovModSkin
    @Environment(\.appLanguage) private var language
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    private var accentColor: Color {
        config.palette.accent(isDark: themeManager.mode == .dark)
    }

    @State private var mods: [ModCatalogItem] = []
    @State private var cachedIDs: Set<Int> = []
    @State private var searchText: String = ""
    @State private var categoryFilter: ModCategoryFilter = .all
    @State private var sortOption: ModSortOption = .newest
    @State private var selectedIDs: Set<Int> = []

    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var alertMessage: String? = nil
    @State private var activeShareItem: ModShareItem? = nil

    // Download Progress State
    @State private var isDownloading: Bool = false
    @State private var downloadTitle: String = ""
    @State private var downloadByteSummary: String = ""
    @State private var downloadFraction: Double = 0.0
    @State private var activeDownloadTask: Task<Void, Never>? = nil

    private var filteredMods: [ModCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let matched = mods.filter { item in
            switch categoryFilter {
            case .all:
                break
            case .skin:
                guard item.normalizedCategory == "skin" else { return false }
            case .button:
                guard item.normalizedCategory == "button" else { return false }
            case .bundle:
                guard item.normalizedCategory == "bundle" else { return false }
            case .cached:
                guard cachedIDs.contains(item.id) else { return false }
            }

            guard !query.isEmpty else { return true }
            if item.name.lowercased().contains(query) { return true }
            if item.heroName.lowercased().contains(query) { return true }
            if item.skinName.lowercased().contains(query) { return true }
            if item.fileName.lowercased().contains(query) { return true }
            if item.resourceVersion.lowercased().contains(query) { return true }
            if let hid = item.heroID, ("\(hid)" == query || "#\(hid)" == query) {
                return true
            }
            return false
        }

        switch sortOption {
        case .newest:
            return matched.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id > rhs.id
            }
        case .popular:
            return matched.sorted { lhs, rhs in
                if lhs.downloadCount != rhs.downloadCount { return lhs.downloadCount > rhs.downloadCount }
                return lhs.createdAt > rhs.createdAt
            }
        case .nameAsc:
            return matched.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .sizeAsc:
            return matched.sorted { lhs, rhs in
                if lhs.fileSize != rhs.fileSize { return lhs.fileSize < rhs.fileSize }
                return lhs.id > rhs.id
            }
        }
    }

    private var selectedModsList: [ModCatalogItem] {
        mods.filter { selectedIDs.contains($0.id) }
    }

    private var uncachedSelectedCount: Int {
        selectedModsList.filter { !cachedIDs.contains($0.id) }.count
    }

    private var showBottomDock: Bool {
        isDownloading || !selectedIDs.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    ModStoreHeaderCard(
                        title: language.text(config.titleKey),
                        subtitle: language.text(config.subtitleKey),
                        iconName: config.iconName,
                        accentColor: accentColor,
                        totalCount: mods.count,
                        cachedCount: cachedIDs.count
                    )

                    filterAndCatalogCard
                }
                .padding(.horizontal, 16)
                .padding(.top, isEmbedded ? 6 : 12)
                .padding(.bottom, showBottomDock ? 16 : 32)
                .frame(width: proxy.size.width > 0 ? proxy.size.width : nil)
            }
            .refreshable {
                await fetchCatalogAsync()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(isEmbedded ? TotoroxTheme.tabCanvasBackground : TotoroxTheme.pageBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showBottomDock {
                bottomActionDock
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showBottomDock)
        .onAppear {
            refreshCachedState()
            if mods.isEmpty && !isLoading {
                loadMods()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModStoreCache.didChangeNotification)) { _ in
            refreshCachedState()
        }
        .sheet(item: $activeShareItem) { item in
            ActivityViewControllerWrapper(activityItems: [item.url])
                .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .alert(language.text("common.notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(language.text("common.ok"), role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Search, Category Filter & Catalog List Card

    private var filterAndCatalogCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Search + Sort + Refresh Row
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textSecondary)

                    TextField(
                        "",
                        text: $searchText,
                        prompt: Text(language.text("modstore.search.placeholder"))
                            .foregroundColor(TotoroxTheme.textSecondary)
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .tint(accentColor)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Menu {
                    Picker(language.text("folders.sort_by"), selection: $sortOption) {
                        ForEach(ModSortOption.allCases) { option in
                            Text(option.title(for: language)).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(sortOption == .newest ? TotoroxTheme.textPrimary : accentColor)
                        .frame(width: 40, height: 42)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isDownloading)

                Button {
                    loadMods()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 40, height: 42)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isLoading || isDownloading)
                .accessibilityLabel(language.text("folders.refresh"))
            }

            // Category Pills (shown in full Mod Skin AOV hub; hidden in focused sub-hubs)
            if config.showCategoryFilterPills {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ModCategoryFilter.allCases) { filter in
                            if filter != .cached || !cachedIDs.isEmpty || categoryFilter == .cached {
                                let isSelected = (categoryFilter == filter)
                                let count = countForFilter(filter)
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        categoryFilter = filter
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: filter.iconName)
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(filter.title(for: language))
                                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                        Text("\(count)")
                                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                isSelected
                                                    ? Color.white.opacity(0.24)
                                                    : accentColor.opacity(0.14)
                                            )
                                            .foregroundStyle(isSelected ? .white : accentColor)
                                            .clipShape(Capsule())
                                    }
                                    .foregroundStyle(isSelected ? .white : TotoroxTheme.textPrimary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                                    .background(isSelected ? accentColor : TotoroxTheme.searchBackground)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            // Selection helper row
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                Text(language.text("modstore.select_guide"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                Spacer(minLength: 4)
                if !filteredMods.isEmpty {
                    Text(language.text("modstore.showing_count", filteredMods.count))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
            }

            Divider()
                .overlay(TotoroxTheme.dividerColor)

            // List Content States
            if isLoading && mods.isEmpty {
                loadingSkeletonState
            } else if let errorMessage, mods.isEmpty {
                errorStateView(message: errorMessage)
            } else if filteredMods.isEmpty {
                emptyStateView
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredMods) { item in
                        ModStoreItemRow(
                            item: item,
                            isSelected: selectedIDs.contains(item.id),
                            isCached: cachedIDs.contains(item.id),
                            isDisabled: isDownloading,
                            onToggleSelect: {
                                toggleSelection(item.id)
                            },
                            onQuickOverwrite: {
                                executeBatch(items: [item], destination: .overwrite)
                            },
                            onQuickMerge: {
                                executeBatch(items: [item], destination: .merge)
                            },
                            onQuickShare: {
                                executeBatch(items: [item], destination: .share)
                            },
                            onDeleteCached: {
                                ModStoreCache.shared.removeCachedFile(for: item.id)
                                refreshCachedState()
                            }
                        )
                    }
                }
            }
        }
        .totoroxCard(cornerRadius: 16, padding: 16)
    }

    private var loadingSkeletonState: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(TotoroxTheme.searchBackground)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(TotoroxTheme.searchBackground)
                            .frame(width: 170, height: 13)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(TotoroxTheme.searchBackground)
                            .frame(width: 120, height: 10)
                    }
                    Spacer()
                }
                .padding(10)
                .background(TotoroxTheme.searchBackground.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 8) {
                ProgressView()
                    .tint(TotoroxTheme.mintAccent)
                    .scaleEffect(0.85)
                Text(language.text("modstore.loading"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(TotoroxTheme.textSecondary)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private func errorStateView(message: String) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                loadMods()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text(language.text("modstore.retry"))
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(TotoroxTheme.mintAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 30))
                .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.5))
            Text(language.text("modstore.empty"))
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .multilineTextAlignment(.center)

            if !searchText.isEmpty || categoryFilter != .all {
                Button(language.text("modstore.reset_filter")) {
                    searchText = ""
                    categoryFilter = .all
                }
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(TotoroxTheme.mintAccent)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Sticky Bottom Action Dock

    private var bottomActionDock: some View {
        VStack(spacing: 10) {
            if isDownloading {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(TotoroxTheme.mintAccent)
                            .scaleEffect(0.85)
                        Text(downloadTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button(language.text("common.cancel")) {
                            cancelActiveDownload()
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.red)
                    }

                    ProgressView(value: min(max(downloadFraction, 0.03), 1.0), total: 1.0)
                        .tint(TotoroxTheme.mintAccent)

                    if !downloadByteSummary.isEmpty {
                        HStack {
                            Text(downloadByteSummary)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                            Spacer()
                            Text("\(Int(min(max(downloadFraction, 0.0), 1.0) * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                        }
                    }
                }
            } else {
                let selectedItems = selectedModsList
                let count = selectedItems.count
                let newCost = uncachedSelectedCount

                HStack(spacing: 8) {
                    Text(language.text("modstore.selected_summary", count))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)

                    Text("•")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textSecondary)

                    Text(
                        newCost == 0
                            ? language.text("modstore.quota_cached_free")
                            : language.text("modstore.quota_cost_count", newCost)
                    )
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accentColor)

                    Spacer()

                    Button(language.text("modstore.clear_selection")) {
                        selectedIDs.removeAll()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .buttonStyle(.plain)
                }

                if count == 1, let single = selectedItems.first {
                    let isAlreadyCached = cachedIDs.contains(single.id)
                    Button {
                        executeBatch(items: [single], destination: .overwrite)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text(
                                language.text(
                                    isAlreadyCached
                                        ? "modstore.action.cached_overwrite"
                                        : "modstore.action.download_overwrite"
                                )
                            )
                            .font(.system(size: 14.5, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(config.palette.primaryButtonGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: accentColor.opacity(0.28), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        Button {
                            executeBatch(items: [single], destination: .merge)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(language.text("modstore.action.send_to_merge_short"))
                                    .font(.system(size: 12.5, weight: .bold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(accentColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(accentColor.opacity(0.13))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            executeBatch(items: [single], destination: .share)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(language.text("modstore.action.share_zip_short"))
                                    .font(.system(size: 12.5, weight: .bold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                } else if count >= 2 {
                    Button {
                        executeBatch(items: selectedItems, destination: .merge)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text(
                                language.text(
                                    newCost == 0
                                        ? "modstore.action.cached_merge"
                                        : "modstore.action.download_merge",
                                    count
                                )
                            )
                            .font(.system(size: 14.5, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(TotoroxTheme.mintAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: TotoroxTheme.mintAccent.opacity(0.28), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TotoroxTheme.cardBackground)
        .overlay(alignment: .top) {
            Divider().overlay(TotoroxTheme.dividerColor)
        }
        .shadow(color: TotoroxTheme.shadowColor, radius: 8, x: 0, y: -3)
    }

    // MARK: - Actions

    private func countForFilter(_ filter: ModCategoryFilter) -> Int {
        switch filter {
        case .all:
            return mods.count
        case .skin:
            return mods.filter { $0.normalizedCategory == "skin" }.count
        case .button:
            return mods.filter { $0.normalizedCategory == "button" }.count
        case .bundle:
            return mods.filter { $0.normalizedCategory == "bundle" }.count
        case .cached:
            return mods.filter { cachedIDs.contains($0.id) }.count
        }
    }

    private func refreshCachedState() {
        cachedIDs = ModStoreCache.shared.cachedModIDs(matching: mods)
    }

    private func toggleSelection(_ id: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func loadMods() {
        Task {
            await fetchCatalogAsync()
        }
    }

    @MainActor
    private func fetchCatalogAsync() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let result = await APIService.shared.fetchModCatalog(
            search: "",
            category: config.serverCategoryQuery,
            token: license.authToken,
            hwid: license.deviceIdentifier
        )

        isLoading = false
        switch result {
        case .success(let items):
            mods = items
            let validIDs = Set(items.map(\.id))
            selectedIDs = selectedIDs.intersection(validIDs)
            refreshCachedState()
        case .failure(let error):
            errorMessage = error.localizedDescription
            if !mods.isEmpty {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func cancelActiveDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        isDownloading = false
        downloadTitle = ""
        downloadByteSummary = ""
        downloadFraction = 0.0
    }

    private func executeBatch(items: [ModCatalogItem], destination: ModDestinationAction) {
        guard !items.isEmpty, !isDownloading else { return }

        let activeLanguage = language
        isDownloading = true
        downloadFraction = 0.02
        downloadByteSummary = ""
        downloadTitle = activeLanguage.text("modstore.downloading_item", 1, items.count, items[0].name)

        let task = Task {
            var resolvedURLs: [URL] = []
            var didConsumeRemoteQuota = false

            for (index, item) in items.enumerated() {
                if Task.isCancelled { return }

                // 0ms Instant Local Cache Hit (không tốn lượt, không cần mạng)
                if let localURL = ModStoreCache.shared.cachedFileURL(for: item) {
                    resolvedURLs.append(localURL)
                    await MainActor.run {
                        self.downloadFraction = Double(index + 1) / Double(items.count)
                    }
                    continue
                }

                await MainActor.run {
                    self.downloadTitle = activeLanguage.text(
                        "modstore.downloading_item",
                        index + 1,
                        items.count,
                        item.name
                    )
                    let baseFrac = Double(index) / Double(items.count)
                    self.downloadFraction = max(0.03, baseFrac)
                    self.downloadByteSummary = ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
                }

                let itemTotal = max(Int64(1), item.fileSize)
                let totalCount = items.count
                let itemIndex = index

                // Bắt buộc vượt Link4m qua Server (vé 1 lần gắn chặt tài khoản + UDID, không lộ link Drive)
                let verifiedGateID: String?
                do {
                    verifiedGateID = try await CatalogLinkGateManager.shared.requireVerifiedGate(
                        action: .modDownload,
                        featureTitle: item.name,
                        accentColor: accentColor
                    )
                } catch is CatalogGateError {
                    await MainActor.run {
                        self.finishDownloadFlow()
                    }
                    return
                } catch {
                    await MainActor.run {
                        self.finishDownloadFlow()
                        self.alertMessage = error.localizedDescription
                    }
                    return
                }

                let downloadResult = await APIService.shared.downloadModFile(
                    modId: item.id,
                    fileName: item.fileName,
                    expectedBytes: item.fileSize,
                    token: license.authToken,
                    hwid: license.deviceIdentifier,
                    gateID: verifiedGateID
                ) { completed, expected in
                    let effectiveTotal = expected > 0 ? expected : itemTotal
                    let itemPct = min(max(Double(completed) / Double(max(1, effectiveTotal)), 0.0), 1.0)
                    let overallPct = (Double(itemIndex) + itemPct) / Double(max(1, totalCount))
                    let doneText = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
                    let totalText = ByteCountFormatter.string(fromByteCount: effectiveTotal, countStyle: .file)
                    Task { @MainActor in
                        guard self.isDownloading else { return }
                        self.downloadFraction = overallPct
                        self.downloadByteSummary = "\(doneText) / \(totalText)"
                    }
                }

                if Task.isCancelled { return }

                switch downloadResult {
                case .success(let stagedURL):
                    do {
                        let cachedURL = try ModStoreCache.shared.storeDownloadedFile(from: stagedURL, for: item)
                        resolvedURLs.append(cachedURL)
                        didConsumeRemoteQuota = true
                        await MainActor.run {
                            if let idx = self.mods.firstIndex(where: { $0.id == item.id }) {
                                self.mods[idx].downloadCount += 1
                            }
                            self.refreshCachedState()
                        }
                    } catch {
                        if didConsumeRemoteQuota {
                            await LicenseManager.shared.refresh()
                        }
                        await MainActor.run {
                            self.finishDownloadFlow()
                            self.alertMessage = error.localizedDescription
                        }
                        return
                    }

                case .failure(let error):
                    await LicenseManager.shared.refresh()
                    await MainActor.run {
                        let wasCancelled = Task.isCancelled
                        self.finishDownloadFlow()
                        if !wasCancelled {
                            self.alertMessage = error.localizedDescription
                        }
                    }
                    return
                }
            }

            if didConsumeRemoteQuota {
                await LicenseManager.shared.refresh()
            }

            await MainActor.run {
                self.finishDownloadFlow()
                self.selectedIDs.removeAll()
                switch destination {
                case .overwrite:
                    if let first = resolvedURLs.first {
                        AppNavigationCoordinator.shared.navigateToOverwrite(
                            patchURL: first,
                            bundleID: self.config.targetBundleID
                        )
                    }
                case .merge:
                    AppNavigationCoordinator.shared.navigateToMerge(modURLs: resolvedURLs)
                case .share:
                    if let first = resolvedURLs.first {
                        self.activeShareItem = ModShareItem(url: first)
                    }
                }
            }
        }
        activeDownloadTask = task
    }

    @MainActor
    private func finishDownloadFlow() {
        isDownloading = false
        activeDownloadTask = nil
        downloadTitle = ""
        downloadByteSummary = ""
        downloadFraction = 0.0
    }
}

// MARK: - Header Banner Card

private struct ModStoreHeaderCard: View {
    @Environment(\.appLanguage) private var language
    let title: String
    let subtitle: String
    let iconName: String
    let accentColor: Color
    let totalCount: Int
    let cachedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accentColor.opacity(0.22),
                                    accentColor.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(accentColor.opacity(0.28), lineWidth: 0.9)
                        )

                    Image(systemName: iconName)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                        Text(language.text("modstore.header.credit"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)
                    }
                    .foregroundStyle(accentColor)
                }

                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(TotoroxTheme.dividerColor)
                .frame(height: 1)

            Text(subtitle)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(TotoroxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(language.text("modstore.badge.total_mods", totalCount))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(accentColor.opacity(0.13))
                .clipShape(Capsule())

                if cachedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(language.text("modstore.badge.cached_count", cachedCount))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(accentColor.opacity(0.13))
                    .clipShape(Capsule())
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text(language.text("modstore.header.quota_short"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(TotoroxTheme.searchBackground)
                .clipShape(Capsule())
            }
        }
        .totoroxCard(cornerRadius: 16, padding: 16)
    }
}

// MARK: - Individual Mod Row Card

private struct ModStoreItemRow: View {
    @Environment(\.appLanguage) private var language

    let item: ModCatalogItem
    let isSelected: Bool
    let isCached: Bool
    let isDisabled: Bool
    let onToggleSelect: () -> Void
    let onQuickOverwrite: () -> Void
    let onQuickMerge: () -> Void
    let onQuickShare: () -> Void
    let onDeleteCached: () -> Void

    private var heroSkinSubtitle: String? {
        let hero = item.heroName.trimmingCharacters(in: .whitespacesAndNewlines)
        let skin = item.skinName.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [hero, skin].filter { !$0.isEmpty }.joined(separator: " • ")
        guard !combined.isEmpty else { return nil }
        if combined.caseInsensitiveCompare(item.name) == .orderedSame {
            return nil
        }
        return combined
    }

    private var categoryBadgeTitle: String {
        switch item.normalizedCategory {
        case "button":
            return language.text("modstore.category.button")
        case "bundle":
            return language.text("modstore.category.bundle")
        default:
            return language.text("modstore.category.skin")
        }
    }

    private var avatarSymbolOrInitial: (symbol: String?, initial: String) {
        switch item.normalizedCategory {
        case "button":
            return ("gamecontroller.fill", "")
        case "bundle":
            return ("square.stack.3d.up.fill", "")
        default:
            let source = item.heroName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? item.name
                : item.heroName
            let first = source.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "M"
            return (nil, first)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleSelect) {
                HStack(spacing: 12) {
                    avatarBadge

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let sub = heroSkinSubtitle {
                            Text(sub)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                                .lineLimit(1)
                        }

                        // Metadata Pills Row
                        HStack(spacing: 6) {
                            Text(categoryBadgeTitle)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TotoroxTheme.mintAccent.opacity(0.14))
                                .clipShape(Capsule())

                            Text("v\(item.resourceVersion)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textSecondary)

                            Text("• \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textSecondary)

                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 10))
                                Text("\(item.downloadCount)")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        .lineLimit(1)

                        if isCached {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(language.text("modstore.cached_badge"))
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(TotoroxTheme.mintAccent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            // Quick Actions Menu + Checkbox
            HStack(spacing: 6) {
                Menu {
                    Button(action: onQuickOverwrite) {
                        Label(
                            language.text(isCached ? "modstore.action.cached_overwrite" : "modstore.action.download_overwrite"),
                            systemImage: "bolt.fill"
                        )
                    }
                    Button(action: onQuickMerge) {
                        Label(
                            language.text("modstore.action.send_to_merge_one"),
                            systemImage: "square.stack.3d.up.fill"
                        )
                    }
                    Button(action: onQuickShare) {
                        Label(
                            language.text("modstore.action.share_zip"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    if isCached {
                        Divider()
                        Button(role: .destructive, action: onDeleteCached) {
                            Label(language.text("modstore.action.delete_cached"), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .frame(width: 28, height: 34)
                }
                .disabled(isDisabled)

                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary.opacity(0.45))
                        .frame(width: 28, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
        .padding(12)
        .background(
            isSelected
                ? TotoroxTheme.mintAccent.opacity(0.11)
                : TotoroxTheme.searchBackground.opacity(0.65)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? TotoroxTheme.mintAccent.opacity(0.55) : TotoroxTheme.cardBorderColor,
                    lineWidth: isSelected ? 1.3 : 0.6
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var avatarBadge: some View {
        let info = avatarSymbolOrInitial
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TotoroxTheme.mintAccent.opacity(0.15))
                .frame(width: 46, height: 46)

            VStack(spacing: 1) {
                if let symbol = info.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                } else {
                    Text(info.initial)
                        .font(.system(size: item.heroID != nil ? 16 : 19, weight: .bold, design: .rounded))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                }

                if let hid = item.heroID {
                    Text("#\(hid)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
