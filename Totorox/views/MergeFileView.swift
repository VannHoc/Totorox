import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MergeFileView: View {
    @State private var selectedMods: [AovModSummary] = []
    @State private var showMultiZipPicker: Bool = false
    @State private var isMerging: Bool = false
    @State private var progressStatus: String = ""
    @State private var progressValue: Double = 0.0
    @State private var mergeResult: AovMergeResult? = nil
    @State private var showShareSheet: Bool = false
    @State private var showLogsDetail: Bool = false
    @State private var alertMessage: String? = nil

    var body: some View {
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(TotoroxTheme.pageBackground)
        .sheet(isPresented: $showMultiZipPicker) {
            MultiZipDocumentPicker { urls in
                handlePickedModURLs(urls)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let result = mergeResult {
                ActivityShareSheet(items: [result.outputZipURL])
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
    }

    // MARK: - Card 1: Header Banner

    private var headerBannerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(TotoroxTheme.mintAccent.opacity(0.15))
                        .frame(width: 46, height: 46)

                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(TotoroxTheme.mintAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Gộp File Mod Liên Quân")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)

                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                        Text("Tính năng độc quyền phát triển bởi VannHoc")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(TotoroxTheme.mintAccent)
                }

                Spacer()
            }

            Divider()

            Text("Hợp nhất thông minh từ 2 gói mod (.zip) Liên Quân Mobile trở lên thành 1 tệp .zip duy nhất theo ánh xạ chuẩn Resources/..., giữ trọn vẹn hiệu ứng biến về, tế đàn, âm thanh và thông báo hạ của tất cả các tướng.")
                .font(.system(size: 12.5))
                .foregroundStyle(TotoroxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

                Text("Danh sách tệp Mod (.zip)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TotoroxTheme.textPrimary)

                Spacer()

                Text("\(selectedMods.count) tệp")
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
                    Text("Chọn từ 2 tệp .zip mod tướng khác nhau trở lên")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
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
                                selectedMods.removeAll { $0.id == mod.id }
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
                        Text(selectedMods.isEmpty ? "Thêm tệp Mod (.zip)" : "Thêm tệp .zip khác")
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
                        selectedMods.removeAll()
                        mergeResult = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Xóa hết")
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
                        Text("Đang giải mã & hợp nhất nhị phân...")
                            .font(.system(size: 15, weight: .bold))
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 15, weight: .bold))
                        Text("Bắt đầu Gộp File Mod (\(selectedMods.count) tệp)")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(canMerge ? TotoroxTheme.mintAccent : Color.gray.opacity(0.35))
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
                    Text("Đã gộp thành công!")
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
                resultInfoRow(label: "Đường dẫn ánh xạ trong .zip:", value: "Resources/\(result.resourceVersion)/...")
                resultInfoRow(label: "Tổng số tệp đã đóng gói:", value: "\(result.totalFilesWritten) tệp")
                resultInfoRow(label: "Xung đột nhị phân đã gộp:", value: "\(result.smartMergedConflicts) tệp (XML/Databin/IFix/UnityFS)")
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
                        Text("Xem chi tiết quá trình hợp nhất (\(result.logs.count) bước)")
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
                        Text("Đưa sang tab Đè file (Liên Quân)")
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
                    showShareSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Lưu / Chia sẻ tệp .zip")
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

    private func handlePickedModURLs(_ urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            var newlyInspected: [AovModSummary] = []
            for url in urls {
                // Copy picked file into temporary workspace so security scope doesn't expire
                let fm = FileManager.default
                let hasSecurity = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurity { url.stopAccessingSecurityScopedResource() }
                }
                let importDir = fm.temporaryDirectory.appendingPathComponent("AovModImports", isDirectory: true)
                try? fm.createDirectory(at: importDir, withIntermediateDirectories: true)
                let localCopy = importDir.appendingPathComponent(url.lastPathComponent)
                try? fm.removeItem(at: localCopy)
                if (try? fm.copyItem(at: url, to: localCopy)) != nil {
                    if let summary = try? AovModMergerEngine.shared.inspectModArchive(at: localCopy) {
                        newlyInspected.append(summary)
                    } else {
                        let sz = Int64((try? localCopy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        newlyInspected.append(AovModSummary(
                            url: localCopy,
                            fileName: url.lastPathComponent,
                            fileSize: sz,
                            heroID: nil,
                            skinID: nil,
                            resourceVersion: nil
                        ))
                    }
                }
            }

            await MainActor.run {
                for item in newlyInspected {
                    if !self.selectedMods.contains(where: { $0.fileName == item.fileName && $0.fileSize == item.fileSize }) {
                        self.selectedMods.append(item)
                    }
                }
            }
        }
    }

    private func executeSmartMerge() {
        let urls = selectedMods.map(\.url)
        guard urls.count >= 2 else { return }

        isMerging = true
        mergeResult = nil
        progressStatus = "Đang khởi tạo tiến trình gộp..."
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
                }
            } catch {
                await MainActor.run {
                    self.isMerging = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Multi-file ZIP Document Picker

private struct MultiZipDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.zip, UTType.archive, UTType.data],
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
