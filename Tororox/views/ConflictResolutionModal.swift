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

struct WindowsConflictDialog: View {
    let conflict: FileConflictInfo

    private var dialogTitle: String {
        switch conflict.conflictKind {
        case .fileExists:
            return "Trùng lặp tệp (File Collision)"
        case .fileOverwritingFolder, .folderOverwritingFile:
            return "Xung đột tệp & thư mục"
        }
    }

    private var dialogSubtitle: String {
        switch conflict.conflictKind {
        case .fileExists:
            return "Tệp '\(conflict.sourceURL.lastPathComponent)' đã tồn tại trong thư mục đích."
        case .fileOverwritingFolder:
            return "Nguồn là Tệp nhưng Đích là Thư mục cùng tên."
        case .folderOverwritingFile:
            return "Nguồn là Thư mục nhưng Đích là Tệp cùng tên."
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header with Icon
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(dialogTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(TotoroxTheme.textPrimary)

                    Text(dialogSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(TotoroxTheme.textSecondary)
                }
                Spacer()
            }

            Divider()

            // Path details
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text("Nguồn:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(TotoroxTheme.textSecondary)
                        .frame(width: 50, alignment: .leading)
                    Text(conflict.sourceURL.lastPathComponent)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(TotoroxTheme.textPrimary)
                }

                HStack(alignment: .top) {
                    Text("Đích:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(TotoroxTheme.textSecondary)
                        .frame(width: 50, alignment: .leading)
                    Text(conflict.destinationURL.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(TotoroxTheme.textPrimary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(TotoroxTheme.searchBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(conflict.conflictKind == .fileExists
                 ? "Chọn thao tác bạn muốn thực hiện đối với tệp bị trùng lặp này."
                 : "Tuyệt đối không tự ý xóa mục đích nếu chưa có sự xác nhận của bạn.")
                .font(.system(size: 12))
                .foregroundColor(TotoroxTheme.textSecondary)
                .multilineTextAlignment(.center)

            // Windows-style options
            VStack(spacing: 9) {
                // 1. Replace (Ghi đè)
                Button(action: { conflict.continuation(.replace) }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Ghi đè tệp này (Replace)")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(TotoroxTheme.mintAccent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // 2. Replace All (Ghi đè tất cả)
                Button(action: { conflict.continuation(.replaceAll) }) {
                    HStack {
                        Image(systemName: "checkmark.circle.badge.questionmark.fill")
                        Text("Ghi đè tất cả các tệp trùng (Replace All)")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color(red: 0.15, green: 0.55, blue: 0.45))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // 3. Skip (Bỏ qua)
                Button(action: { conflict.continuation(.skip) }) {
                    HStack {
                        Image(systemName: "forward.fill")
                        Text("Bỏ qua tệp này (Skip)")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color(red: 0.92, green: 0.93, blue: 0.96))
                    .foregroundColor(TotoroxTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // 4. Cancel (Hủy toàn bộ)
                Button(action: { conflict.continuation(.cancel) }) {
                    HStack {
                        Image(systemName: "xmark")
                        Text("Hủy toàn bộ thao tác (Cancel)")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(24)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 20, y: 10)
        .padding(.horizontal, 24)
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
