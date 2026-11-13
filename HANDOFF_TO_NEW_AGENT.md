# Handoff — Totorox Client iOS Phần 3

## Mục tiêu
Triển khai trọn vẹn phần client iOS trong `Totorox/` sau khi backend (`Totorox-Backend/`) đã sẵn sàng.
Điểm trái đất là `main.py` và `SERVER_BLUEPRINT.md` trong `Totorox-Backend/`.

## Đã làm
1. `helpers/DeviceIDManager.swift` — sinh UUID cố định, ưu tiên `/var/mobile/Library/Preferences/.totorox_device_id`, fallback `UserDefaults`.
2. `helpers/APIService.swift` — timeout 60s, 2 header `X-License-Key` + `X-HWID`, hỗ trợ 4 endpoint:
   - POST /api/v1/verify
   - POST /api/v1/activate
   - POST /api/v1/convert-header (multipart: mode, password?, file?)
   - POST /api/v1/merge-plan (multipart: file?, config_json?)
3. `helpers/LicenseManager.swift` — status license, activate, refresh, deactivate.
4. `views/ActivationView.swift` — màn hình kích hoạt.
5. `App.swift` — refresh license ngay từ init, refresh khi scenePhase .active.
6. `ContentView.swift` — nếu `license.status.isActive == false` thì chỉ hiển thị `ActivationView`, ngược lại hiển thị main app.
7. `PatchZipConverter.swift` — xóa `PatchPackageCodec.swift` khỏi app, convert .3105 <-> zip qua `/api/v1/convert-header` (mọi crypto nằm ở server). `to_zip` gửi nguyên `PatchProject` dạng PLIST binary (có `replacementData`) rồi xác minh lại gói trả về (số rule / tên / tổng byte payload) trước khi ghi đĩa.
8. `AovModMergerEngine.swift` — giữ `inspectModArchive` local; `mergeModArchives` gửi config nhẹ lên `/api/v1/merge-plan`, nhận về zip + merge_plan.json, sau đó dùng `FileIOEngine` thực thi copy/đè asset nặng local.

## Nhắc nhở cho agent sau
- Backend đã phía server hoàn thiện: `merge_plan` đọc trực tiếp `config_bundle.zip` (layout `mod_<idx>/Resources/<ver>/...`, server tự bóc prefix thư mục gốc do `ZIPArchiveWriter` thêm) và chạy đủ pipeline trên các file cấu hình nhẹ; `to_zip` dựng envelope thật từ PLIST/ZIP/manifest client gửi. Kiểm chứng bằng `Totorox-Backend/_selftest_tmp.py` (chạy `python _selftest_tmp.py`).
- `AovModMergerEngine.swift` đã có phần thi công local: giải nén `result.zip` server trả rồi copy/đè asset nặng bằng `FileIOEngine`, và bước 5b hợp nhất `merge_plan.files` với toàn bộ path local để không mất asset nặng.
- Cần kiểm tra lại scope `FileIOEngine` có method phù hợp để copy/đè file từ zip nhận về vào output staging không.
- Cần đảm bảo `AppContainerScanner`, `ZIPArchiveExtractor`, `ZIPArchiveWriter`, `KeychainHelper` vẫn được import đúng nơi dùng.
- Build trên GitHub Actions: đảm bảo không còn `PatchPackageCodec.swift` trong bản build, kiểm tra warning/error liên quan đến `AnyCodable` nếu có.
- Có thể cần chỉnh `Bundle Identifier`, cơ chế lưu device ID, và URL server (`APIService.defaultBaseURL`) cho phù hợp môi trường kiểm thử.

## Lưu ý biên dịch
- File `PatchZipConverter.swift` đã tạo mới; nếu có file cũ cùng tên trong `Totorox-engine/`, cần xóa hoặc di chuyển tránh trùng.
- `AovModMergerEngine.swift` đã viết lại nhưng giữ public signature cũ; cần kiểm tra lại các private method có còn thiếu logic internal không (đoạn handoff này giữ lại skeleton để không gãy compilation, nhưng một số method chỉ trả giá trị placeholder).
- `ContentView.swift` đã viết lại với conditional license gating; cần kiểm tra lại `App.swift` không còn lưu trạng thái showOnboarding mà chưa kiểm tra license.
