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
    
    // Conflict & Outcome modals
    @State private var activeConflict: FileConflictInfo? = nil
    @State private var outcomeResult: OverwriteFileView.FileIOResultWrapper? = nil

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
                HStack {
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
                        loadCurrentDirectory()
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
            ScrollView {
                LazyVStack(spacing: 10) {
                    if filteredEntries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder")
                                .font(.system(size: 44))
                                .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.4))
                            Text("Thư mục trống hoặc không có quyền đọc")
                                .font(.system(size: 14))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(filteredEntries) { entry in
                            fileEntryCard(entry)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, clipboardItem != nil ? 80 : 20)
            }
            .background(TotoroxTheme.pageBackground)
        }
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
        .sheet(item: $outcomeResult) { wrapper in
            OverwriteOutcomeView(result: wrapper.result) {
                outcomeResult = nil
                loadCurrentDirectory()
            }
        }
        .overlay {
            if let conflict = activeConflict {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    WindowsConflictDialog(conflict: conflict)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - File & Folder Card View
    private func fileEntryCard(_ entry: FileEntry) -> some View {
        Button {
            if entry.isDirectory {
                let nextURL = currentURL.appendingPathComponent(entry.name)
                navigateTo(nextURL)
            }
        } label: {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconBackgroundColor(for: entry))
                        .frame(width: 44, height: 44)

                    Image(systemName: iconName(for: entry))
                        .font(.system(size: 20))
                        .foregroundStyle(iconForegroundColor(for: entry))
                }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if entry.isDirectory {
                            if let count = entry.childCount {
                                Text("\(count) mục")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                            }
                            TotoroxBadge(title: "Read / Write")
                        } else {
                            Text(entry.sizeText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textSecondary)

                            if let ext = entry.name.split(separator: ".").last {
                                Text(".\(ext)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(TotoroxTheme.mintAccent.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                Spacer()

                // Context Menu trigger
                Menu {
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

    private func loadCurrentDirectory() {
        isLoading = true
        Task {
            let handle = ContainerStore.grantContainerAccess(currentURL.path)
            defer {
                if handle >= 0 { bad_query_release(handle) }
            }

            let loaded = ContainerStore.listFiles(at: currentURL.path)
            await MainActor.run {
                self.entries = loaded.sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                self.isLoading = false
            }
        }
    }

    // MARK: - File Actions
    private func createNewFolder() {
        guard !newFolderName.isEmpty else { return }
        let target = currentURL.appendingPathComponent(newFolderName)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        loadCurrentDirectory()
    }

    private func applyRename() {
        guard let item = itemToRename, !newRenameName.isEmpty else { return }
        let src = currentURL.appendingPathComponent(item.name)
        let dst = currentURL.appendingPathComponent(newRenameName)
        try? FileManager.default.moveItem(at: src, to: dst)
        loadCurrentDirectory()
    }

    private func applyDelete() {
        guard let item = itemToDelete else { return }
        let src = currentURL.appendingPathComponent(item.name)
        try? FileManager.default.removeItem(at: src)
        loadCurrentDirectory()
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
                self.outcomeResult = OverwriteFileView.FileIOResultWrapper(result: result)
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
            }

            await MainActor.run {
                self.clipboardItem = nil
                self.outcomeResult = OverwriteFileView.FileIOResultWrapper(result: result)
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
