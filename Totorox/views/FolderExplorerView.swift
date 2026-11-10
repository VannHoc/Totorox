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
}

// MARK: - DirectoryViewModel (Pure Read-Only Disk Directory Browser by Absolute Path)

@MainActor
final class DirectoryViewModel: ObservableObject {
    @Published private(set) var entries: [FileEntry] = []
    @Published var isLoading: Bool = false
    private(set) var activeCanonicalPath: String = ""

    /// Strictly Read-Only directory loader. Never executes mkdir/copyItem/moveItem
    /// and never invokes AppContainerScanner. Always clears old entries before assigning
    /// fresh results from disk.
    func loadDirectory(at url: URL, forceRefresh: Bool = false) {
        let path = url.path
        let canonPath = ContainerMetadataCache.canonicalPath(path)

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
            Task.detached(priority: .utility) {
                let loaded = ContainerStore.readDirectoryEntriesFromDisk(at: path)
                ContainerMetadataCache.shared.storeList(loaded, for: canonPath)
                if loaded != cached {
                    await MainActor.run {
                        guard self.activeCanonicalPath == canonPath else { return }
                        self.entries.removeAll()
                        self.entries = loaded
                    }
                }
            }
            return
        }

        entries.removeAll()
        isLoading = true

        Task.detached(priority: .userInitiated) {
            let loaded = ContainerStore.readDirectoryEntriesFromDisk(at: path)
            ContainerMetadataCache.shared.storeList(loaded, for: canonPath)

            await MainActor.run {
                guard self.activeCanonicalPath == canonPath else { return }
                self.entries.removeAll()
                self.entries = loaded
                self.isLoading = false
            }
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
    @StateObject private var directoryVM = DirectoryViewModel()
    @StateObject private var appListVM = AppListViewModel()
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
                            Text("Lùi")
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

                    // Quick location shortcuts
                    Menu {
                        Button("Thư mục Documents") {
                            navigateTo(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)
                        }
                        Button("Thư mục Containers (AppData)") {
                            let containers = URL(fileURLWithPath: ContainerStore.appDataRoot)
                            navigateTo(containers)
                        }
                        Button("Thư mục Tạm (Tmp)") {
                            navigateTo(FileManager.default.temporaryDirectory)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 13))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                            Text("Vị trí nhanh")
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
                        Picker("Sắp xếp", selection: $sortOption) {
                            ForEach(FolderSortOption.allCases) { option in
                                Text(option.rawValue).tag(option)
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
                        ? "Tìm ứng dụng hoặc Bundle ID..."
                        : "Tìm kiếm trong thư mục này..."
                )
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
                                    Text("Đang tải nội dung...")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                } else {
                                    Image(systemName: "folder")
                                        .font(.system(size: 44))
                                        .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.4))
                                    Text(searchText.isEmpty ? "Thư mục trống hoặc không có quyền đọc" : "Không tìm thấy mục phù hợp")
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
                            Text("\(visibleEntries.count) mục (\(fileCount) tệp, \(dirCount) thư mục)")
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
        .alert("Tạo thư mục mới", isPresented: $showNewFolderDialog) {
            TextField("Tên thư mục", text: $newFolderName)
            Button("Tạo") {
                createNewFolder()
            }
            Button("Hủy", role: .cancel) {}
        }
        .alert("Đổi tên", isPresented: $showRenameDialog) {
            TextField("Tên mới", text: $newRenameName)
            Button("Lưu") {
                applyRename()
            }
            Button("Hủy", role: .cancel) {}
        }
        .alert("Xác nhận xóa?", isPresented: $showDeleteConfirmation) {
            Button("Xóa vĩnh viễn", role: .destructive) {
                applyDelete()
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Thao tác này sẽ xóa '\(itemToDelete?.name ?? "")' và không thể hoàn tác.")
        }
        .sheet(isPresented: $showShareSheet) {
            if let share = shareURL {
                ActivityViewControllerWrapper(activityItems: [share])
            }
        }
        .sheet(isPresented: $showImportPicker) {
            DocumentPickerWrapper { pickedURL in
                importFileIntoCurrentDirectory(pickedURL)
            }
        }
        .sheet(item: $inspectingEntry) { entry in
            FileInfoInspectorSheet(entry: entry)
        }
        .confirmationDialog(
            "Giải nén tệp: \(selectedArchiveForExtraction?.name ?? "")",
            isPresented: Binding(
                get: { selectedArchiveForExtraction != nil },
                set: { if !$0 { selectedArchiveForExtraction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = selectedArchiveForExtraction {
                Button("Giải nén tại đây (Extract Here)") {
                    extractArchive(entry: entry, intoNewFolder: false)
                }
                Button("Giải nén vào thư mục mới") {
                    extractArchive(entry: entry, intoNewFolder: true)
                }
                Button("Hủy", role: .cancel) {
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
        }
        .overlay {
            if let conflict = activeConflict {
                ZStack {
                    Color.black.opacity(0.4)
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
                if lower.hasSuffix(".zip") || lower.hasSuffix(".3105") {
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
                                    Text("Thư mục")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                    if let count = entry.childCount {
                                        Text("(\(count) tệp)")
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
            Label("Thông tin chi tiết (Get Info)", systemImage: "info.circle")
        }

        let lower = entry.name.lowercased()
        if lower.hasSuffix(".zip") || lower.hasSuffix(".3105") {
            Divider()
            Button {
                extractArchive(entry: entry, intoNewFolder: false)
            } label: {
                Label("Giải nén tại đây (Extract Here)", systemImage: "archivebox")
            }
            Button {
                extractArchive(entry: entry, intoNewFolder: true)
            } label: {
                Label("Giải nén vào thư mục mới", systemImage: "folder.badge.plus")
            }
        }

        Divider()

        Button {
            let itemURL = URL(fileURLWithPath: entry.path)
            clipboardItem = ClipboardItem(url: itemURL, isCut: false)
        } label: {
            Label("Sao chép (Copy)", systemImage: "doc.on.doc")
        }

        Button {
            let itemURL = URL(fileURLWithPath: entry.path)
            clipboardItem = ClipboardItem(url: itemURL, isCut: true)
        } label: {
            Label("Cắt (Cut)", systemImage: "scissors")
        }

        Button {
            itemToRename = entry
            newRenameName = entry.name
            showRenameDialog = true
        } label: {
            Label("Đổi tên", systemImage: "pencil")
        }

        Button {
            shareURL = URL(fileURLWithPath: entry.path)
            showShareSheet = true
        } label: {
            Label("Chia sẻ", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            itemToDelete = entry
            showDeleteConfirmation = true
        } label: {
            Label("Xóa", systemImage: "trash")
        }
    }

    // MARK: - Floating Clipboard Bar
    private func floatingClipboardBar(_ clip: ClipboardItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: clip.isCut ? "scissors" : "doc.on.doc.fill")
                .font(.system(size: 18))
                .foregroundStyle(TotoroxTheme.mintAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.isCut ? "Đang cắt:" : "Đang giữ bản sao:")
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
                Text("Dán vào đây")
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
        let canonDest = ContainerMetadataCache.canonicalPath(url.path)
        searchText = ""
        pendingScrollToID = savedScrollItemID[canonDest]
        currentURL = url
        rebuildBreadcrumbs()
        loadCurrentDirectory(forceRefresh: false)
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
    private func createNewFolder() {
        let folderName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty else { return }
        let baseDir = currentURL
        let target = baseDir.appendingPathComponent(folderName)
        Task.detached(priority: .userInitiated) {
            try? await FileIOEngine.shared.createFolder(at: target)
            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
    }

    private func applyRename() {
        let newName = newRenameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = itemToRename, !newName.isEmpty else { return }
        let baseDir = currentURL
        let src = URL(fileURLWithPath: item.path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        Task.detached(priority: .userInitiated) {
            try? await FileIOEngine.shared.renameItem(at: src, to: dst)
            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
    }

    private func applyDelete() {
        guard let item = itemToDelete else { return }
        let baseDir = currentURL
        let src = URL(fileURLWithPath: item.path)
        Task.detached(priority: .userInitiated) {
            try? await FileIOEngine.shared.deleteItem(at: src)
            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
    }

    private func importFileIntoCurrentDirectory(_ src: URL) {
        let baseDir = currentURL
        let dst = baseDir.appendingPathComponent(src.lastPathComponent)
        Task.detached(priority: .userInitiated) {
            _ = ContainerStore.ensureContainerAccess(for: baseDir.path)
            let result = await FileIOEngine.shared.copyAndMerge(from: src, to: dst) { s, d, k in
                await withCheckedContinuation { cont in
                    Task { @MainActor in
                        self.activeConflict = FileConflictInfo(
                            sourceURL: s,
                            destinationURL: d,
                            conflictKind: k,
                            continuation: { r in
                                self.activeConflict = nil
                                cont.resume(returning: r)
                            }
                        )
                    }
                }
            }
            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                self.outcomeResult = FileIOResultWrapper(result: result)
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
    }

    private func executePasteAction(_ clip: ClipboardItem) {
        let baseDir = currentURL
        let dest = baseDir.appendingPathComponent(clip.url.lastPathComponent)
        Task.detached(priority: .userInitiated) {
            _ = ContainerStore.ensureContainerAccess(for: baseDir.path)
            let result = await FileIOEngine.shared.copyAndMerge(from: clip.url, to: dest) { s, d, k in
                await withCheckedContinuation { cont in
                    Task { @MainActor in
                        self.activeConflict = FileConflictInfo(
                            sourceURL: s,
                            destinationURL: d,
                            conflictKind: k,
                            continuation: { r in
                                self.activeConflict = nil
                                cont.resume(returning: r)
                            }
                        )
                    }
                }
            }

            if clip.isCut && result.failed.isEmpty && !result.isCancelled {
                try? await FileIOEngine.shared.deleteItem(at: clip.url)
                ContainerMetadataCache.shared.invalidate(path: clip.url.deletingLastPathComponent().path)
            }

            ContainerMetadataCache.shared.invalidate(path: baseDir.path)
            await MainActor.run {
                self.clipboardItem = nil
                self.outcomeResult = FileIOResultWrapper(result: result)
                self.loadCurrentDirectory(forceRefresh: true)
            }
        }
    }

    private func extractArchive(entry: FileEntry, intoNewFolder: Bool) {
        let srcURL = URL(fileURLWithPath: entry.path)
        let baseDir = currentURL
        let destinationDir: URL
        if intoNewFolder {
            let baseName = srcURL.deletingPathExtension().lastPathComponent
            destinationDir = baseDir.appendingPathComponent(baseName, isDirectory: true)
        } else {
            destinationDir = baseDir
        }

        directoryVM.isLoading = true
        Task.detached(priority: .userInitiated) {
            _ = ContainerStore.ensureContainerAccess(for: destinationDir.path)
            let tempStaging = FileManager.default.temporaryDirectory.appendingPathComponent("Extract_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempStaging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempStaging) }

            do {
                let ext = srcURL.pathExtension.lowercased()
                if ext == "zip" {
                    let zipData = try Data(contentsOf: srcURL)
                    let entries = try PatchZipConverter.shared.parseZipArchive(zipData)
                    for (relPath, fileData) in entries {
                        let targetFileURL = tempStaging.appendingPathComponent(relPath)
                        try FileManager.default.createDirectory(at: targetFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fileData.write(to: targetFileURL, options: .atomic)
                    }
                } else if ext == "3105" {
                    let patchData = try Data(contentsOf: srcURL)
                    let decoded = try PatchPackageCodec.decode(patchData, password: nil)
                    for dir in decoded.project.directories {
                        let targetDir = tempStaging.appendingPathComponent(dir.relativePath)
                        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    }
                    for rule in decoded.project.rules {
                        let targetFile = tempStaging.appendingPathComponent(rule.relativePath)
                        try FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try rule.replacementData.write(to: targetFile, options: .atomic)
                    }
                }

                try FileIOEngine.createDirectoryIfNeeded(at: destinationDir)
                let result = await FileIOEngine.shared.copyAndMerge(from: tempStaging, to: destinationDir) { s, d, k in
                    await withCheckedContinuation { cont in
                        Task { @MainActor in
                            self.activeConflict = FileConflictInfo(
                                sourceURL: s,
                                destinationURL: d,
                                conflictKind: k,
                                continuation: { r in
                                    self.activeConflict = nil
                                    cont.resume(returning: r)
                                }
                            )
                        }
                    }
                }

                ContainerMetadataCache.shared.invalidate(path: baseDir.path)
                await MainActor.run {
                    self.directoryVM.isLoading = false
                    self.selectedArchiveForExtraction = nil
                    self.outcomeResult = FileIOResultWrapper(result: result)
                    self.loadCurrentDirectory(forceRefresh: true)
                }
            } catch {
                await MainActor.run {
                    self.directoryVM.isLoading = false
                    self.selectedArchiveForExtraction = nil
                    log("extraction failed: \(error.localizedDescription)")
                }
            }
        }
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
                        Text("THÔNG TIN CHI TIẾT")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)

                        // Full path with copy button
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Đường dẫn đầy đủ:")
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
                                        Text(copiedPath ? "Đã sao chép" : "Sao chép")
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
                                Text("Dung lượng thư mục")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                Spacer()
                                if isCalculatingDirSize {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Đang tính toán...")
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
                            inspectorRow(label: "Kích thước chính xác", value: entry.exactBytesText)
                        }

                        Divider()
                        inspectorRow(label: "Ngày tạo", value: entry.formattedCreatedDate ?? "Không có")
                        Divider()
                        inspectorRow(label: "Ngày sửa đổi", value: entry.formattedModifiedDate ?? "Không có")
                        Divider()
                        inspectorRow(
                            label: "Quyền POSIX",
                            value: "\(entry.symbolicPermissions) (Octal: \(entry.octalPermissions))"
                        )
                    }
                    .totoroxCard()
                }
                .padding(16)
            }
            .background(TotoroxTheme.pageBackground)
            .navigationTitle("Thông tin chi tiết")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
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
