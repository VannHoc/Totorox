import SwiftUI
import UniformTypeIdentifiers

// MARK: - OverwriteFileView (Giao diện chuẩn UI Dự án Totorox)

struct OverwriteFileView: View {
    // Selection State
    @State private var selectedApp: AppContainerInfo? = nil
    @State private var targetBundleIDInput: String = ""
    @State private var selectedTargetFolder: String = "Documents"
    @State private var selectedPatchURL: URL? = nil
    @State private var patchFileSizeText: String = ""
    
    // Custom folder dialog
    @State private var showCustomFolderSheet: Bool = false
    @State private var customFolderInput: String = ""
    
    // Modal Sheets
    @State private var showInstalledAppsSheet: Bool = false
    @State private var showDocumentPicker: Bool = false
    @State private var appSearchQuery: String = ""
    
    // Execution State
    @State private var isExecuting: Bool = false
    @State private var activeConflict: FileConflictInfo? = nil
    @State private var outcomeResult: FileIOResultWrapper? = nil
    @State private var alertMessage: String? = nil
    
    // Scanner
    @ObservedObject private var scanner = AppContainerScanner.shared
    
    // Form validation
    private var isReadyToExecute: Bool {
        selectedApp != nil && selectedPatchURL != nil && !selectedTargetFolder.isEmpty && !isExecuting
    }
    
    var body: some View {
        ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // MARK: - Khối 1: Chọn ứng dụng mục tiêu
                    targetAppCard
                    
                    // MARK: - Khối 2: Thư mục đích (Mặc định Documents & Library, ấn Đổi để tùy chọn)
                    destinationFolderCard
                    
                    // MARK: - Khối 3: Gói tệp bản vá
                    patchPackageCard
                    
                    // MARK: - Nút Thực thi
                    executeButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(TotoroxTheme.pageBackground)
            
            // MARK: - Lớp Conflict Dialog (Nổi trên cùng, không bị che khuất)
            if let conflict = activeConflict {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    WindowsConflictDialog(conflict: conflict)
                }
                .zIndex(999)
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showInstalledAppsSheet) {
            installedAppsPickerSheet
        }
        .sheet(isPresented: $showCustomFolderSheet) {
            customFolderPickerSheet
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerWrapper(
                allowedContentTypes: [
                    UTType.zip,
                    UTType(filenameExtension: "3105") ?? .data,
                    UTType.data,
                    UTType.content
                ]
            ) { url in
                handleSelectedPatch(url: url)
            }
        }
        .sheet(item: $outcomeResult) { wrapper in
            OverwriteOutcomeView(result: wrapper.result) {
                outcomeResult = nil
            }
        }
        .alert("Thông báo", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .task {
            if scanner.apps.isEmpty {
                scanner.prewarmOnLaunch()
            }
        }
    }
    
    // MARK: - Card 1: Chọn ứng dụng mục tiêu
    private var targetAppCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "app.dashed")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                
                Text("Ứng dụng mục tiêu")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                
                Spacer()
                
                if selectedApp != nil {
                    Text("Đã chọn")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            
            if let app = selectedApp {
                // Đã chọn app
                HStack(spacing: 12) {
                    AppIconAvatarView(info: app, size: 48)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.appName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .lineLimit(1)
                        
                        Text(app.bundleID)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                            .lineLimit(1)
                        
                        Text(app.shortDataPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                }
                .padding(12)
                .background(TotoroxTheme.searchBackground.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                HStack(spacing: 10) {
                    Button {
                        showInstalledAppsSheet = true
                        Task {
                            _ = await scanner.scanAllContainers(forceRefresh: false)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Đổi ứng dụng")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    
                    Button {
                        selectedApp = nil
                        targetBundleIDInput = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            } else {
                // Chưa chọn app
                VStack(spacing: 12) {
                    Button {
                        showInstalledAppsSheet = true
                        Task {
                            _ = await scanner.scanAllContainers(forceRefresh: false)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 14, weight: .bold))
                            Text("Chọn ứng dụng đã cài đặt")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(TotoroxTheme.mintAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: TotoroxTheme.mintAccent.opacity(0.25), radius: 6, y: 3)
                    }
                    
                    // Quick manual Bundle ID input
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                        
                        TextField("Hoặc nhập Bundle ID (ví dụ: com.garena.game.kgvn)", text: $targetBundleIDInput)
                            .font(.system(size: 13))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        
                        if !targetBundleIDInput.isEmpty {
                            Button("Tìm") {
                                resolveManualBundleID()
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .modifier(TotoroxCardModifier(cornerRadius: 16, padding: 16))
    }
    
    // MARK: - Card 2: Thư mục đích (Mặc định Documents & Library, ấn Đổi để tùy chọn)
    private var destinationFolderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                
                Text("Thư mục đích")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                
                Spacer()
                
                Text(selectedTargetFolder)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(TotoroxTheme.mintAccent.opacity(0.12))
                    .clipShape(Capsule())
            }
            
            // Selector Pills (Documents / Library / Đổi...)
            HStack(spacing: 10) {
                // Button 1: Documents
                Button {
                    selectedTargetFolder = "Documents"
                } label: {
                    HStack(spacing: 6) {
                        if selectedTargetFolder == "Documents" {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text("Documents")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(selectedTargetFolder == "Documents" ? .white : TotoroxTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(selectedTargetFolder == "Documents" ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                
                // Button 2: Library
                Button {
                    selectedTargetFolder = "Library"
                } label: {
                    HStack(spacing: 6) {
                        if selectedTargetFolder == "Library" {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text("Library")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(selectedTargetFolder == "Library" ? .white : TotoroxTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(selectedTargetFolder == "Library" ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                
                // Button 3: Đổi (Tuỳ chọn thư mục khác)
                Button {
                    customFolderInput = selectedTargetFolder
                    showCustomFolderSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .bold))
                        Text("Đổi")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(selectedTargetFolder != "Documents" && selectedTargetFolder != "Library" ? .white : TotoroxTheme.mintAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(
                        selectedTargetFolder != "Documents" && selectedTargetFolder != "Library"
                            ? TotoroxTheme.mintAccent
                            : TotoroxTheme.mintAccent.opacity(0.12)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            
            // Path preview
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                
                if let app = selectedApp {
                    Text("\(app.shortUDID)/\(selectedTargetFolder)/")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("<Container Ứng dụng>/\(selectedTargetFolder)/")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .modifier(TotoroxCardModifier(cornerRadius: 16, padding: 16))
    }
    
    // MARK: - Card 3: Gói tệp bản vá
    private var patchPackageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                
                Text("Gói tệp bản vá")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                
                Spacer()
                
                if let patch = selectedPatchURL {
                    Text(patch.pathExtension.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            
            if let patch = selectedPatchURL {
                // Đã chọn tệp
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(TotoroxTheme.mintAccent.opacity(0.15))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "doc.zipper")
                            .font(.system(size: 20))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(patch.lastPathComponent)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .lineLimit(1)
                        
                        Text(patchFileSizeText.isEmpty ? "Định dạng hợp lệ" : patchFileSizeText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    }
                    
                    Spacer()
                }
                .padding(10)
                .background(TotoroxTheme.searchBackground.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                HStack(spacing: 10) {
                    Button {
                        showDocumentPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Chọn tệp khác")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    
                    Button {
                        selectedPatchURL = nil
                        patchFileSizeText = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            } else {
                // Chưa chọn tệp
                Button {
                    showDocumentPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Chọn tệp bản vá (.zip hoặc .3105)")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(TotoroxTheme.mintAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(TotoroxTheme.mintAccent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .modifier(TotoroxCardModifier(cornerRadius: 16, padding: 16))
    }
    
    // MARK: - Nút Thực thi Đè File
    private var executeButton: some View {
        Button {
            executePatch()
        } label: {
            HStack(spacing: 8) {
                if isExecuting {
                    ProgressView()
                        .tint(.white)
                    Text("Đang thực thi đè file...")
                        .font(.system(size: 15, weight: .bold))
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text("Thực thi Đè File vào Container")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isReadyToExecute ? TotoroxTheme.mintAccent : Color.gray.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: isReadyToExecute ? TotoroxTheme.mintAccent.opacity(0.3) : Color.clear, radius: 8, y: 4)
        }
        .disabled(!isReadyToExecute)
    }
    
    // MARK: - Modal Sheet: Chọn ứng dụng đã cài đặt
    private var installedAppsPickerSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(TotoroxTheme.textSecondary)
                    TextField("Tìm theo tên app hoặc Bundle ID...", text: $appSearchQuery)
                        .font(.system(size: 14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    
                    if !appSearchQuery.isEmpty {
                        Button {
                            appSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(TotoroxTheme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                
                Divider()
                
                // Apps List
                let filteredApps = filteredInstalledApps
                if filteredApps.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        if scanner.isLoading {
                            ProgressView()
                                .tint(TotoroxTheme.mintAccent)
                            Text("Đang quét danh sách ứng dụng...")
                                .font(.system(size: 14))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        } else {
                            Image(systemName: "app.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                            Text("Không tìm thấy ứng dụng phù hợp")
                                .font(.system(size: 14))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(filteredApps) { app in
                            Button {
                                selectApp(app)
                                showInstalledAppsSheet = false
                            } label: {
                                HStack(spacing: 12) {
                                    AppIconAvatarView(info: app, size: 44)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.appName)
                                            .font(.system(size: 14.5, weight: .bold))
                                            .foregroundStyle(TotoroxTheme.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .minimumScaleFactor(0.82)
                                        
                                        Text(app.bundleID)
                                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(app.appName != app.bundleID ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .minimumScaleFactor(0.85)
                                    }
                                    
                                    Spacer()
                                    
                                    if selectedApp?.bundleID == app.bundleID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(TotoroxTheme.mintAccent)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Ứng dụng đã cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") {
                        showInstalledAppsSheet = false
                    }
                    .foregroundColor(TotoroxTheme.mintAccent)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            _ = await scanner.scanAllContainers(forceRefresh: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(TotoroxTheme.mintAccent)
                    }
                }
            }
            .onAppear {
                if scanner.apps.isEmpty {
                    Task {
                        _ = await scanner.scanAllContainers(forceRefresh: false)
                    }
                }
            }
        }
    }
    
    // MARK: - Modal Sheet: Tùy chọn thư mục đích
    private var customFolderPickerSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Chọn thư mục có sẵn hoặc nhập đường dẫn con:")
                    .font(.system(size: 14))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                
                // Gợi ý nhanh
                VStack(spacing: 8) {
                    ForEach(["Documents", "Library", "Library/Caches", "Library/Preferences", "tmp"], id: \.self) { folder in
                        Button {
                            selectedTargetFolder = folder
                            showCustomFolderSheet = false
                            log("overwrite: target folder -> \(folder)")
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                Text(folder)
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.textPrimary)
                                Spacer()
                                if selectedTargetFolder == folder {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                // Nhập tùy chỉnh
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hoặc nhập đường dẫn tùy chỉnh:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                    
                    HStack(spacing: 8) {
                        TextField("Ví dụ: Documents/Assets", text: $customFolderInput)
                            .font(.system(size: 13, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        
                        Button("Áp dụng") {
                            let clean = customFolderInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                selectedTargetFolder = clean
                                showCustomFolderSheet = false
                                log("overwrite: target folder -> \(clean)")
                            }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(TotoroxTheme.mintAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)
                
                Spacer()
            }
            .navigationTitle("Tùy chọn thư mục đích")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") {
                        showCustomFolderSheet = false
                    }
                    .foregroundColor(TotoroxTheme.mintAccent)
                }
            }
        }
    }
    
    // MARK: - Helpers & Actions
    
    private var filteredInstalledApps: [AppContainerInfo] {
        if appSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return scanner.apps
        }
        let query = appSearchQuery.lowercased()
        return scanner.apps.filter {
            $0.appName.lowercased().contains(query) ||
            $0.bundleID.lowercased().contains(query) ||
            $0.udid.lowercased().contains(query)
        }
    }
    
    private func selectApp(_ app: AppContainerInfo) {
        selectedApp = app
        targetBundleIDInput = app.bundleID
        log("overwrite: selected app \(app.appName) (\(app.bundleID))")
    }

    private func handleSelectedPatch(url: URL) {
        selectedPatchURL = url
        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) {
            defer {
                if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            var autoBundleID: String? = nil
            if url.pathExtension.lowercased() == "3105",
               let data = try? Data(contentsOf: url),
               let decoded = try? PatchPackageCodec.decode(data, password: nil),
               let bid = decoded.project.allBundleIdentifiers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bid.isEmpty {
                autoBundleID = bid
            }
            await MainActor.run {
                self.patchFileSizeText = sizeText
                log("overwrite: selected patch \(url.lastPathComponent) (\(sizeText))")
            }
            if let bid = autoBundleID {
                let currentSelected = await MainActor.run { self.selectedApp }
                if currentSelected == nil, let resolved = await self.scanner.resolveContainer(bundleID: bid) {
                    await MainActor.run {
                        self.selectApp(resolved)
                    }
                }
            }
        }
    }

    private func resolveManualBundleID() {
        let clean = targetBundleIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        Task {
            if let resolved = await scanner.resolveContainer(bundleID: clean) {
                await MainActor.run {
                    self.selectApp(resolved)
                }
            } else {
                await MainActor.run {
                    self.alertMessage = "Không tìm thấy ứng dụng có Bundle ID '\(clean)'."
                }
            }
        }
    }
    
    // MARK: - Thực thi Ghi đè Tệp
    private func executePatch() {
        guard let app = selectedApp, let patchURL = selectedPatchURL else { return }
        let targetSubfolder = selectedTargetFolder
        let promptCoordinator = ConflictPromptCoordinator()
        let hasSecurityAccess = patchURL.startAccessingSecurityScopedResource()

        isExecuting = true
        log("overwrite: starting patch into \(app.bundleID) target=\(targetSubfolder) file=\(patchURL.lastPathComponent)")

        Task.detached(priority: .userInitiated) {
            defer {
                if hasSecurityAccess { patchURL.stopAccessingSecurityScopedResource() }
            }

            // 0. Activate container sandbox permissions via MCM & bad_query (retained lease)
            var actError: NSString? = nil
            let activatedPath = MCMActivateContainerPath(2, app.bundleID, false, &actError)
            let rootPath = (activatedPath != nil && !activatedPath!.isEmpty) ? activatedPath! : app.dataPath
            _ = ContainerStore.ensureContainerAccess(for: rootPath)

            let containerBase = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
            let destinationDir = containerBase.appendingPathComponent(targetSubfolder, isDirectory: true)
            _ = ContainerStore.ensureContainerAccess(for: destinationDir.path)

            // Đảm bảo thư mục đích tồn tại
            do {
                try FileIOEngine.createDirectoryIfNeeded(at: destinationDir)
            } catch {
                await MainActor.run {
                    self.alertMessage = "Không thể tạo thư mục đích: \(error.localizedDescription)"
                    self.isExecuting = false
                }
                return
            }

            // 1. Thư mục tạm staging
            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("TotoroxPatch_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            defer {
                try? FileManager.default.removeItem(at: stagingDir)
            }

            let is3105 = patchURL.pathExtension.lowercased() == "3105"
            var rawExtractedRoot: URL = stagingDir

            if is3105 {
                do {
                    let converter = PatchZipConverter()
                    let zipOutput = stagingDir.appendingPathComponent("converted.zip")
                    try converter.convertPatch3105ToZip(inputURL: patchURL, outputZipURL: zipOutput)
                    let payloadDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
                    try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
                    do {
                        _ = try ZIPArchiveExtractor.extractFlatContents(archiveURL: zipOutput, into: payloadDir)
                    } catch {
                        let result = try ZIPArchiveExtractor.extract(archiveURL: zipOutput, into: payloadDir)
                        rawExtractedRoot = result.destinationURL
                    }
                    if rawExtractedRoot == stagingDir {
                        rawExtractedRoot = payloadDir
                    }
                } catch {
                    await MainActor.run {
                        self.alertMessage = "Giải mã gói .3105 thất bại: \(error.localizedDescription)"
                        self.isExecuting = false
                    }
                    return
                }
            } else {
                do {
                    let extractedDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
                    try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
                    do {
                        _ = try ZIPArchiveExtractor.extractFlatContents(archiveURL: patchURL, into: extractedDir)
                    } catch {
                        let zipData = try Data(contentsOf: patchURL)
                        let entries = try PatchZipConverter.shared.parseZipArchive(zipData)
                        for (relPath, fileData) in entries {
                            let normalized = relPath.replacingOccurrences(of: "\\", with: "/")
                            let parts = normalized
                                .split(separator: "/", omittingEmptySubsequences: true)
                                .map(String.init)
                                .filter { $0 != "." }
                            guard !parts.isEmpty,
                                  !parts.contains(".."),
                                  parts.first != "__MACOSX",
                                  parts.last != ".DS_Store" else {
                                continue
                            }
                            var targetFile = extractedDir
                            for (idx, part) in parts.enumerated() {
                                targetFile.appendPathComponent(part, isDirectory: idx < parts.count - 1)
                            }
                            try FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try fileData.write(to: targetFile, options: .atomic)
                        }
                    }
                    rawExtractedRoot = extractedDir
                } catch {
                    await MainActor.run {
                        self.alertMessage = "Giải nén tệp ZIP thất bại: \(error.localizedDescription)"
                        self.isExecuting = false
                    }
                    return
                }
            }

            // Unwrap payload/<bundleID>/ if the archive is a structured patch package
            let engine = FileIOEngine.shared
            let unwrapped = engine.unwrapExtractedPayloadRoot(
                at: rawExtractedRoot,
                preferredBundleID: app.bundleID
            )
            let sourceToCopy = unwrapped.rootURL

            // Determine whether the payload root already starts with the target subfolder (e.g. Documents/...)
            var effectiveDestination = destinationDir
            let matchingSubfolderInSource = sourceToCopy.appendingPathComponent(targetSubfolder)
            var isSubDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: matchingSubfolderInSource.path, isDirectory: &isSubDir),
               isSubDir.boolValue {
                effectiveDestination = containerBase
            } else if unwrapped.usesContainerRootRelativePaths {
                let topContainerDirs = ["Documents", "Library", "tmp", "SystemData"]
                let hasTopLevelContainerStructure = topContainerDirs.contains { dirName in
                    var d: ObjCBool = false
                    let p = sourceToCopy.appendingPathComponent(dirName).path
                    return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
                }
                if hasTopLevelContainerStructure {
                    effectiveDestination = containerBase
                }
            }

            // 2. Ghi đè và hợp nhất tệp qua FileIOEngine trên Background Thread
            let result = await engine.copyAndMerge(from: sourceToCopy, to: effectiveDestination) { s, d, k in
                await promptCoordinator.resolveConflict(
                    source: s,
                    destination: d,
                    kind: k,
                    presentModal: { info in
                        self.activeConflict = info
                    },
                    dismissModal: {
                        self.activeConflict = nil
                    }
                )
            }
            
            await MainActor.run {
                self.isExecuting = false
                ContainerMetadataCache.shared.invalidate(path: app.dataPath)
                self.outcomeResult = FileIOResultWrapper(result: result)
                log("overwrite: completed succeeded=\(result.succeeded.count) skipped=\(result.skipped.count) failed=\(result.failed.count) cancelled=\(result.isCancelled)")
            }
        }
    }
}
