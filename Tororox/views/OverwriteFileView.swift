import SwiftUI
import UniformTypeIdentifiers

// MARK: - OverwriteFileView (Thiết lập bản vá - 3 bước cơ bản)

struct OverwriteFileView: View {
    // 3 Steps State
    @State private var selectedApp: AppContainerInfo? = nil
    @State private var targetBundleIDInput: String = ""
    @State private var selectedTargetFolder: String = "Documents"
    @State private var selectedPatchURL: URL? = nil
    
    // Modal Sheets
    @State private var showInstalledAppsSheet: Bool = false
    @State private var showFolderPicker: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var showLogSheet: Bool = false
    
    // App search in modal sheet
    @State private var appSearchQuery: String = ""
    
    // Quick presets
    @State private var presetArchives: [URL] = []
    
    // Execution State
    @State private var isExecuting: Bool = false
    @State private var executionProgress: Double = 0.0
    @State private var executionStatusText: String = ""
    @State private var activeConflict: FileConflictInfo? = nil
    @State private var outcomeResult: FileIOResultWrapper? = nil
    
    // Live log tracking
    @State private var latestLogMessage: String = "● [SẴN SÀNG] Đã khởi tạo hệ thống Patch dữ liệu."
    
    // Scanner
    @ObservedObject private var scanner = AppContainerScanner.shared
    
    private var isStep1Ready: Bool { selectedApp != nil }
    private var isStep2Ready: Bool { !selectedTargetFolder.isEmpty }
    private var isStep3Ready: Bool { selectedPatchURL != nil }
    private var areAllStepsReady: Bool { isStep1Ready && isStep2Ready && isStep3Ready }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // MARK: - Card "THIẾT LẬP BẢN VÁ" (3 bước cơ bản)
                VStack(spacing: 16) {
                    // Card Header
                    HStack {
                        Text("THIẾT LẬP BẢN VÁ")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                        
                        Spacer()
                        
                        Text("3 bước cơ bản")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(Capsule())
                    }
                    
                    // MARK: Bước 1 - Ứng dụng mục tiêu
                    VStack(spacing: 10) {
                        HStack(alignment: .center, spacing: 12) {
                            // Step Icon (1 or Checkmark)
                            if let app = selectedApp {
                                ZStack {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 26, height: 26)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                
                                AppIconAvatarView(info: app, size: 40)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ứng dụng mục tiêu")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                    Text(app.appName)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(app.bundleID)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                        .lineLimit(1)
                                }
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(TotoroxTheme.searchBackground)
                                        .frame(width: 26, height: 26)
                                    Text("1")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ứng dụng mục tiêu")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                    Text("Chưa chọn ứng dụng")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                    Text("Nhập Bundle ID hoặc duyệt danh sách app")
                                        .font(.system(size: 11))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            }
                            
                            Spacer()
                            
                            // Button Chọn / Đổi
                            Button {
                                showInstalledAppsSheet = true
                            } label: {
                                Text(selectedApp == nil ? "Chọn" : "Đổi")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .background(Color(red: 0.16, green: 0.45, blue: 0.95))
                                    .clipShape(Capsule())
                            }
                        }
                        
                        // Quick input field for Bundle ID
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                            
                            TextField("Ví dụ: com.garena.game.kgvn", text: $targetBundleIDInput)
                                .font(.system(size: 13, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onSubmit {
                                    resolveTypedBundleID()
                                }
                            
                            if !targetBundleIDInput.isEmpty {
                                Button {
                                    targetBundleIDInput = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    
                    Divider()
                        .background(TotoroxTheme.dividerColor)
                    
                    // MARK: Bước 2 - Thư mục đích
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 26, height: 26)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Thư mục đích")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                            Text(selectedTargetFolder)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                            Text("/\(selectedTargetFolder) (chuẩn ghi đè an toàn)")
                                .font(.system(size: 11))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        
                        Spacer()
                        
                        Menu {
                            Button("Documents (/Documents)") {
                                selectedTargetFolder = "Documents"
                                updateLog("[ĐÍCH] Đã chọn thư mục đích: Documents")
                            }
                            Button("Library (/Library)") {
                                selectedTargetFolder = "Library"
                                updateLog("[ĐÍCH] Đã chọn thư mục đích: Library")
                            }
                            Button("tmp (/tmp)") {
                                selectedTargetFolder = "tmp"
                                updateLog("[ĐÍCH] Đã chọn thư mục đích: tmp")
                            }
                        } label: {
                            Text("Đổi")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.95))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .background(Color(red: 0.16, green: 0.45, blue: 0.95).opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    
                    Divider()
                        .background(TotoroxTheme.dividerColor)
                    
                    // MARK: Bước 3 - Gói tệp bản vá
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 12) {
                            if let patch = selectedPatchURL {
                                ZStack {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 26, height: 26)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Gói tệp bản vá")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                    Text(patch.lastPathComponent)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(formatFileSize(url: patch))
                                        .font(.system(size: 11))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(TotoroxTheme.searchBackground)
                                        .frame(width: 26, height: 26)
                                    Text("3")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Gói tệp bản vá")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                    Text("Chưa có tệp bản vá")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                    Text("Định dạng tệp .zip hoặc .3105")
                                        .font(.system(size: 11))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            }
                            
                            Spacer()
                            
                            Button {
                                showFilePicker = true
                            } label: {
                                Text(selectedPatchURL == nil ? "Chọn" : "Đổi")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .background(Color(red: 0.16, green: 0.45, blue: 0.95))
                                    .clipShape(Capsule())
                            }
                        }
                        
                        // Preset archive chips
                        if !presetArchives.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(presetArchives, id: \.self) { archiveURL in
                                        let isThis = (selectedPatchURL == archiveURL)
                                        Button {
                                            selectedPatchURL = archiveURL
                                            updateLog("[ZIP] Đã chọn tệp: \(archiveURL.lastPathComponent)")
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "doc.zipper")
                                                    .font(.system(size: 12))
                                                Text(archiveURL.lastPathComponent)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .lineLimit(1)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(isThis ? TotoroxTheme.mintAccent.opacity(0.15) : TotoroxTheme.searchBackground)
                                            .foregroundStyle(isThis ? TotoroxTheme.mintAccent : TotoroxTheme.textPrimary)
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule()
                                                    .stroke(isThis ? TotoroxTheme.mintAccent : Color.clear, lineWidth: 1)
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .totoroxCard()
                .padding(.horizontal, 16)
                
                // MARK: - Guidance / Warning Banner
                VStack {
                    if !isStep1Ready {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(red: 0.95, green: 0.52, blue: 0.1))
                            Text("Bước 1: Vui lòng chọn ứng dụng mục tiêu để bắt đầu.")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 0.8, green: 0.42, blue: 0.05))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.99, green: 0.95, blue: 0.91))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if !isStep3Ready {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(red: 0.95, green: 0.52, blue: 0.1))
                            Text("Bước 3: Vui lòng chọn tệp ZIP bản vá để tiếp tục.")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 0.8, green: 0.42, blue: 0.05))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.99, green: 0.95, blue: 0.91))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                            Text("Tất cả 3 bước đã sẵn sàng! Bạn có thể nhấn Áp dụng bản vá ngay.")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)
                
                // MARK: - Primary Action Button
                VStack(spacing: 6) {
                    if !isStep1Ready {
                        Button {
                            showInstalledAppsSheet = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 16, weight: .bold))
                                Text("Chọn ứng dụng mục tiêu")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TotoroxTheme.cardBackground)
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
                        }
                        Text("Cần chọn ứng dụng trước khi áp dụng")
                            .font(.system(size: 11))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    } else if !isStep3Ready {
                        Button {
                            showFilePicker = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.rectangle.on.folder.fill")
                                    .font(.system(size: 16, weight: .bold))
                                Text("Chọn tệp bản vá (.zip / .3105)")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TotoroxTheme.cardBackground)
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
                        }
                        Text("Cần chọn tệp ZIP bản vá để áp dụng")
                            .font(.system(size: 11))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    } else {
                        Button {
                            executePatchAction()
                        } label: {
                            HStack(spacing: 8) {
                                if isExecuting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 16, weight: .bold))
                                }
                                Text(isExecuting ? "Đang áp dụng bản vá..." : "Áp dụng bản vá ngay")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TotoroxTheme.mintAccent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: TotoroxTheme.mintAccent.opacity(0.3), radius: 8, x: 0, y: 3)
                        }
                        .disabled(isExecuting)
                        
                        Text("Sẵn sàng ghi đè an toàn vào Container\nVui lòng giữ ứng dụng mở trong khi ghi đè dữ liệu")
                            .font(.system(size: 11))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                
                // MARK: - Live Log Bar
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    
                    Text(latestLogMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer()
                    
                    Button {
                        showLogSheet = true
                    } label: {
                        Text("Nhật ký >")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.95))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(TotoroxTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 1)
                .padding(.horizontal, 16)
                
                // MARK: - Direct Sandbox Tool Navigation Button
                Button {
                    let destPath: String
                    if let app = selectedApp {
                        destPath = app.dataPath
                    } else {
                        destPath = ContainerStore.appDataRoot
                    }
                    AppNavigationCoordinator.shared.navigateToFolder(url: URL(fileURLWithPath: destPath))
                } label: {
                    HStack {
                        Text("Nâng cao: Công cụ Sandbox trực tiếp")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.95))
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.95))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(TotoroxTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 1)
                }
                .padding(.horizontal, 16)
                
                Spacer(minLength: 40)
            }
            .padding(.top, 12)
        }
        .background(TotoroxTheme.pageBackground)
        .onAppear {
            latestLogMessage = "● [\(Self.formattedCurrentTime())] [SẴN SÀNG] Đã khởi tạo hệ thống Patch dữ liệu."
            loadPresetArchives()
            Task {
                _ = await scanner.scanAllContainers(forceRefresh: false)
            }
        }
        // Modal Sheet: Ứng dụng đã cài đặt
        .sheet(isPresented: $showInstalledAppsSheet) {
            installedAppsModalSheet
        }
        // File picker for patch
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerWrapper(allowedContentTypes: [.zip, UTType("com.vannhoc.tororox.patch") ?? .data]) { pickedURL in
                selectedPatchURL = pickedURL
                updateLog("[ZIP] Đã chọn tệp: \(pickedURL.lastPathComponent)")
            }
        }
        // Full log sheet
        .sheet(isPresented: $showLogSheet) {
            LogView()
        }
        // Outcome View
        .sheet(item: $outcomeResult) { wrapper in
            OverwriteOutcomeView(result: wrapper.result) {
                outcomeResult = nil
            }
        }
        // Conflict Dialog
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
    
    // MARK: - Modal Sheet "Ứng dụng đã cài đặt" (Matches Image 3)
    private var installedAppsModalSheet: some View {
        VStack(spacing: 0) {
            // Header: Đóng / Tiêu đề / Reload
            HStack {
                Button {
                    showInstalledAppsSheet = false
                } label: {
                    Text("Đóng")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.95))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                Text("Ứng dụng đã cài đặt")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                
                Spacer()
                
                Button {
                    Task {
                        _ = await scanner.scanAllContainers(forceRefresh: true)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(TotoroxTheme.searchBackground)
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.95))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            // App List
            if scanner.isLoading && scanner.apps.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(TotoroxTheme.mintAccent)
                        .scaleEffect(1.2)
                    Text("Đang quét ứng dụng qua LaunchServices & MCM...")
                        .font(.system(size: 14))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let filtered = filteredInstalledApps
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.app.dashed")
                            .font(.system(size: 40))
                            .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.4))
                        Text("Không tìm thấy ứng dụng nào.")
                            .font(.system(size: 14))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                        Text("Hãy thử nhập Bundle ID thủ công ở màn hình chính.")
                            .font(.system(size: 12))
                            .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { app in
                                Button {
                                    selectedApp = app
                                    targetBundleIDInput = app.bundleID
                                    showInstalledAppsSheet = false
                                    updateLog("[CHỌN] Đã chọn ứng dụng: \(app.appName) (\(app.bundleID))")
                                } label: {
                                    HStack(spacing: 12) {
                                        AppIconAvatarView(info: app, size: 48)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.appName)
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundStyle(TotoroxTheme.textPrimary)
                                                .lineLimit(1)
                                            
                                            Text(app.bundleID)
                                                .font(.system(size: 12))
                                                .foregroundStyle(TotoroxTheme.textSecondary)
                                                .lineLimit(1)
                                            
                                            Text("UDID: \(app.shortUDID)")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.85))
                                                .lineLimit(1)
                                            
                                            Text("Data: \(app.shortDataPath)")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.85))
                                                .lineLimit(1)
                                            
                                            if let bundlePath = app.shortBundlePath {
                                                Text("Bundle: \(bundlePath)")
                                                    .font(.system(size: 9.5, design: .monospaced))
                                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.75))
                                                    .lineLimit(1)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.4))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(TotoroxTheme.cardBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 80)
                    }
                }
            }
            
            // Bottom Floating Search Bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                
                TextField("Tìm theo tên app hoặc mã...", text: $appSearchQuery)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(TotoroxTheme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 3)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(TotoroxTheme.pageBackground)
    }
    
    private var filteredInstalledApps: [AppContainerInfo] {
        if appSearchQuery.isEmpty { return scanner.apps }
        let q = appSearchQuery.lowercased()
        return scanner.apps.filter {
            $0.appName.lowercased().contains(q) ||
            $0.bundleID.lowercased().contains(q) ||
            $0.udid.lowercased().contains(q)
        }
    }
    
    // MARK: - Actions & Helpers
    
    private func resolveTypedBundleID() {
        let clean = targetBundleIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        updateLog("[TÌM KIẾM] Đang tìm kiếm container cho: \(clean)")
        Task {
            if let found = await scanner.resolveContainer(bundleID: clean) {
                self.selectedApp = found
                updateLog("[THÀNH CÔNG] Đã tìm thấy: \(found.appName) (\(found.bundleID))")
            } else {
                updateLog("[CẢNH BÁO] Không tìm thấy container cho '\(clean)'")
            }
        }
    }
    
    private func loadPresetArchives() {
        var presets: [URL] = []
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for f in files {
                let ext = f.pathExtension.lowercased()
                if ext == "zip" || ext == "3105" {
                    presets.append(f)
                }
            }
        }
        self.presetArchives = presets
    }
    
    private func formatFileSize(url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    private static func formattedCurrentTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
    
    private func updateLog(_ msg: String) {
        let timestamp = Self.formattedCurrentTime()
        let formatted = "● [\(timestamp)] \(msg)"
        self.latestLogMessage = formatted
        log("patch: \(msg)")
    }
    
    private func executePatchAction() {
        guard let app = selectedApp, let patchURL = selectedPatchURL else { return }
        
        isExecuting = true
        executionStatusText = "Đang chuẩn bị gói bản vá..."
        updateLog("[BẢN VÁ] Bắt đầu quá trình áp dụng bản vá cho: \(app.appName)")
        
        let destinationDir = URL(fileURLWithPath: app.dataPath)
            .appendingPathComponent(selectedTargetFolder, isDirectory: true)
        
        updateLog("[BẢN VÁ] Điểm đích: \(destinationDir.path)")
        
        Task {
            let handle = ContainerStore.grantContainerAccess(app.dataPath)
            defer {
                if handle >= 0 { bad_query_release(handle) }
            }
            
            // 1. Stage archive to temp directory
            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("PatchStage_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            
            defer {
                try? FileManager.default.removeItem(at: stagingDir)
            }
            
            let is3105 = patchURL.pathExtension.lowercased() == "3105"
            var sourceToCopy: URL = stagingDir
            
            if is3105 {
                do {
                    let converter = PatchZipConverter()
                    try converter.convertPatch3105ToZip(inputURL: patchURL, outputZipURL: stagingDir.appendingPathComponent("extracted.zip"))
                    let unzippedDir = stagingDir.appendingPathComponent("payload", isDirectory: true)
                    try? FileManager.default.createDirectory(at: unzippedDir, withIntermediateDirectories: true)
                    _ = try ZIPArchiveExtractor.extract(archiveURL: stagingDir.appendingPathComponent("extracted.zip"), into: unzippedDir)
                    sourceToCopy = unzippedDir
                } catch {
                    updateLog("[LỖI] Giải mã gói .3105 thất bại: \(error.localizedDescription)")
                }
            } else {
                do {
                    _ = try ZIPArchiveExtractor.extract(archiveURL: patchURL, into: stagingDir)
                    sourceToCopy = stagingDir
                } catch {
                    updateLog("[LỖI] Giải nén tệp ZIP thất bại: \(error.localizedDescription)")
                }
            }
            
            // 2. Execute Copy & Merge via FileIOEngine
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
                    self.updateLog("[THÀNH CÔNG] Đã áp dụng trọn vẹn \(result.succeeded.count) tệp vào ứng dụng.")
                } else if result.isCancelled {
                    self.updateLog("[HỦY BỎ] Người dùng đã hủy quá trình áp dụng bản vá.")
                } else {
                    self.updateLog("[CẢNH BÁO] Quá trình hoàn tất: \(result.failed.count) lỗi.")
                }
            }
        }
    }
}
