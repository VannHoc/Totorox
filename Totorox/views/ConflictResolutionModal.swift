import SwiftUI

// MARK: - Windows-Style Conflict Resolution State & View

struct FileConflictInfo: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let destinationURL: URL
    let conflictKind: FileIOConflictKind
    let continuation: @Sendable (FileIOConflictResolution) -> Void
}

struct FileIOResultWrapper: Identifiable {
    let id = UUID()
    let result: FileIOResult
}

/// Thread-safe per-operation coordinator preventing any duplicate conflict popup once
/// "Ghi đè tất cả (Replace All)" or "Hủy (Cancel)" has been selected in the current session.
final class ConflictPromptCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldReplaceAllConflicts = false
    private var isCancelled = false

    func resolveConflict(
        source: URL,
        destination: URL,
        kind: FileIOConflictKind,
        presentModal: @escaping @MainActor (FileConflictInfo) -> Void,
        dismissModal: @escaping @MainActor () -> Void
    ) async -> FileIOConflictResolution {
        lock.lock()
        if isCancelled {
            lock.unlock()
            return .cancel
        }
        if shouldReplaceAllConflicts {
            lock.unlock()
            return .replace
        }
        lock.unlock()

        return await withCheckedContinuation { cont in
            Task { @MainActor in
                let info = FileConflictInfo(
                    sourceURL: source,
                    destinationURL: destination,
                    conflictKind: kind,
                    continuation: { choice in
                        self.lock.lock()
                        if choice == .replaceAll {
                            self.shouldReplaceAllConflicts = true
                        } else if choice == .cancel {
                            self.isCancelled = true
                        }
                        self.lock.unlock()
                        dismissModal()
                        cont.resume(returning: choice)
                    }
                )
                presentModal(info)
            }
        }
    }
}

struct WindowsConflictDialog: View {
    let conflict: FileConflictInfo

    private static let pastelRed = Color(red: 1.0, green: 107.0 / 255.0, blue: 107.0 / 255.0)
    private static let pastelRedBorder = Color(red: 224.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0)
    private static let mintColor = Color(red: 91.0 / 255.0, green: 185.0 / 255.0, blue: 168.0 / 255.0)

    private var dialogTitle: String {
        switch conflict.conflictKind {
        case .fileExists:
            return "Trùng lặp tệp"
        case .fileOverwritingFolder, .folderOverwritingFile:
            return "Xung đột tệp & thư mục"
        }
    }

    private var dialogSubtitle: String {
        switch conflict.conflictKind {
        case .fileExists:
            return "Tệp đích đã tồn tại tại đường dẫn này."
        case .fileOverwritingFolder:
            return "Nguồn là Tệp nhưng Đích là Thư mục cùng tên."
        case .folderOverwritingFile:
            return "Nguồn là Thư mục nhưng Đích là Tệp cùng tên."
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            // Compact Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Self.pastelRed.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Self.pastelRed)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(dialogTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)

                    Text(dialogSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            // Compact Path Summary (single-line middle truncation so paths never overflow)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Nguồn:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .frame(width: 48, alignment: .leading)
                    Text(conflict.sourceURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    Text("Đích:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .frame(width: 48, alignment: .leading)
                    Text(conflict.destinationURL.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(TotoroxTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(TotoroxTheme.searchBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Clean Compact Action Buttons
            VStack(spacing: 8) {
                // 1. Replace (Ghi đè) - Pastel Red
                Button {
                    conflict.continuation(.replace)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Ghi đè (Replace)")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Self.pastelRed)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                // 2. Replace All (Ghi đè tất cả) - Pastel Red with highlighted border & icon
                Button {
                    conflict.continuation(.replaceAll)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Ghi đè tất cả (Replace All)")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Self.pastelRed)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Self.pastelRedBorder, lineWidth: 1.8)
                    )
                    .shadow(color: Self.pastelRed.opacity(0.28), radius: 5, y: 2)
                }
                .buttonStyle(.plain)

                // 3. Skip (Bỏ qua) - Mint Accent
                Button {
                    conflict.continuation(.skip)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Bỏ qua (Skip)")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Self.mintColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                // 4. Cancel (Hủy) - Text only, gray, no background
                Button {
                    conflict.continuation(.cancel)
                } label: {
                    Text("Hủy (Cancel)")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: 340)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.88))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 8)
        .padding(.horizontal, 24)
        .presentationDetents([.fraction(0.55), .medium])
    }
}

// MARK: - Overwrite Outcome Report Sheet

struct OverwriteOutcomeView: View {
    let result: FileIOResult
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header Banner
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(result.failed.isEmpty ? TotoroxTheme.mintAccent.opacity(0.15) : Color.orange.opacity(0.15))
                                .frame(width: 50, height: 50)
                            Image(systemName: result.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(result.failed.isEmpty ? TotoroxTheme.mintAccent : Color.orange)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.isCancelled ? "Đã hủy thao tác" : (result.failed.isEmpty ? "Hoàn tất đè file thành công" : "Hoàn tất với một số lỗi"))
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)

                            Text("Thành công: \(result.succeeded.count) • Lỗi: \(result.failed.count) • Bỏ qua: \(result.skipped.count)")
                                .font(.system(size: 13))
                                .foregroundStyle(TotoroxTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .totoroxCard()

                    // Succeeded items
                    if !result.succeeded.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Đã hoàn tất thành công (\(result.succeeded.count))")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textPrimary)

                            ForEach(result.succeeded, id: \.self) { url in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(TotoroxTheme.mintAccent)
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 13, design: .monospaced))
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .totoroxCard()
                    }

                    // Failed items
                    if !result.failed.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Thất bại (\(result.failed.count))")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.red)

                            ForEach(result.failed, id: \.url) { record in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(Color.red)
                                        Text(record.url.lastPathComponent)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    }
                                    Text(record.reason)
                                        .font(.system(size: 12))
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .totoroxCard()
                    }

                    // Skipped items
                    if !result.skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Đã bỏ qua (\(result.skipped.count))")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(TotoroxTheme.textSecondary)

                            ForEach(result.skipped, id: \.self) { url in
                                HStack {
                                    Image(systemName: "arrowshape.turn.up.right.fill")
                                        .foregroundStyle(TotoroxTheme.textSecondary)
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 13, design: .monospaced))
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .totoroxCard()
                    }
                }
                .padding(16)
            }
            .background(TotoroxTheme.pageBackground)
            .navigationTitle("Kết quả thao tác")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong", action: onDismiss)
                        .fontWeight(.semibold)
                        .foregroundColor(TotoroxTheme.mintAccent)
                }
            }
        }
    }
}
