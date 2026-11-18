# Nhật Ký Tiến Độ Phát Triển — Totorox 3.0

> **Cập nhật gần nhất:** `2026-11-19`
> **Phiên bản dự án hiện hành:** **`3.0`** (`MARKETING_VERSION = "3.0"`, Backend `3.0.0`)
> **Tên bản build IPA trên GitHub Actions:** `Totorox-3.0-unsigned.ipa` (Artifact: `Totorox-3.0-unsigned-ipa`)
> **Quy định chung cho mọi AI Agent:** Làm dự án đến đâu **BẮT BUỘC** cập nhật tiến trình, danh sách file sửa, kết quả test và việc tồn đọng vào file này (hoặc file `.md` chuyên biệt rồi liên kết tại mục 3 bên dưới).

---

## 1. Cấu hình Phiên bản 3.0 (Đã đồng bộ)

| Thành phần | File cấu hình | Giá trị hiện tại |
| :--- | :--- | :--- |
| XcodeGen / `Info.plist` (`CFBundleShortVersionString` & `AppReleaseDisplayVersion`) | `project.yml`, `Totorox/Info.plist` | `"3.0"` |
| GitHub Actions Unsigned IPA & Artifact | `.github/workflows/build-and-test.yml` | `Totorox-3.0-unsigned.ipa` / `Totorox-3.0-unsigned-ipa` |
| Hiển thị phiên bản fallback trong Cài đặt | `Totorox/views/SettingsView.swift` | `"3.0"` |
| Core FastAPI Server | `Totorox-Backend/main.py` | `"3.0.0"` |
| Tài liệu giới thiệu | `README.md`, `AGENTS.md`, `.cursorrules` | `3.0` |

---

## 2. Các Hạng Mục Đã Hoàn Thành & Kiểm Chứng (`2026-11-18`)

### 2.1. Đại tu Pipeline Gộp Mod AOV (`Gộp file` — Backend & iOS Client)
Đã đối chiếu trực tiếp trên bộ mẫu thực tế gồm 3 skin lẻ (`Bilow.zip` hero `599`, `Edras Vấn Tâm Kiếm.zip` hero `595`, `Nak.zip` hero `150`), gói gộp lỗi cũ và `Resources Gốc.zip` (`1.64.1.12|1793129`), xử lý triệt để 4 lỗi gốc:

1. **Triệt tiêu Popup quảng cáo từ xa `KIANA MOD AOV` trong `KernelLua.pkg.bytes`:**
   - **Nguyên nhân:** `strict_lua.bytes` giải mã XOR bản vá IFix `_0x432312` (vừa tắt `CBattleResourceCheckSystem.set_Enable(false)` chống lỗi mạng, vừa tìm hàm toàn cục `_0x237912319231723827` trong `Lua_Signed/Kernel/Util/xlua/util_lua.bytes` để gọi `UnityWebRequest` tải `lads.txt` / `la.txt` từ GitHub rồi mở `OpenMessageBoxCallBack`).
   - **Giải pháp (`Totorox-Backend/core_processor.py` → `sanitize_lua_pkg`):** Đổi tên hằng chuỗi `_0x237912319231723827` → `_0x000000000000000000` (giữ nguyên đúng 21 byte để không lệch header chuỗi Lua 5.3) và vô hiệu hóa mọi URL `raw.githubusercontent.com` bằng chuỗi trơ cùng độ dài, trong khi **giữ nguyên `_0x242424` và `_0x432312`** để tính năng chống lỗi mạng hoạt động 100%. Tự động băm lại MD5 `KernelLua.pkg.bytes` và cập nhật vào `Thanos/HeroSkin_1..4`.
2. **Chuẩn hóa Watermark bản quyền Totorox 1 dòng (`languageMap.txt`):**
   - **Giải pháp (`Totorox-Backend/core_processor.py` → `_TOTOROX_WATERMARK_LINE`):** Đổi từ chuỗi 2 dòng (`\n` bị cắt mất dòng dưới ở mép đáy màn hình) sang 1 dòng duy nhất: `Tip_WaterMark_Str = Mod pack được tạo bởi Totorox • Phát triển bởi VannHoc`.
3. **Khóa nguyên tử cặp AssetBundle (`<stem>` + `_raw*`) & Cụm Battle HUD chung (`uisystem/battle/`):**
   - **Nguyên nhân:** `Bilow.zip` ghi đè cả 4 file HUD chung (`battlecommon`, `battlecommon_raw`, `battleotherui`, `battleotherui_raw` + `Sound/iOS/UI.bnk`), trong khi `Edras` ghi đè `uisystem/atlas/primary/allshared.assetbundle` + 2 file `battlecommon_raw`, `battleotherui` (đi cặp với 2 file gốc của game). Cơ chế chọn từng file lẻ trước đây ghép chéo `battlecommon` + `battleotherui_raw` của Bilow với `battlecommon_raw` + `battleotherui` của Edras, làm Edras bị đè nút đánh thường/joystick/viền đỏ của Bilow và lệch texture `.resS`.
   - **Giải pháp (`Totorox/engine/AovModMergerEngine.swift` & `Totorox-Backend/core_processor.py`):** Thêm `assetBundleFamilyKey` / `resolveFamilyWinningModByKey` / `isGlobalUISoundBankPath` gom nguyên tử mọi họ `<stem>` + `_raw`/`_raw_h`/`_raw_mat` và gom chung cụm `__battle_hud__` (`battlecommon*` + `battleotherui*` + `UI.bnk`), ưu tiên mod có kèm `allshared.assetbundle` và **bỏ qua hoàn toàn file mồ côi của mod thua** (để ghép sạch với file gốc của game).
4. **Hỗ trợ gộp `<Array name="skinIdArray">` trong `CommonActions.pkg.bytes` (`Born.xml`):**
   - **Giải pháp (`Totorox-Backend/core_processor.py` → `parse_track`, `replace_skin_id_array`, `merge_xml_tracks`, `merge_common_actions`):** Đọc, tính điểm ghép cặp và gộp danh sách `<int value="..."/>` bên trong `<Array name="skinIdArray">` tương tự `<SkinOrAvatarList>`, bảo toàn hiệu ứng xuất hiện Tế Đàn 3.0 (`59900`) ở cả 2 chiều thứ tự gộp.
5. **Hỗ trợ cập nhật bản ghi biến thiên độ dài trong `ResourcePackerInfoSetAll.assetbundle`:**
   - **Giải pháp (`Totorox-Backend/core_processor.py` → `_rpack_path_matches_heroes`, `merge_resource_packer`):** Cho phép mod cập nhật bản ghi thuộc tướng của mình ngay cả khi số lượng hash thay đổi (`olen != blen`, ví dụ `Actor_599_Actions.pkg.bytes` tăng từ `94` lên `96` hash / `1504 B` → `1536 B`) hoặc khi mod đó có build thấp hơn bản nền (`1.64.1.12 < 1.64.1.13`), đồng thời tự động tính lại `byteSize` và dịch chuyển `byteStart` của các object phía sau trong bảng `m_Objects` Unity `SerializedFile` v22 mà không làm tụt bản ghi dùng chung của build mới hơn.

- **Kiểm thử đã chạy:**
  - `Totorox-Backend/test_backend.py`: **19/19 tests OK** (bao gồm `test_kiana_lua_popup_sanitization_born_skinidarray_rp_resize_and_bundle_families`).
  - `Totorox-Backend/test_store.py`: **7/7 tests PASSED**.
  - `TotoroxTests/PatchZipConverterTests.swift`: Đã bổ sung `testAovModMerger_AtomicAssetBundleFamiliesAndBattleHudGrouping`.
  - Test thực chiến trên 3 gói `Bilow.zip` + `Edras Vấn Tâm Kiếm.zip` + `Nak.zip` (cả 2 chiều thứ tự): **PASS 100%**.

### 2.2. Sửa chuyển đổi `.3105 ⇄ .zip` dung lượng lớn & Dọn file tạm (`b1ffa2c`)
- **Files:** `Totorox/engine/PatchZipConverter.swift`, `Totorox/views/OverwriteFileView.swift`, `TotoroxTests/PatchZipConverterTests.swift`.
- Đọc streaming magic + plist metadata của gói `.3105` > 64 MB (ví dụ gói 220 MB) không bị vướng giới hạn đọc RAM 64 MB; chuyển đổi streaming sang `.zip` và tự xóa file tạm sau khi đè file.

### 2.3. Chống Spam 50 lượt/ngày & Giữ phiên Web Admin Dashboard
- **Files:** `Totorox-Backend/database.py`, `Totorox-Backend/admin.html`, `Totorox-Backend/admin_keys.py`, `Totorox-Backend/test_backend.py`.
- Áp trần `DAILY_ANTI_SPAM_CAP = 50` lượt/ngày cho toàn bộ tài khoản đang hoạt động (cả gói giới hạn lượt lẫn vô hạn).
- Tách kiểm tra `/admin/api/session` khỏi `Promise.allSettled` tải dữ liệu phụ trên `admin.html` để F5/reload không bị văng về màn hình nhập mật khẩu khi 1 API thống kê chậm.

### 2.4. Kho Mod Skin Trực Tuyến Trong App (`Kho Mod` — Tab 5) & Chuyển Đổi Giao Diện Sáng / Tối (`Light ⇄ Dark Theme`) (`2026-11-18`)
- **Mục tiêu & Nguyên nhân gốc:**
  1. Đưa tính năng tải trực tiếp gói Mod Skin Liên Quân (`GET /api/v1/mods`, `POST /api/v1/mods/download`) vào ứng dụng iOS thành Tab thứ 5 (`Kho Mod`) với giao diện đồng bộ hoàn toàn cùng hệ thống thiết kế Mint của Totorox.
  2. Bổ sung bộ chọn chuyển đổi qua lại giữa **Giao diện Sáng (`Light Mode`)** và **Giao diện Tối (`Dark Mode`)** ngay trong `Cài đặt` (và nút chuyển nhanh trên màn hình Đăng nhập).
  3. **Sửa triệt để lỗi chữ khó nhìn khi người dùng bật sẵn Dark Mode của iOS rồi vào app:** Trước đây `TotoroxTheme` gán cứng mã màu sáng (`Color.white`, `#F9FAFC`) nhưng `.preferredColorScheme(.light)` chỉ gắn ở subview sau đăng nhập và không đồng bộ `UIWindow.overrideUserInterfaceStyle`, khiến `UITextField`, `SecureField`, `List`, `Alert`, `ActivationView`, `OnboardingView` và `OverwriteOutcomeView` nhận chữ màu trắng của hệ thống trên nền thẻ trắng.
- **Giải pháp & Danh sách file đã thêm/sửa:**
  - `Totorox/views/DesignSystem.swift`: Thêm `AppThemeMode` (`light` / `dark`), `ThemeManager` đồng bộ trực tiếp `window.overrideUserInterfaceStyle` trên mọi `UIWindow` ngay từ `init()` + lắng nghe `UIScene` / `UIWindow` notifications; chuyển toàn bộ bảng màu `TotoroxTheme` sang `UIColor { traits in ... }` động độ tương phản cao (WCAG AA+/AAA) cho cả chế độ Sáng và Tối.
  - `Totorox/helpers/ModStoreCache.swift` *(mới)*: Bộ nhớ đệm cục bộ `Caches/TotoroxModStoreCache` kiểm tra chữ ký ZIP & băm `SHA-256` khớp máy chủ; gói mod đã tải được gắn nhãn **Đã lưu** để dùng lại cho Đè file / Gộp file / Chia sẻ tức thì (`0ms`) mà không tốn thêm lượt.
  - `Totorox/views/ModStoreView.swift` *(mới)*: Giao diện Tab 5 **Kho Mod** gồm Header thống kê, tìm kiếm đa trường (`name`, `heroName`, `skinName`, `#heroID`), lọc danh mục (`Tất cả`, `Skin Tướng`, `Nút & Hạ`, `Combo Mod`, `Đã lưu`), sắp xếp, kéo làm mới, menu thao tác nhanh từng bản mod và thanh Action Dock ghim đáy có thanh tiến trình MB/% thời gian thực + nút Hủy tải + chuyển thẳng sang `Đè file` (tự chọn Liên Quân) hoặc `Gộp file` (chọn nhiều gói).
  - `Totorox/helpers/APIService.swift`: Bổ sung `fetchModCatalog` và `downloadModFile` (streaming `URLSessionDownloadTask` tốc độ cao kèm theo dõi `Progress` theo byte, hỗ trợ hủy tác vụ, tắt HTTP/3 QUIC chống lỗi `-1005` trên iOS 18 và ký `HMAC-SHA256`).
  - `Totorox/helpers/AppNavigationCoordinator.swift`, `Totorox/views/TotoroxTabBar.swift`, `Totorox/ContentView.swift`, `Totorox/App.swift`, `Totorox/views/MergeFileView.swift`: Mở rộng thanh điều hướng 5 tab, điều phối `navigateToMerge(modURLs:)` và `totorox://mods`, áp dụng `.preferredColorScheme(themeManager.mode.colorScheme)` từ gốc `WindowGroup`.
  - `Totorox/views/SettingsView.swift`, `Totorox/views/ActivationView.swift`, `Totorox/views/OnboardingView.swift`, `Totorox/views/OverwriteFileView.swift`, `Totorox/views/PatchConverterView.swift`, `Totorox/views/FolderExplorerView.swift`, `Totorox/views/ConflictResolutionModal.swift`, `Totorox/views/LogView.swift`: Bổ sung thẻ chọn Giao diện Sáng / Tối trong Cài đặt, đồng bộ màu chữ + placeholder cho toàn bộ `TextField` / `SecureField` / `List` / `Sheet` / `Modal` và dọn `ModStoreCache` khi xóa cache.
  - `Totorox/vi.lproj/Localizable.strings`, `Totorox/en.lproj/Localizable.strings`, `Totorox/zh-Hans.lproj/Localizable.strings`: Đồng bộ `656/656` khóa ngôn ngữ đầy đủ cho cả 3 thứ tiếng.
  - `TotoroxTests/APIServiceLicenseTests.swift`: Thêm `testModCatalogAndDownloadSignRequestsAndVerifyCachedZip` và `testThemeManagerPersistsLightAndDarkModeAndAdaptiveContrast`.
- **Kiểm thử đã chạy:**
  - Kiểm tra cú pháp & đối chiếu khóa `.strings` trên `vi` / `en` / `zh-Hans`: **656/656 keys khớp 100%**.
  - `Totorox-Backend/test_backend.py` (bao gồm luồng `/api/v1/mods` & `/api/v1/mods/download`): **19/19 tests OK**.
  - `Totorox-Backend/test_store.py`: **7/7 tests PASSED**.
  - Bước tiếp theo: Push lên GitHub Actions (`.github/workflows/build-and-test.yml`) để chạy full `XCTest` trên macOS runner và xuất `Totorox-3.0-unsigned.ipa`.

### 2.5. Totorox Mod Studio (Offline Windows App — `127.0.0.1`) (`2026-11-18`)
- **Mục tiêu & Kiến trúc:**
  - Xây dựng ứng dụng Desktop chạy **100% offline trên Windows (`http://127.0.0.1:18305`)** dành cho chủ dự án (`Totorox-Mod-Studio/`), kế thừa `assets/bypass_seed.zst`, tái sử dụng trực tiếp nhân `core_processor.py` & từ điển `aov_zstd_uncompressed.bin` của `Totorox-Backend`, không phụ thuộc mạng hay CDN ngoài.
- **Sửa triệt để 4 lỗi logic cốt lõi & gia cố Engine (`Totorox-Mod-Studio/jtcom.py`, `Totorox-Mod-Studio/studio_engine.py`):**
  1. **Mã hóa `0x224A6700` bắt buộc cho toàn bộ XML trong `Actor_<H>_Actions.pkg.bytes`:** Mã hóa từng entry `.xml` bằng `cp.pg_encrypt(..., stem)` theo tên file không đuôi (`A1`, `S1`, `13109_Back`), đồng bộ kiểm tra an toàn XML và đóng gói `ZIP_STORED (STORE=0)`.
  2. **Hiệu ứng Vòng Biến Về (`Back.xml`) & Gia tốc tế đàn (`HasteE1.xml`) trong `CommonActions.pkg.bytes`:** Thêm `target_skin_ids` vào các track ẩn vòng xanh mặc định (`SkinAvatarFilterType="11"`) và chèn track `TriggerParticleTick`/`TriggerParticle` (`SkinAvatarFilterType="9"`, UUIDv5 chuẩn) + `StopTracks` cho `ResSkinExclusiveBattleEffectCfg.bytes`; xử lý đầy đủ `CheckSkinId*` (`bEqual`, `useNegateValue`, `flt="9"`/`"11"`, `<Array name="skinIdArray">`).
  3. **Ánh xạ âm thanh skin tiến hóa 7 chữ số (`_remap_sound_table_for_hero`):** Hỗ trợ đồng thời dải 5 chữ số (`235XX`) và 7 chữ số (`1503301` → `2353301`), gắn hậu tố `_Skin<idx>` cho `PlayHeroSoundTick` và cập nhật MD5 header bảng `MSES` (`offset 96..128`).
  4. **Đường dẫn hiệu ứng trực tiếp `hero_skill_effects/{skin_id}_*` (`jtcom.rewrite_hero_effect_path`):** Gắn hậu tố `_HD` (skin Huy Hoàng/Chí Tôn từ `ResSkinSeniorLabelCfg`) hoặc `.prefab` (skin thường) mà không chèn lặp thư mục `/{skin_id}/`.
- **3 Nhóm Tính Năng & Giao Diện Offline (`app.py`, `studio.html`, `Run_Totorox_Studio.bat`, `build_exe.bat`, `TotoroxModStudio.spec`):**
  - `Totorox-Mod-Studio/jtcom.py` (`380` dòng): Parser/Serializer `JTCom` (`VSerializer`) lossless 100%, `promote_skin_in_actorinfo`, `transform_assetref_paths`.
  - `Totorox-Mod-Studio/studio_engine.py` (`3,380` dòng): 4 phân hệ `CatalogIndexer`, `SkinModBuilder` (1-Click, Mix Chiêu 8 slot, Cam Xa `5%–25%` & gói 4-file độc lập, Nút bấm/Thông báo hạ `HeroSkin_2`, Watermark `languageMap.txt`, Bypass sạch không popup Kiana), `BinaryInspector` (`0x224A`, `MSES`, `.pkg.bytes` unpack/pack/update-entry, `JTCom` JSON, `AGE XML` tracks), `OfflineMergerAndConverter` (gộp đa gói không giới hạn dung lượng & chuyển đổi `.zip ⇄ .3105` AES-256-GCM + PBKDF2).
  - `Totorox-Mod-Studio/app.py` (`1,202` dòng): FastAPI `3.0.0` local `127.0.0.1` (`--host`, `--port`, `--no-browser`), `21` endpoint JSON/`multipart`, chọn file/thư mục gốc Windows qua `tkinter.filedialog` (bảo vệ bằng `threading.Lock()`), mở `explorer /select,...`, mở cửa sổ riêng qua Microsoft Edge `--app`, kiểm tra `math.isfinite` cho `camera_percent`, tách mật khẩu trùng basename khi gộp đa gói, khóa base64 nghiêm ngặt (`validate=True`) & path traversal / NTFS ADS (`_safe_download_path`).
  - `Totorox-Mod-Studio/studio.html` (`2,595` dòng): Giao diện Tiếng Việt 4 tab + Sổ tay Logic Mod Skin 7 mục, Light/Dark Mint đồng bộ Totorox `3.0`, tìm kiếm Tướng/Skin không dấu, 100% tự thân offline (0 CDN ngoài), bảo vệ `pwMap` khi trùng tên file `.3105` & CSS `.check-row`.
  - `Totorox-Mod-Studio/Run_Totorox_Studio.bat` (`42` dòng), `build_exe.bat` (`60` dòng), `TotoroxModStudio.spec` (`143` dòng): Khởi chạy trực tiếp & đóng gói `dist\TotoroxModStudio\TotoroxModStudio.exe` bằng PyInstaller `6.22.3`.
- **Kiểm thử đã chạy:**
  - `Totorox-Mod-Studio/test_studio.py` (`4,360` dòng): **166/166 tests PASSED** (`0` failed, `0` skipped — gồm Tier 1–4 `154` tests + Tier 5 `12` adversarial edge cases trên dữ liệu thật `Resources Gốc.zip`, `Nak.zip`, `Bilow.zip`, `Edras Vấn Tâm Kiếm.zip` + Playwright headless Edge UI).
  - Đóng gói & Smoke-test `.exe` (`Totorox-Mod-Studio\dist\TotoroxModStudio\TotoroxModStudio.exe --no-browser --port <PORT>`): **PASS** (`GET /api/health` trả `200 OK` với `"frozen": true`, `"has_default_seed": true`; `GET /` trả `200 OK`; `GET /api/catalog` trả `200 OK` với `136` tướng; `POST /api/inspector/crypto/0x224a` mã hóa/giải mã `0x224A (b2=0x67, b3=0x00)` thành công trong chế độ frozen; thư mục `Totorox-Mod-Studio/output/` giữ sạch `0` file).
  - Hồi quy Backend: `Totorox-Backend/test_backend.py` (**19/19 tests OK**), `pytest Totorox-Backend/test_store.py` (**7/7 tests PASSED**).

---

## 3. Các Luồng Công Việc Song Song & Tài Liệu Liên Kết Cho Agent Khác

| Hạng mục | Tài liệu chi tiết | Trạng thái hiện tại | Lưu ý cho Agent tiếp theo |
| :--- | :--- | :--- | :--- |
| **Tầng 4 Sandbox Escape (`worse_query` cho iOS 26+) `2026-11-18`** | [`WORSE_QUERY_INTEGRATION_PLAN.md`](WORSE_QUERY_INTEGRATION_PLAN.md), [`WORSE_QUERY_PROGRESS.md`](WORSE_QUERY_PROGRESS.md) (mục 13 = biên bản audit) | Đã **audit toàn bộ luồng + tối ưu tốc độ (đợt 2)**: sửa thứ tự thử, xác minh handle Tier 4, retry policy variant, cache group, mở gate STAGE 3 cho iOS 26 sideload. **Chưa commit, chưa chạy Xcode CI / test máy thật** (host Windows không có Xcode). | Không tự ý revert/xóa các file `worse_query.{h,m}`, `WorseQuery.swift`, `SandboxGrantRouter.swift`, `WorseQueryTests.swift` và phần toggle trong `SettingsView.swift` / `ContainerStore.swift` / `AppContainerScanner.swift` / `App.swift`. Đọc mục 13 của `WORSE_QUERY_PROGRESS.md` trước khi sửa tiếp. |
| **Kho Mod trực tuyến (Tab 5) & Dark/Light Theme** | Mục `2.4` tại file này | Đã tích hợp hoàn chỉnh trên working tree `main` cho bản `3.0` | Luôn dùng các token động của `TotoroxTheme` và `themeManager.mode.colorScheme` khi thêm view/sheet mới; không hardcode `.preferredColorScheme(.light)` hay `Color.white`. |
| **Lịch sử bàn giao giai đoạn Hybrid ban đầu** | [`HANDOFF_TO_NEW_AGENT.md`](HANDOFF_TO_NEW_AGENT.md) | Lưu trữ tham khảo kiến trúc Hybrid `.3105` & `merge-plan` | Xem thêm [`AGENTS.md`](AGENTS.md) để nắm schema SQLite & quy tắc Subdomain Isolation hiện hành. |
| **Totorox Mod Studio (`127.0.0.1` Offline Windows App)** | Mục `2.5` tại file này (`Totorox-Mod-Studio/`) | Đã hoàn thiện Engine, Local Server, Mint UI, bộ test E2E (`166/166`) & đóng gói `.exe` | Không xóa/ghi đè `assets/bypass_seed.zst`, `studio_config.json`, `catalog_cache.json`; giữ `output/` sạch khi commit và chạy `Totorox-Mod-Studio/test_studio.py` khi sửa `jtcom.py`/`studio_engine.py`/`app.py`/`studio.html`. |

---

## 4. Checklist Triển Khai Hiện Tại (Dành Cho Chủ Dự Án / Agent)

1. **Cập nhật Backend lên VPS (`103.176.24.220`):**
   - Các file Backend đã thay đổi cần đồng bộ lên `/opt/totorox-backend/`: `core_processor.py`, `main.py`, `database.py`, `admin.html`, `admin_keys.py`.
   - Lệnh PowerShell (chạy trên **1 dòng**):
     ```powershell
     scp "C:\Users\studi\OneDrive\Documents\Tools\Totorox\Totorox-Backend\core_processor.py" "C:\Users\studi\OneDrive\Documents\Tools\Totorox\Totorox-Backend\main.py" "C:\Users\studi\OneDrive\Documents\Tools\Totorox\Totorox-Backend\database.py" "C:\Users\studi\OneDrive\Documents\Tools\Totorox\Totorox-Backend\admin.html" "C:\Users\studi\OneDrive\Documents\Tools\Totorox\Totorox-Backend\admin_keys.py" root@103.176.24.220:/opt/totorox-backend/
     ```
   - Khởi động lại service trên VPS:
     ```bash
     ssh root@103.176.24.220 "systemctl restart totorox"
     ```
2. **Build IPA `Totorox-3.0-unsigned.ipa` trên GitHub Actions:**
   - Kiểm tra xem muốn đẩy bản build `3.0` gồm **cả `worse_query` + sửa gộp mod** hay chỉ đẩy trước phần **sửa gộp mod + nâng version 3.0**, sau đó push lên `origin/main` để workflow `.github/workflows/build-and-test.yml` chạy XCTest trên macOS runner và xuất artifact `Totorox-3.0-unsigned.ipa`.
3. **Chạy & Đóng gói Totorox Mod Studio (Windows Offline):**
   - Chạy trực tiếp từ mã nguồn: nháy đúp `Totorox-Mod-Studio\Run_Totorox_Studio.bat` (mặc định mở tại `http://127.0.0.1:18305` bằng Edge `--app`).
   - Đóng gói bản chạy độc lập `.exe`: chạy `Totorox-Mod-Studio\build_exe.bat` để xuất ra `Totorox-Mod-Studio\dist\TotoroxModStudio\TotoroxModStudio.exe`.

---

## 2026-11-18 — Sửa lỗi Mất Model Sảnh, Popup #3 Dữ liệu Trận đấu & Tối ưu Local Resources `1.64.1.13|1802180`

### Nguyên nhân gốc đã xác định
1. **Mất Model Sảnh (`ArtLobbyShowLOD` + `ResourcePackerInfoSetAll`):**
   - `jtcom._force_lod_array_to_highest` tự ép thêm hậu tố `.prefab` vào đường dẫn `Show1`/`Idleshow1` của `ArtLobbyShowLOD` / `ArtLobbyIdleShowLOD`, trong khi 100% tài nguyên chuẩn trong `Resources 18_11.zip` không dùng `.prefab` ở sảnh.
   - `studio_engine._patch_rpack_for_hero_battle_skins` trước đây chỉ đánh dấu `KianaMod` cho `assetbundle/battle/skin/`, bỏ sót `assetbundle/show/skin/`.
2. **Popup #3 (*"Hệ thống kiểm tra thấy dữ liệu của bạn có thể sẽ dẫn đến kết quả trận đấu không chính xác"*):**
   - `Totorox-Mod-Studio/assets/bypass_seed.zst` mặc định trước đó chứa `HeroSkin_1/2` (`44.7KB`) và `KernelLua`/`StableSystems_3` cũ của `1.64.1.12` dù metadata ghi `1.64.1.13|1802180`.
   - `OfflineMergerAndConverter.merge_mods` xóa bỏ `resourcepackerinfosetall.assetbundle` nếu `< 5_000_000` bytes (nhưng RPack nén chuẩn UnityFS chỉ ~`1.98 MB`), khiến gói gộp mất toàn bộ bảng RPack và gây sai lệch kiểm tra dữ liệu.
3. **Quản lý `Resources` cục bộ:** Chưa tự xếp hạng theo `version.txt` + `mtime` khi xuất hiện `Resources *.zip` mới trong `C:\Users\studi\OneDrive\Documents\Tools\game\`.

### Các thay đổi đã thực hiện
- **`Totorox-Mod-Studio/jtcom.py`:** Bỏ tự ép `.prefab` trong `_force_lod_array_to_highest` (dùng `_first_valid_lod_path` giữ nguyên định dạng gốc); bổ sung kiểm tra hợp lệ `SkinPrefab` (cho phép skin gốc `hero_id * 100`), `ArtPrefabLOD` và `ArtLobbyShowLOD` — tự động `raise RuntimeError` nếu thiếu hoặc chỉ toàn `NULL='Y'`.
- **`Totorox-Mod-Studio/studio_engine.py`:**
  - Nâng cấp `_auto_detect_base_resources`, `load_studio_config` và thêm `list_local_resources_candidates` / `scan_local_resources` quét `Resources *.zip` cục bộ trong `game/` theo `(ver_tuple, build_num, mtime)`.
  - Hỗ trợ Bypass Seed 2 chế độ (`lua_only` và `kiana_ifix`) trong `load_bypass_seed`, `import_bypass_seed_from_mod_zip` và thêm `check_bypass_seed_compatibility`. Mặc định `lua_only` giữ nguyên `Thanos/HeroSkin_1..4.bytes` chuẩn từ `Resources`.
  - Cập nhật `_patch_rpack_for_hero_battle_skins` đánh dấu `KianaMod` cho cả `assetbundle/battle/skin/` và `assetbundle/show/skin/`.
  - Bổ sung kiểm tra `RuntimeError` (`ModAssetValidationError` kế thừa `(RuntimeError, ValueError)`) trước khi xuất file nếu thiếu `version.txt`, `resourcepackerinfosetall.assetbundle`, `Thanos/HeroSkin_1..2.bytes`, sai lệch seed bản build hoặc output 0 byte.
  - Sửa `OfflineMergerAndConverter.merge_mods` không xóa `resourcepackerinfosetall.assetbundle` `< 5MB`, thay vào đó hợp nhất/nâng cấp RPack cùng `Resources` gốc + đánh dấu `battle/skin/` & `show/skin/` và thay `HeroSkin_1..4` cũ `< 60KB` bằng bộ chuẩn mới nhất.
- **`Totorox-Mod-Studio/assets/bypass_seed.zst`:** Tạo lại seed mặc định chuẩn `1.64.1.13|1802180` (`lua_only`, sạch quảng cáo) từ gói mẫu `18-11`.
- **`Totorox-Mod-Studio/app.py` & `Totorox-Mod-Studio/studio.html`:** Expose `seed_status` qua `/api/health` và `/api/catalog`, thêm endpoint `POST /api/resources/rescan` (dọn `_PROVIDER_CACHE` + rebuild catalog), nút **`Quét lại Resources`** và banner cảnh báo Tiếng Việt khi thiếu asset/lệch seed; map `RuntimeError` sang HTTP `400`.
- **`Totorox-Mod-Studio/test_studio.py`:** Cập nhật test `lua_only` mặc định + mock Kiana seed cho 5 test Kiana IFix, thêm `test_t5_local_mock_zip_validation_no_prefab_rpack_show_and_rescan`.

### Kết quả kiểm tra & Đóng gói
- `python -m pytest Totorox-Mod-Studio\test_studio.py`: **166 passed, 1 skipped, 0 failed** (chạy sau lần sửa code cuối).
- `python -m pytest Totorox-Backend\test_backend.py`: **19 passed, 0 failed**.
- Build lại `Totorox-Mod-Studio\dist\TotoroxModStudio\TotoroxModStudio.exe` bằng PyInstaller (`TotoroxModStudio.spec`), đồng bộ `studio_config.json`, smoke-test trên `.exe` đang chạy (`frozen=true`, `/api/resources/rescan`, tạo mod Airi `13015` & Nakroth `15015` có `Show1` không `.prefab`, `show=34`/`battle=34..46`, gộp mod giữ RPack `1,978,348` bytes & `HeroSkin_1` `100,280` bytes).
- Thư mục `Totorox-Mod-Studio\output\` sạch sau khi kiểm tra.

---

## 2026-11-18 — Đè Skin Chỉ Định Theo Slot (`replace_skin_ids` / `skin_mappings`) & Mod Hàng Loạt (`batch-build`)

### Mục tiêu
1. Cho phép người dùng chọn **đè chính xác 1 hoặc nhiều skin cụ thể** đang sở hữu (ví dụ skin Bậc A / Bậc S / Mặc định `00`) bằng skin bậc cao hơn (`source_skin_id`, hỗ trợ ánh xạ nhiều cặp `skin_mappings: {dst_sid: src_sid}` trên cùng một tướng) mà **giữ nguyên các skin khác** của tướng đó.
2. Phân loại bậc trang phục (`tier_label`, `tier_rank`) ngay trong catalog để lọc/chọn nhanh các skin bậc thấp (Bậc A, Mặc định/Bậc A).
3. Bổ sung hàng đợi **Mod Hàng Loạt** (`batch-build`): chọn nhiều tướng/cặp skin, gom cùng tướng thành `skin_mappings` rồi gộp chung thành 1 gói mod sạch hoặc xuất từng file riêng.

### Các thay đổi đã thực hiện
- **`Totorox-Mod-Studio/jtcom.py`:**
  - Thêm `_SKIN_TO_ROOT_MAP`, `_prepare_skin_element_for_promote`, `_apply_skin_element_to_root`, và cập nhật `promote_skin_in_actorinfo(..., skin_mappings=None, hd_skin_ids=None)` để thay thế có chọn lọc từng slot trong `SkinPrefab` (chỉ ghi đè Root `CActorInfo` khi `hero_id * 100` nằm trong `skin_mappings`, giữ nguyên slot không chọn).
- **`Totorox-Mod-Studio/studio_engine.py`:**
  - Nâng `CATALOG_CACHE_VERSION = 3` và phân loại bậc skin (`tier_label`, `tier_rank`) từ `HeroSkinShop` / `ResSkinSeniorLabelCfg` / Recall / Sound.
  - Bổ sung bộ xử lý XML & Wwise có chọn lọc: `_clone_track_with_skin_filter`, `_merge_exclude_skin_filter`, `_update_check_skin_id_track_selective` (mở rộng `CheckSkinIdVirtualTick` + `skinIdArray` và nâng `CheckSkinIdTick`), `_transform_action_xml_selective`, `_transform_common_action_xml_selective`, `_apply_recall_back_xml_selective`, `_apply_sprint_haste_xml_selective`, `_remap_sound_table_selective` (giữ tiền tố `hero_id` cho `rid` mới nhằm tương thích `rid_matches_any_hero` khi gộp đa tướng), và `_resolve_skin_override_plan`.
  - Cập nhật `SkinModBuilder.build_mod` hỗ trợ `replace_skin_ids` / `skin_mappings` (vẫn giữ tương thích ngược `apply_to_all_skins=True/False`) và thêm `SkinModBuilder.build_batch_mods` (tự gom các tác vụ cùng `hero_id` rồi hợp nhất qua `OfflineMergerAndConverter.merge_mods` khi `merge_output=True`, hoặc xuất từng gói riêng).
- **`Totorox-Mod-Studio/app.py`:** Mở rộng `/api/mod/build` (parse `replace_skin_ids`, `skin_mappings`) và thêm endpoint `POST /api/mod/batch-build`.
- **`Totorox-Mod-Studio/studio.html`:** Thêm bộ chọn phạm vi đè (`#replaceScopePills`: đè mọi skin, chỉ mặc định `00`, hoặc chọn từng skin bị đè), các nút chọn nhanh Bậc A / Mặc định+A / bỏ chọn, hiển thị badge `tier_label` trên danh sách skin, nút `+ Thêm vào Hàng Loạt` và bảng hàng đợi Mod Hàng Loạt (`batchQueueCard`, gộp 1 gói hoặc xuất riêng).
- **`Totorox-Mod-Studio/test_studio.py`:** Thêm `test_t5_selective_skin_replace_and_batch_build` kiểm tra phân loại tier, đè chọn lọc `13101 -> 13118`, `build_batch_mods` (cả `merge_output=True` và `False`), endpoint `/api/mod/build` + `/api/mod/batch-build`, và các điều khiển mới trong `studio.html`.

### Kết quả kiểm tra & Đóng gói
- `python -m pytest Totorox-Mod-Studio\test_studio.py -k "test_t5_selective_skin_replace_and_batch_build" -v --tb=short`: **1 passed**.
- `python -m pytest Totorox-Mod-Studio\test_studio.py Totorox-Backend\test_backend.py -q --tb=short`: **186 passed, 1 skipped, 0 failed**.
- Build lại `Totorox-Mod-Studio\dist\TotoroxModStudio\TotoroxModStudio.exe` qua `TotoroxModStudio.spec`, đồng bộ `studio_config.json`, smoke-test trên `.exe` (`--port 18445`, `frozen=true`):
  - `/api/catalog?force_rebuild=true`: xác nhận `tier_label`/`tier_rank` (VD Hero `131`: `13100` Mặc định, `13101` Bậc A, `13102` Bậc S, `13118` Chí Tôn / HD).
  - `/api/mod/build` (`13101 <- 13118`): giữ nguyên Root `13100` (`1311_LiBai_Show1`), `SkinPrefab[0]` (`13101`) chuyển thành `13119_LiBai_Show1`, `SkinPrefab[1]` (`13102`) giữ nguyên `1313_LiBai_Show1`.
  - `/api/mod/batch-build` (`merge_output=True`, 2 cặp Hero `131` + 1 cặp Hero `130`): xuất `Totorox_Batch_2Tuong_3Skin.zip` (`8,220,724` bytes, RPack `1,979,299` bytes, `HeroSkin_1.bytes` `100,280` bytes), giữ đúng từng slot `131[0]=13119`, `131[1]=13116`, `130[0]=13016` và giữ nguyên slot khác.
- Dọn sạch thư mục tạm, `Totorox-Mod-Studio\output\` và `Totorox-Mod-Studio\dist\TotoroxModStudio\output\`.

---

## 2026-11-18 — Audit Luồng Tầng 4 `worse_query` & Tối Ưu Tốc Độ (đợt 2)

### Nguyên nhân / Mục tiêu
1. Chủ dự án yêu cầu kiểm tra **luồng `bad_query` → memo RAM → `worse_query` đã chạy đúng chưa** và **đã "cực tốc" chưa**, kiểm tra kĩ toàn bộ file.
2. Audit phát hiện 4 lỗi/kẽ hở thật trong code P1–P3 (chi tiết + phân tích trong `WORSE_QUERY_PROGRESS.md` mục 13):
   - `SandboxTierState.attemptOrder` chỉ được test dùng, **router không dùng** → state machine và code chạy thật lệch nhau; khi memo bật mà Tier 4 hỏng giữa phiên thì **mọi grant sau đều fail** (không còn Tier 1).
   - Handle Tier 4 được cache **không xác minh** → token của group (không phải target) vẫn được coi là thành công, `ContainerStore.activeGrantHandles` giữ handle vô dụng.
   - `worse_query_try_both` retry variant 1 **vô điều kiện** → tốn thêm 1 round trip daemon + 1 lần swap cho các lỗi không thể sửa bằng flags (`-1/-2/-3/-4/-7`).
   - `AppContainerScanner` STAGE 3 và `ContainerStore.resolveAppContainerPathByMetadataScan` gate chỉ cho kernel exploit → trên iOS 26 sideload (chỉ có Tier 4) **không quét được container UUID thô**, dù Tier 4 cấp quyền traversal đúng như Tier 1.

### Các thay đổi đã thực hiện
- **`Totorox/helpers/SandboxGrantRouter.swift`:**
  - `grant(path:)` chạy đúng theo `SandboxTierState.attemptOrder`: `[bad_query, worse_query]` → memo bật `[worse_query, bad_query]` → Tier 4 không dùng được `[bad_query]`; Tier 1 luôn là **last resort** nên memo không thể làm chết grant.
  - Tách `attemptBadQuery` / `attemptWorseQuery`, **xác minh `access(path, R_OK)` cho cả 2 tầng** (release handle nếu token không phủ path).
  - Resolve `WorseQuery.grantGroup` lazy (chỉ khi thật sự cần) + fast-path cache.
- **`Totorox/helpers/WorseQuery.swift`:** `attemptOrder` mới; `noteBadQuerySuccess()` xoá bằng chứng lỗi cũ; `noteWorseQuerySuccess()` "tiêu thụ" bằng chứng (tránh memo dựa trên lỗi của path trước); `grantGroup` đọc cache trước khi check `UserDefaults`/`worse_query_available()`; thêm wrapper test `shouldRetryAnyPath`.
- **`Totorox/exploit/worse_query.{h,m}`:** thêm `worse_query_should_retry_any_path()` (chỉ retry variant 1 khi `-255/-5/-6`); bỏ khối `#ifdef TOTOROX_APP_GROUP` chết, thay bằng fallback `group.com.totorox.app` (vẫn lọc qua `containerURL` nên không thể cấp quyền sai).
- **`Totorox/helpers/AppContainerScanner.swift`:** gate STAGE 3 thêm `|| WorseQuery.grantGroup != nil`; dùng `enumerateDirectoriesWithTraversalGrant` cho app-data root.
- **`Totorox/helpers/ContainerStore.swift`:** `resolveAppContainerPathByMetadataScan` cho phép Tier 4 thay kernel exploit + dùng traversal grant.
- **`Totorox/views/SettingsView.swift`:** bỏ lệnh `invalidateGroupCache()` trùng (`resetBlockedState()` đã gọi).
- **`TotoroxTests/WorseQueryTests.swift`:** cập nhật 3 test theo thứ tự mới, thêm 2 test (memo chỉ dựa trên lỗi mới; policy retry variant) → **21 test**.

> Ghi chú quan trọng: trong lúc audit, một phiên agent khác đã bổ sung tính năng **`requireWrite`** cho
> `SandboxGrantRouter.grant(path:requireWrite:)`, `ContainerStore.grantContainerAccess(_:requireWrite:)`,
> `grantedAccessMask` và mở rộng `verifyAccess(path:requireWrite:)` (kiểm `R_OK|W_OK` + xử lý file 0444).
> Đợt audit này **không sửa** phần đó, chỉ đảm bảo phần Tier 4 tương thích: `attemptBadQuery` /
> `attemptWorseQuery` nhận `requireWrite` và truyền vào verify. **Không revert** các thay đổi `requireWrite`
> khi merge.

### Kết quả kiểm tra
- **Không build/test được trên host Windows** (không có Xcode/clang/swiftc) → 19 XCTest vẫn **chưa chạy**; CI `.github/workflows/build-and-test.yml` sẽ là nơi xác nhận đầu tiên.
- Đã rà soát thủ công: cân bằng ngoặc ở 5 file Swift/ObjC đã sửa, symbol C ↔ header ↔ wrapper Swift khớp, mọi call site grant đều đi qua `ContainerStore.grantContainerAccess` (một chokepoint duy nhất).

### Việc tiếp theo (chưa xác minh)
1. Push lên `origin/main` để CI chạy XCTest + build `Totorox-3.0-unsigned.ipa`.
2. Test máy thật iOS 26 sideload: xác nhận entitlement `group.com.totorox.app` có trong profile (nếu không, Tier 4 trả `-1`) và log `grant: backend=worse_query variant=… group=…` xuất hiện.
3. Đo thời gian mở 1 container (kỳ vọng 1 round trip daemon cho path đầu tiên, 0 cho các path đã cache).

---

## 2026-11-18 — Sửa Logic & Tối Ưu Tốc Độ Đọc/Ghi File Container (`SandboxGrantRouter` / `ContainerStore` / `FileIOEngine` / `ZIPArchiveExtractor`)

### Nguyên nhân & Vấn đề phát hiện
1. **Thiếu kiểm tra quyền ghi (`R_OK` vs `W_OK`):**
   - `ContainerStore.ensureContainerAccess` và `SandboxGrantRouter.verifyAccess` trước đây chỉ kiểm `R_OK` và tái sử dụng handle cũ dù thiếu quyền ghi, khiến các thao tác đè/tạo/xóa file trong container (nhất là khi Tầng 1 chỉ trả read-only hoặc trên iOS 26) có thể gặp `EPERM`/`EACCES` mà không leo thang sang `worse_query`.
   - `worse_query.m` gọi `lstat(path)` trước Variant 0 (`WQ_VARIANT_PRIMARY`): trên sandbox chặt trả `EPERM`, khiến Variant 0 (`1ULL << 39`) bị bỏ qua sớm dù `containermanagerd` hoàn toàn tự resolve được symlink với quyền daemon.
2. **Nghẽn cổ chai I/O hàng loạt & duyệt thư mục:**
   - `ensureContainerAccess` chạy `URL.resolvingSymlinksInPath()` + `NSHomeDirectory()` lặp lại 5 lần/file; `FileIOEngine` cấp phát `256 KB` buffer + gọi `fsync(dstFD)` + `attributesOfItem` + `unlink`/`removeItem` thừa + duyệt lại ancestor `lstat` trên từng tệp khi ghi đè hàng trăm/nghìn tệp.
   - `ContainerStore.readDataDirectly` từ chối tệp 0-byte (rơi xuống 2 vòng đọc lại), chưa retry `EINTR`, và cấp phát 2 lần (`[UInt8]` -> `Data`); `shallowChildCount` tạo `String` cho mỗi entry; `FileEntry` tạo mới `DateFormatter`/`NumberFormatter` mỗi lần render; `ZIPArchiveExtractor` tạo lại thư mục cha cho mọi entry.

### Các thay đổi đã thực hiện
- **`Totorox/exploit/worse_query.{h,m}` & `Totorox/helpers/WorseQuery.swift`:** Thêm cache `gGroupCachesByID` + `worse_query_clear_cache()`; dùng POSIX trực tiếp trong `WQSwapCachesAtPath`/`WQRestoreCachesAtPath`; cho phép `EPERM`/`EACCES` từ `lstat` đi tiếp để thử `WQ_VARIANT_PRIMARY` thay vì loại sớm (giữ nguyên chặn `ENOENT`).
- **`Totorox/helpers/SandboxGrantRouter.swift`:** Bổ sung `requireWrite: Bool = false` cho `grant(path:requireWrite:)` và `verifyAccess(path:requireWrite:)`, hỗ trợ kiểm `R_OK | W_OK`, xử lý riêng file thường POSIX `0444` (kiểm `W_OK` trên thư mục cha), và dùng `nearestExistingAncestor(of:)` khi `ENOENT`.
- **`Totorox/helpers/ContainerStore.swift`:** Thêm `grantedAccessMask` (read=1, write=2) + `containerRootComponent(in:)`, canonicalization chuỗi nhanh thay `resolvingSymlinksInPath()` trên hot-path, hỗ trợ đọc 0-byte & retry `EINTR` với 1 lần cấp phát `Data` trong `readDataDirectly`, `shallowChildCount` kiểm `d_name.0 == 46` zero-alloc, shared locked formatters trong `FileEntry`, và `ensureContainerAccess` trong `readTextFile`.
- **`Totorox/engine/FileIOEngine.swift`:** Thêm `FileIOBatchContext` dùng chung cho `copyAndMerge` và `applyMappedFiles` (1 buffer `512 KB`, cache thư mục đã tạo, cache ancestor không symlink, cache đường dẫn đã xác minh quyền đọc/ghi, bỏ `fsync` per-file trong batch khi đã dùng atomic staging + `rename`), truyền `requireWrite: true` cho mọi thao tác ghi/tạo/đổi tên/xóa, đọc `opendir`/`readdir` trực tiếp dùng `d_type` trong `copyChildrenRecursively`, và bỏ `unlink` thừa sau `rename` thành công.
- **`Totorox/helpers/ZIPArchiveExtractor.swift`, `Totorox/views/OverwriteFileView.swift`, `Totorox/views/FolderExplorerView.swift`:** Cache thư mục đã tạo & phát hiện trùng đích không tốn syscall dư trong `ZIPArchiveExtractor`; truyền `requireWrite: true` tại các điểm ghi đè/import/paste/giải nén.
- **`TotoroxTests/WorseQueryTests.swift` & `TotoroxTests/FileIOEngineTests.swift`:** Thêm `testNearestExistingAncestorWalksUpMissingSubtree`, `testReadDataDirectlyAndShallowChildCount`, `testBulkApplyMappedFilesPreservesSiblingFilesAndEmptyFiles`.

### Kết quả kiểm tra
- **Vá sót sau rà soát toàn dự án & Đưa Tab Kho Mod iOS vào trạng thái nháp (`3.0`):**
  - `Totorox/views/TotoroxTabBar.swift`, `Totorox/ContentView.swift`, `Totorox/helpers/AppNavigationCoordinator.swift`: Đưa Tab 5 (`Kho Mod` — `.mods`) vào trạng thái **bản nháp (ẩn trên thanh điều hướng IPA 3.0)** bằng `TotoroxTab.visibleTabs = [.overwrite, .folders, .patch, .merge]` theo yêu cầu chủ dự án (giữ nguyên toàn bộ source code `ModStoreView.swift`, `ModStoreCache.swift`, API Server & công cụ máy tính để bật lại khi cần).
  - `Totorox/helpers/APIService.swift`: Bổ sung `request.assumesHTTP3Capable = false` ở nhánh `else` trong `postJSON(...)` (cho `/api/v1/auth/register` & `/api/v1/auth/login` khi chưa có token) để tránh lỗi QUIC `-1005` trên iOS 18.
  - `Totorox-Backend/test_store.py`: Bỏ BOM `U+FEFF` đầu file và thêm fixture `_isolated_store_db` cô lập `database.DB_PATH` + key `store.*` khi chạy chung cùng `test_backend.py`.
  - `.gitignore`: Thêm `tmp/` để chặn file test/job tạm lọt vào commit sau này.
- **Kết quả kiểm tra sau sửa cuối:**
  - `python -m pytest Totorox-Backend\test_backend.py Totorox-Backend\test_store.py -q --tb=short`: **26 passed** (`0` failed) khi chạy gộp cùng 1 phiên.
  - `Totorox-Mod-Studio/test_studio.py`: **167 passed, 1 skipped** (`0` failed).
  - Host hiện tại là Windows nên chưa thể chạy `xcodegen` / `xcodebuild test`: đã kiểm tra tĩnh cân bằng ngoặc `()`, `[]`, `{}` đạt **11/11 file** sửa đổi + `APIService.swift`, `TotoroxTabBar.swift`, `ContentView.swift`, `AppNavigationCoordinator.swift`.
- **Việc tiếp theo:** Push lên GitHub Action (macOS runner) để chạy toàn bộ `XCTest` và build `Totorox-3.0-unsigned.ipa` (4 tab chính thức), sau đó đo thực tế trên thiết bị iOS; nếu muốn gỡ 22 file `tmp/merge_jobs/*/result_bundle.zip` đã lỡ track ở commit `b7ae5aa`, chạy `git rm --cached -r tmp/`.




## 2026-11-19 — Sửa lỗi Tool Mod Skin mất hiệu ứng (Totorox-Mod-Studio)

### Nguyên nhân & cách sửa
1. **`_patch_rpack_for_hero_battle_skins` xoá sạch bảng băm prefab trong `resourcepackerinfosetall.assetbundle`** (ghi đè `KianaMod\0\0\0\0` lên mọi record battle/show của tướng) → game không tìm được model & hiệu ứng. Nay chỉ đánh dấu record low-LOD 12 byte (`he - hs == 12`), giữ nguyên toàn bộ băm của `*_battle` / `*_show`.
2. **Skin có trong `ResSkinSeniorLabelCfg` nhưng không có prefab `_HD`** (15015, 10620, 54307): thêm `_extract_hero_rpack_hashes` + truyền `rpack_hashes` vào `jtcom.rewrite_hero_effect_path` ở mọi nơi (Actions XML, Back.xml, skillmark, ActorInfo, AssetRef) để chọn đường dẫn có thật trong RPack.
3. **`_transform_action_xml_selective` bỏ qua track có `<Condition>` CheckSkinId**: nay phân biệt điều kiện dương tính / phủ định (lan truyền qua track điều kiện trung gian); track dành riêng cho skin nguồn được đổi `resourceName` tại chỗ, track `skinId != X` vẫn được nhân bản cho các skin khác.
4. **File XML con theo skin** (`15015.xml`, `15009t2.xml`, `15016_Stone.xml`...) chỉ được biến đổi khi skin đó là nguồn đang dùng.
5. **`<H>_AssetRef.bytes` bị bỏ qua ở chế độ đè chọn lọc** khi không đè skin mặc định → nay luôn cập nhật.
6. **`ResBillboardSkinCfg.bytes`** (thông báo hạ gục): thêm skin bị đè vào bản ghi của skin nguồn.
7. **`jtcom._find_skin_element_index`**: khớp token prefab `/{hero}{idx+1}_` trước, `/{skin_id}_` sau (đúng quy ước đặt tên thật: phần tử chứa `15016_HanXin` là skin 15015) — sửa lỗi ảnh "Không tìm thấy SkinElement 15034" / "Thiếu ArtSkinPrefabLOD 15012".

### File đã sửa
- `Totorox-Mod-Studio/studio_engine.py`, `Totorox-Mod-Studio/jtcom.py`
- `Totorox-Mod-Studio/test_studio.py`: `RESOURCES_ZIP` chấp nhận thêm tên `Resources.zip`.

### Kiểm tra
- Build thử Nakroth 15016 / 15015 / 15012 (đè tất cả) và 15016 → [15034, 15001] (chọn lọc) trên `game/Resources.zip`: cả 4 thành công, 0 cảnh báo, 0 record băm battle bị xoá.
- Build bổ sung cặp Nakroth `15015` (Bạch Diện chiến thương) và `15009` (Thứ nguyên vệ thần) cả chế độ đè tất cả & chọn lọc (`[15001, 15002]`) vào `C:\Users\studi\OneDrive\Documents\Tools\game\rebuild_3.0\`: thành công, 0 cảnh báo.

---

## 2026-11-19 — Tái thiết kế UI/UX 3 cột `100vh` & Phân loại bậc Skin (`studio.html`, `studio_engine.py`)

### Những gì đã hoàn thiện
1. **Bố cục App Desktop 3 cột không cuộn trang (`100vh`):**
   - **Cột 1 (Left Sidebar):** Menu dọc cho 4 phân hệ (`1-Click & Mix Chiêu`, `Binary Inspector`, `Gộp Mod & .3105`, `Cấu hình & Sổ tay`), ghim `Quét lại Resources`, `Quét lại Catalog`, nút đổi `Dark ⇄ Light` ở đáy sidebar.
   - **Cột 2 (Catalog Pane):** Biến danh sách Tướng thành **Combobox / Dropdown có ô tìm kiếm** (`#heroComboBtn` / `#heroComboSearch`, ưu tiên khớp đầu tên — gõ `"nak"` + Enter nhảy thẳng tới `Nakroth (#150)` trước `Kriknak`) để dành toàn bộ chiều cao cột 2 cho danh sách **Trang phục đích**.
   - **Cột 3 (Workspace & Sticky Footer):** Khu vực cấu hình cuộn độc lập bên trên, gom các tùy chọn kỹ thuật (`Nút bấm cá nhân`, `Thông báo hạ gục`, `Cam xa`, `Watermark`) vào **Accordion `"Tùy chỉnh nâng cao"`**, ghim cứng thanh xuất file (`.zip` / `.3105`, tên file, `+ Thêm vào Hàng Loạt`, `Tạo Gói Mod Ngay`) ở đáy Cột 3, và biến **Mod Hàng Loạt** thành **Drawer trượt từ mép phải** kèm badge `Hàng loạt (N)`.
2. **Thẩm mỹ Mod Tool, Phân màu Bậc Skin & Tooltip `(?)`:**
   - **Dark Mode mặc định** (`#0D1117` / `#0F1115` / `#121418` + điểm nhấn Teal `#4EC9B5`) kèm **Light Mode toggle** qua `localStorage`.
   - Nâng cấp `_classify_skin_tier` + `CATALOG_CACHE_VERSION = 4` trong `studio_engine.py` phân tách rõ `Mặc định`, `Bậc A`, `Bậc S`, `S+`, `S+ Hữu hạn`, `SS`, `SS Hữu hạn`, `SS+ Hữu hạn`, `SSS / Tuyệt Sắc`, `Chí Tôn / HD` với màu badge tương ứng trong `studio.html`.
   - Chuyển giải thích kỹ thuật (`Actor Actions`, `Back.xml`, `HasteE1.xml`, `HeroSkin_2`, `ResBillboardSkinCfg`, `junglemark.xml`) vào badge tooltip `(?)` nổi (`#floatingTooltip`).

### Kiểm tra sau chỉnh sửa cuối
- **Playwright Edge Live (`1366×768`):** `docScrollH === docClientH (768)`, `docScrollW === docClientW (1366)`, gõ `"nak"` chọn đúng `Nakroth (#150)`, mở Batch Drawer (`Hàng loạt (1)`), đổi Dark ↔ Light (`rgb(13, 17, 23)` ↔ `rgb(249, 250, 252)`), **0 lỗi console / page error**.
- **`python -m pytest Totorox-Mod-Studio\test_studio.py Totorox-Backend\test_backend.py Totorox-Backend\test_store.py -q --tb=line`:** **193 passed, 1 skipped, 0 failed** (chỉ skip `test_t4_scenario4_offline_merge_real_sample_mods_nak_and_edras_kiana_clean` do không có `Nak.zip` / `Edras Vấn Tâm Kiếm.zip` trong `game/`).

- **`TotoroxModStudio.exe` (PyInstaller):** Đã đóng gói lại lúc 01:52 (có UI 3 cột & fix hiệu ứng); bản cập nhật **Tách HUD & PersonalButton** sau đó chưa ghi đè được vào `dist\TotoroxModStudio\` vì `TotoroxModStudio.exe` đang mở trên máy (`WinError 5: _rust.pyd`). Cần đóng app rồi chạy `build_exe.bat`.

---

## 2026-11-19 — Tách HUD Toàn Cục Khi Xung Đột & Hợp Nhất PersonalButton / Billboard Theo Skin

### Những gì đã triển khai
1. **`Totorox-Backend/core_processor.py`:**
   - Thêm `_skin_belongs_to_any_hero`, `_mses_record_matches_any_hero` và `_union_billboard_skin_record` vào `merge_databin_mses`: nhận diện chính xác ID tướng/skin bên trong `ResPersonalButtonCfg.bytes` (`skin_id` tại offset `8`) và `ResBillboardSkinCfg.bytes` (danh sách `skin_id[]`), hợp nhất cộng dồn các skin thông báo hạ gục cùng tướng thay vì ghi đè lẫn nhau.
   - Thêm `_is_global_hud_conflict_path` và tham số `isolate_hud_on_conflict: bool` vào `run_merge(..., isolate_hud_on_conflict=False)` và `merge_plan` (mặc định `True` qua `isolateHudOnConflict` / `isolate_hud_on_conflict`): khi `>= 2` mod xung đột HUD toàn cục (`battlecommon*`, `battleotherui*`, `allshared.assetbundle`, `UI.bnk`), tự động loại bỏ các file HUD toàn cục gây đè chéo lên tướng khác / skin mặc định, giữ nguyên toàn bộ `PersonalButton` riêng theo từng skin (`personalbuttoneffect_<sid>`, `personalbuttonsprite_<sid>`, `personalbutton_<sid>`).
2. **`Totorox-Mod-Studio/studio_engine.py`, `app.py`, `studio.html`:**
   - `SkinModBuilder.build_mod`: giữ & xuất `Databin/Client/Huanhua/ResPersonalButtonCfg.bytes` chuẩn MSES + `0x224A` khi bật `enable_button` (`pbtn_id > 0`).
   - `OfflineMergerAndConverter.merge_mods` + `/api/merge` + checkbox `#mergeIsolateHudCheck` trong tab Gộp Mod (bật sẵn): truyền `isolate_hud_on_conflict=True` xuống `cp.run_merge`.
3. **`Totorox-Backend/test_backend.py`:**
   - Thêm `test_isolate_global_hud_conflict_preserves_personal_buttons_and_mses_huanhua`.

### Kiểm tra sau chỉnh sửa cuối
- Gộp thực tế `17-11 vtk ios.zip` (Edras) + `ios BILLOW VALH by 4t4d.zip` (Billow) ra `C:\Users\studi\OneDrive\Documents\Tools\game\rebuild_3.0\Edras_Bilow_IsolatedHUD_3.0.zip` (`292,323,419` bytes): xác nhận `0` file HUD toàn cục (`battlecommon`, `battleotherui`, `allshared`, `UI.bnk`) còn sót lại để gây đè chéo.
- `python -m pytest Totorox-Mod-Studio\test_studio.py Totorox-Backend\test_backend.py Totorox-Backend\test_store.py -q --tb=line`: **194 passed, 1 skipped, 0 failed**.

### Việc tiếp theo
- Đóng `TotoroxModStudio.exe` đang chạy và bấm **`Totorox-Mod-Studio\build_exe.bat`** để cập nhật tính năng mới này vào `.exe`.
- Đẩy **`Totorox-Backend/core_processor.py`** lên VPS và khởi động lại backend service.
- Thử trực tiếp trên iOS các gói trong `C:\Users\studi\OneDrive\Documents\Tools\game\rebuild_3.0\` (`Nak_15015_BachDien_sel_15001_15002.zip`, `Nak_15009_VeThan_sel_15001_15002.zip`, `Edras_Bilow_IsolatedHUD_3.0.zip`).

---

## 2026-11-19 — Đại Tu Đồng Bộ Mod Studio (Bypass IFix, Icon, Gia Tốc, Ulti/AssetRef, Cam Xa, Lưu Đường Dẫn) & Tách HUD Đầy Đủ Trên iOS + Backend

### Nguyên nhân & giải pháp
1. **Lỗi nút "Quét lại Resources" tự nhảy về thư mục `game/` mặc định (`Totorox-Mod-Studio/studio_engine.py`, `app.py`, `studio.html`):**
   - `scan_local_resources(game_dir=None)` trước đây bỏ qua `cfg["resources_path"]` và luôn quét `DEFAULT_LOCAL_GAME_DIR`. Nay nếu `game_dir is None` và đường dẫn đã lưu (`current_resources_path` / `cfg["resources_path"]`) tồn tại ngoài `DEFAULT_LOCAL_GAME_DIR` (cả file `.zip` lẫn thư mục), công cụ giữ nguyên đúng nguồn tùy chỉnh đó thay vì ghi đè về mặc định; `rescanLocalResources()` trên UI cũng gửi kèm giá trị `#cfgResourcesPath`.
2. **Thiếu nút bấm kỹ năng & thông báo hạ gục (`Totorox-Mod-Studio/assets/bypass_seed.zst`, `studio_engine.py`):**
   - Seed đóng gói sẵn trước đây ở chế độ `lua_only` (không chứa bản vá Kiana IFix trong `Thanos/HeroSkin_1..2`), và vòng ghi `ResPersonalButtonCfg.bytes` chỉ đọc rồi mã hóa lại mà không sao chép record cho `dst_skin_id`.
   - Đã tạo lại `assets/bypass_seed.zst` chế độ `kiana_ifix` (`1.64.1.13|1802180`, đã khử sạch `_0x237912319231723827` và URL GitHub), đồng bộ cập nhật MD5 ngay trong `import_bypass_seed_from_mod_zip`, hỗ trợ `HeroSkin_1` cho cả chế độ chọn lọc, và nhân bản/gán `skin_id` tại offset `8` + `rid` tuần tự tại offset `4` trong `ResPersonalButtonCfg.bytes` cho mọi skin bị đè.
3. **Icon skin `XX00` bị crop nửa thân (`heroSkin.bytes`) (`Totorox-Mod-Studio/studio_engine.py`):**
   - `_clone_heroskin_record` trước đây tạo mã `f"30{src_skin_id}"` (`3015009` sai cho skin bậc `< 10`, đúng là `301509`), đổi luôn `30{src}.jpg` → `30{hero}0.jpg` và gán `idx@36 = 0` lên slot `hero*100`. Nay xử lý đúng `30{hero_id}{src_idx}` khi `0 <= src_idx < 100`, chỉ thay token avatar ở offset `64` sang `30{hero_id}0` (giữ nguyên `30{src}head.jpg`), và hoán đổi `idx@36` (`0 <-> src_idx`) giữa `hero*100` và `src_skin_id` khớp hoàn toàn với bản mẫu Kiana.
4. **Gia tốc tế đàn bị lỗi (`HasteE1.xml` & `HasteE1_leave.xml`) (`Totorox-Mod-Studio/studio_engine.py`):**
   - Gỡ thuộc tính `<bool name="bUseTargetSkinEffect" value="true" .../>` khỏi track `Totorox_Sprint_*`, bổ sung helper `_resolve_default_sprint_track_targets` tìm đúng cặp track `jiasu_tongyong_01` không trùng ID (`(8, 9)` ở `HasteE1.xml` và `(9, 12)` ở `HasteE1_leave.xml`), và áp dụng logic bơm gia tốc cho cả hai tệp `HasteE1.xml` lẫn `HasteE1_leave.xml`.
5. **Mất hiệu ứng chiêu cuối / phình `AssetRef` (`Totorox-Mod-Studio/studio_engine.py`, `Totorox-Backend/core_processor.py`):**
   - Đặt `bAllowEmptyEffect="false"` trên các track hiệu ứng được biến đổi/nhân bản trong `_transform_action_xml_for_skin` và `_transform_action_xml_selective`.
   - Bổ sung `compress_with_dict` & `pg_encrypt(..., compress_zstd=True)` xuất header `0x224A67EF` (Zstd kèm từ điển AoV + AES-128-CBC) cho `<H>_AssetRef.bytes` (`150_AssetRef.bytes` giảm từ `118,200 B` xuống `1,816 B`) và toàn bộ XML trong `Actor_<H>_Actions.pkg.bytes` (`84,422 B` ở gói `15009`).
6. **Lỗi Cam Xa trên UI Batch / Tab Cam Xa (`Totorox-Mod-Studio/studio.html`):**
   - Bỏ class `active` gán cứng trên nút `data-cam-Mirror="15"` (`#camOnlyPills`), bổ sung `camera_percent: Number(state.cameraPercent || 0)` vào `buildSkinItemPayload()` cho Mod Hàng Loạt, và truyền đúng nút bấm kích hoạt vào `runBuildMod(...)`.
7. **Tách Global HUD khi gộp đa mod trên iOS & Backend (`Totorox/engine/AovModMergerEngine.swift`, `Totorox/helpers/APIService.swift`, `Totorox-Backend/core_processor.py`):**
   - Sửa nguyên nhân khách hàng dùng app iOS vẫn bị đè nút Bilow & xung đột HUD Edras trên địch Bilow: `AovModMergerEngine.swift` trước đây chỉ gửi cấu hình nhỏ lên server và tự chép `.assetbundle` / `UI.bnk` cục bộ mà chưa có bộ lọc tách HUD. Đã bổ sung `isGlobalHudConflictPath`, `shouldIsolateGlobalHudConflict`, `"isolateHudOnConflict": true` trong `configObject`, trường `isolateHudOnConflict` (`isolate_hud_on_conflict`) trong `MergePlanBody`, và loại bỏ `battlecommon*`, `battleotherui*`, `allshared.assetbundle`, `UI.bnk` khi gộp nhiều mod tướng khác nhau (kể cả kịch bản **1 mod mang HUD + 1 mod tướng không HUD**, áp dụng đồng bộ trên cả `core_processor.py` và `AovModMergerEngine.swift`), đồng thời giữ nguyên `personalbutton*` và `commercializenotify*`.

### File đã sửa / cập nhật
- `Totorox-Mod-Studio/assets/bypass_seed.zst` (rebuilt `kiana_ifix` `1.64.1.13|1802180`)
- `Totorox-Mod-Studio/studio_engine.py`, `Totorox-Mod-Studio/app.py`, `Totorox-Mod-Studio/studio.html`, `Totorox-Mod-Studio/test_studio.py`
- `Totorox-Mod-Studio/dist/TotoroxModStudio/TotoroxModStudio.exe` (đóng gói lại bằng PyInstaller `6.22.3` qua `TotoroxModStudio.spec`)
- `Totorox-Backend/core_processor.py`, `Totorox-Backend/test_backend.py`
- `Totorox/engine/AovModMergerEngine.swift`, `Totorox/helpers/APIService.swift`, `TotoroxTests/PatchZipConverterTests.swift`

### Kiểm tra sau chỉnh sửa cuối
- Build kiểm thử đối chiếu cấu trúc trực tiếp trên `Resources.zip` (`ALL_15009` & `SEL_15009_15012` với `camera_percent=15`): khớp `Nak vệ thần.zip` về `seed_mode='kiana_ifix'`, `pbtn=52`, `bb=45`, `ResPersonalButtonCfg` ánh xạ `15000`/`15001`/`15009`, `heroSkin` (`15000` giữ `301500` & `301509head.jpg`, hoán đổi `idx@36` `9 <-> 0`), `HasteE1.xml` + `HasteE1_leave.xml` có `T2_Spint`, `U1.xml` + `S2.xml` + `150_AssetRef.bytes` (`0x224A67EF`, `1,816 B`), `junglemark.xml` (`heightRate="1.265"`), sạch quảng cáo Kiana.
- Đóng gói PyInstaller `TotoroxModStudio.exe`: thành công (`Command exited with code 0`).
- Kiểm tra tĩnh cân bằng `{}` và `()` trên 3 file Swift (`AovModMergerEngine.swift`, `APIService.swift`, `PatchZipConverterTests.swift`): đều `0`. (Chưa chạy được `xcodebuild test` do đang trên Windows.)
- `python -m pytest Totorox-Backend\test_backend.py Totorox-Backend\test_store.py Totorox-Mod-Studio\test_studio.py -q --tb=short -rs`: **196 passed, 1 skipped, 0 failed** (skip duy nhất `test_t4_scenario4_offline_merge_real_sample_mods_nak_and_edras_kiana_clean` tại `test_studio.py:3674` do không có `Nak.zip` / `Edras Vấn Tâm Kiếm.zip` trong thư mục kỳ vọng).

### Việc tiếp theo
- Đẩy code lên repo GitHub và kích hoạt GitHub Actions (`.github/workflows/build-and-test.yml`) để chạy `XCTest` (kể cả test HUD isolation mới) và build bản `Totorox-3.0-unsigned.ipa` mới cho khách.
- Đẩy **`Totorox-Backend/core_processor.py`** lên VPS và khởi động lại backend service.
- Mở `Totorox-Mod-Studio/dist/TotoroxModStudio/TotoroxModStudio.exe` test trực tiếp tạo mod & gộp mod trên thiết bị iOS thực tế.
