import SwiftUI
import UniformTypeIdentifiers

struct ClipboardItem {
    let url: URL
    let isCut: Bool
}

enum FolderSortOption: String, CaseIterable, Identifiable {
    case nameAsc = "Tên (A → Z)"
    case nameDesc = "Tên (Z → A)"
    case userAppsFirst = "Ứng dụng ngoài trước"
    case dateDesc = "Ngày sửa đổi (Mới nhất)"

    var id: String { rawValue }

    func displayTitle(language: AppLanguage) -> String {
        switch self {
        case .nameAsc: return language.text("folders.sort.name_asc")
        case .nameDesc: return language.text("folders.sort.name_desc")
        case .userAppsFirst: return language.text("folders.sort.user_apps_first")
        case .dateDesc: return language.text("folders.sort.date_desc")
        }
    }
}

// MARK: - DirectoryViewModel (Pure Read-Only Disk Directory Browser by Absolute Path)

@MainActor
final class DirectoryViewModel: ObservableObject {
    @Published private(set) var entries: [FileEntry] = []
    @Published var isLoading: Bool = false
    private(set) var activeCanonicalPath: String = ""
    private var loadTask: Task<Void, Never>? = nil

    func cancelPendingLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    /// Strictly Read-Only directory loader. Never executes mkdir/copyItem/moveItem
    /// and never invokes AppContainerScanner. Cancels stale loads when navigating rapidly
    /// and clears old entries before assigning fresh results from disk.
    func loadDirectory(at url: URL, forceRefresh: Bool = false) {
        let path = url.path
        let canonPath = ContainerMetadataCache.canonicalPath(path)

        loadTask?.cancel()
        loadTask = nil

        if activeCanonicalPath != canonPath {
            entries.removeAll()
            activeCanonicalPath = canonPath
        }

        // 0ms Instant Cache Hit (including valid empty directories `[]`)
        if !forceRefresh, let cached = ContainerMetadataCache.shared.cachedList(for: canonPath) {
            entries.removeAll()
            entries = cached
            isLoading = false

            // Background read-only verification
            loadTask = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return }
                let loaded = SecurityScopedFolderManager.shared.withScopedAccess(for: url) {
                    ContainerStore.readDirectoryEntriesFromDisk(at: path)
                }
                guard !Task.isCancelled else { return }
                ContainerMetadataCache.shared.storeList(loaded, for: canonPath)
                if loaded != cached {
                    await MainActor.run {
                        guard !Task.isCancelled, self.activeCanonicalPath == canonPath else { return }
                        self.entries.removeAll()
                        self.entries = loaded
                    }
                }
            }
            return
        }

        entries.removeAll()
        isLoading = true

        loadTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            let loaded = SecurityScopedFolderManager.shared.withScopedAccess(for: url) {
                ContainerStore.readDirectoryEntriesFromDisk(at: path)
            }
            guard !Task.isCancelled else { return }
            ContainerMetadataCache.shared.storeList(loaded, for: canonPath)

            await MainActor.run {
                guard !Task.isCancelled, self.activeCanonicalPath == canonPath else { return }
                self.entries.removeAll()
                self.entries = loaded
                self.isLoading = false
            }
        }
    }
}

/// Isolated observable model for file-operation progress so rapid progress ticks
/// only re-render the progress banner instead of re-evaluating the entire file list.
@MainActor
final class FolderTaskProgressModel: ObservableObject {
    @Published var title: String? = nil
    @Published var subtitle: String = ""
    @Published var completedCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var isCancelling: Bool = false

    private var activeTask: Task<Void, Never>? = nil

    var isRunning: Bool {
        title != nil
    }

    func begin(title: String, subtitle: String, totalCount: Int = 0) {
        self.title = title
        self.subtitle = subtitle
        self.completedCount = 0
        self.totalCount = totalCount
        self.isCancelling = false
    }

    func attach(_ task: Task<Void, Never>) {
        activeTask = task
    }

    func update(completed: Int, total: Int? = nil, subtitle: String? = nil) {
        self.completedCount = completed
        if let total {
            self.totalCount = total
        }
        if let subtitle {
            self.subtitle = subtitle
        }
    }

    func cancelCurrentTask() {
        isCancelling = true
        activeTask?.cancel()
    }

    func finish() {
        activeTask = nil
        title = nil
        subtitle = ""
        completedCount = 0
        totalCount = 0
        isCancelling = false
    }
}

private struct FolderTaskProgressBanner: View {
    @ObservedObject var progress: FolderTaskProgressModel
    let language: AppLanguage

    var body: some View {
        if let title = progress.title {
            let fraction: Double? = {
                guard progress.totalCount > 0 else { return nil }
                return min(max(Double(progress.completedCount) / Double(progress.totalCount), 0.02), 1.0)
            }()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.85)
                        .tint(TotoroxTheme.mintAccent)

                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    if let frac = fraction {
                        Text("\(Int(frac * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                    } else if progress.completedCount > 0 {
                        Text(language.text("common.items_count", progress.completedCount))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                    }

                    Button {
                        progress.cancelCurrentTask()
                    } label: {
                        Text(progress.isCancelling
                             ? language.text("folders.task.cancelling")
                             : language.text("common.cancel"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(progress.isCancelling)
                }

                if let frac = fraction {
                    ProgressView(value: frac, total: 1.0)
                        .tint(TotoroxTheme.mintAccent)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(TotoroxTheme.mintAccent)
                }

                if !progress.subtitle.isEmpty {
                    Text(progress.subtitle)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(TotoroxTheme.mintAccent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(TotoroxTheme.mintAccent.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - AppListViewModel (Dedicated App Container List ViewModel for /var/mobile/Containers/Data/Application)

@MainActor
final class AppListViewModel: ObservableObject {
    @Published private(set) var entries: [FileEntry] = []
    @Published var isLoading: Bool = false

    func loadAppContainers(forceRefresh: Bool = false) {
        let canonRoot = "/var/mobile/Containers/Data/Application"

        if !forceRefresh,
           let cached = ContainerMetadataCache.shared.cachedList(for: canonRoot),
           !cached.isEmpty {
            entries.removeAll()
            entries = cached
            isLoading = false
            AppContainerScanner.shared.prewarmOnLaunch()
            return
        }

        entries.removeAll()
        isLoading = true

        if forceRefresh {
            Task.detached(priority: .userInitiated) {
                _ = await AppContainerScanner.shared.scanAllContainers(forceRefresh: true)
                let built = ContainerMetadataCache.shared.rebuildApplicationDirectoryListCache()
                await MainActor.run {
                    self.entries.removeAll()
                    self.entries = built
                    self.isLoading = false
                }
            }
        } else {
            Task.detached(priority: .userInitiated) {
                AppContainerScanner.shared.performFastPassSync()
                let initial = ContainerMetadataCache.shared.rebuildApplicationDirectoryListCache()
                if !initial.isEmpty {
                    await MainActor.run {
                        self.entries.removeAll()
                        self.entries = initial
                        self.isLoading = false
                    }
                }
                _ = await AppContainerScanner.shared.scanAllContainers(forceRefresh: false)
                let finalEntries = ContainerMetadataCache.shared.rebuildApplicationDirectoryListCache()
                await MainActor.run {
                    self.entries.removeAll()
                    self.entries = finalEntries
                    self.isLoading = false
                }
            }
        }
    }

    func applyUpdatedCacheIfNeeded() {
        let canonRoot = "/var/mobile/Containers/Data/Application"
        if let updated = ContainerMetadataCache.shared.cachedList(for: canonRoot),
           !updated.isEmpty,
           updated.count != entries.count {
            entries.removeAll()
            entries = updated
            isLoading = false
        }
    }
}

struct FolderExplorerView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var directoryVM = DirectoryViewModel()
    @StateObject private var appListVM = AppListViewModel()
    @StateObject private var taskProgress = FolderTaskProgressModel()
    @State private var currentURL: URL
    @State private var breadcrumbs: [URL] = []
    @State private var searchText: String = ""
    @State private var sortOption: FolderSortOption = .nameAsc

    private var isAtAppContainersRoot: Bool {
        ContainerMetadataCache.isApplicationContainersRoot(currentURL.path)
    }

    private var entries: [FileEntry] {
        isAtAppContainersRoot ? appListVM.entries : directoryVM.entries
    }

    private var isLoading: Bool {
        isAtAppContainersRoot ? appListVM.isLoading : directoryVM.isLoading
    }

    // Clipboard state
    @State private var clipboardItem: ClipboardItem? = nil

    // Scroll restoration & indicators (keyed by canonical directory path)
    @State private var savedScrollItemID: [String: String] = [:]
    @State private var pendingScrollToID: String? = nil

    // Dialogs & Modals
    @State private var showNewFolderDialog = false
    @State private var newFolderName: String = ""
    @State private var showRenameDialog = false
    @State private var itemToRename: FileEntry? = nil
    @State private var newRenameName: String = ""
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: FileEntry? = nil
    @State private var showOperationError = false
    @State private var operationErrorMessage: String = ""
    @State private var showShareSheet = false
    @State private var shareURL: URL? = nil
    @State private var showImportPicker = false

    // Inspector & Archive Extraction
    @State private var inspectingEntry: FileEntry? = nil
    @State private var selectedArchiveForExtraction: FileEntry? = nil

    // Conflict & Outcome modals
    @State private var activeConflict: FileConflictInfo? = nil
    @State private var outcomeResult: FileIOResultWrapper? = nil

    private var canGoBack: Bool {
        currentURL.path != "/" && breadcrumbs.count > 1
    }

    private func dismissSearchKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    init(initialURL: URL? = nil) {
        let baseDir: URL
        if let initial = initialURL {
            baseDir = initial
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            baseDir = docs
        }
        _currentURL = State(initialValue: baseDir)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Action & Breadcrumb Header
            VStack(spacing: 8) {
                // Top controls
                HStack(spacing: 6) {
                    // Backward Button
                    Button {
                        if canGoBack {
                            navigateBack()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                            Text(language.text("folders.nav_back"))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(canGoBack ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary.opacity(0.35))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(Capsule())
                    }
                    .disabled(!canGoBack)

                    // Quick location shortcuts (chỉ giữ Documents & Containers AppData)
                    Menu {
                        Button {
                            navigateTo(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)
                        } label: {
                            Label(language.text("folders.quick.documents"), systemImage: "doc.fill")
                        }
                        Button {
                            let containers = URL(fileURLWithPath: ContainerStore.appDataRoot)
                            navigateTo(containers)
                        } label: {
                            Label(language.text("folders.quick.containers"), systemImage: "app.dashed")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 13))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                            Text(language.text("folders.quick_locations"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(Capsule())
                    }

                    Spacer(minLength: 4)

                    // Sort Menu Button
                    Menu {
                        Picker(language.text("folders.sort_by"), selection: $sortOption) {
                            ForEach(FolderSortOption.allCases) { option in
                                Text(option.displayTitle(language: language)).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(sortOption == .nameAsc ? TotoroxTheme.textPrimary : TotoroxTheme.mintAccent)
                            .frame(width: 34, height: 34)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(Circle())
                    }

                    // New Folder Button
                    Button {
                        newFolderName = ""
                        showNewFolderDialog = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(Circle())
                    }

                    // Import File Button
                    Button {
                        showImportPicker = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(Circle())
                    }

                    // Refresh Button
                    Button {
                        loadCurrentDirectory(forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)

                // Breadcrumb Navigation Bar
                ScrollViewReader { crumbProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                                Button {
                                    navigateTo(crumb)
                                } label: {
                                    HStack(spacing: 4) {
                                        if index == 0 {
                                            Image(systemName: "internaldrive.fill")
                                                .font(.system(size: 12))
                                        }
                                        Text(breadcrumbTitle(for: crumb))
                                            .font(.system(size: 12, weight: index == breadcrumbs.count - 1 ? .bold : .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(index == breadcrumbs.count - 1 ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                    .foregroundColor(index == breadcrumbs.count - 1 ? .white : TotoroxTheme.textPrimary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .id(index)

                                if index < breadcrumbs.count - 1 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.5))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .onChange(of: breadcrumbs) { newCrumbs in
                        if !newCrumbs.isEmpty {
                            withAnimation(.easeOut(duration: 0.15)) {
                                crumbProxy.scrollTo(newCrumbs.count - 1, anchor: .trailing)
                            }
                        }
                    }
                    .onAppear {
                        if !breadcrumbs.isEmpty {
                            crumbProxy.scrollTo(breadcrumbs.count - 1, anchor: .trailing)
                        }
                    }
                }

                // Filter search
                TotoroxSearchBar(
                    text: $searchText,
                    placeholder: ContainerMetadataCache.isApplicationContainersRoot(currentURL.path)
                        ? language.text("overwrite.search_apps_placeholder")
                        : language.text("folders.search_in_folder")
                )

                // Thanh hiển thị tiến trình tác vụ tệp (Copy/Paste, Giải nén, Nhập, Xóa...)
                FolderTaskProgressBanner(progress: taskProgress, language: language)
            }
            .padding(.bottom, 8)
            .background(TotoroxTheme.cardBackground)
            .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 2)

            // Content List (ScrollView + LazyVStack with stable IDs for 60-120fps)
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        let visibleEntries = displayedEntries
                        if visibleEntries.isEmpty {
                            VStack(spacing: 12) {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(1.2)
                                        .padding(.bottom, 4)
                                    Text(language.text("folders.loading_content"))
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                } else {
                                    Image(systemName: "folder")
                                        .font(.system(size: 44))
                                        .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.4))
                                    Text(searchText.isEmpty ? language.text("folders.empty_or_unreadable") : language.text("overwrite.folder.no_match"))
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        } else {
                            ForEach(visibleEntries, id: \.id) { entry in
                                fileEntryCard(entry)
                                    .id(entry.id)
                            }

                            let fileCount = visibleEntries.filter { !$0.isDirectory }.count
                            let dirCount = visibleEntries.filter { $0.isDirectory }.count
                            Text(language.text("folders.summary_status", visibleEntries.count, fileCount, dirCount))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 14)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, clipboardItem != nil ? 80 : 20)
                }
                .scrollIndicators(.visible)
                .onChange(of: currentURL) { _ in
                    restoreScrollIfNeeded(using: scrollProxy)
                }
                .onChange(of: entries) { _ in
                    restoreScrollIfNeeded(using: scrollProxy)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 80)
                }
                .background(TotoroxTheme.pageBackground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 25, coordinateSpace: .local)
                .onEnded { value in
                    if value.startLocation.x < 60 && value.translation.width > 80 && abs(value.translation.height) < 60 {
                        if canGoBack {
                            navigateBack()
                        }
                    }
                }
        )
        .overlay(alignment: .bottom) {
            if let clip = clipboardItem {
                floatingClipboardBar(clip)
            }
        }
        .onAppear {
            rebuildBreadcrumbs()
            loadCurrentDirectory()
        }
        .onDisappear {
            directoryVM.cancelPendingLoad()
        }
        .onReceive(NotificationCenter.default.publisher(for: .totoroxContainersDidUpdate)) { _ in
            guard isAtAppContainersRoot else { return }
            appListVM.applyUpdatedCacheIfNeeded()
        }
        .onReceive(AppNavigationCoordinator.shared.$folderExplorerTargetURL) { targetURL in
            if let url = targetURL {
                AppNavigationCoordinator.shared.folderExplorerTargetURL = nil
                navigateTo(url)
            }
        }
        .alert(language.text("folders.new_folder.title"), isPresented: $showNewFolderDialog) {
            TextField(language.text("folders.new_folder.placeholder"), text: $newFolderName)
            Button(language.text("folders.new_folder.create_btn")) {
                createNewFolder()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        }
        .alert(language.text("folders.rename.title"), isPresented: $showRenameDialog) {
            TextField(language.text("folders.rename.placeholder"), text: $newRenameName)
            Button(language.text("folders.rename.save_btn")) {
                applyRename()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        }
        .alert(language.text("folders.delete_confirm_title"), isPresented: $showDeleteConfirmation) {
            Button(language.text("folders.delete_forever_btn"), role: .destructive) {
                applyDelete()
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("folders.delete_confirm_message", itemToDelete?.name ?? ""))
        }
        .alert(language.text("folders.error.cannot_perform"), isPresented: $showOperationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationErrorMessage)
        }
        .sheet(isPresented: $showShareSheet) {
            if let share = shareURL {
                ActivityViewControllerWrapper(activityItems: [share])
                    .preferredColorScheme(themeManager.mode.colorScheme)
            }
        }
        .sheet(isPresented: $showImportPicker) {
            DocumentPickerWrapper { pickedURL in
                importFileIntoCurrentDirectory(pickedURL)
            }
            .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .sheet(item: $inspectingEntry) { entry in
            FileInfoInspectorSheet(entry: entry)
                .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .confirmationDialog(
            language.text("folders.extract.title", selectedArchiveForExtraction?.name ?? ""),
            isPresented: Binding(
                get: { selectedArchiveForExtraction != nil },
                set: { if !$0 { selectedArchiveForExtraction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = selectedArchiveForExtraction {
                Button(language.text("folders.extract.here")) {
                    extractArchive(entry: entry, intoNewFolder: false)
                }
                Button(language.text("folders.extract.into_new_folder")) {
                    extractArchive(entry: entry, intoNewFolder: true)
                }
                Button(language.text("common.cancel"), role: .cancel) {
                    selectedArchiveForExtraction = nil
                }
            }
        }
        .sheet(item: $outcomeResult) { wrapper in
            OverwriteOutcomeView(result: wrapper.result) {
                outcomeResult = nil
                ContainerMetadataCache.shared.invalidate(path: currentURL.path)
                loadCurrentDirectory(forceRefresh: true)
            }
            .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .overlay {
            if let conflict = activeConflict {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    WindowsConflictDialog(conflict: conflict)
                }
                .zIndex(999)
                .transition(.opacity)
            }
        }
    }

    // MARK: - File & Folder Card View (Zero Main Thread I/O, Clean 3105 Layout, No UDID)
    private func fileEntryCard(_ entry: FileEntry) -> some View {
        Button {
            dismissSearchKeyboard()
            if entry.isDirectory {
                let canonCurrent = ContainerMetadataCache.canonicalPath(currentURL.path)
                savedScrollItemID[canonCurrent] = entry.id
                let nextURL: URL
                if entry.isAppContainer {
                    nextURL = URL(fileURLWithPath: entry.path)
                } else {
                    nextURL = currentURL.appendingPathComponent(entry.name)
                }
                navigateTo(nextURL)
            } else {
                let lower = entry.name.lowercased()
                if lower.hasSuffix(".zip") {
                    selectedArchiveForExtraction = entry
                }
            }
        } label: {
            HStack(spacing: 10) {
                // Uniform lightweight vector icon for 120fps scrolling
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconBackgroundColor(for: entry))
                        .frame(width: 40, height: 40)

                    Image(systemName: iconName(for: entry))
                        .font(.system(size: 18))
                        .foregroundStyle(iconForegroundColor(for: entry))
                }

                // Text Column: Full folder/app title + Bundle ID (no UDID or raw path clutter)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if entry.isAppContainer {
                        if let bid = entry.bundleID, !bid.isEmpty {
                            Text(bid)
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // Regular folder/file metadata HStack
                        HStack(spacing: 6) {
                            if entry.isDirectory {
                                HStack(spacing: 4) {
                                    Text(language.text("folders.folder_type"))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                    if let count = entry.childCount {
                                        Text(language.text("common.files_paren_count", count))
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(TotoroxTheme.mintAccent)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TotoroxTheme.mintAccent.opacity(0.12))
                                .clipShape(Capsule())
                                .lineLimit(1)
                                .layoutPriority(1)
                            } else {
                                Text(entry.sizeText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .lineLimit(1)
                                    .layoutPriority(1)

                                if !entry.extensionBadge.isEmpty {
                                    Text(entry.extensionBadge)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                                        .clipShape(Capsule())
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                }
                            }

                            if let mod = entry.formattedModifiedDate {
                                Text("•")
                                    .font(.system(size: 9))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.4))
                                Text(mod)
                                    .font(.system(size: 11))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Info (i) Button
                Button {
                    inspectingEntry = entry
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)

                // Context Menu trigger
                Menu {
                    entryMenuItems(for: entry)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .frame(width: 26, height: 30)
                }
            }
            .totoroxCard(cornerRadius: 14, padding: 12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            entryMenuItems(for: entry)
        }
    }

    @ViewBuilder
    private func entryMenuItems(for entry: FileEntry) -> some View {
        Button {
            inspectingEntry = entry
        } label: {
            Label(language.text("folders.menu.get_info"), systemImage: "info.circle")
        }

        let lower = entry.name.lowercased()
        if lower.hasSuffix(".zip") {
            Divider()
            Button {
                extractArchive(entry: entry, intoNewFolder: false)
            } label: {
                Label(language.text("folders.extract.here"), systemImage: "archivebox")
            }
            Button {
                extractArchive(entry: entry, intoNewFolder: true)
            } label: {
                Label(language.text("folders.extract.into_new_folder"), systemImage: "folder.badge.plus")
            }
        }

        Divider()

        Button {
            let itemURL = URL(fileURLWithPath: entry.path)
            clipboardItem = ClipboardItem(url: itemURL, isCut: false)
        } label: {
            Label(language.text("folders.menu.copy"), systemImage: "doc.on.doc")
        }

        Button {
            let itemURL = URL(fileURLWithPath: entry.path)
            clipboardItem = ClipboardItem(url: itemURL, isCut: true)
        } label: {
            Label(language.text("folders.menu.cut"), systemImage: "scissors")
        }

        Button {
            itemToRename = entry
            newRenameName = entry.name
            showRenameDialog = true
        } label: {
            Label(language.text("folders.menu.rename"), systemImage: "pencil")
        }

        Button {
            shareURL = URL(fileURLWithPath: entry.path)
            showShareSheet = true
        } label: {
            Label(language.text("folders.action_share"), systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            itemToDelete = entry
            showDeleteConfirmation = true
        } label: {
            Label(language.text("folders.action_delete"), systemImage: "trash")
        }
    }

    // MARK: - Floating Clipboard Bar
    private func floatingClipboardBar(_ clip: ClipboardItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: clip.isCut ? "scissors" : "doc.on.doc.fill")
                .font(.system(size: 18))
                .foregroundStyle(TotoroxTheme.mintAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.isCut ? language.text("folders.clipboard.cutting") : language.text("folders.clipboard.copying"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                Text(clip.url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                executePasteAction(clip)
            } label: {
                Text(language.text("folders.clipboard.paste_here"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(TotoroxTheme.mintAccent)
                    .clipShape(Capsule())
            }

            Button {
                clipboardItem = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(TotoroxTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TotoroxTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Search & Sort Filtering
    private var displayedEntries: [FileEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [FileEntry]
        if query.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter { entry in
                if entry.displayTitle.localizedCaseInsensitiveContains(query) { return true }
                if let bid = entry.bundleID, bid.localizedCaseInsensitiveContains(query) { return true }
                if let appName = entry.appName, appName.localizedCaseInsensitiveContains(query) { return true }
                if !entry.isAppContainer && entry.name.localizedCaseInsensitiveContains(query) { return true }
                return false
            }
        }

        switch sortOption {
        case .nameAsc:
            return filtered.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                let cmp = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return (lhs.bundleID ?? lhs.name).localizedCaseInsensitiveCompare(rhs.bundleID ?? rhs.name) == .orderedAscending
            }
        case .nameDesc:
            return filtered.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                let cmp = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                if cmp != .orderedSame { return cmp == .orderedDescending }
                return (lhs.bundleID ?? lhs.name).localizedCaseInsensitiveCompare(rhs.bundleID ?? rhs.name) == .orderedDescending
            }
        case .userAppsFirst:
            return filtered.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                if lhs.isAppContainer || rhs.isAppContainer {
                    let lhsUser = !(lhs.bundleID ?? "").hasPrefix("com.apple.")
                    let rhsUser = !(rhs.bundleID ?? "").hasPrefix("com.apple.")
                    if lhsUser != rhsUser { return lhsUser }
                }
                let cmp = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return (lhs.bundleID ?? lhs.name).localizedCaseInsensitiveCompare(rhs.bundleID ?? rhs.name) == .orderedAscending
            }
        case .dateDesc:
            return filtered.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                let d1 = lhs.modifiedAt ?? .distantPast
                let d2 = rhs.modifiedAt ?? .distantPast
                if d1 != d2 { return d1 > d2 }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
        }
    }

    // MARK: - Navigation & 0ms Cache-Backed Loading
    private func navigateBack() {
        let childURL = currentURL
        let parent = childURL.deletingLastPathComponent()
        let canonParent = ContainerMetadataCache.canonicalPath(parent.path)

        // Ensure savedScrollItemID points to the folder we are backing out of
        if savedScrollItemID[canonParent] == nil {
            let childName = childURL.lastPathComponent
            if let cachedParentList = ContainerMetadataCache.shared.cachedList(for: parent.path),
               let matchingEntry = cachedParentList.first(where: {
                   $0.name.caseInsensitiveCompare(childName) == .orderedSame ||
                   ContainerMetadataCache.canonicalPath($0.path) == ContainerMetadataCache.canonicalPath(childURL.path)
               }) {
                savedScrollItemID[canonParent] = matchingEntry.id
            }
        }

        navigateTo(parent)
    }

    private func navigateTo(_ url: URL) {
        dismissSearchKeyboard()
        let canonDest = ContainerMetadataCache.canonicalPath(url.path)
        searchText = ""
        pendingScrollToID = savedScrollItemID[canonDest]
        currentURL = url
        rebuildBreadcrumbs()
        loadCurrentDirectory(forceRefresh: false)
    }

    private nonisolated static func countItemsRecursively(at url: URL) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return 1
        }
        guard isDir.boolValue else { return 1 }
        var total = 1
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for _ in enumerator {
                total += 1
            }
        }
        return max(total, 1)
    }

    private func restoreScrollIfNeeded(using scrollProxy: ScrollViewProxy) {
        guard let targetID = pendingScrollToID else { return }
        guard entries.contains(where: { $0.id == targetID }) else { return }
        pendingScrollToID = nil
        DispatchQueue.main.async {
            scrollProxy.scrollTo(targetID, anchor: .center)
        }
    }

    private func rebuildBreadcrumbs() {
        var crumbs: [URL] = []
        let canonical = ContainerMetadataCache.canonicalPath(currentURL.path)
        var curr = URL(fileURLWithPath: canonical)
        while curr.path != "/" && !curr.path.isEmpty {
            crumbs.insert(curr, at: 0)
            curr = curr.deletingLastPathComponent()
        }
        crumbs.insert(URL(fileURLWithPath: "/"), at: 0)
        self.breadcrumbs = crumbs
    }

    private func breadcrumbTitle(for crumb: URL) -> String {
        let name = crumb.lastPathComponent
        if name.isEmpty || name == "/" { return "Root" }
        let parentCanon = ContainerMetadataCache.canonicalPath(crumb.deletingLastPathComponent().path)
        let isInsideContainersRoot = ContainerMetadataCache.isApplicationContainersRoot(parentCanon)
            || parentCanon == "/var/containers/Bundle/Application"
        if isInsideContainersRoot, UUID(uuidString: name) != nil {
            if let bid = ContainerMetadataCache.shared.bundleID(forUUID: name), !bid.isEmpty {
                return bid
            }
            if let app = AppContainerScanner.shared.getCachedInfo(forUDID: name), !app.bundleID.isEmpty {
                return app.bundleID
            }
            if let bid = ContainerStore.bundleID(forUUID: name), !bid.isEmpty {
                return bid
            }
        }
        return name
    }

    private func loadCurrentDirectory(forceRefresh: Bool = false) {
        if isAtAppContainersRoot {
            appListVM.loadAppContainers(forceRefresh: forceRefresh)
        } else {
            directoryVM.loadDirectory(at: currentURL, forceRefresh: forceRefresh)
        }
    }

    // MARK: - File Actions (All executed on Background Thread via FileIOEngine / Task.detached)
    private func presentOperationError(_ message: String) {
        operationErrorMessage = message
        showOperationError = true
    }

    private func createNewFolder() {
        let baseDir = currentURL
        let folderName: String
        do {
            folderName = try FileManagerService.validatedName(newFolderName)
        } catch {
            presentOperationError(language.text("folders.error.invalid_folder_name"))
            return
        }

        let target = baseDir.appendingPathComponent(folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            presentOperationError(language.text("folders.error.folder_exists", folderName))
            return
        }

        let activeLanguage = language
        Task.detached(priority: .userInitiated) {
            do {
                try await FileIOEngine.shared.createFolder(at: target)
            } catch {
                await MainActor.run {
                    self.presentOperationError(activeLanguage.text("folders.error.create_folder_failed", error.localizedDescription))
                }
                return
            }
            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
    }

    private func applyRename() {
        guard let item = itemToRename else { return }
        let baseDir = currentURL
        let src = URL(fileURLWithPath: item.path).standardizedFileURL
        let newName: String
        do {
            newName = try FileManagerService.validatedName(newRenameName)
        } catch {
            presentOperationError(language.text("folders.error.invalid_new_name"))
            return
        }

        let dst = src.deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: item.isDirectory)
            .standardizedFileURL
        if dst == src {
            return
        }
        if FileManager.default.fileExists(atPath: dst.path) {
            presentOperationError(language.text("folders.error.name_exists", newName))
            return
        }

        let activeLanguage = language
        Task.detached(priority: .userInitiated) {
            do {
                try await FileIOEngine.shared.renameItem(at: src, to: dst)
            } catch {
                await MainActor.run {
                    self.presentOperationError(activeLanguage.text("folders.error.rename_failed", error.localizedDescription))
                }
                return
            }
            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
    }

    private func applyDelete() {
        guard let item = itemToDelete else { return }
        guard !taskProgress.isRunning else {
            presentOperationError(language.text("folders.error.task_already_running"))
            return
        }
        let baseDir = currentURL
        let src = URL(fileURLWithPath: item.path)
        let activeLanguage = language
        let progressModel = taskProgress
        progressModel.begin(
            title: activeLanguage.text("folders.task.deleting", item.name),
            subtitle: item.name
        )

        let worker = Task.detached(priority: .userInitiated) {
            let needsLocalScope = SecurityScopedFolderManager.shared.matchingFolder(forPath: baseDir.path) == nil
            let localScope = needsLocalScope ? baseDir.startAccessingSecurityScopedResource() : false
            defer { if localScope { baseDir.stopAccessingSecurityScopedResource() } }
            do {
                try await FileIOEngine.shared.deleteItem(at: src)
            } catch {
                await MainActor.run {
                    progressModel.finish()
                    self.presentOperationError(activeLanguage.text("folders.error.delete_failed", error.localizedDescription))
                }
                return
            }
            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                progressModel.finish()
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
        progressModel.attach(worker)
    }

    private func makeConflictResolver(
        using coordinator: ConflictPromptCoordinator
    ) -> FileIOConflictResolver {
        { source, destination, kind in
            await coordinator.resolveConflict(
                source: source,
                destination: destination,
                kind: kind,
                presentModal: { info in
                    self.activeConflict = info
                },
                dismissModal: {
                    self.activeConflict = nil
                }
            )
        }
    }

    private func importFileIntoCurrentDirectory(_ src: URL) {
        guard !taskProgress.isRunning else {
            presentOperationError(language.text("folders.error.task_already_running"))
            return
        }
        let baseDir = currentURL.standardizedFileURL
        let fileName = src.lastPathComponent
        guard !fileName.isEmpty, fileName != "/", fileName != "." else { return }
        let dst = baseDir.appendingPathComponent(fileName, isDirectory: false)
        let hasSecurityAccess = src.startAccessingSecurityScopedResource()
        let promptCoordinator = ConflictPromptCoordinator()
        let resolver = makeConflictResolver(using: promptCoordinator)

        let activeLanguage = language
        let progressModel = taskProgress
        progressModel.begin(
            title: activeLanguage.text("folders.task.importing", fileName),
            subtitle: fileName,
            totalCount: 1
        )

        let worker = Task.detached(priority: .userInitiated) {
            defer {
                if hasSecurityAccess { src.stopAccessingSecurityScopedResource() }
            }
            _ = ContainerStore.ensureContainerAccess(for: baseDir.path, requireWrite: true)
            let totalItems = Self.countItemsRecursively(at: src)
            await MainActor.run {
                progressModel.update(completed: 0, total: totalItems)
            }
            let result = await FileIOEngine.shared.copyAndMerge(
                from: src,
                to: dst,
                progressHandler: { completed, currentName in
                    if completed == 1 || completed == totalItems || completed % 4 == 0 {
                        Task { @MainActor in
                            progressModel.update(
                                completed: completed,
                                subtitle: activeLanguage.text("folders.task.processed_progress", completed, totalItems, currentName)
                            )
                        }
                    }
                },
                conflictResolver: resolver
            )
            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                progressModel.finish()
                self.outcomeResult = FileIOResultWrapper(result: result)
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
        progressModel.attach(worker)
    }

    private func executePasteAction(_ clip: ClipboardItem) {
        guard !taskProgress.isRunning else {
            presentOperationError(language.text("folders.error.task_already_running"))
            return
        }
        let baseDir = currentURL.standardizedFileURL
        let destName = clip.url.lastPathComponent
        guard !destName.isEmpty, destName != "/", destName != "." else { return }
        let source = clip.url.standardizedFileURL
        let dest = baseDir.appendingPathComponent(destName).standardizedFileURL

        var sourceIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory),
           sourceIsDirectory.boolValue {
            let sourcePath = source.path
            let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            if dest.path == sourcePath || dest.path.hasPrefix(sourcePrefix) {
                presentOperationError(language.text("folders.error.paste_into_self"))
                return
            }
        }

        if clip.isCut && source == dest {
            presentOperationError(language.text("folders.error.cut_same_folder"))
            return
        }

        let promptCoordinator = ConflictPromptCoordinator()
        let resolver = makeConflictResolver(using: promptCoordinator)
        let activeLanguage = language
        let progressModel = taskProgress

        progressModel.begin(
            title: clip.isCut
                ? activeLanguage.text("folders.task.moving", destName)
                : activeLanguage.text("folders.task.copying", destName),
            subtitle: activeLanguage.text("folders.task.preparing")
        )

        let worker = Task.detached(priority: .userInitiated) {
            _ = ContainerStore.ensureContainerAccess(for: baseDir.path, requireWrite: true)
            let totalItems = Self.countItemsRecursively(at: source)
            await MainActor.run {
                progressModel.update(
                    completed: 0,
                    total: totalItems,
                    subtitle: activeLanguage.text("folders.task.item_progress_init", totalItems, destName)
                )
            }
            let result = await FileIOEngine.shared.copyAndMerge(
                from: source,
                to: dest,
                progressHandler: { completed, currentName in
                    if completed == 1 || completed == totalItems || completed % 4 == 0 {
                        Task { @MainActor in
                            progressModel.update(
                                completed: completed,
                                subtitle: activeLanguage.text("folders.task.processed_progress", completed, totalItems, currentName)
                            )
                        }
                    }
                },
                conflictResolver: resolver
            )

            if clip.isCut {
                if FileIOEngine.shared.canDeleteCutSource(
                    sourceURL: source,
                    destinationURL: dest,
                    result: result
                ) {
                    await MainActor.run {
                        progressModel.update(
                            completed: totalItems,
                            subtitle: activeLanguage.text("folders.task.cleaning_cut_source")
                        )
                    }
                    do {
                        try await FileIOEngine.shared.deleteItem(at: source)
                        ContainerMetadataCache.shared.invalidate(path: source.deletingLastPathComponent().path)
                    } catch {
                        log("paste: cut completed but could not remove source: \(error.localizedDescription)")
                    }
                } else {
                    log("paste: keeping cut source because not every item was copied")
                }
            }

            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                progressModel.finish()
                self.clipboardItem = nil
                self.outcomeResult = FileIOResultWrapper(result: result)
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
        progressModel.attach(worker)
    }

    private func extractArchive(entry: FileEntry, intoNewFolder: Bool) {
        guard entry.name.lowercased().hasSuffix(".zip") else { return }
        guard !taskProgress.isRunning else {
            presentOperationError(language.text("folders.error.task_already_running"))
            return
        }
        let srcURL = URL(fileURLWithPath: entry.path)
        let baseDir = currentURL.standardizedFileURL
        let destinationDir: URL
        if intoNewFolder {
            let baseName = srcURL.deletingPathExtension().lastPathComponent
            destinationDir = baseDir.appendingPathComponent(baseName, isDirectory: true)
        } else {
            destinationDir = baseDir
        }

        let promptCoordinator = ConflictPromptCoordinator()
        let resolver = makeConflictResolver(using: promptCoordinator)

        let activeLanguage = language
        let progressModel = taskProgress
        progressModel.begin(
            title: activeLanguage.text("folders.task.extracting", entry.name),
            subtitle: activeLanguage.text("folders.task.unpacking_archive")
        )

        let worker = Task.detached(priority: .userInitiated) {
            _ = ContainerStore.ensureContainerAccess(for: destinationDir.path, requireWrite: true)
            let tempStaging = FileManager.default.temporaryDirectory
                .appendingPathComponent("Extract_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempStaging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempStaging) }

            do {
                var extractedFileCount = 0
                let ext = srcURL.pathExtension.lowercased()
                if ext == "zip" {
                    // Prefer low-memory C streaming extractor so multi-hundred-MB ZIPs never bloat RAM;
                    // fallback to PatchZipConverter for ZIP64 archives.
                    do {
                        extractedFileCount = try ZIPArchiveExtractor.extractFlatContents(
                            archiveURL: srcURL,
                            into: tempStaging,
                            shouldCancel: { Task.isCancelled },
                            progressHandler: { extracted, total, entryName in
                                Task { @MainActor in
                                    progressModel.update(
                                        completed: extracted,
                                        total: total,
                                        subtitle: activeLanguage.text("folders.task.processed_progress", extracted, total, entryName)
                                    )
                                }
                            }
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch ZIPArchiveExtractorError.expandedTooLarge {
                        throw ZIPArchiveExtractorError.expandedTooLarge
                    } catch ZIPArchiveExtractorError.symbolicLinkUnsupported {
                        throw ZIPArchiveExtractorError.symbolicLinkUnsupported
                    } catch {
                        let archiveSize = (try? srcURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(archiveSize)) else {
                            throw ZIPArchiveExtractorError.expandedTooLarge
                        }
                        let zipData = try Data(contentsOf: srcURL)
                        let entries = try PatchZipConverter.shared.parseZipArchive(zipData)
                        for (relPath, fileData) in entries {
                            if Task.isCancelled { throw CancellationError() }
                            let normalized = relPath.replacingOccurrences(of: "\\", with: "/")
                            let parts = normalized
                                .split(separator: "/", omittingEmptySubsequences: true)
                                .map(String.init)
                                .filter { $0 != "." }
                            guard !parts.isEmpty,
                                  !parts.contains(".."),
                                  parts.first != "__MACOSX",
                                  parts.last != ".DS_Store",
                                  parts.last?.lowercased() != "patch.json" else {
                                continue
                            }
                            var targetFileURL = tempStaging
                            for (idx, part) in parts.enumerated() {
                                targetFileURL.appendPathComponent(part, isDirectory: idx < parts.count - 1)
                            }
                            try FileManager.default.createDirectory(at: targetFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try fileData.write(to: targetFileURL, options: .atomic)
                            extractedFileCount += 1
                        }
                    }
                    // Strip stray patch.json if present at archive root
                    let strayPatchJSON = tempStaging.appendingPathComponent("patch.json")
                    if FileManager.default.fileExists(atPath: strayPatchJSON.path) {
                        try? FileManager.default.removeItem(at: strayPatchJSON)
                    }
                }

                if Task.isCancelled { throw CancellationError() }

                let totalItems = extractedFileCount > 0 ? extractedFileCount : Self.countItemsRecursively(at: tempStaging)
                await MainActor.run {
                    progressModel.update(
                        completed: 0,
                        total: totalItems,
                        subtitle: activeLanguage.text("folders.task.copying_extracted", totalItems)
                    )
                }

                try FileIOEngine.createDirectoryIfNeeded(at: destinationDir)
                let result = await FileIOEngine.shared.copyAndMerge(
                    from: tempStaging,
                    to: destinationDir,
                    progressHandler: { completed, currentName in
                        if completed == 1 || completed == totalItems || completed % 4 == 0 {
                            Task { @MainActor in
                                progressModel.update(
                                    completed: min(completed, totalItems),
                                    subtitle: activeLanguage.text("folders.task.copied_progress", completed, totalItems, currentName)
                                )
                            }
                        }
                    },
                    conflictResolver: resolver
                )

                ContainerMetadataCache.shared.invalidate(path: baseDir.path)
                await MainActor.run {
                    progressModel.finish()
                    self.selectedArchiveForExtraction = nil
                    self.outcomeResult = FileIOResultWrapper(result: result)
                    self.loadCurrentDirectory(forceRefresh: true)
                }
            } catch is CancellationError {
                await MainActor.run {
                    progressModel.finish()
                    self.selectedArchiveForExtraction = nil
                    self.loadCurrentDirectory(forceRefresh: true)
                }
            } catch {
                await MainActor.run {
                    progressModel.finish()
                    self.selectedArchiveForExtraction = nil
                    if let extractorError = error as? ZIPArchiveExtractorError,
                       extractorError == .expandedTooLarge {
                        self.presentOperationError(activeLanguage.text("folders.error.zip_size_limit"))
                    } else if let extractorError = error as? ZIPArchiveExtractorError,
                              extractorError == .symbolicLinkUnsupported {
                        self.presentOperationError(activeLanguage.text("error.filemanager.symlink_unsupported"))
                    } else {
                        self.presentOperationError(activeLanguage.text("folders.error.extract_failed", error.localizedDescription))
                    }
                    log("extraction failed: \(error.localizedDescription)")
                }
            }
        }
        progressModel.attach(worker)
    }

    // MARK: - Icon Helpers
    private func iconName(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        let ext = entry.name.split(separator: ".").last?.lowercased() ?? ""
        switch ext {
        case "zip", "3105": return "archivebox.fill"
        case "json", "plist", "xml": return "doc.text.fill"
        case "png", "jpg", "jpeg": return "photo.fill"
        case "mp3", "wav", "m4a": return "music.note"
        case "mp4", "mov": return "film.fill"
        default: return "doc.fill"
        }
    }

    private func iconBackgroundColor(for entry: FileEntry) -> Color {
        if entry.isDirectory { return TotoroxTheme.mintAccent.opacity(0.12) }
        let ext = entry.name.split(separator: ".").last?.lowercased() ?? ""
        switch ext {
        case "zip", "3105": return Color.purple.opacity(0.12)
        case "json", "plist": return Color.blue.opacity(0.12)
        case "png", "jpg": return Color.pink.opacity(0.12)
        default: return TotoroxTheme.searchBackground
        }
    }

    private func iconForegroundColor(for entry: FileEntry) -> Color {
        if entry.isDirectory { return TotoroxTheme.mintAccent }
        let ext = entry.name.split(separator: ".").last?.lowercased() ?? ""
        switch ext {
        case "zip", "3105": return Color.purple
        case "json", "plist": return Color.blue
        case "png", "jpg": return Color.pink
        default: return TotoroxTheme.textSecondary
        }
    }
}

// MARK: - File Info Inspector Sheet

struct FileInfoInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    let entry: FileEntry
    @State private var copiedPath = false
    @State private var directorySizeText: String? = nil
    @State private var isCalculatingDirSize = false
    @State private var dirCalculationTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header Card
                    VStack(spacing: 12) {
                        if let appIcon = entry.appIcon {
                            Image(uiImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                                )
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(TotoroxTheme.mintAccent.opacity(0.12))
                                    .frame(width: 64, height: 64)
                                Image(systemName: entry.isDirectory ? "folder.fill" : (entry.isSymlink ? "link" : "doc.fill"))
                                    .font(.system(size: 32))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                            }
                        }

                        Text(entry.displayTitle)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        if entry.isAppContainer, let bid = entry.bundleID {
                            Text(bid)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(TotoroxTheme.mintAccent.opacity(0.12))
                                .clipShape(Capsule())
                        } else {
                            Text(entry.typeDescription)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .totoroxCard()

                    // Details Card
                    VStack(alignment: .leading, spacing: 14) {
                        Text(language.text("folders.info.section_title"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        // Full path with copy button
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(language.text("folders.info.full_path"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = entry.path
                                    copiedPath = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        copiedPath = false
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                                        Text(copiedPath ? language.text("folders.info.copied") : language.text("folders.info.copy"))
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                }
                            }

                            Text(entry.path)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(TotoroxTheme.searchBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Divider()

                        // Size row: for directories calculate recursively, for files show exact bytes
                        if entry.isDirectory {
                            HStack(alignment: .top) {
                                Text(language.text("folders.info.folder_size"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                Spacer()
                                if isCalculatingDirSize {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text(language.text("folders.info.calculating"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(TotoroxTheme.textSecondary)
                                    }
                                } else if let sizeText = directorySizeText {
                                    Text(sizeText)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                        .multilineTextAlignment(.trailing)
                                } else {
                                    Text(entry.childCountText)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                }
                            }
                        } else {
                            inspectorRow(label: language.text("folders.info.exact_size"), value: entry.exactBytesText)
                        }

                        Divider()
                        inspectorRow(label: language.text("folders.info.created_at"), value: entry.formattedCreatedDate ?? language.text("folders.info.unavailable"))
                        Divider()
                        inspectorRow(label: language.text("folders.info.modified_at"), value: entry.formattedModifiedDate ?? language.text("folders.info.unavailable"))
                        Divider()
                        inspectorRow(
                            label: language.text("folders.info.posix_permissions"),
                            value: language.text("folders.info.permissions_value", entry.symbolicPermissions, entry.octalPermissions)
                        )
                    }
                    .totoroxCard()
                }
                .padding(16)
            }
            .background(TotoroxTheme.pageBackground)
            .navigationTitle(language.text("folders.info.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.bold)
                }
            }
            .onAppear {
                if entry.isDirectory {
                    if let cached = ContainerMetadataCache.shared.cachedDirectorySize(for: entry.path) {
                        self.directorySizeText = cached.formattedText
                    } else {
                        isCalculatingDirSize = true
                        dirCalculationTask = Task.detached(priority: .userInitiated) {
                            let result = await DirectorySizeService.calculateSize(at: entry.path)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                self.directorySizeText = result.formattedText
                                self.isCalculatingDirSize = false
                            }
                        }
                    }
                }
            }
            .onDisappear {
                dirCalculationTask?.cancel()
            }
        }
    }

    private func inspectorRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TotoroxTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(TotoroxTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}
