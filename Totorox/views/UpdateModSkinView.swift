import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum ModUpdaterPickerMode: Identifiable {
    case resourcesZip
    case resourcesFolder
    case oldModFile
    case share(URL)

    var id: String {
        switch self {
        case .resourcesZip: return "resourcesZip"
        case .resourcesFolder: return "resourcesFolder"
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

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    headerIntroCard

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
                SingleFileOrFolderDocumentPicker(allowDirectories: false) { url in
                    if let url { handlePickedResources(url) }
                }
                .preferredColorScheme(themeManager.mode.colorScheme)
            case .resourcesFolder:
                SingleFileOrFolderDocumentPicker(allowDirectories: true) { url in
                    if let url { handlePickedResources(url) }
                }
                .preferredColorScheme(themeManager.mode.colorScheme)
            case .oldModFile:
                SingleFileOrFolderDocumentPicker(allowDirectories: false) { url in
                    if let url { handlePickedOldMod(url) }
                }
                .preferredColorScheme(themeManager.mode.colorScheme)
            case .share(let url):
                ModUpdaterShareSheet(items: [url])
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

    // MARK: - Header Intro Card (Description Shown Inside Feature Screen)

    private var headerIntroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(red: 0.16, green: 0.56, blue: 0.96).opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.16, green: 0.56, blue: 0.96))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("catalog.sub.update_mod"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                    Text(language.text("modupdater.header.badge"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                }

                Spacer(minLength: 0)
            }

            Text(language.text("catalog.sub.update_mod.desc"))
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(TotoroxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .totoroxCard(cornerRadius: 18, padding: 15)
    }

    // MARK: - Step 1: Resources Gốc Mới Nhất

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
                        .disabled(isWorking || isPreparingResources)
                    }
                    .padding(11)
                    .background(TotoroxTheme.mintAccent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                    resourcesPickerButtons(compact: true)
                }
            } else {
                Text(language.text("modupdater.step1.hint"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(TotoroxTheme.textSecondary)

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
                .frame(height: 40)
                .background(compact ? TotoroxTheme.mintAccent.opacity(0.14) : TotoroxTheme.mintAccent)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isPreparingResources)

            Menu {
                Button {
                    activeSheet = .resourcesZip
                } label: {
                    Label(language.text("modupdater.step1.pick_zip"), systemImage: "doc.zipper")
                }
                Button {
                    activeSheet = .resourcesFolder
                } label: {
                    Label(language.text("modupdater.step1.pick_folder"), systemImage: "folder")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                    Text(language.text(compact ? "modupdater.step1.change_file" : "modupdater.step1.pick_file"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundStyle(TotoroxTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(TotoroxTheme.searchBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .disabled(isWorking || isPreparingResources)
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

            if let modURL = selectedOldModURL {
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
            } else if cachedSnapshot != nil && selectedOldModURL != nil && !isWorking && !isPreparingResources {
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
        let canRun = (cachedSnapshot != nil && selectedOldModURL != nil && !isWorking && !isPreparingResources)

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
                        Text(language.text("wallpaper.cancel"))
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
                    navCoordinator.navigateToOverwrite(patchURL: output.outputURL)
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

    // MARK: - Actions

    private func handlePickedResources(_ url: URL) {
        activeTask?.cancel()
        isPreparingResources = true
        progressValue = 0.05
        statusMessage = language.text("modupdater.progress.indexing_resources")

        activeTask = Task {
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
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var is3105 = url.pathExtension.lowercased() == "3105"
        if !is3105, let h = try? FileHandle(forReadingFrom: url) {
            let head = (try? h.read(upToCount: 10)) ?? Data()
            try? h.close()
            is3105 = head.starts(with: Data("3105PATCH\0".utf8))
        }
        if hasScope { url.stopAccessingSecurityScopedResource() }

        selectedOldModURL = url
        oldModSizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        requiresPasswordInput = is3105
        if !is3105 { inputPassword = "" }
        inspectionPreview = nil
        updatedOutput = nil
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
        let gateAccent = CatalogScreenPalette.oceanBlue.accent(isDark: themeManager.mode == .dark)
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

// MARK: - Lightweight Document Picker Supporting File or Folder (asCopy = false for 8 GB+ ZIP!)

private struct SingleFileOrFolderDocumentPicker: UIViewControllerRepresentable {
    let allowDirectories: Bool
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = allowDirectories ? [.folder] : [.item, .archive, .zip, .data]
        // QUAN TRỌNG: `asCopy: false` để mở trực tiếp URL security-scoped thay vì ép iOS copy cả cục Resources 8 GB vào Inbox!
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}

private struct ModUpdaterShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
