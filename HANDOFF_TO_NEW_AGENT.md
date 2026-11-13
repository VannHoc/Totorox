# Handoff — Totorox Client iOS Phần 4

Trạng thái bàn giao tính đến 2026-11-13. Phần 3 đã hoàn tất và được kiểm chứng lại.

## Mục tiêu
Triển khai trọn vẹn phần client iOS trong `Totorox/` sau khi backend (`Totorox-Backend/`) đã sẵn sàng.
Điểm neo là `main.py` và `SERVER_BLUEPRINT.md` trong `Totorox-Backend/`.

## Trạng thái đã kiểm chứng (Phần 4)
1. Mô hình **hybrid** đã chốt cho cả convert và merge:
   - `convert-header to_zip`: server chỉ sinh content key + envelope params (PBKDF2/AES-GCM nếu có password);
     client (`Totorox/engine/PatchZipConverter.swift`) tự seal payload PLIST và build envelope `.3105` local
     (`sealPayload` + `buildEnvelope`, AAD `3105PATCH/v{schema}/payload/{uuid}`, nonce 12 byte zero).
   - `convert-header from_zip`: client gửi envelope không payload, server mở key, client tự giải mã payload.
   - `merge-plan`: client upload `config_bundle.zip` (layout `mod_<idx>/Resources/<ver>/...`, chỉ file nhẹ),
     server chạy pipeline (UnityFS/RP/RV/XML/MSES/HeroSkin) và trả `zip_bytes_b64` chứa
     `merge_plan.json`, `config.json`, `result.zip`; client ghép asset nặng local
     (`AovModMergerEngine.swift` — bước hybrid ghép `prepared.first?.heavyEntries`).
2. `Totorox-Backend/_selftest_tmp.py` chạy xanh toàn bộ (`python _selftest_tmp.py`):
   - Đã cập nhật cho hợp đồng hybrid: `build_local_package()` trong self-test tái tạo envelope
     giống hệt flow Swift (dùng `content_key_b64`, `kdf_*`, `wrapped_content_key_b64`; KHÔNG còn
     `package_bytes_b64` từ server).
   - Chạy cả 3 nhóm: convert_header round-trip (plist + password + zip-patch + manifest-only),
     merge_plan config_bundle (CommonActions XML merge, MSES, HeroSkin_1), và HTTP routes thật qua TestClient.
3. CI GitHub Actions pass (run cuối `fix: keep hybrid helpers inside converter scope`, 2026-11-13).
   `PatchPackageCodec.swift` không còn tồn tại; không có stub/TODO/fatalError trong code Swift.
4. Dọn depot: đã bỏ khỏi git và xóa `Totorox-engine-jgdecrypted.txt`, `Totorox-engine-jgencrypted.txt`,
   `ion to 1.2…` (rác terminal); `.gitignore` bổ sung `__pycache__/`, `*.pyc`, các file debris nói trên.
   `Totorox-Backend/` vốn đã bị ignore cả thư mục (chỉ chạy local).
   Đã dọn `Totorox-Backend/tmp/` và `__pycache__/` trên đĩa.

## Kiến trúc nghiệp đã biết
- `AovModMergerEngine.inspectModArchive` đọc metadata nhẹ local (parse zip, regex `hero[_-]?\d{3,4}`).
- `isServerConfigPath` (CommonActions/Databin/Thanos) quyết định file nào lên server.
- `makeMergedOutputFilename` sinh tên `AOV_Mod_<N>Heroes_<hash4>.zip`.

## Nhắc nhở cho agent sau
- Khi chạy backend self-test ở môi trường mới: cần `pip install fastapi uvicorn slowapi httpx cryptography`
  (xem `requirements.txt`); test dùng `fastapi.testclient` nên cần `httpx`.
- `APIService.defaultBaseURL` là tunnel trycloudflare tạm — đổi theo môi trường kiểm thử
  (trong app: ẩn sau triple-tap logo ở `ActivationView`).
- `licenses.db` chỉ nằm trên đĩa (đã ignore `*.db` + cả thư mục backend) — không commit DB license thật.
- Nếu đổi hợp đồng `convert-header` (thêm/bỏ field), cập nhật đồng bộ: `core_processor.py::convert_header`,
  `APIService.swift::ConvertHeaderResponse`, và `build_local_package()` trong `_selftest_tmp.py`.
- Lưu ý: AOV/patch engine này chứa kernel exploit + đổi file trong sandbox app game (kexploit_opa334,
  sandbox_escape, wallpaper_zip...). Chỉ dùng cho mục đích research/nghiên cứu kỹ thuật.

## Lưu ý biên dịch
- Build iOS qua `project.yml` (XcodeGen) hoặc `scripts/generate_pbxproj.py`; CI sinh unsigned IPA.
- `AovModMergerEngine.swift` giữ public signature cũ; logic hybrid gộp đã hoàn chỉnh, không còn placeholder.
