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
    @State private var executionLogs: [String] = [
        "● [SẴN SÀNG] Hệ thống đè file container Totorox đã sẵn sàng."
    ]
    @State private var activeConflict: FileConflictInfo? = nil
    @State private var outcomeResult: FileIOResultWrapper? = nil
    
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
                    
                    // MARK: - Khối 4: Nhật ký (Thiết kế nền trắng)
                    whiteBackgroundLogCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(TotoroxTheme.pageBackground)
            
            // MARK: - Lớp Conflict Dialog (Nổi trên cùng, không bị che khuất)
            if let conflict = activeConflict {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    WindowsConflictDialog(conflict: conflict)
                        .padding(.horizontal, 24)
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
        .task {
            if scanner.apps.isEmpty {
                _ = await scanner.scanAllContainers(forceRefresh: false)
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
    
    // MARK: - Card 4: Nhật ký (Thiết kế theo nền trắng theo yêu cầu)
    private var whiteBackgroundLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header nhật ký
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                
                Text("Nhật ký xử lý")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                
                Spacer()
                
                Button {
                    copyLogsToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .padding(6)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(Circle())
                }
                
                Button {
                    executionLogs.removeAll()
                    executionLogs.append("● [SẴN SÀNG] Đã xóa toàn bộ nhật ký.")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .padding(6)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(Circle())
                }
            }
            
            Divider()
                .background(TotoroxTheme.dividerColor)
            
            // Log Content Box trên NỀN TRẮNG
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(executionLogs.enumerated()), id: \.offset) { index, log in
                            HStack(alignment: .top, spacing: 6) {
                                Text(log)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(logTextColor(for: log))
                                    .lineSpacing(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(index)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 190)
                .background(Color.white) // BẮT BUỘC NỀN TRẮNG
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .onChange(of: executionLogs.count) { _ in
                    if let lastIndex = executionLogs.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
        .modifier(TotoroxCardModifier(cornerRadius: 16, padding: 16))
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
                                selectedApp = app
                                targetBundleIDInput = app.bundleID
                                showInstalledAppsSheet = false
                                appendLog("[CHỌN APP] Đã chọn: \(app.appName) (\(app.bundleID))")
                            } label: {
                                HStack(spacing: 12) {
                                    AppIconAvatarView(info: app, size: 44)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.appName)
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(TotoroxTheme.textPrimary)
                                            .lineLimit(1)
                                        
                                        if app.appName != app.bundleID {
                                            Text(app.bundleID)
                                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(TotoroxTheme.mintAccent)
                                                .lineLimit(1)
                                        }
                                        
                                        HStack(spacing: 6) {
                                            Text("UDID: \(app.shortUDID)")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundStyle(TotoroxTheme.textSecondary)
                                                .lineLimit(1)
                                            Text("Data: \(app.dataPath)")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.75))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
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
                            appendLog("[THƯ MỤC] Đã chuyển thư mục đích sang: \(folder)")
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
                                appendLog("[THƯ MỤC] Đã chuyển thư mục đích sang: \(clean)")
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
    
    private func handleSelectedPatch(url: URL) {
        selectedPatchURL = url
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        patchFileSizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        appendLog("[TỆP BẢN VÁ] Đã chọn: \(url.lastPathComponent) (\(patchFileSizeText))")
    }
    
    private func resolveManualBundleID() {
        let clean = targetBundleIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        
        Task {
            if let resolved = await scanner.resolveContainer(bundleID: clean) {
                await MainActor.run {
                    self.selectedApp = resolved
                    self.appendLog("[NHẬP TAY] Đã tìm thấy container cho: \(clean)")
                }
            } else {
                await MainActor.run {
                    self.appendLog("[CẢNH BÁO] Không tìm thấy App có Bundle ID '\(clean)'")
                }
            }
        }
    }
    
    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        executionLogs.append("[\(timestamp)] \(message)")
    }
    
    private func copyLogsToClipboard() {
        UIPasteboard.general.string = executionLogs.joined(separator: "\n")
        appendLog("[THÔNG BÁO] Đã sao chép nhật ký vào Clipboard.")
    }
    
    private func logTextColor(for text: String) -> Color {
        if text.contains("[THÀNH CÔNG]") {
            return Color(red: 0.05, green: 0.65, blue: 0.35)
        } else if text.contains("[LỖI]") || text.contains("[THẤT BẠI]") {
            return Color(red: 0.85, green: 0.20, blue: 0.20)
        } else if text.contains("[CẢNH BÁO]") {
            return Color(red: 0.85, green: 0.55, blue: 0.10)
        }
        return Color(red: 0.15, green: 0.18, blue: 0.22) // Chuẩn chữ tối trên nền trắng
    }
    
    // MARK: - Thực thi Ghi đè Tệp
    private func executePatch() {
        guard let app = selectedApp, let patchURL = selectedPatchURL else { return }
        
        isExecuting = true
        appendLog("[BẮT ĐẦU] Bắt đầu quá trình đè file vào: \(app.appName)")
        appendLog("  - Thư mục đích: \(selectedTargetFolder)")
        appendLog("  - Gói bản vá: \(patchURL.lastPathComponent)")
        
        Task.detached(priority: .userInitiated) {
            // 0. Activate container sandbox permissions via MCM & bad_query
            var actError: NSString? = nil
            _ = MCMActivateContainerPath(2, app.bundleID, false, &actError)
            let grantHandle = ContainerStore.grantContainerAccess(app.dataPath)
            defer {
                if grantHandle >= 0 { bad_query_release(grantHandle) }
            }

            let containerBase = URL(fileURLWithPath: app.dataPath)
            let destinationDir = containerBase.appendingPathComponent(self.selectedTargetFolder, isDirectory: true)
            
            // Đảm bảo thư mục đích tồn tại
            do {
                try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            } catch {
                await MainActor.run {
                    self.appendLog("[LỖI] Không thể tạo thư mục đích: \(error.localizedDescription)")
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
            var sourceToCopy: URL = stagingDir
            
            if is3105 {
                do {
                    let converter = PatchZipConverter()
                    let zipOutput = stagingDir.appendingPathComponent("converted.zip")
                    try converter.convertPatch3105ToZip(inputURL: patchURL, outputZipURL: zipOutput)
                    let payloadDir = stagingDir.appendingPathComponent("payload", isDirectory: true)
                    try? FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
                    _ = try ZIPArchiveExtractor.extract(archiveURL: zipOutput, into: payloadDir)
                    sourceToCopy = payloadDir
                    await MainActor.run {
                        self.appendLog("[GIẢI MÃ] Giải mã thành công gói tệp .3105.")
                    }
                } catch {
                    await MainActor.run {
                        self.appendLog("[LỖI] Giải mã gói .3105 thất bại: \(error.localizedDescription)")
                    }
                }
            } else {
                do {
                    _ = try ZIPArchiveExtractor.extract(archiveURL: patchURL, into: stagingDir)
                    sourceToCopy = stagingDir
                    await MainActor.run {
                        self.appendLog("[GIẢI NÉN] Giải nén thành công tệp ZIP.")
                    }
                } catch {
                    await MainActor.run {
                        self.appendLog("[LỖI] Giải nén tệp ZIP thất bại: \(error.localizedDescription)")
                    }
                }
            }
            
            // 2. Ghi đè và hợp nhất tệp qua FileIOEngine
            let engine = FileIOEngine()
            let result = await engine.copyAndMerge(from: sourceToCopy, to: destinationDir) { s, d, k in
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
                self.isExecuting = false
                ContainerMetadataCache.shared.invalidate(path: app.dataPath)
                self.outcomeResult = FileIOResultWrapper(result: result)
                if result.succeeded.count > 0 {
                    self.appendLog("[THÀNH CÔNG] Đã đè thành công \(result.succeeded.count) tệp vào container.")
                } else if result.isCancelled {
                    self.appendLog("[HỦY BỎ] Người dùng đã hủy thao tác.")
                } else {
                    self.appendLog("[CẢNH BÁO] Hoàn tất với \(result.failed.count) lỗi.")
                }
            }
        }
    }
}
