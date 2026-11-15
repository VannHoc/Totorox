import SwiftUI
import UniformTypeIdentifiers

enum ConverterDirection: String, CaseIterable, Identifiable {
    case zipToPatch = "ZIP ➔ .3105"
    case patchToZip = ".3105 ➔ ZIP"

    var id: String { rawValue }

    var outputExtension: String {
        switch self {
        case .zipToPatch: return "3105"
        case .patchToZip: return "zip"
        }
    }

    func displayTitle(language: AppLanguage) -> String {
        switch self {
        case .zipToPatch: return language.text("converter.dir.zip_to_patch")
        case .patchToZip: return language.text("converter.dir.patch_to_zip")
        }
    }
}

struct ConversionHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceName: String
    let targetName: String
    let targetPath: String
    let timestamp: Date
    let fileSizeText: String
}

private struct ConverterShareURLItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct PatchConverterView: View {
    @Environment(\.appLanguage) private var language
    @State private var direction: ConverterDirection = .zipToPatch
    @State private var selectedSourceURL: URL? = nil
    @State private var sourceFileSizeText: String = ""
    @State private var sourceMetadataSummary: String? = nil
    @State private var isSourceValid: Bool = false
    @State private var isSourcePasswordProtected: Bool = false
    @State private var inspectGeneration: UUID = UUID()
    @State private var sourcePasswordText: String = ""
    @State private var showSourcePassword: Bool = false

    // Output customization
    @State private var outputFileNameText: String = ""
    @State private var outputPasswordText: String = ""
    @State private var showOutputPassword: Bool = false

    // Processing state
    @State private var isConverting: Bool = false
    @State private var conversionError: String? = nil
    @State private var convertedFileURL: URL? = nil
    @State private var convertedFileSizeText: String = ""

    // UI sheets
    @State private var showFilePicker: Bool = false
    @State private var activeShareItem: ConverterShareURLItem? = nil

    // History
    @State private var history: [ConversionHistoryItem] = []

    /// Converted outputs live in the temp folder. Keep only a small window so the folder cannot
    /// grow without bound while the history entries that reference them stay usable.
    private static let maximumRetainedConversions = 10
    private static let historyStorageKey = "totorox.patch.history.v1"

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    // Header description
                    VStack(spacing: 4) {
                        Text(language.text("converter.header.title"))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .multilineTextAlignment(.center)

                        Text(language.text("converter.header.subtitle"))
                            .font(.system(size: 13))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    // Direction Pill Switcher
                    HStack(spacing: 8) {
                        ForEach(ConverterDirection.allCases) { dir in
                            let isSelected = (direction == dir)
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    direction = dir
                                    inspectGeneration = UUID()
                                    selectedSourceURL = nil
                                    sourceMetadataSummary = nil
                                    isSourceValid = false
                                    isSourcePasswordProtected = false
                                    sourcePasswordText = ""
                                    outputFileNameText = ""
                                    outputPasswordText = ""
                                    convertedFileURL = nil
                                    conversionError = nil
                                }
                            } label: {
                                Text(dir.displayTitle(language: language))
                                    .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                                    .foregroundColor(isSelected ? .white : TotoroxTheme.textSecondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Dropzone / File Picker Card
                    if let source = selectedSourceURL {
                        VStack(spacing: 12) {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(TotoroxTheme.mintAccent.opacity(0.12))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: direction == .zipToPatch ? "doc.zipper" : "archivebox.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.lastPathComponent)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    HStack(spacing: 8) {
                                        Text(sourceFileSizeText)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(TotoroxTheme.textSecondary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)

                                        TotoroxBadge(
                                            title: language.text(direction == .zipToPatch ? "converter.badge.zip_source" : "converter.badge.3105_source"),
                                            isAccent: true
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button(language.text("converter.button.change_file")) {
                                    showFilePicker = true
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TotoroxTheme.mintAccent)
                                .fixedSize(horizontal: true, vertical: false)
                            }

                            if let summary = sourceMetadataSummary {
                                Divider()
                                let summaryIcon: String = isSourceValid
                                    ? "info.circle"
                                    : (isSourcePasswordProtected ? "lock.circle" : "exclamationmark.triangle.fill")
                                let summaryColor: Color = isSourceValid
                                    ? TotoroxTheme.mintAccent
                                    : (isSourcePasswordProtected ? Color.orange : Color.red)
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: summaryIcon)
                                        .foregroundStyle(summaryColor)
                                    Text(summary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(isSourceValid || isSourcePasswordProtected ? TotoroxTheme.textSecondary : Color.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .totoroxCard()
                    } else {
                        // Empty Dropzone
                        Button {
                            showFilePicker = true
                        } label: {
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(TotoroxTheme.searchBackground)
                                        .frame(width: 60, height: 60)
                                    Image(systemName: "arrow.down.doc.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                }

                                Text(language.text(direction == .zipToPatch ? "converter.dropzone.pick_zip" : "converter.dropzone.pick_3105"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.textPrimary)
                                    .multilineTextAlignment(.center)

                                Text(language.text("converter.dropzone.subtitle"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 28)
                            .background(TotoroxTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(TotoroxTheme.mintAccent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                            )
                            .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                    }

                    // Source Unlock Password Field (only shown when input file is password-protected)
                    if isSourcePasswordProtected {
                        let trimmedSourcePwd = sourcePasswordText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let needsRequiredPassword = trimmedSourcePwd.isEmpty
                        VStack(alignment: .leading, spacing: 8) {
                            Text(language.text("converter.section.source_password"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TotoroxTheme.textPrimary)

                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill")
                                    .foregroundStyle(needsRequiredPassword ? Color.orange : TotoroxTheme.mintAccent)

                                Group {
                                    if showSourcePassword {
                                        TextField(
                                            language.text(direction == .patchToZip ? "converter.placeholder.source_password_3105" : "converter.placeholder.source_password_zip"),
                                            text: $sourcePasswordText
                                        )
                                    } else {
                                        SecureField(
                                            language.text(direction == .patchToZip ? "converter.placeholder.source_password_3105" : "converter.placeholder.source_password_zip"),
                                            text: $sourcePasswordText
                                        )
                                    }
                                }
                                .font(.system(size: 14))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .onSubmit {
                                    if let source = selectedSourceURL {
                                        inspectSourceFile(source, keepCustomInputs: true)
                                    }
                                }

                                if needsRequiredPassword {
                                    Text(language.text("converter.badge.required"))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.14))
                                        .clipShape(Capsule())
                                } else if let source = selectedSourceURL {
                                    Button(language.text("converter.button.unlock_preview")) {
                                        inspectSourceFile(source, keepCustomInputs: true)
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                    .buttonStyle(.plain)
                                }

                                Button {
                                    showSourcePassword.toggle()
                                } label: {
                                    Image(systemName: showSourcePassword ? "eye.slash.fill" : "eye.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(TotoroxTheme.searchBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(needsRequiredPassword ? Color.orange.opacity(0.75) : Color.clear, lineWidth: 1.2)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .totoroxCard()
                    }

                    // Output Customization Card (Filename + Output Password)
                    let canCustomizeAndConvert = isSourceValid
                        || (isSourcePasswordProtected && !sourcePasswordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if selectedSourceURL != nil && canCustomizeAndConvert {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                Text(language.text("converter.section.output_config"))
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(TotoroxTheme.textPrimary)
                            }

                            // Output File Name
                            VStack(alignment: .leading, spacing: 6) {
                                Text(language.text("converter.label.output_filename"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.textSecondary)

                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.mintAccent)

                                    TextField(
                                        language.text("converter.placeholder.output_filename"),
                                        text: $outputFileNameText
                                    )
                                    .font(.system(size: 14, weight: .medium))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)

                                    if !outputFileNameText.isEmpty {
                                        Button {
                                            outputFileNameText = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(TotoroxTheme.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Text(".\(direction.outputExtension)")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(TotoroxTheme.mintAccent.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 44)
                                .background(TotoroxTheme.searchBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }

                            // Output Password (optional for both .zip -> .3105 and .3105 -> .zip)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(language.text("converter.label.output_password"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.textSecondary)

                                HStack(spacing: 8) {
                                    Image(systemName: outputPasswordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "lock.open.fill" : "lock.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TotoroxTheme.textSecondary)

                                    Group {
                                        if showOutputPassword {
                                            TextField(
                                                language.text(direction == .zipToPatch ? "converter.placeholder.output_password_3105" : "converter.placeholder.output_password_zip"),
                                                text: $outputPasswordText
                                            )
                                        } else {
                                            SecureField(
                                                language.text(direction == .zipToPatch ? "converter.placeholder.output_password_3105" : "converter.placeholder.output_password_zip"),
                                                text: $outputPasswordText
                                            )
                                        }
                                    }
                                    .font(.system(size: 14))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)

                                    Button {
                                        showOutputPassword.toggle()
                                    } label: {
                                        Image(systemName: showOutputPassword ? "eye.slash.fill" : "eye.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(TotoroxTheme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 44)
                                .background(TotoroxTheme.searchBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .totoroxCard()
                    }

                    // Error Banner
                    if let err = conversionError {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.red)
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Convert Button
                    TotoroxPrimaryButton(
                        title: language.text("converter.button.start"),
                        icon: "arrow.triangle.2.circlepath",
                        isLoading: isConverting,
                        isEnabled: selectedSourceURL != nil && canCustomizeAndConvert && !isConverting
                    ) {
                        performConversion()
                    }

                    // Converted Result Banner
                    if let converted = convertedFileURL {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(TotoroxTheme.mintAccent.opacity(0.15))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language.text("converter.result.success"))
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(TotoroxTheme.textPrimary)

                                    Text("\(converted.lastPathComponent) (\(convertedFileSizeText))")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                activeShareItem = ConverterShareURLItem(url: converted)
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text(language.text("converter.button.share_output"))
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(TotoroxTheme.mintAccent)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .totoroxCard()
                    }

                    // Recent History
                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(language.text("converter.history.title"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)

                            VStack(spacing: 8) {
                                ForEach(history) { item in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(item.sourceName) ➔ \(item.targetName)")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(TotoroxTheme.textPrimary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(item.fileSizeText)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(TotoroxTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        Button {
                                            let target = URL(fileURLWithPath: item.targetPath)
                                            if FileManager.default.fileExists(atPath: target.path) {
                                                activeShareItem = ConverterShareURLItem(url: target)
                                            } else {
                                                loadPersistedHistory()
                                            }
                                        } label: {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(TotoroxTheme.mintAccent)
                                                .padding(8)
                                                .background(TotoroxTheme.mintAccent.opacity(0.12))
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .totoroxCard(cornerRadius: 14, padding: 12)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(width: proxy.size.width > 0 ? proxy.size.width : nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TotoroxTheme.pageBackground)
        .onAppear {
            loadPersistedHistory()
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerWrapper(
                allowedContentTypes: direction == .zipToPatch
                    ? [UTType.zip]
                    : [UTType(filenameExtension: "3105") ?? .data, .data, .item]
            ) { picked in
                inspectSourceFile(picked, keepCustomInputs: false)
            }
        }
        .sheet(item: $activeShareItem) { item in
            ActivityViewControllerWrapper(activityItems: [item.url])
        }
    }

    private static func sanitizedOutputStem(from rawText: String, fallback: String) -> String {
        var stem = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".3105", ".zip", ".ZIP"] where stem.hasSuffix(ext) {
            stem = String(stem.dropLast(ext.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        stem = stem.components(separatedBy: invalidChars).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if stem.isEmpty || stem == "." || stem == ".." {
            return fallback.isEmpty ? "ConvertedPatch" : fallback
        }
        return stem
    }

    private func inspectSourceFile(_ url: URL, keepCustomInputs: Bool) {
        let initialStem = Self.sanitizedOutputStem(
            from: url.deletingPathExtension().lastPathComponent,
            fallback: "ConvertedPatch"
        )
        let inspectionToken = UUID()
        inspectGeneration = inspectionToken
        selectedSourceURL = url
        convertedFileURL = nil
        conversionError = nil
        isSourceValid = false
        if !keepCustomInputs {
            isSourcePasswordProtected = false
            sourcePasswordText = ""
            outputPasswordText = ""
            outputFileNameText = initialStem
        }

        let currentDirection = direction
        let trimmedSourcePwd = keepCustomInputs
            ? sourcePasswordText.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let currentSourcePassword = trimmedSourcePwd.isEmpty ? nil : trimmedSourcePwd
        let activeLanguage = language

        Task.detached(priority: .userInitiated) {
            let hasScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasScope { url.stopAccessingSecurityScopedResource() }
            }

            let fm = FileManager.default
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)

            var detectedProtected = false
            var detectedValid = false
            var suggestedStem: String? = nil
            let summary: String
            if currentDirection == .zipToPatch {
                if PatchPackageLimits.exceedsExpandedLimit(size) {
                    summary = activeLanguage.text("converter.summary.zip_too_large")
                } else {
                    do {
                        let zipInfo = try PatchZipConverter.shared.inspectZipMetadata(at: url, password: currentSourcePassword)
                        if let name = zipInfo.suggestedName, !name.isEmpty {
                            suggestedStem = Self.sanitizedOutputStem(from: name, fallback: initialStem)
                        }
                        if zipInfo.entryCount == 0 {
                            summary = activeLanguage.text("converter.summary.zip_empty")
                        } else if zipInfo.hasUnsupportedCompression {
                            summary = activeLanguage.text("converter.summary.zip_unsupported_compression")
                        } else if !zipInfo.isValidPatchOrModArchive {
                            summary = activeLanguage.text("converter.summary.zip_unrecognized_structure")
                        } else if zipInfo.isPasswordProtected && currentSourcePassword == nil {
                            detectedProtected = true
                            summary = activeLanguage.text("converter.summary.zip_protected", zipInfo.entryCount)
                        } else if zipInfo.isPasswordProtected && !zipInfo.isUnlocked {
                            detectedProtected = true
                            summary = activeLanguage.text("converter.summary.zip_wrong_unlock_preview")
                        } else {
                            detectedProtected = zipInfo.isPasswordProtected
                            detectedValid = true
                            let detectedTarget = zipInfo.detectedTarget ?? "com.garena.game.kgvn"
                            summary = activeLanguage.text("converter.summary.zip_valid", zipInfo.entryCount, detectedTarget)
                        }
                    } catch {
                        summary = activeLanguage.text("converter.summary.zip_invalid", error.localizedDescription)
                    }
                }
            } else {
                if PatchPackageLimits.exceedsExpandedLimit(size) {
                    summary = activeLanguage.text("converter.summary.3105_too_large")
                } else if let pkgSummary = try? await PatchZipConverter.shared.inspect(patchURL: url) {
                    detectedProtected = pkgSummary.isPasswordProtected
                    if pkgSummary.isPasswordProtected && currentSourcePassword == nil {
                        summary = activeLanguage.text("converter.summary.3105_protected", pkgSummary.schemaVersion)
                    } else if let project = PatchZipConverter.shared.inspectProjectMetadataLocally(
                        patchURL: url,
                        password: currentSourcePassword
                    ) {
                        detectedValid = true
                        if !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            suggestedStem = Self.sanitizedOutputStem(from: project.name, fallback: initialStem)
                        }
                        summary = activeLanguage.text(
                            "converter.summary.3105_project",
                            project.name,
                            project.author,
                            project.rules.count,
                            project.bundleIdentifiers.joined(separator: ", ")
                        )
                    } else if pkgSummary.isPasswordProtected {
                        summary = activeLanguage.text("converter.summary.3105_protected_retry", pkgSummary.schemaVersion)
                    } else {
                        detectedValid = true
                        summary = activeLanguage.text("converter.summary.3105_valid", pkgSummary.schemaVersion)
                    }
                } else {
                    summary = activeLanguage.text("converter.summary.3105_invalid_header")
                }
            }

            await MainActor.run {
                guard self.inspectGeneration == inspectionToken,
                      self.selectedSourceURL == url,
                      self.direction == currentDirection else { return }
                self.sourceFileSizeText = sizeStr
                self.sourceMetadataSummary = summary
                self.isSourceValid = detectedValid
                self.isSourcePasswordProtected = detectedProtected
                if let suggested = suggestedStem, !suggested.isEmpty,
                   (!keepCustomInputs || self.outputFileNameText == initialStem) {
                    self.outputFileNameText = suggested
                }
            }
        }
    }

    private func performConversion() {
        guard let source = selectedSourceURL else { return }
        let currentDirection = direction
        let trimmedSourcePwd = sourcePasswordText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePassword = trimmedSourcePwd.isEmpty ? nil : trimmedSourcePwd
        guard isSourceValid || (isSourcePasswordProtected && sourcePassword != nil) else {
            conversionError = language.text("converter.error.invalid_source_file")
            return
        }
        if isSourcePasswordProtected && sourcePassword == nil {
            conversionError = language.text(
                currentDirection == .patchToZip
                    ? "converter.error.source_password_required_3105"
                    : "converter.error.source_password_required_zip"
            )
            return
        }

        let trimmedOutputPwd = outputPasswordText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputPassword = trimmedOutputPwd.isEmpty ? nil : trimmedOutputPwd
        let fallbackStem = Self.sanitizedOutputStem(
            from: source.deletingPathExtension().lastPathComponent,
            fallback: "ConvertedPatch"
        )
        let outputStem = Self.sanitizedOutputStem(from: outputFileNameText, fallback: fallbackStem)

        isConverting = true
        conversionError = nil
        convertedFileURL = nil

        history.removeAll { !FileManager.default.fileExists(atPath: $0.targetPath) }
        let retainedPaths = Set(history.map { URL(fileURLWithPath: $0.targetPath).standardizedFileURL.path })

        Task.detached(priority: .userInitiated) {
            let converter = PatchZipConverter()
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ConvertedPatches", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Prune outputs that no history entry points at anymore.
            if let existingItems = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                for item in existingItems where !retainedPaths.contains(item.standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: item)
                }
            }

            do {
                let outURL = AovModMergerEngine.uniqueOutputURL(
                    in: tempDir,
                    preferredName: "\(outputStem).\(currentDirection.outputExtension)"
                )
                if currentDirection == .zipToPatch {
                    try await converter.convertZipToPatch(
                        zipURL: source,
                        destinationPatchURL: outURL,
                        password: outputPassword,
                        sourcePassword: sourcePassword,
                        customProjectName: outputStem
                    )
                } else {
                    try await converter.convertPatchToZip(
                        patchURL: source,
                        destinationZipURL: outURL,
                        password: sourcePassword,
                        outputPassword: outputPassword
                    )
                }
                let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
                let outSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let sizeStr = ByteCountFormatter.string(fromByteCount: outSize, countStyle: .file)

                await MainActor.run {
                    self.convertedFileURL = outURL
                    self.convertedFileSizeText = sizeStr
                    self.isConverting = false
                    self.history.insert(ConversionHistoryItem(
                        id: UUID(),
                        sourceName: source.lastPathComponent,
                        targetName: outURL.lastPathComponent,
                        targetPath: outURL.path,
                        timestamp: Date(),
                        fileSizeText: sizeStr
                    ), at: 0)
                    if self.history.count > Self.maximumRetainedConversions {
                        let overflow = self.history.suffix(from: Self.maximumRetainedConversions)
                        for old in overflow {
                            try? FileManager.default.removeItem(atPath: old.targetPath)
                        }
                        self.history.removeLast(self.history.count - Self.maximumRetainedConversions)
                    }
                    self.savePersistedHistory()
                }
            } catch {
                await MainActor.run {
                    self.conversionError = error.localizedDescription
                    self.isConverting = false
                }
            }
        }
    }

    private func loadPersistedHistory() {
        let fm = FileManager.default
        if let data = UserDefaults.standard.data(forKey: Self.historyStorageKey),
           let decoded = try? JSONDecoder().decode([ConversionHistoryItem].self, from: data) {
            let valid = Array(decoded.filter { fm.fileExists(atPath: $0.targetPath) }.prefix(Self.maximumRetainedConversions))
            history = valid
            if valid != decoded {
                savePersistedHistory()
            }
        } else {
            history.removeAll { !fm.fileExists(atPath: $0.targetPath) }
        }
    }

    private func savePersistedHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyStorageKey)
        }
    }
}
