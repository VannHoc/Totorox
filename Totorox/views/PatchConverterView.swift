import SwiftUI
import UniformTypeIdentifiers

enum ConverterDirection: String, CaseIterable, Identifiable {
    case zipToPatch = "ZIP ➔ .3105"
    case patchToZip = ".3105 ➔ ZIP"

    var id: String { rawValue }
}

struct ConversionHistoryItem: Identifiable, Codable {
    let id: UUID
    let sourceName: String
    let targetName: String
    let targetPath: String
    let timestamp: Date
    let fileSizeText: String
}

struct PatchConverterView: View {
    @State private var direction: ConverterDirection = .zipToPatch
    @State private var selectedSourceURL: URL? = nil
    @State private var sourceFileSizeText: String = ""
    @State private var sourceMetadataSummary: String? = nil
    @State private var isSourcePasswordProtected: Bool = false
    @State private var passwordText: String = ""
    @State private var showPassword: Bool = false
    
    // Processing state
    @State private var isConverting: Bool = false
    @State private var conversionError: String? = nil
    @State private var convertedFileURL: URL? = nil
    @State private var convertedFileSizeText: String = ""
    
    // UI sheets
    @State private var showFilePicker: Bool = false
    @State private var showShareSheet: Bool = false
    
    // History
    @State private var history: [ConversionHistoryItem] = []

    /// Converted outputs live in the temp folder. Keep only a small window so the folder cannot
    /// grow without bound while the history entries that reference them stay usable.
    private static let maximumRetainedConversions = 10

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                // Header description
                VStack(spacing: 4) {
                    Text("Bộ Chuyển Đổi Hai Chiều")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)

                    Text("Giải mã .3105 xuất sang .zip hoặc đóng gói .zip thành .3105")
                        .font(.system(size: 13))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)

                // Direction Pill Switcher
                HStack(spacing: 8) {
                    ForEach(ConverterDirection.allCases) { dir in
                        let isSelected = (direction == dir)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                direction = dir
                                selectedSourceURL = nil
                                sourceMetadataSummary = nil
                                isSourcePasswordProtected = false
                                convertedFileURL = nil
                                conversionError = nil
                            }
                        } label: {
                            Text(dir.rawValue)
                                .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .white : TotoroxTheme.textSecondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(isSelected ? TotoroxTheme.mintAccent : TotoroxTheme.searchBackground)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                // Dropzone / File Picker Card
                VStack(spacing: 12) {
                    if let source = selectedSourceURL {
                        // Selected File Info Card
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(TotoroxTheme.mintAccent.opacity(0.12))
                                    .frame(width: 48, height: 48)
                                Image(systemName: direction == .zipToPatch ? "doc.zipper" : "archivebox.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.lastPathComponent)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(TotoroxTheme.textPrimary)
                                    .lineLimit(1)

                                HStack(spacing: 8) {
                                    Text(sourceFileSizeText)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                    
                                    TotoroxBadge(
                                        title: direction == .zipToPatch ? "ZIP Source" : ".3105 Source",
                                        isAccent: true
                                    )
                                }
                            }

                            Spacer()

                            Button("Đổi tệp") {
                                showFilePicker = true
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                        }

                        if let summary = sourceMetadataSummary {
                            Divider()
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                Text(summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                                Spacer()
                            }
                        }
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

                                Text(direction == .zipToPatch ? "Nhấn để chọn tệp .zip nguồn" : "Nhấn để chọn tệp .3105 nguồn")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.textPrimary)

                                Text("Hỗ trợ bảo toàn 100% metadata, manifest và rules payload")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(TotoroxTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(TotoroxTheme.mintAccent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .totoroxCard()
                .padding(.horizontal, 16)

                // Optional Password Field
                let needsRequiredPassword = (direction == .patchToZip && isSourcePasswordProtected && passwordText.isEmpty)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: isSourcePasswordProtected ? "lock.shield.fill" : "lock.fill")
                            .foregroundStyle(needsRequiredPassword ? Color.orange : TotoroxTheme.textSecondary)

                        Group {
                            if showPassword {
                                TextField(
                                    isSourcePasswordProtected ? "Nhập mật khẩu bắt buộc của gói .3105" : "Mật khẩu gói (nếu có mã hóa)",
                                    text: $passwordText
                                )
                            } else {
                                SecureField(
                                    isSourcePasswordProtected ? "Nhập mật khẩu bắt buộc của gói .3105" : "Mật khẩu gói (nếu có mã hóa)",
                                    text: $passwordText
                                )
                            }
                        }
                        .font(.system(size: 14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                        if isSourcePasswordProtected && passwordText.isEmpty {
                            Text("Bắt buộc")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.14))
                                .clipShape(Capsule())
                        }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
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
                .padding(.horizontal, 16)

                // Error Banner
                if let err = conversionError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.red)
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red)
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                // Convert Button
                TotoroxPrimaryButton(
                    title: "Bắt đầu Chuyển đổi",
                    icon: "arrow.triangle.2.circlepath",
                    isLoading: isConverting,
                    isEnabled: selectedSourceURL != nil && !isConverting
                ) {
                    performConversion()
                }
                .padding(.horizontal, 16)

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
                                Text("Chuyển đổi thành công!")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(TotoroxTheme.textPrimary)

                                Text("\(converted.lastPathComponent) (\(convertedFileSizeText))")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                            }
                            Spacer()
                        }

                        Button {
                            showShareSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Lưu / Chia sẻ Tệp Đích")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(TotoroxTheme.mintAccent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .totoroxCard()
                    .padding(.horizontal, 16)
                }

                // Recent History
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Lịch sử chuyển đổi")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(history) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(item.sourceName) ➔ \(item.targetName)")
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                        Text(item.fileSizeText)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(TotoroxTheme.textSecondary)
                                    }
                                    Spacer()
                                    Button {
                                        convertedFileURL = URL(fileURLWithPath: item.targetPath)
                                        showShareSheet = true
                                    } label: {
                                        Image(systemName: "square.and.arrow.up")
                                            .foregroundStyle(TotoroxTheme.mintAccent)
                                    }
                                }
                                .totoroxCard(padding: 12)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 80)
        }
        .background(TotoroxTheme.pageBackground)
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerWrapper { picked in
                inspectSourceFile(picked)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let target = convertedFileURL {
                ActivityViewControllerWrapper(activityItems: [target])
            }
        }
    }

    private func inspectSourceFile(_ url: URL) {
        selectedSourceURL = url
        convertedFileURL = nil
        conversionError = nil
        isSourcePasswordProtected = false
        
        let currentDirection = direction
        let currentPassword = passwordText.isEmpty ? nil : passwordText

        Task.detached(priority: .userInitiated) {
            // URL lấy từ DocumentPicker có thể là security-scoped: mở quyền trước khi đọc.
            let hasScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasScope { url.stopAccessingSecurityScopedResource() }
            }

            let fm = FileManager.default
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)

            var detectedProtected = false
            let summary: String
            if currentDirection == .zipToPatch {
                if PatchPackageLimits.exceedsExpandedLimit(size) {
                    summary = "Tệp ZIP vượt quá giới hạn 3.6 GB nên không thể xem trước."
                } else if let headers = try? PatchZipConverter.shared.inspectZipCentralDirectory(url) {
                    let detectedBundle = headers.lazy.compactMap { h -> String? in
                        let parts = h.path.split(separator: "/").map(String.init)
                        guard parts.count > 1 else { return nil }
                        for seg in parts.dropLast() where seg.contains(".") && !seg.lowercased().hasSuffix(".bytes") && !seg.lowercased().hasSuffix(".assetbundle") {
                            if seg.range(of: #"^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil {
                                return seg
                            }
                        }
                        return nil
                    }.first ?? "com.garena.game.kgvn"
                    summary = "Gói ZIP hợp lệ (\(headers.count) tệp) • Ánh xạ Bundle ID: \(detectedBundle)"
                } else {
                    summary = "Tệp ZIP tiêu chuẩn. Tự động ánh xạ theo Bundle ID ứng dụng."
                }
            } else {
                if PatchPackageLimits.exceedsExpandedLimit(size) {
                    summary = "Gói .3105 vượt quá giới hạn 3.6 GB nên không thể xem trước."
                } else if let pkgSummary = try? await PatchZipConverter.shared.inspect(patchURL: url) {
                    detectedProtected = pkgSummary.isPasswordProtected
                    if pkgSummary.isPasswordProtected && currentPassword == nil {
                        summary = "Gói .3105 (v\(pkgSummary.schemaVersion)) được bảo vệ bằng mật khẩu. Vui lòng nhập mật khẩu trước khi chuyển đổi."
                    } else if let data = try? Data(contentsOf: url),
                              let project = try? await PatchZipConverter.shared.decodeProject(
                                  patchData: data,
                                  password: currentPassword
                              ) {
                        summary = "Dự án: \(project.name) • Tác giả: \(project.author) • Quy tắc: \(project.rules.count) rules • Đích: \(project.bundleIdentifiers.joined(separator: ", "))"
                    } else if pkgSummary.isPasswordProtected {
                        summary = "Gói .3105 (v\(pkgSummary.schemaVersion)) có bảo vệ mật khẩu. Bấm Bắt đầu Chuyển đổi để kiểm tra mật khẩu và giải mã."
                    } else {
                        summary = "Gói .3105 hợp lệ (v\(pkgSummary.schemaVersion)). Sẵn sàng giải mã sang .zip."
                    }
                } else {
                    summary = "Không đọc được header gói .3105. Vui lòng kiểm tra định dạng tệp."
                }
            }

            await MainActor.run {
                self.sourceFileSizeText = sizeStr
                self.sourceMetadataSummary = summary
                self.isSourcePasswordProtected = detectedProtected
            }
        }
    }

    private func performConversion() {
        guard let source = selectedSourceURL else { return }
        let currentDirection = direction
        let password = passwordText.isEmpty ? nil : passwordText
        if currentDirection == .patchToZip && isSourcePasswordProtected && password == nil {
            conversionError = "Gói .3105 này được bảo vệ bằng mật khẩu. Vui lòng nhập đúng mật khẩu của tệp rồi thử lại."
            return
        }
        isConverting = true
        conversionError = nil
        convertedFileURL = nil

        // iOS can purge the temp folder at any time and this history is not persisted, so drop
        // entries whose output is already gone instead of letting share taps fail silently.
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

            let baseName = source.deletingPathExtension().lastPathComponent

            do {
                if currentDirection == .zipToPatch {
                    let outURL = tempDir.appendingPathComponent("\(baseName).3105")
                    try await converter.convertZipToPatch(
                        zipURL: source,
                        destinationPatchURL: outURL,
                        password: password
                    )
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
                            self.history.removeLast(self.history.count - Self.maximumRetainedConversions)
                        }
                    }
                } else {
                    let outURL = tempDir.appendingPathComponent("\(baseName).zip")
                    try await converter.convertPatchToZip(
                        patchURL: source,
                        destinationZipURL: outURL,
                        password: password
                    )
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
                            self.history.removeLast(self.history.count - Self.maximumRetainedConversions)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.conversionError = error.localizedDescription
                    self.isConverting = false
                }
            }
        }
    }
}
