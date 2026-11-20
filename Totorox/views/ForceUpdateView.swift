import SwiftUI

/// Màn hình toàn trang khi server yêu cầu cập nhật bắt buộc.
/// Không có nút đóng, không thể vuốt xuống để tắt.
struct ForceUpdateView: View {
    let message: String
    let downloadURL: String

    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ZStack {
            TotoroxTheme.pageBackground
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // Icon
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(TotoroxTheme.mintAccent)

                // Tiêu đề
                Text("Yêu cầu cập nhật")
                    .font(.title2.bold())
                    .foregroundStyle(TotoroxTheme.textPrimary)

                // Nội dung thông báo từ server
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TotoroxTheme.textSecondary)
                    .padding(.horizontal, 36)

                // Nút tải bản mới (chỉ hiện khi có URL hợp lệ)
                if !downloadURL.isEmpty, let url = URL(string: downloadURL) {
                    Link(destination: url) {
                        Text("Tải bản mới ngay")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(TotoroxTheme.mintAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 36)
                }

                Spacer()

                // Ghi chú nhỏ bên dưới
                Text("Liên hệ hỗ trợ nếu bạn gặp vấn đề khi tải.")
                    .font(.caption)
                    .foregroundStyle(TotoroxTheme.textSecondary.opacity(0.6))
                    .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled(true) // Cấm vuốt xuống để tắt
    }
}
