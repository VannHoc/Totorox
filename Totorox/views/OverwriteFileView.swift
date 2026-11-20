import SwiftUI
import UniformTypeIdentifiers

// MARK: - Isolated Execution Progress Model (prevents full-form re-renders on progress ticks)

@MainActor
private final class OverwriteExecutionProgress: ObservableObject {
    @Published var stageText: String = ""
    @Published var detailText: String = ""
    @Published var completedCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var isCancelling: Bool = false

    private var activeTask: Task<Void, Never>? = nil

    func begin(stage: String, detail: String = "") {
        stageText = stage
        detailText = detail
        completedCount = 0
        totalCount = 0
        isCancelling = false
    }

    func attach(_ task: Task<Void, Never>) {
        activeTask = task
    }

    func update(stage: String? = nil, detail: String? = nil, completed: Int? = nil, total: Int? = nil) {
        if let stage { stageText = stage }
        if let detail { detailText = detail }
        if let completed { completedCount = completed }
        if let total { totalCount = total }
    }

    func cancel() {
        isCancelling = true
        activeTask?.cancel()
    }

    func finish() {
        activeTask = nil
        stageText = ""
        detailText = ""
        completedCount = 0
        totalCount = 0
        isCancelling = false
    }
}

private struct OverwriteProgressCard: View {
    @ObservedObject var progress: OverwriteExecutionProgress
    let language: AppLanguage

    var body: some View {
        let fraction: Double? = {
            guard progress.totalCount > 0 else { return nil }
            return min(max(Double(progress.completedCount) / Double(progress.totalCount), 0.02), 1.0)
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.85)
                    .tint(TotoroxTheme.mintAccent)

                Text(progress.stageText.isEmpty ? language.text("overwrite.execute.running") : progress.stageText)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if let frac = fraction {
                    Text("\(Int(frac * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                }

                Button {
                    progress.cancel()
                } label: {
                    Text(progress.isCancelling
                         ? language.text("folders.task.cancelling")
                         : language.text("common.cancel"))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
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

            if !progress.detailText.isEmpty {
                Text(progress.detailText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .modifier(TotoroxCardModifier(cornerRadius: 14, padding: 14))
    }
}

// MARK: - OverwriteFileView (Giao diện chuẩn UI Dự án Totorox)

struct OverwriteFileView: View {
    @Environment(\.appLanguage) private var language

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
    @State private var passwordDetectTask: Task<Void, Never>? = nil
    
    // Custom folder dialog
    @State private var showCustomFolderSheet: Bool = false
    @State private var showCustomPathInput: Bool = false
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
    @State private var selectedHistorySession: OverwriteBackupSession? = nil
    @State private var showClearAllBackupsConfirm: Bool = false
    
    // Execution State
    @State private var isExecuting: Bool = false
    @StateObject private var executionProgress = OverwriteExecutionProgress()
    @State private var activeConflict: FileConflictInfo? = nil
    @State private var outcomeResult: FileIOResultWrapper? = nil
    @State private var alertMessage: String? = nil
    
    // Scanner, Backup Manager & Navigation Coordinator
    @ObservedObject private var scanner = AppContainerScanner.shared
    @ObservedObject private var backupManager = OverwriteBackupManager.shared
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    
    // Form validation
    private var hasDestinationTarget: Bool {
        selectedApp != nil
    }

    private var isReadyToExecute: Bool {
        guard selectedPatchURL != nil && !isExecuting else { return false }
        return selectedApp != nil && !selectedTargetFolder.isEmpty
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

                    // MARK: - Thanh tiến trình thực thi & nút Hủy
                    if isExecuting {
                        OverwriteProgressCard(progress: executionProgress, language: language)
                            .transition(.opacity)
                    }
                    
                    // MARK: - Nút Thực thi
                    executeButton

                    // MARK: - Lịch sử ghi đè & Khôi phục về trước khi đè
                    if !backupManager.sessions.isEmpty {
                        overwriteHistorySection
                    }
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
                .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .sheet(isPresented: $showCustomFolderSheet) {
            customFolderPickerSheet
                .preferredColorScheme(themeManager.mode.colorScheme)
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
            .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .sheet(item: $outcomeResult) { wrapper in
            OverwriteOutcomeView(result: wrapper.result) {
                outcomeResult = nil
            }
            .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .sheet(item: $selectedHistorySession) { session in
            OverwriteBackupDetailSheet(
                session: session,
                backupManager: backupManager
            ) {
                selectedHistorySession = nil
            }
            .preferredColorScheme(themeManager.mode.colorScheme)
        }
        .alert(language.text("overwrite.backup.clear_all_title"), isPresented: $showClearAllBackupsConfirm) {
            Button(language.text("common.delete"), role: .destructive) {
                backupManager.clearAllSessions()
            }
            Button(language.text("common.cancel"), role: .cancel) { }
        } message: {
            Text(language.text("overwrite.backup.clear_all_message"))
        }
        .alert(language.text("common.notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(language.text("common.ok"), role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .alert(language.text("overwrite.alert.password_title"), isPresented: $showPasswordPromptDialog) {
            SecureField(language.text("overwrite.alert.password_placeholder"), text: $patchPassword)
            Button(language.text("overwrite.alert.password_confirm")) {
                executePatch()
            }
            Button(language.text("common.cancel"), role: .cancel) { }
        } message: {
            Text(language.text("overwrite.alert.password_message"))
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
                
                Text(language.text("overwrite.target_app.title"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                
                Spacer()
                
                if hasDestinationTarget {
                    Text(language.text("overwrite.target_app.selected"))
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
                            Text(language.text("overwrite.target_app.change"))
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
                            Text(language.text("overwrite.target_app.choose_installed"))
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
                        
                        TextField(
                            "",
                            text: $targetBundleIDInput,
                            prompt: Text(language.text("overwrite.target_app.bundle_placeholder"))
                                .foregroundColor(TotoroxTheme.textSecondary)
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .tint(TotoroxTheme.mintAccent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        
                        if !targetBundleIDInput.isEmpty {
                            Button(language.text("overwrite.target_app.find")) {
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
                
                Text(language.text("overwrite.dest_folder.title"))
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
                        Text(language.text("overwrite.dest_folder.change"))
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
                    Text(language.text("overwrite.dest_folder.app_container_placeholder", selectedTargetFolder))
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
                
                Text(language.text("overwrite.patch.title"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                
                Spacer()
                
                if let patch = selectedPatchURL {
                    HStack(spacing: 4) {
                        if isPatchPasswordProtected {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text(language.text("overwrite.patch.has_password"))
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
                                    Text(language.text("overwrite.patch.locked_badge"))
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(Color.orange)
                                .clipShape(Capsule())
                            }
                        }
                        
                        Text(patchFileSizeText.isEmpty ? language.text("overwrite.patch.valid_format") : patchFileSizeText)
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
                        
                        let pwdPlaceholder = language.text(
                            isPatchPasswordProtected
                                ? "overwrite.patch.password_required_placeholder"
                                : "overwrite.patch.password_optional_placeholder"
                        )
                        if isShowPassword {
                            TextField(
                                "",
                                text: $patchPassword,
                                prompt: Text(pwdPlaceholder).foregroundColor(TotoroxTheme.textSecondary)
                            )
                            .font(.system(size: 13))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .tint(TotoroxTheme.mintAccent)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .onChange(of: patchPassword) { newPass in
                                tryAutoDetectBundleID(password: newPass)
                            }
                        } else {
                            SecureField(
                                "",
                                text: $patchPassword,
                                prompt: Text(pwdPlaceholder).foregroundColor(TotoroxTheme.textSecondary)
                            )
                            .font(.system(size: 13))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .tint(TotoroxTheme.mintAccent)
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
                            Text(language.text("overwrite.patch.password_hint"))
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
                            Text(language.text("overwrite.patch.change_file"))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    
                    Button {
                        passwordDetectTask?.cancel()
                        passwordDetectTask = nil
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
                        Text(language.text("overwrite.patch.choose_file"))
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
                    Text(language.text("overwrite.execute.running"))
                        .font(.system(size: 15, weight: .bold))
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(language.text("overwrite.execute.button"))
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle((isReadyToExecute || isExecuting) ? .white : TotoroxTheme.disabledText)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background((isReadyToExecute || isExecuting) ? TotoroxTheme.mintAccent : TotoroxTheme.disabledBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: isReadyToExecute ? TotoroxTheme.mintAccent.opacity(0.3) : Color.clear, radius: 8, y: 4)
        }
        .disabled(!isReadyToExecute)
    }

    // MARK: - Lịch sử ghi đè & Khôi phục dữ liệu
    private var overwriteHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                    Text(language.text("overwrite.backup.history_title"))
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                }

                Spacer()

                if backupManager.totalStoredBackupBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: backupManager.totalStoredBackupBytes, countStyle: .file))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(Capsule())
                }

                Button(language.text("overwrite.backup.clear_all")) {
                    showClearAllBackupsConfirm = true
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.85))
                .buttonStyle(.plain)
            }

            Text(language.text("overwrite.backup.history_hint"))
                .font(.system(size: 11.5))
                .foregroundStyle(TotoroxTheme.textSecondary)

            VStack(spacing: 8) {
                ForEach(backupManager.sessions) { session in
                    Button {
                        selectedHistorySession = session
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill((session.isRestored ? Color.blue : TotoroxTheme.mintAccent).opacity(0.14))
                                    .frame(width: 40, height: 40)
                                Image(systemName: session.isRestored ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(session.isRestored ? Color.blue : TotoroxTheme.mintAccent)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(session.patchName)
                                        .font(.system(size: 13.5, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Text(language.text(session.isRestored ? "overwrite.backup.badge_restored" : "overwrite.backup.badge_ready"))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(session.isRestored ? Color.blue : TotoroxTheme.mintAccent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background((session.isRestored ? Color.blue : TotoroxTheme.mintAccent).opacity(0.12))
                                        .clipShape(Capsule())
                                }

                                Text("\(session.appName) • \(session.targetSubfolder) • \(Self.formatHistoryDate(session.createdAt))")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                let backupText = ByteCountFormatter.string(fromByteCount: session.totalBackupBytes, countStyle: .file)
                                Text(language.text(
                                    "overwrite.backup.session_meta",
                                    session.totalFilesCount,
                                    session.overwrittenCount,
                                    session.addedCount,
                                    backupText
                                ))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                                .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
                        }
                        .modifier(TotoroxCardModifier(cornerRadius: 14, padding: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private static func formatHistoryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter.string(from: date)
    }
    
    // MARK: - Modal Sheet: Chọn ứng dụng đã cài đặt
    private var installedAppsPickerSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(TotoroxTheme.textSecondary)
                    TextField(
                        "",
                        text: $appSearchQuery,
                        prompt: Text(language.text("overwrite.apps_sheet.search_placeholder"))
                            .foregroundColor(TotoroxTheme.textSecondary)
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .tint(TotoroxTheme.mintAccent)
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
                            Text(language.text("overwrite.apps_sheet.scanning"))
                                .font(.system(size: 14))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        } else {
                            Image(systemName: "app.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                            Text(language.text("overwrite.apps_sheet.empty"))
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
                            .listRowBackground(TotoroxTheme.cardBackground)
                            .listRowSeparatorTint(TotoroxTheme.dividerColor)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(TotoroxTheme.pageBackground)
                }
            }
            .background(TotoroxTheme.pageBackground)
            .navigationTitle(language.text("overwrite.apps_sheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.close")) {
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

    private func dismissPickerKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var customFolderPickerSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header điều hướng & tìm kiếm đồng bộ với tab Thư mục
                VStack(spacing: 8) {
                    // Hàng nút Lùi + Thanh Breadcrumb dạng Pill cuộn ngang
                    if let app = selectedApp {
                        let canNavigateBack = !currentBrowsingSubpath.isEmpty
                        let segments = currentBrowsingSubpath.split(separator: "/").map(String.init)
                        HStack(spacing: 8) {
                            Button {
                                dismissPickerKeyboard()
                                if canNavigateBack {
                                    navigateUpContainerFolder()
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
                                .foregroundStyle(canNavigateBack ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary.opacity(0.35))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(TotoroxTheme.searchBackground)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canNavigateBack)

                            ScrollViewReader { crumbProxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        Button {
                                            dismissPickerKeyboard()
                                            browseContainerSubpath("")
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "internaldrive.fill")
                                                    .font(.system(size: 12))
                                                Text(app.bundleID)
                                                    .font(.system(size: 12, weight: segments.isEmpty ? .bold : .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(segments.isEmpty ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                            .foregroundColor(segments.isEmpty ? .white : TotoroxTheme.textPrimary)
                                            .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .id(0)

                                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.5))

                                            let partialPath = segments.prefix(index + 1).joined(separator: "/")
                                            let isLast = (index == segments.count - 1)
                                            Button {
                                                dismissPickerKeyboard()
                                                pendingTargetFolder = partialPath
                                                customFolderInput = partialPath
                                                browseContainerSubpath(partialPath)
                                            } label: {
                                                Text(segment)
                                                    .font(.system(size: 12, weight: isLast ? .bold : .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .background(isLast ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                                    .foregroundColor(isLast ? .white : TotoroxTheme.textPrimary)
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .id(index + 1)
                                        }
                                    }
                                    .padding(.trailing, 4)
                                }
                                .onChange(of: currentBrowsingSubpath) { _ in
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        crumbProxy.scrollTo(segments.count, anchor: .trailing)
                                    }
                                }
                                .onAppear {
                                    crumbProxy.scrollTo(segments.count, anchor: .trailing)
                                }
                            }

                            if isLoadingFolders {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(TotoroxTheme.mintAccent)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                            Text(language.text("overwrite.folder.no_app_hint"))
                                .font(.system(size: 12))
                                .foregroundColor(TotoroxTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    }

                    // Hàng Thanh tìm kiếm + Nút bật/tắt nhập đường dẫn tùy chỉnh (icon bút chì)
                    HStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(TotoroxTheme.textSecondary)

                            TextField(
                                selectedApp.map { language.text("overwrite.folder.search_in_app", $0.bundleID) }
                                    ?? language.text("overwrite.folder.search_placeholder"),
                                text: $folderSearchQuery
                            )
                            .font(.system(size: 15))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                            if !folderSearchQuery.isEmpty {
                                Button {
                                    folderSearchQuery = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showCustomPathInput.toggle()
                            }
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(showCustomPathInput ? .white : TotoroxTheme.mintAccent)
                                .frame(width: 40, height: 40)
                                .background(showCustomPathInput ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(language.text("overwrite.folder.custom_input_a11y"))
                    }
                    .padding(.horizontal, 14)

                    // Ô nhập đường dẫn tùy chỉnh thu gọn (chỉ hiện khi bấm nút bút chì)
                    if showCustomPathInput {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(TotoroxTheme.mintAccent)

                            TextField(language.text("overwrite.folder.custom_example"), text: $customFolderInput)
                                .font(.system(size: 13.5, design: .monospaced))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .onChange(of: customFolderInput) { newVal in
                                    let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        pendingTargetFolder = trimmed
                                    }
                                }

                            if !customFolderInput.isEmpty {
                                Button {
                                    customFolderInput = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(TotoroxTheme.searchBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(TotoroxTheme.mintAccent.opacity(0.45), lineWidth: 1)
                        )
                        .padding(.horizontal, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 10)
                .background(TotoroxTheme.cardBackground)
                .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 2)

                // Danh sách thư mục dạng Card trắng đồng bộ với tab Thư mục
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        if let err = folderBrowseError, !err.isEmpty {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        if !isLoadingFolders && filteredBrowsingFolders.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .font(.system(size: 42))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.4))
                                Text(folderSearchQuery.isEmpty
                                     ? language.text("overwrite.folder.empty_subfolders")
                                     : language.text("overwrite.folder.no_match"))
                                    .font(.system(size: 14))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 52)
                        } else {
                            ForEach(filteredBrowsingFolders) { folder in
                                let isSelected = (pendingTargetFolder == folder.relativePath)
                                HStack(spacing: 10) {
                                    Button {
                                        dismissPickerKeyboard()
                                        pendingTargetFolder = folder.relativePath
                                        customFolderInput = folder.relativePath
                                        if !folder.isVirtualSuggestion {
                                            browseContainerSubpath(folder.relativePath)
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(TotoroxTheme.mintAccent.opacity(0.12))
                                                    .frame(width: 40, height: 40)

                                                Image(systemName: "folder.fill")
                                                    .font(.system(size: 18))
                                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                            }

                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(folder.title)
                                                    .font(.system(size: 14.5, weight: .bold))
                                                    .foregroundStyle(TotoroxTheme.textPrimary)
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)

                                                HStack(spacing: 4) {
                                                    Text(language.text("folders.folder_type"))
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                                    if let count = folder.childCount {
                                                        Text(language.text("common.items_paren_count", count))
                                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                                            .foregroundStyle(TotoroxTheme.mintAccent)
                                                    }
                                                }
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(TotoroxTheme.mintAccent.opacity(0.12))
                                                .clipShape(Capsule())
                                            }

                                            Spacer(minLength: 4)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        dismissPickerKeyboard()
                                        pendingTargetFolder = folder.relativePath
                                        customFolderInput = folder.relativePath
                                    } label: {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundStyle(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.textSecondary.opacity(0.35))
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .totoroxCard(cornerRadius: 14, padding: 12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(isSelected ? TotoroxTheme.mintAccent : Color.clear, lineWidth: 1.5)
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                }
                .background(TotoroxTheme.pageBackground)

                // Nút Xác nhận màu xanh ghim dưới cùng (chỉ hiển thị tên ngắn gọn của thư mục)
                VStack(spacing: 8) {
                    Divider()
                    let candidatePath = validatedTargetSubfolder(customFolderInput.isEmpty ? pendingTargetFolder : customFolderInput)
                    let shortFolderTitle: String = {
                        guard let clean = candidatePath else { return language.text("overwrite.folder.confirm_btn") }
                        let last = (clean as NSString).lastPathComponent
                        return language.text("overwrite.folder.confirm_with_name", last.isEmpty ? clean : last)
                    }()
                    Button {
                        dismissPickerKeyboard()
                        guard let clean = candidatePath else {
                            folderBrowseError = language.text("overwrite.folder.invalid_subpath")
                            return
                        }
                        selectedTargetFolder = clean
                        showCustomFolderSheet = false
                        log("overwrite: target folder -> \(clean)")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text(shortFolderTitle)
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
                .background(TotoroxTheme.cardBackground)
            }
            .background(TotoroxTheme.pageBackground)
            .navigationTitle(language.text("overwrite.custom_folder_sheet_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) {
                        dismissPickerKeyboard()
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
        showCustomPathInput = false
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
            DestinationFolderOption(
                title: ($0 as NSString).lastPathComponent,
                relativePath: $0,
                childCount: nil,
                isVirtualSuggestion: true
            )
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
                    title: entry.name,
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
                    self.folderBrowseError = AppLanguage.current.text("overwrite.folder.container_open_error", err)
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
            let ext = url.pathExtension.lowercased()
            if ext == "3105",
               !PatchPackageLimits.exceedsExpandedLimit(Int64(size)) {
                let converter = PatchZipConverter.shared
                if let summary = try? await converter.inspect(patchURL: url) {
                    isProtected = summary.isPasswordProtected
                }
                if let project = converter.inspectProjectMetadataLocally(patchURL: url),
                   let bid = project.allBundleIdentifiers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bid.isEmpty {
                    autoBundleID = bid
                }
            } else if ext == "zip",
                      !PatchPackageLimits.exceedsExpandedLimit(Int64(size)) {
                isProtected = PatchZipConverter.shared.isZipPasswordProtected(url: url)
            }
            await MainActor.run {
                self.patchFileSizeText = sizeText
                self.isPatchPasswordProtected = isProtected
                log("overwrite: selected patch \(url.lastPathComponent) (\(sizeText)) isProtected=\(isProtected)")
            }
            if let bid = autoBundleID {
                let hasTarget = await MainActor.run { self.selectedApp != nil }
                if !hasTarget, let resolved = await self.scanner.resolveContainer(bundleID: bid) {
                    await MainActor.run {
                        self.selectApp(resolved)
                    }
                }
            }
        }
    }

    private func tryAutoDetectBundleID(password: String) {
        passwordDetectTask?.cancel()
        passwordDetectTask = nil

        guard let url = selectedPatchURL,
              url.pathExtension.lowercased() == "3105",
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        passwordDetectTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
            }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  !PatchPackageLimits.exceedsExpandedLimit(Int64(size)) else { return }
            guard !Task.isCancelled else { return }
            guard let project = PatchZipConverter.shared.inspectProjectMetadataLocally(patchURL: url, password: password),
                  let bid = project.allBundleIdentifiers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bid.isEmpty else {
                return
            }
            guard !Task.isCancelled else { return }
            let hasTarget = await MainActor.run { self.selectedApp != nil }
            if !hasTarget, let resolved = await self.scanner.resolveContainer(bundleID: bid) {
                guard !Task.isCancelled else { return }
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
                    self.alertMessage = AppLanguage.current.text("overwrite.not_found_bundle", clean)
                }
            }
        }
    }
    
    /// Only relative paths inside the target app container are valid. Rejecting absolute
    /// paths and `..` components prevents a custom destination from escaping the container.
    /// Pure helper — never mutates `@State` so it is safe to call during SwiftUI body evaluation.
    private func validatedTargetSubfolder(_ rawValue: String) -> String? {
        // Accept a trailing slash from manual input ("Documents/") but keep leading
        // slashes rejected as absolute paths.
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        return try? PatchPathValidator.canonicalRelativePath(candidate)
    }

    // MARK: - Thực thi Ghi đè Tệp
    private func executePatch() {
        guard let patchURL = selectedPatchURL else { return }
        guard !isExecuting else { return }
        guard let targetApp = selectedApp else { return }

        guard let targetSubfolder = validatedTargetSubfolder(selectedTargetFolder) else {
            alertMessage = language.text("overwrite.error.invalid_target_subfolder")
            return
        }

        let is3105 = patchURL.pathExtension.lowercased() == "3105"

        if isPatchPasswordProtected && patchPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showPasswordPromptDialog = true
            return
        }

        let promptCoordinator = ConflictPromptCoordinator()
        let hasSecurityAccess = patchURL.startAccessingSecurityScopedResource()
        let currentPassword = patchPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : patchPassword
        let activeLanguage = language
        let progressModel = executionProgress
        let patchDisplayName = patchURL.lastPathComponent
        let backupManagerRef = backupManager

        isExecuting = true
        progressModel.begin(
            stage: activeLanguage.text("overwrite.progress.extracting"),
            detail: patchDisplayName
        )
        log("overwrite: starting patch into \(targetApp.bundleID) target=\(targetSubfolder) file=\(patchDisplayName)")

        let worker = Task.detached(priority: .userInitiated) {
            defer {
                if hasSecurityAccess { patchURL.stopAccessingSecurityScopedResource() }
            }

            // 0. Activate container sandbox permissions via MCM & bad_query (retained lease)
            var actError: NSString? = nil
            let activatedPath = MCMActivateContainerPath(2, targetApp.bundleID, false, &actError)
            let rootPath = (activatedPath != nil && !activatedPath!.isEmpty) ? activatedPath! : targetApp.dataPath
            _ = ContainerStore.ensureContainerAccess(for: rootPath, requireWrite: true)

            let containerBase = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL
            let candidateDest = containerBase
                .appendingPathComponent(targetSubfolder, isDirectory: true)
                .standardizedFileURL
            let containerPrefix = containerBase.path.hasSuffix("/") ? containerBase.path : containerBase.path + "/"
            guard candidateDest.path == containerBase.path || candidateDest.path.hasPrefix(containerPrefix) else {
                await MainActor.run {
                    progressModel.finish()
                    self.alertMessage = activeLanguage.text("overwrite.error.outside_container")
                    self.isExecuting = false
                }
                return
            }
            _ = ContainerStore.ensureContainerAccess(for: candidateDest.path, requireWrite: true)
            let destinationDir = candidateDest
            let cacheInvalidationPath = targetApp.dataPath

            // Đảm bảo thư mục đích tồn tại
            do {
                try FileIOEngine.createDirectoryIfNeeded(at: destinationDir)
            } catch {
                await MainActor.run {
                    progressModel.finish()
                    self.alertMessage = activeLanguage.text("overwrite.error.create_dest_failed", error.localizedDescription)
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
            var extractedFileCount = 0

            if is3105 {
                do {
                    if Task.isCancelled { throw CancellationError() }
                    let converter = PatchZipConverter()
                    let zipOutput = stagingDir.appendingPathComponent("converted.zip")
                    try await converter.convertPatch3105ToZip(
                        inputURL: patchURL,
                        outputZipURL: zipOutput,
                        password: currentPassword
                    )
                    if Task.isCancelled { throw CancellationError() }
                    let payloadDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
                    try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
                    do {
                        extractedFileCount = try ZIPArchiveExtractor.extractFlatContents(
                            archiveURL: zipOutput,
                            into: payloadDir,
                            shouldCancel: { Task.isCancelled },
                            progressHandler: { extracted, total, entryName in
                                Task { @MainActor in
                                    progressModel.update(
                                        stage: activeLanguage.text("overwrite.progress.extracting"),
                                        detail: activeLanguage.text("folders.task.processed_progress", extracted, total, entryName),
                                        completed: extracted,
                                        total: total
                                    )
                                }
                            }
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch ZIPArchiveExtractorError.symbolicLinkUnsupported {
                        throw ZIPArchiveExtractorError.symbolicLinkUnsupported
                    } catch {
                        let result = try ZIPArchiveExtractor.extract(archiveURL: zipOutput, into: payloadDir)
                        rawExtractedRoot = result.destinationURL
                        extractedFileCount = result.fileCount
                    }
                    if rawExtractedRoot == stagingDir {
                        rawExtractedRoot = payloadDir
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        progressModel.finish()
                        self.isExecuting = false
                    }
                    return
                } catch {
                    await MainActor.run {
                        progressModel.finish()
                        if let converterError = error as? PatchZipConverterError {
                            switch converterError {
                            case .cryptoFailed:
                                self.alertMessage = activeLanguage.text("overwrite.error.decrypt_wrong_password")
                            default:
                                self.alertMessage = activeLanguage.text("overwrite.error.decrypt_failed", error.localizedDescription)
                            }
                        } else {
                            let errText = error.localizedDescription
                            if errText.contains("Mật khẩu") || errText.contains("Password") || errText.contains("password") || errText.contains("密码") {
                                self.alertMessage = activeLanguage.text("overwrite.error.decrypt_wrong_password")
                            } else {
                                self.alertMessage = activeLanguage.text("overwrite.error.decrypt_failed", errText)
                            }
                        }
                        self.isExecuting = false
                    }
                    return
                }
            } else {
                var patchIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: patchURL.path, isDirectory: &patchIsDir), patchIsDir.boolValue {
                    rawExtractedRoot = patchURL
                } else if patchURL.pathExtension.lowercased() == "zip" {
                    do {
                        let extractedDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
                        try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
                        let parseZipManually = { () throws -> Int in
                            let archiveSize = (try? patchURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                            guard !PatchPackageLimits.exceedsExpandedLimit(Int64(archiveSize)) else {
                                throw ZIPArchiveExtractorError.expandedTooLarge
                            }
                            let zipData = try Data(contentsOf: patchURL, options: .alwaysMapped)
                            let entries = try PatchZipConverter.shared.parseZipArchive(zipData, password: currentPassword)
                            var written = 0
                            let total = max(entries.count, 1)
                            for (relPath, fileData) in entries {
                                if Task.isCancelled { throw CancellationError() }
                                let normalized = relPath.replacingOccurrences(of: "\\", with: "/")
                                let parts = normalized
                                    .split(separator: "/", omittingEmptySubsequences: true)
                                    .map(String.init)
                                    .filter { $0 != "." }
                                guard !parts.isEmpty, !parts.contains("..") else { continue }
                                var targetFile = extractedDir
                                for (idx, part) in parts.enumerated() {
                                    targetFile.appendPathComponent(part, isDirectory: idx < parts.count - 1)
                                }
                                try FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try fileData.write(to: targetFile, options: .atomic)
                                written += 1
                                if written == 1 || written == total || written % 8 == 0 {
                                    let lastName = parts.last ?? targetFile.lastPathComponent
                                    let snapshot = written
                                    Task { @MainActor in
                                        progressModel.update(
                                            stage: activeLanguage.text("overwrite.progress.extracting"),
                                            detail: activeLanguage.text("folders.task.processed_progress", snapshot, total, lastName),
                                            completed: snapshot,
                                            total: total
                                        )
                                    }
                                }
                            }
                            return written
                        }
                        if isPatchPasswordProtected || currentPassword != nil {
                            extractedFileCount = try parseZipManually()
                        } else {
                            do {
                                extractedFileCount = try ZIPArchiveExtractor.extractFlatContents(
                                    archiveURL: patchURL,
                                    into: extractedDir,
                                    shouldCancel: { Task.isCancelled },
                                    progressHandler: { extracted, total, entryName in
                                        Task { @MainActor in
                                            progressModel.update(
                                                stage: activeLanguage.text("overwrite.progress.extracting"),
                                                detail: activeLanguage.text("folders.task.processed_progress", extracted, total, entryName),
                                                completed: extracted,
                                                total: total
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
                                extractedFileCount = try parseZipManually()
                            }
                        }
                        rawExtractedRoot = extractedDir
                    } catch is CancellationError {
                        await MainActor.run {
                            progressModel.finish()
                            self.isExecuting = false
                        }
                        return
                    } catch {
                        let message: String
                        if let extractorError = error as? ZIPArchiveExtractorError,
                           extractorError == .expandedTooLarge {
                            message = activeLanguage.text("overwrite.error.size_limit")
                        } else if let extractorError = error as? ZIPArchiveExtractorError,
                                  extractorError == .symbolicLinkUnsupported {
                            message = activeLanguage.text("error.filemanager.symlink_unsupported")
                        } else if let converterError = error as? PatchZipConverterError {
                            switch converterError {
                            case .sizeLimitExceeded:
                                message = activeLanguage.text("overwrite.error.size_limit")
                            case .cryptoFailed:
                                message = activeLanguage.text("overwrite.error_wrong_password")
                            default:
                                message = activeLanguage.text("overwrite.error.unzip_failed", error.localizedDescription)
                            }
                        } else {
                            message = activeLanguage.text("overwrite.error.unzip_failed", error.localizedDescription)
                        }
                        await MainActor.run {
                            progressModel.finish()
                            self.alertMessage = message
                            self.isExecuting = false
                        }
                        return
                    }
                } else {
                    do {
                        let extractedDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
                        try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
                        let stagedFile = extractedDir.appendingPathComponent(patchURL.lastPathComponent)
                        try FileManager.default.copyItem(at: patchURL, to: stagedFile)
                        rawExtractedRoot = extractedDir
                        extractedFileCount = 1
                    } catch {
                        let lang = AppLanguage.current
                        await MainActor.run {
                            progressModel.finish()
                            self.alertMessage = lang.text("overwrite.error.unzip_failed", error.localizedDescription)
                            self.isExecuting = false
                        }
                        return
                    }
                }
            }

            if Task.isCancelled {
                await MainActor.run {
                    progressModel.finish()
                    self.isExecuting = false
                }
                return
            }

            let engine = FileIOEngine.shared

            // 2. Quét danh sách đường dẫn tương đối nguồn & cấu trúc thư mục đích gửi lên Server
            await MainActor.run {
                progressModel.update(
                    stage: activeLanguage.text("overwrite.progress.planning"),
                    detail: targetApp.bundleID,
                    completed: 0,
                    total: 0
                )
            }

            let (sourcePaths, sourceSizes) = Self.collectRelativeSourcePaths(at: rawExtractedRoot)
            let targetPaths = Self.collectTargetStructurePaths(at: destinationDir)
            log("overwrite: extracted=\(extractedFileCount) sourcePaths=\(sourcePaths.count) targetDirs=\(targetPaths.count)")

            if Task.isCancelled {
                await MainActor.run {
                    progressModel.finish()
                    self.isExecuting = false
                }
                return
            }

            let planRequest = OverwritePlanRequest(
                sourcePaths: sourcePaths,
                targetPaths: targetPaths,
                targetBundleId: targetApp.bundleID,
                targetSubfolder: targetSubfolder,
                sourceSizes: sourceSizes
            )

            let planResponse: OverwritePlanResponse
            switch await APIService.shared.overwritePlan(
                planRequest,
                token: LicenseManager.shared.authToken,
                hwid: LicenseManager.shared.deviceIdentifier
            ) {
            case .success(let resp):
                planResponse = resp
            case .failure(let error):
                await MainActor.run {
                    progressModel.finish()
                    self.alertMessage = error.localizedDescription
                    self.isExecuting = false
                }
                return
            }

            if Task.isCancelled {
                await MainActor.run {
                    progressModel.finish()
                    self.isExecuting = false
                }
                return
            }

            if let note = planResponse.note, !note.isEmpty {
                log("overwrite: server plan note=\(note) mapped=\(planResponse.mappings.count) skipped=\(planResponse.skipped?.count ?? 0)")
            }

            // 3. Khởi tạo bộ ghi nhận & sao lưu tự động trước khi đè từng file
            let recorder = await MainActor.run {
                backupManagerRef.createRecorder(
                    patchName: patchDisplayName,
                    bundleID: targetApp.bundleID,
                    appName: targetApp.appName,
                    targetSubfolder: targetSubfolder,
                    destinationRoot: destinationDir
                )
            }

            // 4. Thực hiện ghi đè đúng từng file theo mappings của server qua FileManager / FileIOEngine
            let mappings = planResponse.mappings.map { (source: $0.source, destination: $0.destination) }
            let totalMappings = max(mappings.count, 1)
            await MainActor.run {
                progressModel.update(
                    stage: activeLanguage.text("overwrite.progress.writing"),
                    detail: activeLanguage.text("folders.task.copying_extracted", totalMappings),
                    completed: 0,
                    total: totalMappings
                )
            }

            let result = await engine.applyMappedFiles(
                mappings,
                from: rawExtractedRoot,
                to: destinationDir,
                progressHandler: { completed, currentName in
                    if completed == 1 || completed == totalMappings || completed % 4 == 0 {
                        Task { @MainActor in
                            progressModel.update(
                                stage: activeLanguage.text("overwrite.progress.writing"),
                                detail: activeLanguage.text("folders.task.copied_progress", completed, totalMappings, currentName),
                                completed: min(completed, totalMappings),
                                total: totalMappings
                            )
                        }
                    }
                },
                beforeWriteFile: { destURL, existedBefore in
                    recorder.recordBeforeWrite(destinationURL: destURL, existedBefore: existedBefore)
                }
            ) { s, d, k in
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

            let recordedSession = recorder.finalize(succeededURLs: result.succeeded)

            await MainActor.run {
                progressModel.finish()
                self.isExecuting = false
                if let session = recordedSession {
                    backupManagerRef.saveSession(session)
                    log("overwrite-backup: saved session \(session.id.uuidString) files=\(session.totalFilesCount) overwritten=\(session.overwrittenCount) added=\(session.addedCount) backupBytes=\(session.totalBackupBytes)")
                }
                ContainerMetadataCache.shared.invalidate(path: cacheInvalidationPath)
                self.outcomeResult = FileIOResultWrapper(result: result)
                log("overwrite: completed succeeded=\(result.succeeded.count) skipped=\(result.skipped.count) failed=\(result.failed.count) cancelled=\(result.isCancelled)")
            }
        }
        progressModel.attach(worker)
    }

    private static func collectRelativeSourcePaths(at rootURL: URL) -> (paths: [String], sizes: [String: Int]) {
        let fm = FileManager.default
        let base = rootURL.standardizedFileURL
        let baseComponents = base.pathComponents
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) else {
            return ([], [:])
        }

        var paths: [String] = []
        var sizes: [String: Int] = [:]
        for case let itemURL as URL in enumerator {
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            let itemComponents = itemURL.standardizedFileURL.pathComponents
            guard itemComponents.count > baseComponents.count else { continue }
            let rel = itemComponents.dropFirst(baseComponents.count).joined(separator: "/")
            paths.append(rel)
            if let fileSize = values?.fileSize {
                sizes[rel] = fileSize
            }
        }
        return (paths, sizes)
    }

    private static func collectTargetStructurePaths(
        at destinationRoot: URL,
        maxDepth: Int = 4,
        limit: Int = 500
    ) -> [String] {
        let fm = FileManager.default
        let base = destinationRoot.standardizedFileURL
        let baseComponents = base.pathComponents
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let itemURL as URL in enumerator {
            let level = enumerator.level
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                let comps = itemURL.standardizedFileURL.pathComponents
                if comps.count > baseComponents.count {
                    let rel = comps.dropFirst(baseComponents.count).joined(separator: "/")
                    paths.append(rel)
                    if paths.count >= limit { break }
                }
                if level >= maxDepth {
                    enumerator.skipDescendants()
                }
            }
        }
        return paths
    }
}

// MARK: - Sheet Chi tiết Phiên Sao lưu & Khôi phục Lịch sử Ghi đè (Bảo mật - Không lộ danh sách file)

private struct OverwriteBackupDetailSheet: View {
    @Environment(\.appLanguage) private var language
    let session: OverwriteBackupSession
    @ObservedObject var backupManager: OverwriteBackupManager
    let onDismiss: () -> Void

    @State private var showRestoreConfirm: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var isRestoring: Bool = false
    @State private var restoreCompleted: Int = 0
    @State private var restoreTotal: Int = 0
    @State private var restoreCurrentName: String = ""
    @State private var restoreResultMessage: String? = nil

    private var liveSession: OverwriteBackupSession {
        backupManager.sessions.first(where: { $0.id == session.id }) ?? session
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = "HH:mm • dd/MM/yyyy"
        return formatter.string(from: liveSession.createdAt)
    }

    var body: some View {
        NavigationView {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // MARK: - Card Thông tin Tóm tắt Phiên Sao lưu
                    VStack(spacing: 16) {
                        // Icon trạng thái lớn + Tên gói bản vá
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill((liveSession.isRestored ? Color.blue : TotoroxTheme.mintAccent).opacity(0.14))
                                    .frame(width: 64, height: 64)
                                Image(systemName: liveSession.isRestored ? "checkmark.circle.fill" : "archivebox.fill")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(liveSession.isRestored ? Color.blue : TotoroxTheme.mintAccent)
                            }

                            Text(liveSession.patchName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            // Badge trạng thái
                            Text(liveSession.isRestored ? language.text("overwrite.backup.badge_restored") : language.text("overwrite.backup.badge_ready"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(liveSession.isRestored ? Color.blue : TotoroxTheme.mintAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background((liveSession.isRestored ? Color.blue : TotoroxTheme.mintAccent).opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)

                        Divider()
                            .overlay(TotoroxTheme.dividerColor)

                        // Bảng thuộc tính chi tiết phiên
                        VStack(spacing: 12) {
                            detailRow(
                                title: language.text("overwrite.target_app"),
                                value: liveSession.appName,
                                icon: "app.dashed"
                            )
                            detailRow(
                                title: "Bundle ID",
                                value: liveSession.bundleID,
                                icon: "barcode"
                            )
                            detailRow(
                                title: language.text("folders.folder_type"),
                                value: liveSession.targetSubfolder,
                                icon: "folder.fill"
                            )
                            detailRow(
                                title: "Thời gian",
                                value: formattedDate,
                                icon: "clock.fill"
                            )
                            detailRow(
                                title: language.text("overwrite.backup.filter_overwritten", liveSession.overwrittenCount),
                                value: "\(liveSession.overwrittenCount) tệp",
                                icon: "arrow.counterclockwise.circle.fill"
                            )
                            detailRow(
                                title: language.text("overwrite.backup.filter_added", liveSession.addedCount),
                                value: "\(liveSession.addedCount) tệp",
                                icon: "plus.circle.fill"
                            )
                            detailRow(
                                title: "Dung lượng sao lưu",
                                value: ByteCountFormatter.string(fromByteCount: liveSession.totalBackupBytes, countStyle: .file),
                                icon: "internaldrive.fill"
                            )
                        }
                    }
                    .padding(18)
                    .background(TotoroxTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(TotoroxTheme.cardBorderColor, lineWidth: 0.8)
                    )
                    .shadow(color: TotoroxTheme.shadowColor, radius: 8, x: 0, y: 3)

                    // MARK: - Card Hành động: Khôi phục & Xóa bản sao lưu
                    VStack(spacing: 12) {
                        if isRestoring {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.85)
                                        .tint(TotoroxTheme.mintAccent)
                                    Text(language.text("overwrite.backup.restoring_progress", restoreCompleted, max(restoreTotal, 1)))
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                    Spacer()
                                }
                                if restoreTotal > 0 {
                                    ProgressView(value: Double(restoreCompleted), total: Double(restoreTotal))
                                        .tint(TotoroxTheme.mintAccent)
                                }
                                if !restoreCurrentName.isEmpty {
                                    Text(restoreCurrentName)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(12)
                            .background(TotoroxTheme.searchBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        // Nút Khôi phục về trước khi đè
                        Button {
                            showRestoreConfirm = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    .font(.system(size: 16, weight: .bold))
                                Text(language.text("overwrite.backup.restore_button"))
                                    .font(.system(size: 15, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(isRestoring ? TotoroxTheme.disabledBackground : TotoroxTheme.mintAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(isRestoring)

                        // Nút Xóa bản sao lưu này
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(language.text("overwrite.backup.delete_session"))
                                    .font(.system(size: 13.5, weight: .semibold))
                            }
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Color.red.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(isRestoring)
                    }
                    .padding(16)
                    .background(TotoroxTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(TotoroxTheme.cardBorderColor, lineWidth: 0.8)
                    )
                    .shadow(color: TotoroxTheme.shadowColor, radius: 8, x: 0, y: 3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(TotoroxTheme.pageBackground)
            .navigationTitle(language.text("overwrite.backup.detail_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.close")) {
                        onDismiss()
                    }
                    .font(.system(size: 15, weight: .medium))
                    .disabled(isRestoring)
                }
            }
        }
        .alert(language.text("overwrite.backup.restore_confirm_title"), isPresented: $showRestoreConfirm) {
            Button(language.text("overwrite.backup.restore_confirm_action"), role: .destructive) {
                runRestore()
            }
            Button(language.text("common.cancel"), role: .cancel) { }
        } message: {
            Text(language.text(
                "overwrite.backup.restore_confirm_message",
                liveSession.appName,
                liveSession.overwrittenCount,
                liveSession.addedCount
            ))
        }
        .alert(language.text("overwrite.backup.delete_confirm_title"), isPresented: $showDeleteConfirm) {
            Button(language.text("common.delete"), role: .destructive) {
                backupManager.deleteSession(liveSession)
                onDismiss()
            }
            Button(language.text("common.cancel"), role: .cancel) { }
        } message: {
            Text(language.text("overwrite.backup.delete_confirm_message"))
        }
        .alert(language.text("common.notice"), isPresented: Binding(
            get: { restoreResultMessage != nil },
            set: { if !$0 { restoreResultMessage = nil } }
        )) {
            Button(language.text("common.ok"), role: .cancel) {
                restoreResultMessage = nil
            }
        } message: {
            Text(restoreResultMessage ?? "")
        }
    }

    private func detailRow(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TotoroxTheme.mintAccent)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TotoroxTheme.textSecondary)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(TotoroxTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func runRestore() {
        let target = liveSession
        isRestoring = true
        restoreCompleted = 0
        restoreTotal = target.totalFilesCount
        restoreCurrentName = ""

        Task {
            let res = await backupManager.restoreSession(target) { completed, total, name in
                Task { @MainActor in
                    self.restoreCompleted = completed
                    self.restoreTotal = total
                    self.restoreCurrentName = name
                }
            }
            await MainActor.run {
                self.isRestoring = false
                if res.hasFailures {
                    self.restoreResultMessage = language.text(
                        "overwrite.backup.restore_partial",
                        res.restoredOriginalCount,
                        res.deletedNewCount,
                        res.failedItems.count
                    )
                } else {
                    self.restoreResultMessage = language.text(
                        "overwrite.backup.restore_success",
                        res.restoredOriginalCount,
                        res.deletedNewCount
                    )
                }
                log("overwrite-backup: restored=\(res.restoredOriginalCount) deletedNew=\(res.deletedNewCount) failed=\(res.failedItems.count)")
            }
        }
    }
}
