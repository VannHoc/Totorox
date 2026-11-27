import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum ModUpdaterPickerMode: Identifiable {
    case resourcesZip
    case oldModFile
    case share(URL)

    var id: String {
        switch self {
        case .resourcesZip: return "resourcesZip"
        case .oldModFile: return "oldModFile"
        case .share(let u): return "share:\(u.path)"
        }
    }
}

struct UpdateModSkinView: View {
    var isEmbedded: Bool = false

    @Environment(\.appLanguage) private var language
    @ObservedObject private var navCoordinator = AppNavigationCoordinator.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    // Step 1: Resources Snapshot Cache
    @State private var cachedSnapshot: (meta: CachedResourcesSnapshot, fileURL: URL)? = nil
    @State private var isPreparingResources: Bool = false

    // Step 2: Old Mod Selection & Options
    @State private var selectedOldModURL: URL? = nil
    @State private var oldModSizeText: String = ""
    @State private var isImportingOldMod: Bool = false
    @State private var requiresPasswordInput: Bool = false
    @State private var inputPassword: String = ""
    @State private var upgradeMissingFeatures: Bool = true
    @State private var inspectionPreview: ModUpdaterInspectionResponse? = nil

    // Step 3: Execution & Result
    @State private var isWorking: Bool = false
    @State private var statusMessage: String = ""
    @State private var progressValue: Double = 0.0
    @State private var activeTask: Task<Void, Never>? = nil
    @State private var updatedOutput: UpdatedModOutput? = nil

    @State private var activeSheet: ModUpdaterPickerMode? = nil
    @State private var alertMessage: String? = nil

    private var updaterAccent: Color {
        CatalogScreenPalette.oceanBlue.accent(isDark: themeManager.mode == .dark)
    }

    private static var resourcesZipContentTypes: [UTType] {
        [UTType.zip, UTType.archive, UTType.data]
    }

    private static var oldModContentTypes: [UTType] {
        var types: [UTType] = [UTType.zip, UTType.archive]
        if let patchExported = UTType("com.totorox.patch-package") {
            types.append(patchExported)
        }
        if let patchExt = UTType(filenameExtension: "3105") {
            types.append(patchExt)
        }
        types.append(contentsOf: [UTType.data, UTType.content])
        return types
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    headerTitleCard

                    step1ResourcesCard

                    step2OldModCard

                    step3UpdateActionCard

                    if let output = updatedOutput {
                        resultCard(output)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, isEmbedded ? 6 : 12)
                .padding(.bottom, 32)
                .frame(width: proxy.size.width > 0 ? proxy.size.width : nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TotoroxTheme.tabCanvasBackground)
        .onAppear {
            cachedSnapshot = AovModUpdaterEngine.shared.loadCachedSnapshot()
        }
        .onDisappear {
            activeTask?.cancel()
        }
        .sheet(item: $activeSheet) { mode in
            switch mode {
            case .resourcesZip:
                DocumentPickerWrapper(
                    allowedContentTypes: Self.resourcesZipContentTypes,
                    asCopy: true
                ) { url in
                    handlePickedResources(url)
                }
                .preferredColorScheme(themeManager.mode.colorScheme)
            case .oldModFile:
                DocumentPickerWrapper(
                    allowedContentTypes: Self.oldModContentTypes,
                    asCopy: true
                ) { url in
                    handlePickedOldMod(url)
                }
                .preferredColorScheme(themeManager.mode.colorScheme)
            case .share(let url):
                ActivityViewControllerWrapper(activityItems: [url])
                    .preferredColorScheme(themeManager.mode.colorScheme)
            }
        }
        .alert(language.text("common.notice"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(language.text("common.ok"), role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Compact Title Header (No Subtitles or Descriptions)

    private var headerTitleCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(updaterAccent.opacity(0.16))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(updaterAccent.opacity(0.28), lineWidth: 0.9)
                    )
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(updaterAccent)
            }

            Text(language.text("catalog.sub.update_mod"))
                .font(.system(size: 17.5, weight: .bold))
                .foregroundStyle(TotoroxTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 6)

            if let snap = cachedSnapshot {
                Text("v\(snap.meta.gameVersion)")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(updaterAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(updaterAccent.opacity(0.13))
                    .clipShape(Capsule())
            }
        }
        .totoroxCard(cornerRadius: 16, padding: 14)
    }

    // MARK: - Step 1: Resources Gốc Mới Nhất (Chỉ giữ Quét trên máy & Chọn ZIP)

    private var step1ResourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                number: 1,
                title: language.text("modupdater.step1.title"),
                isReady: cachedSnapshot != nil
            )

            if let snap = cachedSnapshot {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(TotoroxTheme.mintAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resources \(snap.meta.gameVersion)")
                                .font(.system(size: 14.5, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                            Text(
                                language.text(
                                    "modupdater.step1.cached_meta",
                                    snap.meta.sourceLabel,
                                    snap.meta.formattedSize
                                )
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Button {
                            AovModUpdaterEngine.shared.clearCache()
                            cachedSnapshot = nil
                            inspectionPreview = nil
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.red.opacity(0.85))
                                .padding(8)
                                .background(Color.red.opacity(0.10))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking || isPreparingResources || isImportingOldMod)
                    }
                    .padding(11)
                    .background(TotoroxTheme.mintAccent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                    resourcesPickerButtons(compact: true)
                }
            } else {
                resourcesPickerButtons(compact: false)
            }
        }
        .totoroxCard(cornerRadius: 18, padding: 15)
    }

    private func resourcesPickerButtons(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                scanResourcesFromInstalledGame()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 13, weight: .bold))
                    Text(language.text("modupdater.step1.scan_game"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundStyle(compact ? TotoroxTheme.mintAccent : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(compact ? TotoroxTheme.mintAccent.opacity(0.14) : TotoroxTheme.mintAccent)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isPreparingResources || isImportingOldMod)

            Button {
                activeSheet = .resourcesZip
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 13, weight: .bold))
                    Text(language.text("modupdater.step1.pick_zip"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundStyle(TotoroxTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isPreparingResources || isImportingOldMod)
        }
    }

    // MARK: - Step 2: File Mod Cũ (.zip / .3105)

    private var step2OldModCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                number: 2,
                title: language.text("modupdater.step2.title"),
                isReady: selectedOldModURL != nil
            )

            if isImportingOldMod {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(TotoroxTheme.mintAccent)
                        .scaleEffect(0.9)
                    Text(language.text("common.loading"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                    Spacer()
                }
                .padding(12)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else if let modURL = selectedOldModURL {
                HStack(spacing: 10) {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(red: 0.92, green: 0.56, blue: 0.12))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(modURL.lastPathComponent)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .lineLimit(1)
                        Text(oldModSizeText)
                            .font(.system(size: 12))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                    }

                    Spacer(minLength: 4)

                    Button {
                        activeSheet = .oldModFile
                    } label: {
                        Text(language.text("modupdater.step2.change"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(TotoroxTheme.mintAccent.opacity(0.13))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking || isPreparingResources)
                }
                .padding(11)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else {
                Button {
                    activeSheet = .oldModFile
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text(language.text("modupdater.step2.pick_button"))
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(TotoroxTheme.mintAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(TotoroxTheme.mintAccent.opacity(0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(TotoroxTheme.mintAccent.opacity(0.38), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isWorking || isPreparingResources)
            }

            if requiresPasswordInput {
                SecureField(language.text("modupdater.step2.password_placeholder"), text: $inputPassword)
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            Toggle(isOn: $upgradeMissingFeatures) {
                Text(language.text("modupdater.step2.upgrade_features"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(TotoroxTheme.textPrimary)
            }
            .tint(TotoroxTheme.mintAccent)

            if let insp = inspectionPreview {
                inspectionSummaryBox(insp)
            } else if cachedSnapshot != nil && selectedOldModURL != nil && !isWorking && !isPreparingResources && !isImportingOldMod {
                Button {
                    runInspectPreview()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12.5, weight: .bold))
                        Text(language.text("modupdater.step2.inspect_btn"))
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .totoroxCard(cornerRadius: 18, padding: 15)
    }

    private func inspectionSummaryBox(_ insp: ModUpdaterInspectionResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    "\(insp.oldGameVersion ?? "?") → \(insp.targetGameVersion ?? "?")"
                )
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(TotoroxTheme.mintAccent)

                Spacer()

                if let bundles = insp.customAssetbundleCount, bundles > 0 {
                    Text(language.text("modupdater.inspect.bundles", bundles))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
            }

            if let items = insp.items, !items.isEmpty {
                ForEach(items.prefix(5)) { item in
                    Text("• \(item.heroName) → \(item.sourceSkinName)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)
                }
                if items.count > 5 {
                    Text("+\(items.count - 5)...")
                        .font(.system(size: 11.5))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
            }
        }
        .padding(11)
        .background(TotoroxTheme.mintAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Step 3: Ấn Update & Xuất File Mới

    private var step3UpdateActionCard: some View {
        let canRun = (cachedSnapshot != nil && selectedOldModURL != nil && !isWorking && !isPreparingResources && !isImportingOldMod)

        return VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                number: 3,
                title: language.text("modupdater.step3.title"),
                isReady: updatedOutput != nil
            )

            if isWorking || isPreparingResources {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text(statusMessage)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int((progressValue * 100).rounded()))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                    }

                    ProgressView(value: min(max(progressValue, 0.02), 1.0))
                        .tint(TotoroxTheme.mintAccent)

                    Button(role: .destructive) {
                        activeTask?.cancel()
                        isWorking = false
                        isPreparingResources = false
                    } label: {
                        Text(language.text("common.cancel"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Color.red.opacity(0.11))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    runUpdateMod()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 17, weight: .bold))
                        Text(language.text("modupdater.step3.run_button"))
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        canRun
                            ? LinearGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.54, blue: 0.95),
                                    TotoroxTheme.mintAccent
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            : LinearGradient(
                                colors: [Color.gray.opacity(0.38), Color.gray.opacity(0.38)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canRun)
            }
        }
        .totoroxCard(cornerRadius: 18, padding: 15)
    }

    private func resultCard(_ output: UpdatedModOutput) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("modupdater.result.ready"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                    Text("\(output.fileName) • \(output.formattedSize) • v\(output.targetGameVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    navCoordinator.navigateToOverwrite(
                        patchURL: output.outputURL,
                        bundleID: "com.garena.game.kgvn"
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(language.text("modupdater.result.overwrite_now"))
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(TotoroxTheme.mintAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .share(output.outputURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .bold))
                        Text(language.text("modstore.action.share_zip_short"))
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(TotoroxTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(TotoroxTheme.searchBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .totoroxCard(cornerRadius: 18, padding: 15)
    }

    private func stepHeader(number: Int, title: String, isReady: Bool) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(isReady ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(isReady ? .white : TotoroxTheme.textSecondary)
            }

            Text(title)
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(TotoroxTheme.textPrimary)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions & Sandbox File Staging

    private static func isTemporaryInboxCopy(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let tmpRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return path.hasPrefix(tmpRoot) || path.contains("-Inbox/")
    }

    private static func stagePickedFileIntoSandbox(from sourceURL: URL, subfolder: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(subfolder, isDirectory: true)
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let rawName = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = rawName.isEmpty ? "SelectedMod.zip" : rawName
        let destURL = dir.appendingPathComponent(safeName, isDirectory: false)

        if isTemporaryInboxCopy(sourceURL), (try? fm.moveItem(at: sourceURL, to: destURL)) != nil {
            return destURL
        }
        if (try? FileIOEngine.shared.copySingleFile(from: sourceURL, to: destURL, syncAfterWrite: false)) != nil {
            return destURL
        }
        if (try? fm.copyItem(at: sourceURL, to: destURL)) != nil {
            return destURL
        }

        var coordError: NSError?
        var copyErr: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordError) { readableURL in
            do {
                try FileIOEngine.shared.copySingleFile(from: readableURL, to: destURL, syncAfterWrite: false)
            } catch {
                do {
                    try fm.copyItem(at: readableURL, to: destURL)
                } catch let fallbackErr {
                    copyErr = fallbackErr
                }
            }
        }
        if let coordError { throw coordError }
        if let copyErr { throw copyErr }
        return destURL
    }

    private func handlePickedResources(_ url: URL) {
        activeTask?.cancel()
        isPreparingResources = true
        progressValue = 0.05
        statusMessage = language.text("modupdater.progress.indexing_resources")
        let hasScope = url.startAccessingSecurityScopedResource()

        activeTask = Task {
            defer {
                if hasScope { url.stopAccessingSecurityScopedResource() }
                if Self.isTemporaryInboxCopy(url) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            do {
                let snap = try await AovModUpdaterEngine.shared.prepareResourcesSnapshot(from: url) { msg, frac in
                    Task { @MainActor in
                        self.statusMessage = msg
                        self.progressValue = frac
                    }
                }
                await MainActor.run {
                    self.cachedSnapshot = snap
                    self.inspectionPreview = nil
                    self.isPreparingResources = false
                }
            } catch is CancellationError {
                await MainActor.run { self.isPreparingResources = false }
            } catch {
                await MainActor.run {
                    self.isPreparingResources = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func scanResourcesFromInstalledGame() {
        activeTask?.cancel()
        isPreparingResources = true
        progressValue = 0.05
        statusMessage = language.text("modupdater.progress.locating_game")

        activeTask = Task {
            do {
                let snap = try await AovModUpdaterEngine.shared.prepareResourcesSnapshotFromInstalledGame { msg, frac in
                    Task { @MainActor in
                        self.statusMessage = msg
                        self.progressValue = frac
                    }
                }
                await MainActor.run {
                    self.cachedSnapshot = snap
                    self.inspectionPreview = nil
                    self.isPreparingResources = false
                }
            } catch is CancellationError {
                await MainActor.run { self.isPreparingResources = false }
            } catch {
                await MainActor.run {
                    self.isPreparingResources = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func handlePickedOldMod(_ url: URL) {
        let hasScope = url.startAccessingSecurityScopedResource()
        let activeLanguage = language
        isImportingOldMod = true

        Task.detached(priority: .userInitiated) {
            defer {
                if hasScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let stagedURL = try Self.stagePickedFileIntoSandbox(
                    from: url,
                    subfolder: "TotoroxSelectedOldMod"
                )
                let size = Int64((try? stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard size > 0 else {
                    try? FileManager.default.removeItem(at: stagedURL)
                    throw AovModUpdaterError.invalidOldModArchive(
                        activeLanguage.text("overwrite.error_invalid_archive")
                    )
                }

                var is3105 = stagedURL.pathExtension.lowercased() == "3105"
                var isZip = false
                if let h = try? FileHandle(forReadingFrom: stagedURL) {
                    let head = (try? h.read(upToCount: 10)) ?? Data()
                    try? h.close()
                    if head.starts(with: Data("3105PATCH\0".utf8)) {
                        is3105 = true
                    } else if head.count >= 4 {
                        let m4 = head.prefix(4)
                        isZip = (m4 == Data([0x50, 0x4B, 0x03, 0x04]) || m4 == Data([0x50, 0x4B, 0x05, 0x06]))
                    }
                }

                guard is3105 || isZip else {
                    try? FileManager.default.removeItem(at: stagedURL)
                    throw AovModUpdaterError.invalidOldModArchive(
                        activeLanguage.text("overwrite.error_invalid_archive")
                    )
                }

                let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                await MainActor.run {
                    self.selectedOldModURL = stagedURL
                    self.oldModSizeText = formattedSize
                    self.requiresPasswordInput = is3105
                    if !is3105 { self.inputPassword = "" }
                    self.inspectionPreview = nil
                    self.updatedOutput = nil
                    self.isImportingOldMod = false
                }
            } catch {
                await MainActor.run {
                    self.isImportingOldMod = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func runInspectPreview() {
        guard let snap = cachedSnapshot, let modURL = selectedOldModURL else { return }
        activeTask?.cancel()
        isWorking = true
        progressValue = 0.1
        statusMessage = language.text("modupdater.progress.inspecting_server")
        let pw = inputPassword

        activeTask = Task {
            do {
                let insp = try await AovModUpdaterEngine.shared.inspectOldMod(
                    snapshot: snap,
                    oldModURL: modURL,
                    inputPassword: pw
                ) { msg, frac in
                    Task { @MainActor in
                        self.statusMessage = msg
                        self.progressValue = frac
                    }
                }
                await MainActor.run {
                    self.inspectionPreview = insp
                    self.isWorking = false
                }
            } catch is CancellationError {
                await MainActor.run { self.isWorking = false }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func runUpdateMod() {
        guard let snap = cachedSnapshot, let modURL = selectedOldModURL else { return }
        activeTask?.cancel()
        isWorking = true
        updatedOutput = nil
        progressValue = 0.08
        statusMessage = language.text("modupdater.progress.checking_server_cache")
        let pw = inputPassword
        let upg = upgradeMissingFeatures
        let gateAccent = updaterAccent
        let gateTitle = language.text("catalog.sub.update_mod")

        activeTask = Task {
            do {
                let verifiedGateID = try await CatalogLinkGateManager.shared.requireVerifiedGate(
                    action: .modUpdate,
                    featureTitle: gateTitle,
                    accentColor: gateAccent
                )
                let output = try await AovModUpdaterEngine.shared.updateOldMod(
                    snapshot: snap,
                    oldModURL: modURL,
                    inputPassword: pw,
                    upgradeMissingFeatures: upg,
                    gateID: verifiedGateID
                ) { msg, frac in
                    Task { @MainActor in
                        self.statusMessage = msg
                        self.progressValue = frac
                    }
                }
                await MainActor.run {
                    self.updatedOutput = output
                    if let insp = output.inspection {
                        self.inspectionPreview = insp
                    }
                    self.isWorking = false
                }
            } catch is CancellationError {
                await MainActor.run { self.isWorking = false }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }
}
