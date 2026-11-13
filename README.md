# Totorox

<p align="center">
  <img src="Totorox/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="132" alt="Biểu tượng ứng dụng Totorox">
</p>

<h1 align="center">Totorox</h1>

<p align="center">
  Trình quản lý Patch, Tệp tin và Container ứng dụng nâng cao dành cho iOS.
</p>

<p align="center">
  <b>Phiên bản:</b> 1.1 &nbsp;|&nbsp;
  <b>Người sáng lập:</b> VannHoc &nbsp;|&nbsp;
  <b>Bundle Identifier:</b> <code>com.apple.mobile.MobileHouseArrest</code>
</p>

---

## 🌟 Giới thiệu

**Totorox** là giải pháp nâng cao được phát triển dựa trên nền tảng kiến trúc của `3105` và `FilzaSlop`, mang lại khả năng quản lý container dữ liệu ứng dụng, tệp tin và gói Patch mạnh mẽ trên iOS (hỗ trợ từ iOS 16.0 đến iOS 27.x).

Ứng dụng tích hợp toàn bộ các cơ chế cấp thấp (MCM exploit, Sandbox escape, Kernel R/W primitives OPA334, Bridging Header) và bổ sung các hệ thống xử lý tệp tin chuyên biệt:
1. **File I/O Engine chuyên dụng:** Quy tắc ghi đè file không hash check, merge đệ quy thư mục nhiều cấp trên Background Thread, xử lý xung đột loại (File vs Folder) với cơ chế hỏi ý kiến người dùng (`Replace` / `Skip` / `Cancel`) tuyệt đối không xóa âm thầm dữ liệu đích, cùng khả năng hủy thao tác an toàn và báo cáo chi tiết (`Succeeded`, `Failed`, `Skipped`).
2. **Bộ chuyển đổi hai chiều `.3105` <-> `.zip`:** Cho phép giải mã gói `.3105` xuất ra `.zip` tiêu chuẩn và ngược lại, bảo toàn nguyên vẹn 100% cấu trúc, metadata và dữ liệu thay thế.
3. **Giới hạn dung lượng an toàn:** Mọi archive và gói patch, cả nén lẫn giải nén, bị chặn ở mức tối đa 3.6 GB trước khi cấp phát bộ nhớ.
4. **Bộ kiểm thử tự động:** Target `TotoroxTests` bao phủ File I/O, chuyển đổi `.3105`/`.zip`, giới hạn dung lượng và kiểm tra đường dẫn (XCTest).
5. **CI/CD Tự động:** GitHub Actions workflow hỗ trợ chạy unit tests và đóng gói Unsigned `.ipa`.

---

## 📂 Cấu trúc dự án

```
Totorox/
├── .github/
│   └── workflows/
│       └── build-and-test.yml          # GitHub Actions CI/CD (Test & Build Unsigned IPA)
├── project.yml                          # Cấu hình XcodeGen tạo .xcodeproj chuẩn mực
│                                        # (.xcodeproj được sinh bằng `xcodegen generate`)
├── Totorox/                             # Mã nguồn ứng dụng chính
│   ├── App.swift                       # SwiftUI App Entrypoint
│   ├── ContentView.swift               # Giao diện điều hướng chính
│   ├── Info.plist                      # Cấu hình Bundle ID, document types (.3105, .zip)
│   ├── Totorox-Bridging-Header.h       # Cầu nối C / Objective-C sang Swift
│   ├── Assets.xcassets/                # Tài nguyên và AppIcon Totoro đầy đủ kích thước
│   ├── engine/
│   │   ├── FileIOEngine.swift          # Engine sao chép, merge đệ quy, xử lý xung đột & báo cáo
│   │   └── PatchZipConverter.swift     # Converter song xạ hai chiều .3105 <-> .zip
│   ├── exploit/                        # MCM bad_query, wallpaper_zip và mcm_bridge
│   ├── kexploit/                       # Kernel read/write, offsets, sandbox_escape
│   ├── helpers/                        # Trình quản lý container, mã hóa AES-GCM, UI helpers
│   ├── views/                          # SwiftUI views (FolderExplorer, OverwriteFile, PatchConverter, Settings)
│   ├── en.lproj/                       # Đa ngôn ngữ tiếng Anh
│   ├── vi.lproj/                       # Đa ngôn ngữ tiếng Việt
│   └── zh-Hans.lproj/                  # Đa ngôn ngữ tiếng Trung giản thể
├── TotoroxTests/                        # Bộ kiểm thử Unit Test (XCTest)
│   ├── FileIOEngineTests.swift         # Kiểm thử File I/O Engine, cut/paste và symlink
│   ├── PatchZipConverterTests.swift    # Kiểm thử chuyển đổi khứ hồi & tính toàn vẹn
│   ├── ArchiveSizeLimitTests.swift     # Kiểm thử giới hạn 3.6 GB
│   └── PatchPathValidatorTests.swift   # Kiểm thử đường dẫn/tên an toàn
└── scripts/
    ├── generate_pbxproj.py             # Script sinh và cập nhật project.pbxproj
    └── test_engine.py                  # Script kiểm thử độc lập các module engine
```

---

## 🛠 Hướng dẫn Build & Chạy Test

### Cách 1: Sử dụng XcodeGen
```bash
brew install xcodegen
xcodegen generate
xcodebuild test -project Totorox.xcodeproj -scheme Totorox -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Cách 2: Mở trực tiếp bằng Xcode
Mở tệp `Totorox.xcodeproj` trên macOS, chọn Scheme `Totorox` để build ứng dụng hoặc Scheme `TotoroxTests` (phím tắt `Cmd + U`) để chạy toàn bộ Unit Test.

---

## 👤 Người sáng lập
- **Sáng lập & Phát triển:** VannHoc
