import SwiftUI
import UniformTypeIdentifiers

struct ClipboardItem {
    let url: URL
    let isCut: Bool
}

struct FolderExplorerView: View {
    @State private var currentURL: URL
    @State private var breadcrumbs: [URL] = []
    @State private var entries: [FileEntry] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false
    
    // Clipboard state
    @State private var clipboardItem: ClipboardItem? = nil
    
    // Scroll restoration & indicators
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
            // Default to app documents or containers directory
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
                HStack(spacing: 8) {
                    // Backward Button
                    Button {
                        if canGoBack {
                            let parent = currentURL.deletingLastPathComponent()
                            navigateTo(parent)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .bold))
                            Text("Lùi")
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
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
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundStyle(TotoroxTheme.mintAccent)
                            Text("Vị trí nhanh")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(Capsule())
                    }

                    Spacer()

                    // New Folder Button
                    Button {
                        newFolderName = ""
                        showNewFolderDialog = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(Circle())
                    }

                    // Import File Button
                    Button {
                        showImportPicker = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(Circle())
                    }

                    // Refresh Button
                    Button {
                        loadCurrentDirectory(forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)

                // Breadcrumb Navigation Bar
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
                                    Text(crumb.lastPathComponent.isEmpty ? "Root" : crumb.lastPathComponent)
                                        .font(.system(size: 12, weight: index == breadcrumbs.count - 1 ? .bold : .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(index == breadcrumbs.count - 1 ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                .foregroundColor(index == breadcrumbs.count - 1 ? .white : TotoroxTheme.textPrimary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            if index < breadcrumbs.count - 1 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.5))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Filter search
                TotoroxSearchBar(text: $searchText, placeholder: "Tìm kiếm trong thư mục này...")
            }
            .padding(.bottom, 8)
            .background(TotoroxTheme.cardBackground)
            .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 2)

            // Content List
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 10) {
                        if filteredEntries.isEmpty {
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
                                    Text("Thư mục trống hoặc không có quyền đọc")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        } else {
                            ForEach(filteredEntries) { entry in
                                fileEntryCard(entry)
                                    .id(entry.path)
                            }

                            if !filteredEntries.isEmpty {
                                Text("\(filteredEntries.count) mục")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 14)
                            }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, clipboardItem != nil ? 80 : 20)
                }
                .scrollIndicators(.visible)
                .onChange(of: entries) { _ in
                    if let targetID = pendingScrollToID {
                        pendingScrollToID = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                scrollProxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 80)
                }
                .background(TotoroxTheme.pageBackground)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 25, coordinateSpace: .local)
                .onEnded { value in
                    if value.startLocation.x < 60 && value.translation.width > 80 && abs(value.translation.height) < 60 {
                        if canGoBack {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                let parent = currentURL.deletingLastPathComponent()
                                navigateTo(parent)
                            }
                        }
                    }
                }
        )
        .overlay(alignment: .bottom) {
            // Floating Clipboard Bar
            if let clip = clipboardItem {
                floatingClipboardBar(clip)
            }
        }
        .onAppear {
            rebuildBreadcrumbs()
            loadCurrentDirectory()
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

    // MARK: - File & Folder Card View
    private func fileEntryCard(_ entry: FileEntry) -> some View {
        Button {
            if entry.isDirectory {
                savedScrollItemID[currentURL.path] = entry.path
                let nextURL = currentURL.appendingPathComponent(entry.name)
                navigateTo(nextURL)
            } else {
                let lower = entry.name.lowercased()
                if lower.hasSuffix(".zip") || lower.hasSuffix(".3105") {
                    selectedArchiveForExtraction = entry
                }
            }
        } label: {
            HStack(spacing: 12) {
                // Icon: Uniform default icon (all folders identical mint squircle, matching original design)
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconBackgroundColor(for: entry))
                        .frame(width: 44, height: 44)

                    Image(systemName: iconName(for: entry))
                        .font(.system(size: 20))
                        .foregroundStyle(iconForegroundColor(for: entry))
                }

                // Info: Line 1 (Name in com.... format) & Line 2 (Metadata)
                VStack(alignment: .leading, spacing: 3) {
                    // Line 1: Primary Title (appName if available, else bundleID, else UUID name)
                    let resolvedBID = entry.bundleID ?? ContainerStore.bundleID(forUUID: entry.name)
                    let titleText: String = {
                        if entry.isAppContainer {
                            if let appName = entry.appName, !appName.isEmpty && appName != resolvedBID {
                                return appName
                            }
                            if let bid = resolvedBID, !bid.isEmpty {
                                return bid
                            }
                            return entry.name
                        }
                        return entry.name
                    }()

                    Text(titleText)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if entry.isAppContainer {
                        VStack(alignment: .leading, spacing: 2) {
                            // Line 2: Bundle ID (if Line 1 is appName)
                            if let appName = entry.appName, let bid = resolvedBID,
                               !appName.isEmpty && !bid.isEmpty && appName != bid {
                                Text(bid)
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                    .lineLimit(1)
                            }
                            
                            // Line 3: UDID: <UUID>, [X mục], và Data: <Đường dẫn>
                            HStack(spacing: 8) {
                                if let shortId = entry.shortUUID {
                                    Text("UDID: \(shortId)")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                        .lineLimit(1)
                                }
                                if let count = entry.childCount {
                                    Text("\(count) mục")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                                Text("Data: \(entry.path)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } else {
                        // Regular metadata HStack
                        HStack(spacing: 6) {
                            if entry.isDirectory {
                                Text(entry.childCountText)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(TotoroxTheme.mintAccent.opacity(0.12))
                                    .clipShape(Capsule())
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            } else {
                                Text(entry.sizeText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)

                                if !entry.extensionBadge.isEmpty {
                                    Text(entry.extensionBadge)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                                        .clipShape(Capsule())
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }

                            if let mod = entry.formattedModifiedDate {
                                Text("•")
                                    .font(.system(size: 9))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.4))
                                    .fixedSize(horizontal: true, vertical: false)
                                Text(mod)
                                    .font(.system(size: 11))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                // Info (i) Button
                Button {
                    inspectingEntry = entry
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                // Context Menu trigger
                Menu {
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
                        let itemURL = currentURL.appendingPathComponent(entry.name)
                        clipboardItem = ClipboardItem(url: itemURL, isCut: false)
                    } label: {
                        Label("Sao chép (Copy)", systemImage: "doc.on.doc")
                    }

                    Button {
                        let itemURL = currentURL.appendingPathComponent(entry.name)
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
                        shareURL = currentURL.appendingPathComponent(entry.name)
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
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }
            .totoroxCard()
        }
        .buttonStyle(.plain)
        .contextMenu {
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
                let itemURL = currentURL.appendingPathComponent(entry.name)
                clipboardItem = ClipboardItem(url: itemURL, isCut: false)
            } label: {
                Label("Sao chép (Copy)", systemImage: "doc.on.doc")
            }

            Button {
                let itemURL = currentURL.appendingPathComponent(entry.name)
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
                shareURL = currentURL.appendingPathComponent(entry.name)
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

            // Paste button
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

            // Cancel button
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

    // MARK: - Navigation & Loading
    private var filteredEntries: [FileEntry] {
        if searchText.isEmpty { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func navigateTo(_ url: URL) {
        let destPath = url.path
        if let savedID = savedScrollItemID[destPath] {
            pendingScrollToID = savedID
        } else {
            pendingScrollToID = nil
        }
        currentURL = url
        rebuildBreadcrumbs()
        loadCurrentDirectory()
    }

    private func rebuildBreadcrumbs() {
        var crumbs: [URL] = []
        var curr = currentURL.standardizedFileURL
        while curr.path != "/" {
            crumbs.insert(curr, at: 0)
            curr = curr.deletingLastPathComponent()
        }
        crumbs.insert(URL(fileURLWithPath: "/"), at: 0)
        self.breadcrumbs = crumbs
    }

    private func loadCurrentDirectory(forceRefresh: Bool = false) {
        let path = currentURL.path
        if !forceRefresh, let cached = ContainerMetadataCache.shared.cachedList(for: path) {
            self.entries = cached
            self.isLoading = false
            if let targetID = self.pendingScrollToID {
                self.pendingScrollToID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    // Triggers change handler or direct scrollTo if needed
                }
            }
        } else {
            self.isLoading = true
        }

        Task.detached(priority: .userInitiated) {
            let grantHandle = ContainerStore.grantContainerAccess(path)
            defer {
                if grantHandle >= 0 { bad_query_release(grantHandle) }
            }

            let loaded = ContainerStore.listFiles(at: path)
            ContainerMetadataCache.shared.storeList(loaded, for: path)

            await MainActor.run {
                if self.currentURL.path == path {
                    self.entries = loaded
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - File Actions
    private func createNewFolder() {
        guard !newFolderName.isEmpty else { return }
        let target = currentURL.appendingPathComponent(newFolderName)
        do {
            try FileIOEngine.createDirectoryIfNeeded(at: target)
        } catch {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        ContainerMetadataCache.shared.invalidate(path: currentURL.path)
        loadCurrentDirectory(forceRefresh: true)
    }

    private func applyRename() {
        guard let item = itemToRename, !newRenameName.isEmpty else { return }
        let src = currentURL.appendingPathComponent(item.name)
        let dst = currentURL.appendingPathComponent(newRenameName)
        if rename(src.path, dst.path) != 0 {
            try? FileManager.default.moveItem(at: src, to: dst)
        }
        ContainerMetadataCache.shared.invalidate(path: currentURL.path)
        loadCurrentDirectory(forceRefresh: true)
    }

    private func applyDelete() {
        guard let item = itemToDelete else { return }
        let src = currentURL.appendingPathComponent(item.name)
        if item.isDirectory {
            try? FileManager.default.removeItem(at: src)
            if FileManager.default.fileExists(atPath: src.path) {
                _ = rmdir(src.path)
            }
        } else {
            _ = unlink(src.path)
            try? FileManager.default.removeItem(at: src)
        }
        ContainerMetadataCache.shared.invalidate(path: currentURL.path)
        loadCurrentDirectory(forceRefresh: true)
    }

    private func importFileIntoCurrentDirectory(_ src: URL) {
        Task {
            let engine = FileIOEngine()
            let dst = currentURL.appendingPathComponent(src.lastPathComponent)
            let result = await engine.copyAndMerge(from: src, to: dst) { s, d, k in
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
            await MainActor.run {
                ContainerMetadataCache.shared.invalidate(path: currentURL.path)
                self.outcomeResult = FileIOResultWrapper(result: result)
            }
        }
    }

    private func executePasteAction(_ clip: ClipboardItem) {
        let dest = currentURL.appendingPathComponent(clip.url.lastPathComponent)
        Task {
            let engine = FileIOEngine()
            let result = await engine.copyAndMerge(from: clip.url, to: dest) { s, d, k in
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
                try? FileManager.default.removeItem(at: clip.url)
                ContainerMetadataCache.shared.invalidate(path: clip.url.deletingLastPathComponent().path)
            }

            await MainActor.run {
                self.clipboardItem = nil
                ContainerMetadataCache.shared.invalidate(path: currentURL.path)
                self.outcomeResult = FileIOResultWrapper(result: result)
            }
        }
    }

    private func extractArchive(entry: FileEntry, intoNewFolder: Bool) {
        let srcURL = URL(fileURLWithPath: entry.path)
        let destinationDir: URL
        if intoNewFolder {
            let baseName = srcURL.deletingPathExtension().lastPathComponent
            destinationDir = currentURL.appendingPathComponent(baseName, isDirectory: true)
        } else {
            destinationDir = currentURL
        }

        isLoading = true
        Task {
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

                // Copy and merge from staging to destination directory with Windows conflict rules
                try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                let engine = FileIOEngine()
                let result = await engine.copyAndMerge(from: tempStaging, to: destinationDir) { s, d, k in
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

                await MainActor.run {
                    self.isLoading = false
                    self.selectedArchiveForExtraction = nil
                    ContainerMetadataCache.shared.invalidate(path: currentURL.path)
                    self.outcomeResult = FileIOResultWrapper(result: result)
                    self.loadCurrentDirectory(forceRefresh: true)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
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

                        Text(entry.appName ?? entry.name)
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
