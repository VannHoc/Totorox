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
    @State private var patchPassword: String = ""
    @State private var isPatchPasswordProtected: Bool = false
    @State private var isShowPassword: Bool = false
    @State private var showPasswordPromptDialog: Bool = false
    
    // Custom folder dialog
    @State private var showCustomFolderSheet: Bool = false
    @State private var customFolderInput: String = ""
    @State private var pendingTargetFolder: String = "Documents"
    @State private var currentBrowsingSubpath: String = ""
    @State private var folderSearchQuery: String = ""
    @State private var browsingFolders: [DestinationFolderOption] = []
    @State private var isLoadingFolders: Bool = false
    @State private var folderBrowseError: String? = nil
    
    // Modal Sheets
    @State private var showInstalledAppsSheet: Bool = false
    @State private var showDocumentPicker: Bool = false
    @State private var appSearchQuery: String = ""
    
    // Execution State
    @State private var isExecuting: Bool = false
    @State private var activeConflict: FileConflictInfo? = nil
    @State private var outcomeResult: FileIOResultWrapper? = nil
    @State private var alertMessage: String? = nil
    
    // Scanner & Navigation Coordinator
    @ObservedObject private var scanner = AppContainerScanner.shared
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
    
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
        .alert("Nhập mật khẩu gói .3105", isPresented: $showPasswordPromptDialog) {
            SecureField("Mật khẩu giải mã", text: $patchPassword)
            Button("Xác nhận & Đè file") {
                executePatch()
            }
            Button("Hủy", role: .cancel) { }
        } message: {
            Text("Gói bản vá này yêu cầu mật khẩu để giải mã nội dung. Vui lòng nhập mật khẩu để tiếp tục đè file vào container.")
        }
        .task {
            if scanner.apps.isEmpty {
                scanner.prewarmOnLaunch()
            }
            consumePendingNavigationIfNeeded()
        }
        .onChange(of: navCoordinator.pendingOverwritePatchURL) { _ in
            consumePendingNavigationIfNeeded()
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
                    openCustomFolderPicker()
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
                    Text("\(app.bundleID)/\(selectedTargetFolder)/")
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
                    HStack(spacing: 4) {
                        if isPatchPasswordProtected {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text("Có mật khẩu")
                                .font(.system(size: 11, weight: .bold))
                        } else {
                            Text(patch.pathExtension.uppercased())
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .foregroundStyle(isPatchPasswordProtected ? Color.orange : TotoroxTheme.mintAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((isPatchPasswordProtected ? Color.orange : TotoroxTheme.mintAccent).opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            
            if let patch = selectedPatchURL {
                // Đã chọn tệp
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill((isPatchPasswordProtected ? Color.orange : TotoroxTheme.mintAccent).opacity(0.15))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: isPatchPasswordProtected ? "lock.doc.fill" : "doc.zipper")
                            .font(.system(size: 20))
                            .foregroundStyle(isPatchPasswordProtected ? Color.orange : TotoroxTheme.mintAccent)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(patch.lastPathComponent)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                                .lineLimit(1)
                            
                            if isPatchPasswordProtected {
                                HStack(spacing: 3) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9))
                                    Text("Khóa")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(Color.orange)
                                .clipShape(Capsule())
                            }
                        }
                        
                        Text(patchFileSizeText.isEmpty ? "Định dạng hợp lệ" : patchFileSizeText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    }
                    
                    Spacer()
                }
                .padding(10)
                .background(TotoroxTheme.searchBackground.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                // MARK: Ô nhập mật khẩu gói (Hỗ trợ giải mã gói .3105 / zip mã hóa)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: isPatchPasswordProtected ? "lock.fill" : "lock")
                            .font(.system(size: 14))
                            .foregroundStyle(isPatchPasswordProtected ? Color.orange : TotoroxTheme.textSecondary)
                        
                        if isShowPassword {
                            TextField(
                                isPatchPasswordProtected ? "Nhập mật khẩu gói .3105 (bắt buộc)..." : "Mật khẩu gói (nếu có mã hóa)...",
                                text: $patchPassword
                            )
                            .font(.system(size: 13))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .onChange(of: patchPassword) { newPass in
                                tryAutoDetectBundleID(password: newPass)
                            }
                        } else {
                            SecureField(
                                isPatchPasswordProtected ? "Nhập mật khẩu gói .3105 (bắt buộc)..." : "Mật khẩu gói (nếu có mã hóa)...",
                                text: $patchPassword
                            )
                            .font(.system(size: 13))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .onChange(of: patchPassword) { newPass in
                                tryAutoDetectBundleID(password: newPass)
                            }
                        }
                        
                        Button {
                            isShowPassword.toggle()
                        } label: {
                            Image(systemName: isShowPassword ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        
                        if !patchPassword.isEmpty {
                            Button {
                                patchPassword = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                isPatchPasswordProtected && patchPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.orange.opacity(0.6)
                                    : Color.clear,
                                lineWidth: 1.2
                            )
                    )
                    
                    if isPatchPasswordProtected {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                            Text("Gói bản vá có đặt mật khẩu bảo vệ, vui lòng nhập mật khẩu để giải mã.")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.orange)
                        .padding(.leading, 4)
                    }
                }
                
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
                        patchPassword = ""
                        isPatchPasswordProtected = false
                        isShowPassword = false
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
    private struct DestinationFolderOption: Identifiable, Hashable {
        var id: String { relativePath }
        let title: String
        let relativePath: String
        let childCount: Int?
        let isVirtualSuggestion: Bool
    }

    private var filteredBrowsingFolders: [DestinationFolderOption] {
        let query = folderSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return browsingFolders }
        return browsingFolders.filter {
            $0.title.lowercased().contains(query) || $0.relativePath.lowercased().contains(query)
        }
    }

    private var customFolderPickerSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Thanh tìm kiếm trên cùng (đồng bộ với Bước 1 chọn App)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(TotoroxTheme.textSecondary)
                    TextField(
                        selectedApp.map { "Tìm thư mục trong \($0.bundleID)..." } ?? "Tìm thư mục đích...",
                        text: $folderSearchQuery
                    )
                    .font(.system(size: 14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                    if !folderSearchQuery.isEmpty {
                        Button {
                            folderSearchQuery = ""
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
                .padding(.top, 10)
                .padding(.bottom, 8)

                // Thanh ánh xạ đường dẫn container của app đang chọn
                if let app = selectedApp {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if !currentBrowsingSubpath.isEmpty {
                                Button {
                                    navigateUpContainerFolder()
                                } label: {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(TotoroxTheme.mintAccent)
                                        .frame(width: 28, height: 28)
                                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                                        .clipShape(Circle())
                                }
                            }

                            Button {
                                browseContainerSubpath("")
                            } label: {
                                Text(app.bundleID)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(currentBrowsingSubpath.isEmpty ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary)
                            }

                            let segments = currentBrowsingSubpath.split(separator: "/").map(String.init)
                            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(TotoroxTheme.textSecondary)

                                let partialPath = segments.prefix(index + 1).joined(separator: "/")
                                Button {
                                    browseContainerSubpath(partialPath)
                                } label: {
                                    Text(segment)
                                        .font(.system(size: 12, weight: index == segments.count - 1 ? .bold : .medium, design: .monospaced))
                                        .foregroundColor(index == segments.count - 1 ? TotoroxTheme.mintAccent : TotoroxTheme.textPrimary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text("Chưa chọn ứng dụng ở Bước 1 — đang hiển thị thư mục gợi ý.")
                            .font(.system(size: 12))
                            .foregroundColor(TotoroxTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(currentBrowsingSubpath.isEmpty
                                 ? "Thư mục bên trong \(selectedApp?.bundleID ?? "Container"):"
                                 : "Thư mục con trong \(currentBrowsingSubpath)/:")
                                .font(.system(size: 13))
                                .foregroundStyle(TotoroxTheme.textSecondary)

                            Spacer()

                            if isLoadingFolders {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(TotoroxTheme.mintAccent)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        if let err = folderBrowseError, !err.isEmpty {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 16)
                        }

                        if !isLoadingFolders && filteredBrowsingFolders.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "folder.badge.questionmark")
                                    .font(.system(size: 28))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
                                Text(folderSearchQuery.isEmpty
                                     ? "Thư mục này chưa có thư mục con. Bạn có thể chọn chính thư mục hiện tại hoặc nhập đường dẫn bên dưới."
                                     : "Không tìm thấy thư mục khớp \"\(folderSearchQuery)\".")
                                    .font(.system(size: 13))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .padding(.horizontal, 20)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(filteredBrowsingFolders) { folder in
                                    let isSelected = (pendingTargetFolder == folder.relativePath)
                                    HStack(spacing: 8) {
                                        Button {
                                            pendingTargetFolder = folder.relativePath
                                            customFolderInput = folder.relativePath
                                            if !folder.isVirtualSuggestion {
                                                browseContainerSubpath(folder.relativePath)
                                            }
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: "folder.fill")
                                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(folder.title)
                                                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                                        .lineLimit(1)
                                                    if let count = folder.childCount {
                                                        Text("\(count) mục")
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(TotoroxTheme.textSecondary)
                                                    }
                                                }
                                                Spacer()
                                                if isSelected {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 13, weight: .bold))
                                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                                }
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        if !folder.isVirtualSuggestion {
                                            Button {
                                                pendingTargetFolder = folder.relativePath
                                                customFolderInput = folder.relativePath
                                            } label: {
                                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                    .font(.system(size: 18))
                                                    .foregroundStyle(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary.opacity(0.45))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 46)
                                    .background(isSelected ? TotoroxTheme.mintAccent.opacity(0.10) : TotoroxTheme.searchBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(isSelected ? TotoroxTheme.mintAccent.opacity(0.65) : Color.clear, lineWidth: 1.2)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        // Nhập đường dẫn tùy chỉnh
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hoặc nhập đường dẫn tùy chỉnh:")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TotoroxTheme.textPrimary)

                            TextField("Ví dụ: Documents/Resources/1.64.1", text: $customFolderInput)
                                .font(.system(size: 13, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .padding(.horizontal, 12)
                                .frame(height: 42)
                                .background(TotoroxTheme.searchBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .onChange(of: customFolderInput) { newVal in
                                    let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        pendingTargetFolder = trimmed
                                    }
                                }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }

                // Nút Xác nhận màu xanh ghim dưới cùng
                VStack(spacing: 8) {
                    Divider()
                    let candidatePath = validatedTargetSubfolder(customFolderInput.isEmpty ? pendingTargetFolder : customFolderInput)
                    Button {
                        guard let clean = candidatePath else {
                            folderBrowseError = "Đường dẫn không hợp lệ. Vui lòng nhập đường dẫn con bên trong container."
                            return
                        }
                        selectedTargetFolder = clean
                        showCustomFolderSheet = false
                        log("overwrite: target folder -> \(clean)")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text(candidatePath.map { "Xác nhận (\($0))" } ?? "Xác nhận")
                                .font(.system(size: 15, weight: .bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(candidatePath != nil ? TotoroxTheme.mintAccent : TotoroxTheme.mintAccent.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(candidatePath == nil)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .background(TotoroxTheme.pageBackground)
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
            .onAppear {
                browseContainerSubpath(currentBrowsingSubpath)
            }
        }
    }

    private func openCustomFolderPicker() {
        pendingTargetFolder = selectedTargetFolder
        customFolderInput = selectedTargetFolder
        currentBrowsingSubpath = ""
        folderSearchQuery = ""
        folderBrowseError = nil
        showCustomFolderSheet = true
    }

    private func navigateUpContainerFolder() {
        let components = currentBrowsingSubpath.split(separator: "/").dropLast().map(String.init)
        let parent = components.joined(separator: "/")
        if !parent.isEmpty {
            pendingTargetFolder = parent
            customFolderInput = parent
        }
        browseContainerSubpath(parent)
    }

    private func browseContainerSubpath(_ subpath: String) {
        currentBrowsingSubpath = subpath
        folderSearchQuery = ""
        folderBrowseError = nil

        let defaultSuggestions: [DestinationFolderOption] = [
            "Documents", "Library", "Library/Caches", "Library/Preferences", "tmp"
        ].map {
            DestinationFolderOption(title: $0, relativePath: $0, childCount: nil, isVirtualSuggestion: true)
        }

        guard let app = selectedApp else {
            browsingFolders = defaultSuggestions
            isLoadingFolders = false
            return
        }

        isLoadingFolders = true
        Task.detached(priority: .userInitiated) {
            var actError: NSString? = nil
            let activatedPath = MCMActivateContainerPath(2, app.bundleID, false, &actError)
            let baseRoot = (activatedPath != nil && !activatedPath!.isEmpty) ? activatedPath! : app.dataPath
            let securedRoot = ContainerStore.ensureContainerAccess(for: baseRoot)

            let targetDir = subpath.isEmpty
                ? securedRoot
                : (securedRoot as NSString).appendingPathComponent(subpath)
            _ = ContainerStore.ensureContainerAccess(for: targetDir)

            let entries = ContainerStore.sortedEntries(ContainerStore.listFiles(at: targetDir))
            let dirEntries = entries.filter { $0.isDirectory && $0.name != "." && $0.name != ".." }

            var mapped: [DestinationFolderOption] = dirEntries.map { entry in
                let rel = subpath.isEmpty ? entry.name : "\(subpath)/\(entry.name)"
                return DestinationFolderOption(
                    title: subpath.isEmpty ? entry.name : rel,
                    relativePath: rel,
                    childCount: entry.childCount,
                    isVirtualSuggestion: false
                )
            }

            if subpath.isEmpty {
                let existing = Set(mapped.map { $0.relativePath.lowercased() })
                for suggestion in defaultSuggestions where !existing.contains(suggestion.relativePath.lowercased()) {
                    mapped.append(suggestion)
                }
            }

            await MainActor.run {
                self.browsingFolders = mapped
                self.isLoadingFolders = false
                if let err = actError as String?, mapped.isEmpty && !err.isEmpty {
                    self.folderBrowseError = "Không mở được đầy đủ container (\(err))."
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

    private func consumePendingNavigationIfNeeded() {
        guard let pendingURL = navCoordinator.pendingOverwritePatchURL else { return }
        let targetBundle = navCoordinator.pendingOverwriteBundleID
        navCoordinator.pendingOverwritePatchURL = nil
        navCoordinator.pendingOverwriteBundleID = nil

        selectedTargetFolder = "Documents"
        handleSelectedPatch(url: pendingURL)

        if let bid = targetBundle, !bid.isEmpty {
            targetBundleIDInput = bid
            if let existing = scanner.apps.first(where: { $0.bundleID == bid }) {
                selectApp(existing)
            } else {
                Task {
                    if let resolved = await scanner.resolveContainer(bundleID: bid) {
                        await MainActor.run {
                            self.selectApp(resolved)
                        }
                    }
                }
            }
        }
    }

    private func handleSelectedPatch(url: URL) {
        selectedPatchURL = url
        patchPassword = ""
        isPatchPasswordProtected = false
        isShowPassword = false
        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) {
            defer {
                if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            var autoBundleID: String? = nil
            var isProtected = false
            if url.pathExtension.lowercased() == "3105",
               !PatchPackageLimits.exceedsExpandedLimit(Int64(size)) {
                let converter = PatchZipConverter.shared
                if let summary = try? await converter.inspect(patchURL: url) {
                    isProtected = summary.isPasswordProtected
                }
                if let data = try? Data(contentsOf: url),
                   let project = try? await converter.decodeProject(patchData: data),
                   let bid = project.allBundleIdentifiers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bid.isEmpty {
                    autoBundleID = bid
                }
            }
            await MainActor.run {
                self.patchFileSizeText = sizeText
                self.isPatchPasswordProtected = isProtected
                log("overwrite: selected patch \(url.lastPathComponent) (\(sizeText)) isProtected=\(isProtected)")
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

    private func tryAutoDetectBundleID(password: String) {
        guard let url = selectedPatchURL,
              url.pathExtension.lowercased() == "3105",
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) {
            defer {
                if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
            }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  !PatchPackageLimits.exceedsExpandedLimit(Int64(size)) else { return }
            guard let data = try? Data(contentsOf: url),
                  let project = try? await PatchZipConverter.shared.decodeProject(patchData: data, password: password),
                  let bid = project.allBundleIdentifiers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bid.isEmpty else {
                return
            }
            let currentSelected = await MainActor.run { self.selectedApp }
            if currentSelected == nil, let resolved = await self.scanner.resolveContainer(bundleID: bid) {
                await MainActor.run {
                    self.selectApp(resolved)
                    log("overwrite: auto-detected app \(bid) after unlocking with password")
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
    
    /// Only relative paths inside the target app container are valid. Rejecting absolute
    /// paths and `..` components prevents a custom destination from escaping the container.
    private func validatedTargetSubfolder(_ rawValue: String) -> String? {
        // Accept a trailing slash from manual input ("Documents/") but keep leading
        // slashes rejected as absolute paths.
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        do {
            return try PatchPathValidator.canonicalRelativePath(candidate)
        } catch {
            alertMessage = "Thư mục đích không hợp lệ. Chỉ nhập đường dẫn tương đối bên trong container (ví dụ: Documents/Assets); không dùng '..', đường dẫn tuyệt đối hoặc ký tự điều khiển."
            return nil
        }
    }

    // MARK: - Thực thi Ghi đè Tệp
    private func executePatch() {
        guard let app = selectedApp, let patchURL = selectedPatchURL else { return }
        guard let targetSubfolder = validatedTargetSubfolder(selectedTargetFolder) else { return }
        let is3105 = patchURL.pathExtension.lowercased() == "3105"

        if is3105 && isPatchPasswordProtected && patchPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showPasswordPromptDialog = true
            return
        }

        let promptCoordinator = ConflictPromptCoordinator()
        let hasSecurityAccess = patchURL.startAccessingSecurityScopedResource()
        let currentPassword = patchPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : patchPassword

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

            let containerBase = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL
            let destinationDir = containerBase
                .appendingPathComponent(targetSubfolder, isDirectory: true)
                .standardizedFileURL
            let containerPrefix = containerBase.path.hasSuffix("/") ? containerBase.path : containerBase.path + "/"
            guard destinationDir.path == containerBase.path || destinationDir.path.hasPrefix(containerPrefix) else {
                await MainActor.run {
                    self.alertMessage = "Thư mục đích nằm ngoài container của ứng dụng. Vui lòng chọn đường dẫn con hợp lệ."
                    self.isExecuting = false
                }
                return
            }
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

            var rawExtractedRoot: URL = stagingDir

            if is3105 {
                do {
                    let converter = PatchZipConverter()
                    let zipOutput = stagingDir.appendingPathComponent("converted.zip")
                    try await converter.convertPatch3105ToZip(
                        inputURL: patchURL,
                        outputZipURL: zipOutput,
                        password: currentPassword
                    )
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
                        let errText = error.localizedDescription
                        if errText.contains("Mật khẩu") || errText.contains("Password") || errText.contains("password") {
                            self.alertMessage = "Giải mã gói .3105 thất bại: Mật khẩu không chính xác hoặc gói đã bị chỉnh sửa."
                        } else {
                            self.alertMessage = "Giải mã gói .3105 thất bại: \(errText)"
                        }
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
                    } catch ZIPArchiveExtractorError.expandedTooLarge {
                        throw ZIPArchiveExtractorError.expandedTooLarge
                    } catch {
                        let archiveSize = (try? patchURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        guard !PatchPackageLimits.exceedsExpandedLimit(Int64(archiveSize)) else {
                            throw ZIPArchiveExtractorError.expandedTooLarge
                        }
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
                    let message: String
                    if let extractorError = error as? ZIPArchiveExtractorError,
                       extractorError == .expandedTooLarge {
                        message = "Gói patch vượt quá giới hạn giải nén 3.6 GB."
                    } else if let converterError = error as? PatchZipConverterError,
                              converterError == .sizeLimitExceeded {
                        message = "Gói patch vượt quá giới hạn 3.6 GB."
                    } else {
                        message = "Giải nén tệp ZIP thất bại: \(error.localizedDescription)"
                    }
                    await MainActor.run {
                        self.alertMessage = message
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

            // 1.5. Bộ lọc bảo vệ Liên Quân Mobile (AOV SafeGuard)
            // Tự động loại bỏ các tệp Databin rỗng/chữ ký rác (< 32 bytes, ví dụ 9 bytes watermark)
            // gây lỗi parser Databin làm kẹt game ở 78%, giữ nguyên toàn bộ hiệu ứng skin & hạ địch.
            let targetBundleLower = app.bundleID.lowercased()
            let isAovGame = targetBundleLower.contains("kgvn") ||
                            targetBundleLower.contains("kgth") ||
                            targetBundleLower.contains("kgtw") ||
                            targetBundleLower.contains("sgame")
            if isAovGame {
                Self.sanitizeAovModPayload(at: sourceToCopy)
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

    private static func sanitizeAovModPayload(at sourceRoot: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var toRemove: [URL] = []
        for case let fileURL as URL in enumerator {
            let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if res?.isDirectory == true { continue }
            let size = res?.fileSize ?? 0
            let pathLower = fileURL.path.replacingOccurrences(of: "\\", with: "/").lowercased()

            // Chỉ loại bỏ các tệp Databin bị hỏng/chứa watermark rác (< 32 bytes, ví dụ 9 bytes UTF-8)
            // Không bao giờ xoá HeroSkin_*.bytes, KernelLua.pkg.bytes, StableSystems_3.pkg.bytes hay resourcepackerinfosetall.assetbundle
            if pathLower.contains("/databin/") && pathLower.hasSuffix(".bytes") && size < 32 {
                toRemove.append(fileURL)
                log("[AOV SafeGuard] Đã loại bỏ tệp Databin lỗi/watermark rác: \(fileURL.lastPathComponent) (\(size) bytes < 32 bytes).")
            }
        }

        for u in toRemove {
            try? fm.removeItem(at: u)
        }
    }
}
