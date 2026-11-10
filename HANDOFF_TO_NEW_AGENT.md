# HANDOFF TÀI LIỆU CHUYỂN GIAO DỰ ÁN TOTOROX

## 1. Mục tiêu dự án
- **Tên dự án chuẩn:** `Totorox` (Tuyệt đối không sử dụng tên sai lệch như `Tororox`).
- **Mô tả:** Công cụ quản lý tệp tin chuyên dụng cho iOS, hỗ trợ can thiệp sandbox và xử lý đóng gói/giải nén định dạng `.3105` <-> `.zip`.
- **Cơ sở mã nguồn:** Xây dựng và kế thừa trực tiếp từ mã nguồn gốc của repo `3105` và `FilzaSlop`.

---

## 2. Thực trạng kỹ thuật hiện tại (Critical Regressions)
- **Hỏng Core I/O & Sandbox:** Core I/O bị lỗi phân quyền, mất khả năng truy cập và can thiệp vào đường dẫn `/var/mobile/Containers/Data/Application`.
- **Treo giao diện (UI Freeze):** Các tác vụ quét thư mục, đọc file, copy/move I/O đang bị gọi đồng bộ trực tiếp trên Main Thread khiến toàn bộ ứng dụng bị đơ cứng.
- **Lỗi hiển thị Bundle ID:** Không phân giải được thông tin ứng dụng thực tế; UI đang hiển thị mã băm UUID thô thay vì Bundle Identifier hoặc Display Name.
- **Luồng Đè File 3 bước bị giả lập:** Logic đè file đang bị hardcode tĩnh, không kết nối với luồng quét ứng dụng thực tế trên thiết bị.

---

## 3. Quy tắc kỹ thuật bắt buộc cho Agent tiếp theo
1. **DỪNG TỰ BỊA CODE TỪ REA:**
   - Tuyệt đối không phỏng đoán hay viết lại logic trừu tượng từ mã dịch ngược giả định.
   - Bắt buộc khôi phục và tái sử dụng trực tiếp các đoạn mã/lõi xử lý nguyên bản bằng C / Objective-C từ repo `3105` (posix_spawn, quyền root/bypass sandbox, direct posix I/O).
2. **CHUẨN HÓA BUNDLE ID SCANNING:**
   - Quét và trích xuất Bundle ID chuẩn từ file cấu hình:
     `[Container_Path]/.com.apple.mobile_container_manager.metadata.plist`
   - Đọc key `MCMMetadataIdentifier` để hiển thị đúng định danh ứng dụng thay vì UUID.
3. **BẤT ĐỒNG BỘ TOÀN BỘ FILE I/O:**
   - Mọi thao tác quét đĩa, đọc metadata, copy, ghi đè file bắt buộc phải ném xuống Background Thread (`DispatchQueue.global()`, `Task.detached`).
   - Chỉ điều phối về `DispatchQueue.main` khi cập nhật trạng thái lên giao diện.
4. **CHUẨN HÓA ĐỊNH DANH DỰ ÁN:**
   - Rà soát toàn bộ project configuration, Xcode Target, Schemes, Info.plist, file code: đổi toàn bộ `Tororox` -> `Totorox`.
5. **TRỌNG TÂM CẦN XỬ LÝ NGAY:**
   - Tái cấu trúc lại ngay lập tức 2 module trọng yếu:
     - `AppContainerScanner`
     - `FileIOEngine`
