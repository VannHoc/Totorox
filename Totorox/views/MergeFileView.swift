import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CryptoKit

struct MergeHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceSummary: String
    let targetName: String
    let targetPath: String
    let resourceVersion: String
    let totalFilesWritten: Int
    let smartMergedConflicts: Int
    let fileSizeText: String
    let timestamp: Date
}

private struct MergeShareURLItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct MergeFileView: View {
    @Environment(\.appLanguage) private var language
    @State private var selectedMods: [AovModSummary] = []
    @State private var modContentHashes: [URL: String] = [:]

    @State private var showMultiZipPicker: Bool = false
    @State private var isMerging: Bool = false
    @State private var progressStatus: String = ""
    @State private var progressValue: Double = 0.0
    @State private var mergeResult: AovMergeResult? = nil
    @State private var activeShareItem: MergeShareURLItem? = nil
    @State private var showLogsDetail: Bool = false
    @State private var alertMessage: String? = nil
    @State private var mergeHistory: [MergeHistoryItem] = []

    private static let maximumRetainedMerges = 10
    private static let historyStorageKey = "totorox.merge.history.v1"

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // MARK: - Card 1: Banner Giới thiệu & Bản quyền tính năng
                    headerBannerCard

                    // MARK: - Card 2: Danh sách gói Mod (.zip) cần gộp
                    modSelectionListCard

                    // MARK: - Card 3: Nút thực thi & Tiến trình
                    mergeActionCard

                    // MARK: - Card 4: Kết quả sau khi gộp
                    if let result = mergeResult {
                        mergeResultCard(result)
                    }

                    // MARK: - Lịch sử gộp file mod
                    if !mergeHistory.isEmpty {
                        mergeHistorySection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(width: proxy.size.width > 0 ? proxy.size.width : nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TotoroxTheme.pageBackground)
        .onAppear {
            loadPersistedHistory()
        }
        .sheet(isPresented: $showMultiZipPicker) {
            MultiZipDocumentPicker { urls in
                handlePickedModURLs(urls)
            }
        }
        .sheet(item: $activeShareItem) { item in
            ActivityShareSheet(items: [item.url])
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

    // MARK: - Card 1: Header Banner

    private var headerBannerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    TotoroxTheme.mintAccent.opacity(0.20),
                                    TotoroxTheme.mintAccent.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(TotoroxTheme.mintAccent.opacity(0.22), lineWidth: 0.75)
                        )

                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("merge.header.title"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))

                        Text(language.text("merge.header.credit"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)
                    }
                    .foregroundStyle(TotoroxTheme.mintAccent)
                }

                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(TotoroxTheme.dividerColor)
                .frame(height: 1)

            Text(language.text("merge.header.subtitle"))
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(TotoroxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(".ZIP")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(TotoroxTheme.mintAccent)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(TotoroxTheme.mintAccent.opacity(0.12))
                .clipShape(Capsule())

                Spacer(minLength: 6)

                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                    Text(language.text("merge.header.subcredit"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(TotoroxTheme.searchBackground.opacity(0.9))
                .clipShape(Capsule())
            }
        }
        .modifier(TotoroxCardModifier(cornerRadius: 16, padding: 16))
    }

    // MARK: - Card 2: Danh sách gói Mod (.zip)

    private var modSelectionListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)

                Text(language.text("merge.list.title"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)

                Spacer()

                Text(language.text("merge.list.file_count", selectedMods.count))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(TotoroxTheme.mintAccent.opacity(0.12))
                    .clipShape(Capsule())
            }

            if selectedMods.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.5))
                    Text(language.text("merge.list.empty_hint"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
                .background(TotoroxTheme.searchBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(selectedMods.enumerated()), id: \.element.id) { index, mod in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(TotoroxTheme.mintAccent)
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mod.fileName)
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundStyle(TotoroxTheme.textPrimary)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(mod.heroBadgeText)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.mintAccent)

                                    if let ver = mod.resourceVersion {
                                        Text("• v\(ver)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(TotoroxTheme.textSecondary)
                                    }

                                    Text("• \(ByteCountFormatter.string(fromByteCount: mod.fileSize, countStyle: .file))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                            }

                            Spacer()

                            Button {
                                removeMod(mod)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
                            }
                            .disabled(isMerging)
                        }
                        .padding(10)
                        .background(TotoroxTheme.searchBackground.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    showMultiZipPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text(language.text(selectedMods.isEmpty ? "merge.button.add_first" : "merge.button.add_more"))
                    }
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(TotoroxTheme.mintAccent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isMerging)

                if !selectedMods.isEmpty {
                    Button {
                        clearAllMods()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text(language.text("merge.button.clear_all"))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isMerging)
                }
            }
        }
        .modifier(TotoroxCardModifier(cornerRadius: 16, padding: 16))
    }

    // MARK: - Card 3: Nút Gộp & Tiến trình

    private var mergeActionCard: some View {
        VStack(spacing: 12) {
            if isMerging {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .tint(TotoroxTheme.mintAccent)
                            .scaleEffect(0.85)
                        Text(progressStatus)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(TotoroxTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(progressValue * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                    }

                    ProgressView(value: progressValue, total: 1.0)
                        .tint(TotoroxTheme.mintAccent)
                }
                .padding(12)
                .background(TotoroxTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            let canMerge = selectedMods.count >= 2 && !isMerging
            Button {
                executeSmartMerge()
            } label: {
                HStack(spacing: 8) {
                    if isMerging {
                        ProgressView()
                            .tint(.white)
                        Text(language.text("merge.button.merging"))
                            .font(.system(size: 15, weight: .bold))
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 15, weight: .bold))
                        Text(language.text("merge.button.start", selectedMods.count))
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle((canMerge || isMerging) ? .white : TotoroxTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background((canMerge || isMerging) ? TotoroxTheme.mintAccent : Color(red: 0.91, green: 0.92, blue: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: canMerge ? TotoroxTheme.mintAccent.opacity(0.3) : Color.clear, radius: 8, y: 4)
            }
            .disabled(!canMerge)
        }
    }

    // MARK: - Card 4: Kết quả Gộp File

    private func mergeResultCard(_ result: AovMergeResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(TotoroxTheme.mintAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("merge.result.success"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)

                    Text(result.outputZipURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                }

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: result.outputFileSize, countStyle: .file))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(TotoroxTheme.searchBackground)
                    .clipShape(Capsule())
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                resultInfoRow(label: language.text("merge.result.mapped_path"), value: "Resources/\(result.resourceVersion)/...")
                resultInfoRow(label: language.text("merge.result.total_files"), value: language.text("merge.list.file_count", result.totalFilesWritten))
                resultInfoRow(label: language.text("merge.result.merged_conflicts"), value: language.text("merge.result.merged_conflicts_value", result.smartMergedConflicts))
            }

            if !result.logs.isEmpty {
                DisclosureGroup(
                    isExpanded: $showLogsDetail,
                    content: {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(result.logs.enumerated()), id: \.offset) { _, line in
                                Text("• \(line)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(TotoroxTheme.textSecondary)
                            }
                        }
                        .padding(.top, 6)
                    },
                    label: {
                        Text(language.text("merge.result.logs_toggle", result.logs.count))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TotoroxTheme.mintAccent)
                    }
                )
            }

            VStack(spacing: 10) {
                // Nút chuyển thẳng sang tab Đè file
                Button {
                    AppNavigationCoordinator.shared.navigateToOverwrite(
                        patchURL: result.outputZipURL,
                        bundleID: "com.garena.game.kgvn"
                    )
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                        Text(language.text("merge.result.send_to_overwrite"))
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(TotoroxTheme.mintAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Nút Lưu / Chia sẻ file .zip
                Button {
                    activeShareItem = MergeShareURLItem(url: result.outputZipURL)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text(language.text("merge.result.share_output"))
                    }
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(TotoroxTheme.mintAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(TotoroxTheme.mintAccent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .modifier(TotoroxCardModifier(cornerRadius: 16, padding: 16))
    }

    private var mergeHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language.text("merge.history.title"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)

                Spacer()

                Button(language.text("merge.history.clear")) {
                    clearMergeHistory()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.85))
                .buttonStyle(.plain)
            }

            VStack(spacing: 8) {
                ForEach(mergeHistory) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.targetName)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(TotoroxTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text(item.sourceSummary)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Text(
                                language.text(
                                    "merge.history.meta",
                                    item.fileSizeText,
                                    item.totalFilesWritten,
                                    item.smartMergedConflicts
                                )
                            )
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 8) {
                            Button {
                                let target = URL(fileURLWithPath: item.targetPath)
                                guard FileManager.default.fileExists(atPath: target.path) else {
                                    loadPersistedHistory()
                                    return
                                }
                                AppNavigationCoordinator.shared.navigateToOverwrite(
                                    patchURL: target,
                                    bundleID: "com.garena.game.kgvn"
                                )
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(language.text("merge.history.send_action"))
                                        .font(.system(size: 11.5, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(TotoroxTheme.mintAccent)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            Button {
                                let target = URL(fileURLWithPath: item.targetPath)
                                if FileManager.default.fileExists(atPath: target.path) {
                                    activeShareItem = MergeShareURLItem(url: target)
                                } else {
                                    loadPersistedHistory()
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(TotoroxTheme.mintAccent)
                                    .padding(7)
                                    .background(TotoroxTheme.mintAccent.opacity(0.12))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(language.text("merge.history.share_action"))
                        }
                    }
                    .modifier(TotoroxCardModifier(cornerRadius: 14, padding: 12))
                }
            }
        }
    }

    private func resultInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(TotoroxTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(TotoroxTheme.textPrimary)
        }
    }

    // MARK: - Logic Actions

    private static func sha256Hex(forFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            var shouldBreak = false
            autoreleasepool {
                if let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    shouldBreak = true
                }
            }
            if shouldBreak { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func cleanupStagedDirectoryIfNeeded(for stagedURL: URL) {
        let parentDir = stagedURL.deletingLastPathComponent()
        let grandParent = parentDir.deletingLastPathComponent()
        guard grandParent.lastPathComponent == "AovModImports" else { return }
        try? FileManager.default.removeItem(at: parentDir)
    }

    private func removeMod(_ mod: AovModSummary) {
        selectedMods.removeAll { $0.id == mod.id }
        modContentHashes.removeValue(forKey: mod.url)
        Self.cleanupStagedDirectoryIfNeeded(for: mod.url)
        mergeResult = nil
    }

    private func clearAllMods() {
        let removed = selectedMods
        selectedMods.removeAll()
        modContentHashes.removeAll()
        mergeResult = nil
        for mod in removed {
            Self.cleanupStagedDirectoryIfNeeded(for: mod.url)
        }
    }

    private static func isZipArchiveFile(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "3105" {
            return false
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    private func handlePickedModURLs(_ urls: [URL]) {
        let activeLanguage = language
        Task.detached(priority: .userInitiated) {
            struct PickedItem: Sendable {
                let summary: AovModSummary
                let sha256: String?
            }

            var newlyInspected: [PickedItem] = []
            var rejectedDetails: [String] = []
            for url in urls {
                if url.pathExtension.lowercased() == "3105" {
                    rejectedDetails.append("• \(activeLanguage.text("merge.error.only_zip_entry", url.lastPathComponent))")
                    continue
                }

                // Copy picked file into isolated UUID workspace so duplicate filenames don't collide and security scope doesn't expire
                let fm = FileManager.default
                let hasSecurity = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurity { url.stopAccessingSecurityScopedResource() }
                }
                let importDir = fm.temporaryDirectory
                    .appendingPathComponent("AovModImports", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? fm.createDirectory(at: importDir, withIntermediateDirectories: true)
                let localCopy = importDir.appendingPathComponent(url.lastPathComponent)
                try? fm.removeItem(at: localCopy)

                if (try? fm.copyItem(at: url, to: localCopy)) != nil {
                    guard Self.isZipArchiveFile(at: localCopy) else {
                        rejectedDetails.append("• \(activeLanguage.text("merge.error.not_valid_zip_entry", url.lastPathComponent))")
                        try? fm.removeItem(at: importDir)
                        continue
                    }
                    do {
                        let summary = try AovModMergerEngine.shared.inspectModArchive(at: localCopy)
                        let hash = Self.sha256Hex(forFileAt: localCopy)
                        newlyInspected.append(PickedItem(summary: summary, sha256: hash))
                    } catch {
                        rejectedDetails.append("• \(error.localizedDescription)")
                        try? fm.removeItem(at: importDir)
                    }
                } else {
                    rejectedDetails.append("• \(activeLanguage.text("merge.error.open_source_mod", url.lastPathComponent))")
                    try? fm.removeItem(at: importDir)
                }
            }

            await MainActor.run {
                var addedHashes = Set(self.modContentHashes.values)
                for item in newlyInspected {
                    let isDuplicate: Bool
                    if let h = item.sha256 {
                        isDuplicate = addedHashes.contains(h)
                    } else {
                        isDuplicate = self.selectedMods.contains(where: {
                            $0.fileName == item.summary.fileName && $0.fileSize == item.summary.fileSize
                        })
                    }

                    if isDuplicate {
                        Self.cleanupStagedDirectoryIfNeeded(for: item.summary.url)
                    } else {
                        self.selectedMods.append(item.summary)
                        if let h = item.sha256 {
                            self.modContentHashes[item.summary.url] = h
                            addedHashes.insert(h)
                        }
                    }
                }
                if !rejectedDetails.isEmpty {
                    self.alertMessage = self.language.text(
                        "merge.alert.invalid_mods_skipped",
                        rejectedDetails.count,
                        rejectedDetails.joined(separator: "\n")
                    )
                }
            }
        }
    }

    private func executeSmartMerge() {
        let urls = selectedMods.map(\.url)
        guard urls.count >= 2 else { return }

        let activeLanguage = language
        loadPersistedHistory()
        isMerging = true
        mergeResult = nil
        progressStatus = activeLanguage.text("merge.progress.initializing")
        progressValue = 0.02

        Task {
            do {
                let res = try await AovModMergerEngine.shared.mergeModArchives(inputURLs: urls) { status, pct in
                    Task { @MainActor in
                        self.progressStatus = status
                        self.progressValue = pct
                    }
                }
                await MainActor.run {
                    self.isMerging = false
                    self.mergeResult = res
                    let modNames = res.mergedMods.map {
                        URL(fileURLWithPath: $0.fileName).deletingPathExtension().lastPathComponent
                    }
                    let sourceSummary: String
                    if modNames.count <= 2 {
                        sourceSummary = modNames.joined(separator: " + ")
                    } else {
                        let firstTwo = modNames.prefix(2).joined(separator: ", ")
                        sourceSummary = activeLanguage.text("merge.history.sources_more", firstTwo, modNames.count - 2)
                    }
                    let sizeStr = ByteCountFormatter.string(fromByteCount: res.outputFileSize, countStyle: .file)
                    let item = MergeHistoryItem(
                        id: UUID(),
                        sourceSummary: sourceSummary,
                        targetName: res.outputZipURL.lastPathComponent,
                        targetPath: res.outputZipURL.path,
                        resourceVersion: res.resourceVersion,
                        totalFilesWritten: res.totalFilesWritten,
                        smartMergedConflicts: res.smartMergedConflicts,
                        fileSizeText: sizeStr,
                        timestamp: Date()
                    )
                    self.mergeHistory.insert(item, at: 0)
                    if self.mergeHistory.count > Self.maximumRetainedMerges {
                        let activeResultPath = res.outputZipURL.standardizedFileURL.path
                        let overflow = self.mergeHistory.suffix(from: Self.maximumRetainedMerges)
                        for old in overflow {
                            let oldPath = URL(fileURLWithPath: old.targetPath).standardizedFileURL.path
                            if oldPath != activeResultPath {
                                try? FileManager.default.removeItem(atPath: old.targetPath)
                            }
                        }
                        self.mergeHistory.removeLast(self.mergeHistory.count - Self.maximumRetainedMerges)
                    }
                    self.savePersistedHistory()
                    self.pruneOrphanedMergedFiles()
                }
            } catch {
                await MainActor.run {
                    self.isMerging = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadPersistedHistory() {
        let fm = FileManager.default
        if let data = UserDefaults.standard.data(forKey: Self.historyStorageKey),
           let decoded = try? JSONDecoder().decode([MergeHistoryItem].self, from: data) {
            let valid = Array(decoded.filter { fm.fileExists(atPath: $0.targetPath) }.prefix(Self.maximumRetainedMerges))
            mergeHistory = valid
            if valid != decoded {
                savePersistedHistory()
            }
        } else {
            mergeHistory.removeAll { !fm.fileExists(atPath: $0.targetPath) }
        }
        pruneOrphanedMergedFiles()
    }

    private func savePersistedHistory() {
        if let data = try? JSONEncoder().encode(mergeHistory) {
            UserDefaults.standard.set(data, forKey: Self.historyStorageKey)
        }
    }

    private func clearMergeHistory() {
        let fm = FileManager.default
        let activeResultPath = mergeResult?.outputZipURL.standardizedFileURL.path
        for item in mergeHistory {
            let itemPath = URL(fileURLWithPath: item.targetPath).standardizedFileURL.path
            if itemPath != activeResultPath {
                try? fm.removeItem(atPath: item.targetPath)
            }
        }
        mergeHistory.removeAll()
        savePersistedHistory()
        pruneOrphanedMergedFiles()
    }

    private func pruneOrphanedMergedFiles() {
        let fm = FileManager.default
        let mergedDir = fm.temporaryDirectory.appendingPathComponent("TotoroxMergedMods", isDirectory: true)
        var retained = Set(mergeHistory.map { URL(fileURLWithPath: $0.targetPath).standardizedFileURL.path })
        if let current = mergeResult?.outputZipURL {
            retained.insert(current.standardizedFileURL.path)
        }
        guard let entries = try? fm.contentsOfDirectory(at: mergedDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !retained.contains(entry.standardizedFileURL.path) {
            try? fm.removeItem(at: entry)
        }
    }
}

// MARK: - Multi-file ZIP Document Picker

private struct MultiZipDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.zip, UTType.archive],
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

// MARK: - Share Sheet

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
