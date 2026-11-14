# Handoff — Totorox Client iOS Phần 5

Trạng thái bàn giao tính đến 2026-11-13 (sau vòng sửa lỗi từ ảnh chụp thiết bị).

## Mục tiêu
Triển khai trọn vẹn phần client iOS trong `Totorox/` sau khi backend (`Totorox-Backend/`) đã sẵn sàng.
Điểm neo là `main.py` và `SERVER_BLUEPRINT.md` trong `Totorox-Backend/`.

## Sửa lỗi trong Phần 5 (quan trọng)

### 1. Lỗi "I/O error: Header/ngữ cảnh vượt quá 15,7 MB" với gói `.3105` 16 MB
Nguyên nhân: `envelopeWithoutPayload` chỉ `removeValue(forKey: "encryptedPayload")` — nếu gói mang
blob lớn ở khoá khác (payload nhúng, preview…), header gửi server vẫn ~16 MB rồi bị chặn bởi
`APIService.maximumUploadBytes` (15 MB).

Đã sửa (`Totorox/engine/PatchZipConverter.swift`):
- `envelopeWithoutPayload` chuyển sang **whitelist** `envelopeMetadataKeys` (`schemaVersion`,
  `packageID`, `isPasswordProtected`, `keyAADVersion`, `keyFingerprint`, `kdfSalt`, `kdfIterations`,
  `wrappedContentKey`, `publicContentKey`). Header luôn chỉ vài trăm byte.
- `inspect(patchData:)` / `inspect(patchURL:)` parse envelope **local** trước (gói ≤ 64 MB đọc trọn),
  chỉ gọi server khi magic không khớp → không còn phụ thuộc giới hạn upload khi chỉ xem metadata.
- `inspect` lấy `keyFingerprint` từ envelope thay vì tự hash content key.

### 2. Lỗi "Yêu cầu hết thời gian chờ" khi gộp 4 gói mod
Hai nguyên nhân độc lập:

a) **Timeout 60 s cho mọi request.** Đã tách trong `APIService.swift`:
   `requestTimeout = 60` (metadata), `mergeTimeout = 300` (merge-plan),
   `timeoutIntervalForResource = 300`. `mergePlan` set `request.timeoutInterval = mergeTimeout`.

b) **Phân loại "file nhẹ" quá rộng.** Điều kiện cũ
   `isServerConfigPath(path) || (fileData.count <= 2MB && !.assetbundle)` đẩy mọi file ≤ 2 MB
   (Lua, texture nhỏ, prefab…) lên server → bundle phình to và server ghi đè sai asset.
   Đã sửa: **chỉ** `isServerConfigPath(path)` lên server.

### 3. `isServerConfigPath` thiếu RP/RV metadata
Server chạy `merge_resource_packer` / `merge_resource_verification` trên
`ResourcePackerInfoSetAll.assetbundle` / `ResourceVerificationInfoSetAll.assetbundle`; client cũ
không gửi hai file này nên asset mới không được đăng ký. Đã thêm vào `isServerConfigPath`.

### 4. Nguy cơ jetsam khi gộp nhiều gói lớn (147 MB × 4)
Đã sửa (`AovModMergerEngine.swift` + `PatchZipConverter.swift`):
- `mergeModArchives` chạy **hai lượt**: lượt 1 chỉ trích file cấu hình nhẹ; lượt 2 đọc lại từng gói
  một rồi ghi thẳng xuống đĩa. RAM đỉnh ~1 gói thay vì cả bộ.
- Thêm `PatchZipConverter.ZipArchiveWriter` — writer ZIP streaming (`add(path:data:)`/`finish()`/`cancel()`),
  chỉ giữ central directory trong RAM. `writeZipArchive(entries:to:)` bọc writer.
- `inspectModArchive` không còn parse ZIP hai lần; có `AovModMergerEngine.summary(url:fileSize:entryNames:)`
  để dựng metadata từ entry names đã có.

### 5. Version Resources không khớp giữa server và client
Server remap `Resources/<ver>/…` về `target_version` (mặc định `1.64.1`), client lại ghép asset nặng
với đường dẫn gốc → asset rơi vào thư mục version cũ và game bỏ qua.
Đã sửa: client gửi `output.resourcesVersion`, và `remapResourceVersion(path:from:to:)` + 
`resolveTargetVersion(_:)` (so sánh theo từng thành phần số) đổi tiền tố asset nặng cho khớp.

### 6. Hạn mức upload backend & quota
`Totorox-Backend/main.py`: `MAX_UPLOAD_BYTES` (convert-header, mặc định **100 MB**) và
`MAX_MERGE_UPLOAD_BYTES` (merge-plan, mặc định **100 MB**) đều đọc từ env
(`TOTOROX_MAX_UPLOAD_BYTES`, `TOTOROX_MAX_MERGE_BYTES`). `Content-Length`, file upload và
`config_json` đều bị chặn ở ngưỡng tương ứng trước khi xử lý.
Client guard `APIService.maximumUploadBytes` / `maximumMergeBundleBytes` cũng đã nâng lên 100 MB.
Quota chuyển từ đếm theo ngày sang **tích lũy** (`used_count`): gói 1 ngày = 5 lượt, 7 ngày = 30,
>= 30 ngày = vô hạn (anti-spam 300/ngày); chỉ trừ khi convert/merge thành công.

## Test đã thêm (`TotoroxTests/PatchZipConverterTests.swift`)
- `testWriteZipArchive_MatchesInMemoryBuilder`, `testWriteZipArchive_ReplacesExistingFile`
- `testEnvelopeWithoutPayload_StripsLargeBlobs` (bảo vệ trực tiếp lỗi 15,7 MB)
- `testEnvelopeWithoutPayload_KeepsPasswordFields`
- `testResolveTargetVersion_PicksHighestAndFallsBack` (1.64.10 > 1.64.1)
- `testRemapResourceVersion_RewritesPrefixOnly`
- `testAovModMerger_ClassifiesServerConfigPaths` đã cập nhật cho RP/RV

`convert-header`/`merge-plan` vẫn không test được offline (cần backend + license key);
các test trên chỉ chạm nhánh local.

## Trạng thái đã kiểm chứng
1. Mô hình **hybrid** giữ nguyên:
   - `convert-header to_zip`: server sinh content key + envelope params; client seal payload local
     (AAD `3105PATCH/v{schema}/payload/{uuid}`, nonce 12 byte zero).
   - `convert-header from_zip`: client gửi envelope **chỉ metadata**, server mở key, client giải mã payload.
   - `merge-plan`: client upload `config_bundle.zip` (chỉ file cấu hình server thật sự merge),
     server trả `zip_bytes_b64`, client ghép asset nặng local + remap version.
2. `python _selftest_tmp.py` (trong `Totorox-Backend/`) xanh toàn bộ 3 nhóm: convert_header
   round-trip (plist/password/zip-patch/manifest-only), merge_plan config_bundle
   (CommonActions XML, MSES, HeroSkin_1), và HTTP routes qua `TestClient`.
3. `PatchPackageCodec.swift` không còn; không có stub/TODO/fatalError trong code Swift.
4. Dọn depot: `.gitignore` có `__pycache__/`, `*.pyc`, `*.db` và các file rác
   (`Totorox-engine-jg*.txt`, `ion to 1.2*`); thư mục `Totorox-Backend/` bị ignore toàn bộ.

## Kiến trúc nghiệp đã biết
- `AovModMergerEngine.inspectModArchive` → `summary(url:fileSize:entryNames:)`, regex `hero[_-]?\d{3,4}`.
- `isServerConfigPath` = `commonactions` | `/databin/` | `/thanos/` | `resourcepackerinfosetall.assetbundle`
  | `resourceverificationinfosetall.assetbundle`.
- `makeMergedOutputFilename` sinh `AOV_Mod_<N>Heroes_<hash4>.zip`.

## Nhắc nhở cho agent sau
- Cần `pip install fastapi uvicorn slowapi httpx cryptography` (xem `requirements.txt`);
  self-test dùng `fastapi.testclient` nên phải có `httpx`.
- CommonActions `.pkg.bytes` là **ZIP lồng bên trong**; muốn test `merge_plan` thủ công phải bọc
  XML trong một ZIP, không đưa bytes thô.
- `APIService.defaultBaseURL` là tunnel trycloudflare tạm — đổi qua UI triple-tap logo ở `ActivationView`.
- Nếu đổi hợp đồng `convert-header`, cập nhật đồng bộ 3 chỗ: `core_processor.py::convert_header`,
  `APIService.swift::ConvertHeaderResponse`, `_selftest_tmp.py::build_local_package`.
- Nếu đổi `isServerConfigPath`, cập nhật cả test `testAovModMerger_ClassifiesServerConfigPaths`
  và `KNOWN_ROOT_DIRS` phía server.
- Lưu ý: engine chứa kernel exploit + đổi file trong sandbox app game — chỉ dùng cho research.

## Lưu ý biên dịch
- Build qua `project.yml` (XcodeGen); CI sinh unsigned IPA trên `macos-latest`, chạy unit test
  trên simulator rồi archive. iOS deployment target 16.0.
