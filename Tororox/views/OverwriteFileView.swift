import SwiftUI
import UniformTypeIdentifiers

struct TargetAppItem: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleID: String
    let containerPath: String
    let iconName: String
    var iconImage: UIImage? = nil

    static func == (lhs: TargetAppItem, rhs: TargetAppItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum OverwriteFilterCategory: String, CaseIterable {
    case all = "Tất cả"
    case app = "App"
    case patch3105 = "Gói .3105"
}

struct OverwriteFileView: View {
    @State private var searchText: String = ""
    @State private var selectedFilter: OverwriteFilterCategory = .all
    @State private var installedApps: [TargetAppItem] = []
    @State private var selectedApp: TargetAppItem? = nil
    
    // File execution sheet & state
    @State private var showExecutionSheet = false
    @State private var selectedContainerTargetFolder: String = "Documents"
    @State private var sourceURL: URL? = nil
    @State private var isExecuting: Bool = false
    @State private var executionProgress: Double = 0.0
    @State private var executionStatusText: String = ""
    
    // Outcome & Conflict Modals
    @State private var outcomeResult: FileIOResultWrapper? = nil
    @State private var activeConflict: FileConflictInfo? = nil
    @State private var showFilePicker = false
    
    // Container target directories
    @State private var containerFolders: [(title: String, badge: String, isSuccess: Bool)] = [
        ("Documents", "Read / Write", false),
        ("Library", "Read / Write", false),
        ("tmp", "Read / Write", false)
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Search bar
                TotoroxSearchBar(text: $searchText, placeholder: "Tìm container hoặc tệp...") {
                    // Filter action
                }
                .padding(.top, 4)

                // Container gần đây Header
                VStack(alignment: .leading, spacing: 12) {
                    Text("Container gần đây")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .padding(.horizontal, 16)

                    // Horizontal ScrollView for App Cards
                    if filteredApps.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(TotoroxTheme.mintAccent)
                            Text("Đang quét danh sách container ứng dụng...")
                                .font(.system(size: 13))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(TotoroxTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 16)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(filteredApps) { app in
                                    let isSelected = (selectedApp?.id == app.id)
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedApp = app
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            // App Icon
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(TotoroxTheme.searchBackground)
                                                    .frame(width: 54, height: 54)

                                                if let uiImg = app.iconImage {
                                                    Image(uiImage: uiImg)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 54, height: 54)
                                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                                } else {
                                                    Image(systemName: app.iconName)
                                                        .font(.system(size: 26))
                                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                                }
                                            }

                                            // App title
                                            Text(app.name)
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(TotoroxTheme.textPrimary)
                                                .lineLimit(1)

                                            // Bundle ID subline
                                            Text(app.bundleID)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(TotoroxTheme.textSecondary)
                                                .lineLimit(2)
                                                .frame(maxWidth: 110, alignment: .leading)
                                        }
                                        .padding(14)
                                        .frame(width: 140, height: 140, alignment: .topLeading)
                                        .background(TotoroxTheme.cardBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(isSelected ? TotoroxTheme.mintAccent : Color.clear, lineWidth: 2)
                                        )
                                        .shadow(color: Color.black.opacity(isSelected ? 0.08 : 0.04), radius: 8, x: 0, y: 3)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                // Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(OverwriteFilterCategory.allCases, id: \.self) { cat in
                            let isSelected = (selectedFilter == cat)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selectedFilter = cat
                                }
                            } label: {
                                Text(cat.rawValue)
                                    .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? .white : TotoroxTheme.textSecondary)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                    .background(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Container directories list
                VStack(spacing: 12) {
                    ForEach(filteredFolders, id: \.title) { item in
                        Button {
                            selectedContainerTargetFolder = item.title
                            showExecutionSheet = true
                        } label: {
                            HStack(spacing: 14) {
                                // Teal Folder Icon
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(TotoroxTheme.mintAccent.opacity(0.12))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)

                                    TotoroxBadge(
                                        title: item.badge,
                                        isAccent: item.isSuccess
                                    )
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
                            }
                            .totoroxCard()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                // Quick execute button
                Button {
                    showExecutionSheet = true
                } label: {
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text("Thực thi Đè File vào Container")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(TotoroxTheme.mintAccent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: TotoroxTheme.mintAccent.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 80)
        }
        .background(TotoroxTheme.pageBackground)
        .onAppear {
            loadDiscoveredApps()
        }
        .sheet(isPresented: $showExecutionSheet) {
            executionModalView
        }
        .sheet(item: $outcomeResult) { wrapper in
            OverwriteOutcomeView(result: wrapper.result) {
                outcomeResult = nil
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

    private var filteredApps: [TargetAppItem] {
        if searchText.isEmpty {
            return installedApps
        }
        return installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredFolders: [(title: String, badge: String, isSuccess: Bool)] {
        if selectedFilter == .patch3105 {
            return [("Gói .3105 Payload", "Sẵn sàng ghi đè", true)]
        }
        return containerFolders
    }

    private func loadDiscoveredApps() {
        Task {
            var discovered = ContainerStore.installedAppsFromAPI()
            if discovered.isEmpty {
                discovered = ContainerStore.installedAppsFromMCM()
            }
            if discovered.isEmpty {
                discovered = ContainerStore.containersFromFilesystem()
            }
            let catalog = ContainerStore.applicationBundleMetadataCatalog()
            if !catalog.isEmpty {
                discovered = ContainerStore.applyingBundleMetadata(to: discovered, catalog: catalog)
            }

            let sorted = discovered.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            for app in sorted {
                let uuid = (app.containerPath as NSString).lastPathComponent
                if UUID(uuidString: uuid) != nil {
                    let meta = AppContainerMetadata(
                        uuid: uuid,
                        containerPath: app.containerPath,
                        bundleID: app.bundleID,
                        appName: app.displayName.isEmpty ? app.bundleID : app.displayName,
                        icon: app.icon,
                        isUserApp: true,
                        modificationDate: nil
                    )
                    ContainerMetadataCache.shared.store(app: meta)
                }
            }

            await MainActor.run {
                self.installedApps = sorted.map { app in
                    TargetAppItem(
                        id: app.bundleID,
                        name: app.displayName.isEmpty ? app.bundleID : app.displayName,
                        bundleID: app.bundleID,
                        containerPath: app.containerPath,
                        iconName: "app.fill",
                        iconImage: app.icon
                    )
                }
                if self.selectedApp == nil || !self.installedApps.contains(where: { $0.id == self.selectedApp?.id }) {
                    self.selectedApp = self.installedApps.first
                }
            }

            // Asynchronously resolve icons in background without blocking launch
            Task.detached(priority: .background) {
                for app in sorted.prefix(25) {
                    if let icon = iconForBundleID(app.bundleID) {
                        let uuid = (app.containerPath as NSString).lastPathComponent
                        if let cached = ContainerMetadataCache.shared.cachedApp(forUUID: uuid) {
                            let updated = AppContainerMetadata(
                                uuid: uuid,
                                containerPath: cached.containerPath,
                                bundleID: cached.bundleID,
                                appName: cached.appName,
                                icon: icon,
                                isUserApp: true,
                                modificationDate: cached.modificationDate
                            )
                            ContainerMetadataCache.shared.store(app: updated)
                        }
                        await MainActor.run {
                            if let idx = self.installedApps.firstIndex(where: { $0.id == app.bundleID }) {
                                self.installedApps[idx].iconImage = icon
                            }
                            if self.selectedApp?.id == app.bundleID {
                                self.selectedApp?.iconImage = icon
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Overwrite Execution Modal
    private var executionModalView: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Target Info Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("ĐÍCH GHI ĐÈ:")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textSecondary)

                    HStack(spacing: 12) {
                        Image(systemName: "app.badge.checkmark.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(TotoroxTheme.mintAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedApp?.name ?? "Chưa chọn ứng dụng")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)

                            Text("\(selectedApp?.bundleID ?? "N/A") / \(selectedContainerTargetFolder)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                    }
                }
                .totoroxCard()

                // Source Selection
                VStack(alignment: .leading, spacing: 10) {
                    Text("NGUỒN DỮ LIỆU:")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textSecondary)

                    if let source = sourceURL {
                        HStack {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.lastPathComponent)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(source.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Đổi") { showFilePicker = true }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                        }
                    } else {
                        Button {
                            showFilePicker = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 20))
                                Text("Chọn tệp, thư mục hoặc gói .3105...")
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(TotoroxTheme.mintAccent)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .totoroxCard()

                // Overwrite Rules Notice (Windows style)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(TotoroxTheme.mintAccent)
                        Text("Quy tắc ghi đè chuẩn Windows:")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text("• File trùng tên: Ghi đè trực tiếp (không hash check)\n• Folder trùng tên: Gộp (merge) đệ quy mọi cấp\n• Xung đột Tệp/Thư mục: Hỏi ý kiến (Replace / Skip / Cancel)")
                        .font(.system(size: 12))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
                .padding(12)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if isExecuting {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(TotoroxTheme.mintAccent)
                        Text(executionStatusText)
                            .font(.system(size: 13))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    }
                    .padding()
                }

                Spacer()

                // Execute Button
                TotoroxPrimaryButton(
                    title: "Thực thi Đè File",
                    icon: "bolt.fill",
                    isLoading: isExecuting,
                    isEnabled: sourceURL != nil && !isExecuting
                ) {
                    executeOverwriteAction()
                }
            }
            .padding(16)
            .background(TotoroxTheme.pageBackground)
            .navigationTitle("Đè File Container")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Đóng") { showExecutionSheet = false }
                        .foregroundColor(TotoroxTheme.textPrimary)
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPickerWrapper { pickedURL in
                    self.sourceURL = pickedURL
                }
            }
            .overlay {
                if let conflict = activeConflict {
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                        WindowsConflictDialog(conflict: conflict)
                    }
                    .zIndex(999)
                    .transition(.opacity)
                }
            }
        }
    }

    private func executeOverwriteAction() {
        guard let source = sourceURL, let targetApp = selectedApp else { return }
        isExecuting = true
        executionStatusText = "Đang chuẩn bị container..."

        Task {
            // Determine target path
            let destinationPath: String
            if let resolved = ContainerStore.resolveAppContainerPath(bundleID: targetApp.bundleID) {
                destinationPath = (resolved as NSString).appendingPathComponent(selectedContainerTargetFolder)
            } else {
                let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent("Totorox_Containers/\(targetApp.bundleID)")
                destinationPath = tempBase.appendingPathComponent(selectedContainerTargetFolder).path
            }

            let destinationURL = URL(fileURLWithPath: destinationPath)
            try? FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

            // If source is a .3105 patch, convert it to temporary payload first
            var actualSourceURL = source
            var tempCleanups: [URL] = []
            
            if source.pathExtension.lowercased() == "3105" {
                await MainActor.run { executionStatusText = "Đang giải mã gói .3105..." }
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                tempCleanups.append(tempDir)
                
                let zipOut = tempDir.appendingPathComponent("patch.zip")
                do {
                    try PatchZipConverter.shared.convertPatch3105ToZip(inputURL: source, outputZipURL: zipOut)
                    // Unzip to temp payload
                    let unzippedDir = tempDir.appendingPathComponent("unzipped")
                    _ = try ZIPArchiveExtractor.extract(archiveURL: zipOut, into: unzippedDir)
                    
                    // Search for target container directory inside unzipped
                    let payloadDir = unzippedDir.appendingPathComponent("payload")
                    if FileManager.default.fileExists(atPath: payloadDir.path) {
                        actualSourceURL = payloadDir
                    } else {
                        actualSourceURL = unzippedDir
                    }
                } catch {
                    log("patch convert failed: \(error)")
                }
            }

            await MainActor.run { executionStatusText = "Đang áp dụng ghi đè & gộp thư mục..." }

            let engine = FileIOEngine()
            let result = await engine.copyAndMerge(
                from: actualSourceURL,
                to: destinationURL
            ) { src, dest, kind in
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        self.activeConflict = FileConflictInfo(
                            sourceURL: src,
                            destinationURL: dest,
                            conflictKind: kind,
                            continuation: { res in
                                self.activeConflict = nil
                                continuation.resume(returning: res)
                            }
                        )
                    }
                }
            }

            // Cleanup temp resources
            for cleanup in tempCleanups {
                try? FileManager.default.removeItem(at: cleanup)
            }

            await MainActor.run {
                self.isExecuting = false
                self.showExecutionSheet = false
                self.outcomeResult = FileIOResultWrapper(result: result)
            }
        }
    }
}

// MARK: - Document Picker Helper

struct DocumentPickerWrapper: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder, .data], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerWrapper
        init(_ parent: DocumentPickerWrapper) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            parent.onPick(url)
        }
    }
}
