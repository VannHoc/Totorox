# Báo cáo tiến độ — tích hợp `worse_query` (Tầng 4)

> **Ngày:** 2026-11-18
> **Trạng thái:** đã viết xong code P1–P3. **CHƯA BUILD, CHƯA CHẠY TEST, CHƯA THỬ MÁY THẬT.**
> Host hiện tại là Windows, không có Xcode/clang nên không thể biên dịch.
> **Kế hoạch gốc:** `WORSE_QUERY_INTEGRATION_PLAN.md` (đọc §2 để hiểu cơ chế đã dịch ngược).
> **Người tiếp nhận:** đọc hết file này, rồi mở 3 file mới: `worse_query.m`, `WorseQuery.swift`,
> `SandboxGrantRouter.swift`.

---

## 1. TL;DR

Đã cài đúng chuỗi mà yêu cầu mô tả:

```
Tầng 1 bad_query  →  (thất bại)  →  Tầng 4 worse_query
                         │
                         └── nếu Tầng 4 thành công: badQueryBlocked = true (RAM, cả phiên)
                             từ file thứ 2 trở đi bỏ qua hẳn bad_query
```

- Tầng 1–3 giữ nguyên: máy nào `bad_query`/quyền sẵn có còn sống thì **không bao giờ** chạm `worse_query`.
- iOS < 26: `WorseQuery` tự tắt (`isEligible = major >= 26`), hành vi y như trước khi merge.
- Có toggle trong Settings, mặc định **bật**, tắt là quay lại hành vi cũ ngay (không cần relaunch).
- Có tự chữa lành `Library/Caches` lúc khởi động (`recoverAllGroups`) để chống crash giữa lúc swap.
- **Chưa xác minh gì trên máy thật** — xem §8, §9.

---

## 2. Đối chiếu với yêu cầu

| Yêu cầu | Cách đáp ứng | Nơi code |
|---|---|---|
| `bad_query` đi trước | `SandboxGrantRouter.grant` gọi `bad_query` đầu tiên khi chưa bị memo | `SandboxGrantRouter.swift` L64–75 |
| Bị chặn thì tự lùi `worse_query` | Sau khi `bad_query` fail, gọi `WorseQuery.grantRaw` (try 2 bộ cờ) | L77–95 |
| Nhớ trong RAM `badQueryBlocked` | `SandboxTierState.badQueryBlocked`, static + `NSLock` | `WorseQuery.swift` L245–272 |
| Từ file thứ 2 nhảy thẳng Tầng 4 | `if !blocked` → chỉ gọi `bad_query` khi memo chưa bật | `SandboxGrantRouter.swift` L58–64 |
| TrollStore lẫn sideload | Không hard-code group lạ; đọc group từ chữ ký (`SecTask`) + cho override runtime | `worse_query.m` `WQCopyEntitlementAppGroups` |
| Không ảnh hưởng iOS cũ | `isEligibleOnThisDevice = major >= 26` | `WorseQuery.swift` L33–44 |

### Khác một chỗ so với quote (có chủ ý)

Quote nói "bad_query bị chặn → đặt `badQueryBlocked = true`". Code chỉ bật memo **sau khi
`worse_query` thành công cho chính path đó**, không bật ngay khi `bad_query` fail.

Lý do: `bad_query` có thể fail vì lý do riêng của một path (path chưa tồn tại, `create=false`, …).
Nếu bật memo ngay, một lần fail lẻ sẽ tắt Tầng 1 cho **toàn bộ** phiên → mất quyền ở mọi container khác.
Với điều kiện "bật khi Tầng 4 đã chứng minh chạy được", hiệu quả tốc độ vẫn đúng như yêu cầu:
file đầu tiên trả giá 1 lần `bad_query` + 1 lần `worse_query`, từ file thứ 2 trở đi chỉ còn `worse_query`.
Nếu muốn bật memo ngay khi fail (kể cả khi Tầng 4 cũng hỏng), sửa `SandboxTierState.noteWorseQuerySuccess`
→ gọi ngay sau `noteBadQueryFailure` trong router.

---

## 3. File đã thêm / sửa

### Mới

| File | Nội dung |
|---|---|
| `Totorox/exploit/worse_query.h` | API C: `worse_query`, `worse_query_try_both`, `worse_query_release`, `worse_query_recover`, `worse_query_available`, `worse_query_last_error`, `worse_query_error_name`; 3 helper path-only `WQSwapCachesAtPath` / `WQRestoreCachesAtPath` / `WQRecoverCachesAtPath`; 2 hàm ObjC đọc app group từ chữ ký |
| `Totorox/exploit/worse_query.m` | Toàn bộ cơ chế: lazy `dlsym`, swap symlink, query class 7 / part 3 / flags `1<<39` hoặc `1<<35`, consume token, **luôn restore** `Library/Caches`, `NSLock` serialize, self-heal, buffer lỗi theo thread |
| `Totorox/helpers/WorseQuery.swift` | Facade Swift: eligibility, toggle, đọc group khả dụng, grant/release, recover, probe/chẩn đoán; **`SandboxTierState`** (state machine thuần, test được) |
| `Totorox/helpers/SandboxGrantRouter.swift` | Policy Tầng 1 → Tầng 4 + memo `badQueryBlocked` + log backend |
| `TotoroxTests/WorseQueryTests.swift` | 17 test: swap/restore/recover trên thư mục tạm, mã lỗi, biên version 25/26/27, state machine của memo |

### Sửa

| File | Thay đổi |
|---|---|
| `Totorox/helpers/ContainerStore.swift` | `grantContainerAccess` (~L936): `bad_query(&pathC, …)` → `SandboxGrantRouter.grant(path: clean)`. Cache `activeGrantHandles` giữ nguyên |
| `Totorox/App.swift` | `AppState.runEarlyPrivilegeInit`: gọi `WorseQuery.recoverAllGroups()` trước khi prewarm scanner |
| `Totorox/Totorox-Bridging-Header.h` | thêm `#import "exploit/worse_query.h"` |
| `Totorox/Totorox.entitlements` | thêm `com.apple.security.application-groups` = `group.com.totorox.app` (kèm comment cảnh báo) |
| `Totorox/views/SettingsView.swift` | thêm hàng "Tầng 4: worse_query" + `Toggle` (`@AppStorage("totorox.useWorseQuery")`), đổi toggle thì reset memo + cache group |
| `Totorox/{en,vi,zh-Hans}.lproj/Localizable.strings` | 6 khoá `settings.worse_query_*` |
| `AGENTS.md` | cây thư mục có thêm `worse_query` |
| `WORSE_QUERY_INTEGRATION_PLAN.md` | dòng trạng thái trỏ về file này |

`git status`: 9 file modified, 6 file mới (5 code + 1 plan). **Chưa commit.**

---

## 4. Luồng chạy thực tế

### 4.1 Khi mở một thư mục container

```
ContainerStore.enumerateDirectories / ensureContainerAccess
        │
        ▼
ContainerStore.grantContainerAccess(path)        [cache theo canonical path]
        │ miss
        ▼
SandboxGrantRouter.grant(path)
        │
        ├─ badQueryBlocked == false ──► bad_query(path, create=true, nil, false)
        │        │ handle >= 0  → cache handle, return              (backend=bad_query)
        │        └ handle < 0   → ghi lastBadQueryError, đi tiếp
        │
        ├─ WorseQuery.grantGroup == nil → trả lỗi của bad_query (hành vi cũ)
        │
        └─ WorseQuery.grantRaw(path, group)
                 │ worse_query_try_both: variant 0 (1<<39, path phải tồn tại)
                 │                     → fail → variant 1 (1<<35, path được thiếu)
                 │ handle >= 0 → memo.badQueryBlocked = true, cache handle, return
                 └ handle < 0 → log mã lỗi + detail, trả lỗi bad_query
```

### 4.2 Bên trong `worse_query()` (`worse_query.m`)

Đúng thứ tự đã dịch ngược ở plan §2.1:

1. validate path / group.
2. `dlopen` containermanager + `dlsym` 8 symbol (một lần, `dispatch_once`, **không `dlclose`**).
3. variant 0: `lstat(path)` phải tồn tại, nếu không → `-255`.
4. `containerURLForSecurityApplicationGroupIdentifier:` → nil thì `-1`.
5. `container_query_create` → nil thì `-3`.
6. `set_class(7)`, `set_group_identifiers(xpc_string(group))`, `set_part(3)`, `set_flags(1<<39 | 1<<35)`.
7. **swap**: `lstat` `<group>/Library/Caches` → remove (kể cả symlink sót) → `createSymbolicLink` → `path`.
   Lỗi → `-4`.
8. `get_single_result` → nil thì `-5`; `copy_sandbox_token` → nil thì `-6`; `sandbox_extension_consume`.
9. **cleanup luôn chạy**: xoá symlink (nếu có) và dựng lại `Library/Caches` thành thư mục thật 0755,
   giải phóng token/xpc/query, mở khoá.
10. Trả handle `>= 0` (thành công) hoặc mã âm.

### 4.3 Lúc khởi động

`AppState.runEarlyPrivilegeInit` (background queue) → `WorseQuery.recoverAllGroups()` → với mỗi group
khả dụng gọi `worse_query_recover` → nếu `Library/Caches` là symlink/file thì dựng lại thư mục.
Đây là lưới an toàn cho trường hợp app bị kill đúng lúc đang swap.

---

## 5. Yêu cầu ký app — ĐỌC KỸ, ĐÂY LÀ ĐIỀU KIỆN SỐNG CÒN

`worse_query` **chỉ** hoạt động khi:

1. `Totorox.entitlements` có `com.apple.security.application-groups` (đã thêm `group.com.totorox.app`);
2. **profile dùng để ký cũng phải chứa group đó** — nếu không, `containerURL(forSecurityApplicationGroupIdentifier:)`
   trả `nil` → `worse_query` trả `-1` ngay, và log sẽ ghi
   `worse_query: declared groups [...] have no container — provisioning profile does not include them`;
3. app được build **không** dùng App Store signing.

Cách xử lý theo từng kiểu cài:

- **TrollStore / ldid / ESign**: entitlements được nhúng từ file của mình → group ở trên là thứ được khai báo.
  Nếu containermanager không tạo container cho group này (chưa xác minh), thay bằng một group **có thật**
  trong profile đang dùng, hoặc set runtime:
  `UserDefaults.standard.set("group.<thật>", forKey: "totorox.worseQueryGroup")`.
- **Sideload bằng profile cá nhân**: profile thường **không** có app group → phải thêm capability
  App Groups trong Apple Developer account rồi ký lại, hoặc chấp nhận Tier 4 không chạy.
- **Nếu việc thêm key làm Xcode báo lỗi ký** (`Provisioning profile doesn't include the
  com.apple.security.application-groups entitlement`): xoá đúng 6 dòng đã thêm trong
  `Totorox/Totorox.entitlements` (có comment đánh dấu). Tầng 1–3 không bị ảnh hưởng.

Ngoài ra có thể truyền group lúc build bằng `-DTOTOROX_APP_GROUP=\"group.xxx\"` (C đọc trong
`WQCopyEntitlementAppGroups` khi `SecTask` không trả gì) — nhưng entitlement vẫn là điều kiện tiên quyết.

---

## 6. Test

### 6.1 Unit test (simulator)

File `TotoroxTests/WorseQueryTests.swift`, không gọi private API nào:

- `testSwapCreatesSymlinkToTarget`, `testSwapRejectsMissingTargetWhenRequired`,
  `testSwapAllowsMissingTargetWhenNotRequired`, `testSwapReplacesStaleSymlink`,
  `testSwapRejectsRelativePaths`
- `testRestoreRebuildsRealDirectory`, `testRestoreCreatesMissingDirectory`
- `testRecoverIsIdempotentOnHealthyDirectory`, `testRecoverRepairsStaleSymlink`,
  `testRecoverCreatesMissingDirectory`
- `testErrorNamesAreStable`, `testEligibilityBoundary`
- `testTierOneFailureAloneDoesNotBlockTierOne`, `testTierOneIsMemoizedAfterTierFourSucceeds`,
  `testMemoStaysOffWhenTierFourAlsoFails`, `testTierFourAbsentKeepsTierOneOnly`, `testResetClearsMemo`
- `testBadQueryAccessErrorFlagsOnlySandboxDenials`,
  `testPermissionDeniedKeepsTierOneUnmemoizedUntilTierFourSucceeds`
- (đợt audit 2026-11-18) `testTierOneSuccessClearsStaleFailureEvidence`,
  `testRetryPolicySkipsDeterministicFailures`

Tổng: **21 test**.

Test target **không** có bridging header riêng, nên test gọi helper qua wrapper `#if DEBUG` trong
`WorseQuery.swift` (`swapCaches/restoreCaches/recoverCaches/shouldRetryAnyPath`). Không phải sửa `project.yml`.

Lệnh (trên macOS):

```bash
xcodegen generate
xcodebuild -project Totorox.xcodeproj -scheme Totorox \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

### 6.2 Checklist máy thật (CHƯA LÀM)

- [ ] iOS 18.7.1: log **không** có `worse_query`, duyệt container bình thường.
- [ ] iOS 26.0 (TrollStore): mở container app khác → log `grant: backend=worse_query variant=0 group=…`.
- [ ] iOS 26.x sideload bị chặn `bad_query`: log lần 1 có `bad_query failed` rồi `backend=worse_query`;
      lần 2 trở đi **không** còn dòng `bad_query failed`.
- [ ] Đọc `Info.plist`, ghi 1 file, xoá 1 file trong container app khác.
- [ ] Dòng log đầu tiên sau khi mở app:
      `worse_query: probe eligible=true api=true enabled=true grantGroup=group.xxx declared=[…] usable=[…]`
      — nếu `grantGroup=-` thì xử lý theo §5 trước khi kết luận cơ chế hỏng.
- [ ] Sau 50 lần grant: `ls -l <group>/Library/Caches` là `drwx` (không phải `lrwx`).
- [ ] Kill app giữa lúc grant → mở lại → log `worse_query: recover ok`, `Library/Caches` là thư mục.
- [ ] Tắt toggle → log không còn `worse_query`, hành vi về như trước.
- [ ] Xem Settings hiển thị đúng trạng thái (`Sẵn sàng` / `Thiếu App Group` / `Đã tắt`).

---

## 7. Trạng thái xác minh (quan trọng cho agent kế tiếp)

| Hạng mục | Trạng thái |
|---|---|
| Viết code C/ObjC | ✅ xong, **chưa biên dịch** |
| Viết code Swift | ✅ xong, **chưa biên dịch** |
| Unit test | ✅ đã viết, **chưa chạy** |
| `xcodegen generate` | ❌ chưa chạy (không có Xcode) |
| Build simulator/device | ❌ chưa |
| Máy thật iOS 26+ | ❌ chưa |
| Entitlement với profile thật | ❌ chưa |

Rủi ro biên dịch cần soát trước tiên khi có Xcode:

1. `worse_query.m` là ARC; đã bọc `xpc_release` trong `#if !OS_OBJECT_USE_OBJC` giống `mcm_bridge.m`.
   Nếu compiler báo lỗi quanh `CFRelease((CFTypeRef)task)` thì đổi sang giữ `CFTypeRef task`
   rồi `CFRelease(task)`.
2. `goto cleanup` trong `worse_query()` nhảy qua các block lồng — C hợp lệ, nhưng nếu bật
   `-Werror` và cảnh báo "jump bypasses variable initialization" thì khai báo `void *result` ở đầu hàm.
3. `@AppStorage(WorseQuery.enabledDefaultsKey)` cần key là `String` — đã là `static let` String.
4. `onChange(of:perform:)` một tham số là API iOS 14–16 (deprecated từ iOS 17 nhưng vẫn chạy);
   deployment target là 16.0 nên không dùng overload hai tham số.
5. Test dùng `ImplicitlyUnwrappedOptional` (`URL!`) — ổn với XCTest.

---

## 8. Hạn chế / rủi ro đã biết

1. **Chưa chứng minh `containerURLForSecurityApplicationGroupIdentifier` tạo được container** cho app
   có `platform-application` + `com.apple.private.security.no-container`. Đây là giả định lớn nhất.
2. **Swap symlink ảnh hưởng process khác** nếu group bị chia sẻ với app khác. Đã serialize trong
   process này, không serialize được với process khác. Khuyến nghị: group riêng của Totorox.
3. **Crash giữa swap** để lại `Library/Caches` là symlink → đã có `recoverAllGroups` + test, nhưng
   chỉ chạy khi app khởi động lại bình thường.
4. **Đa luồng**: `worse_query.m` giữ `NSLock` quanh toàn bộ swap→query→restore, nên 2 grant song song
   không đè nhau. Nhưng đọc/ghi không liên quan vào group Caches trong lúc swap vẫn có thể thấy symlink.
5. **iOS 27 đã vá `container_query` class 7**: chưa kiểm chứng; khi đó `worse_query` trả `-5` và log rõ.
6. **`resolveAppContainerPathByMetadataScan` vẫn chặn khi `requiresSandboxEscape && !hasSandboxAccess()`**
   (`ContainerStore.swift` ~L337). Tier 4 chỉ cấp extension theo từng container, **không** làm
   `sandbox_access_is_active()` thành true. Nếu trên iOS 26 kexploit fail, đường metadata-scan vẫn bị
   skip — cần quyết định có nới điều kiện này khi `WorseQuery.grantGroup != nil` hay không (xem §9).
7. Handle Tier 4 cấp cho đúng path được yêu cầu; muốn duyệt con bên trong vẫn phải grant từng path
   (code hiện tại đã làm vậy). Không có quyền "cả cây" như `sandbox_escape`.

---

## 9. Việc tiếp theo (theo thứ tự)

1. **Build + chạy unit test** trên macOS (`xcodegen generate` rồi `xcodebuild test`). Sửa lỗi biên dịch
   nếu có (xem §7).
2. **Chạy trên máy thật iOS 26.x** và đọc log theo checklist §6.2. Ghi lại mã lỗi thực tế:
   - `-1` → lỗi chữ ký/profile (không phải lỗi code) → xử lý theo §5.
   - `-5` → daemon từ chối (có thể build đã vá) → báo lại, cân nhắc dừng tính năng.
3. Nếu `-5` xuất hiện trên mọi group: kiểm tra xem có cần thêm
   `com.apple.private.security.storage.AppGroups` hoặc class/part khác — **chỉ sau khi có log thật**.
4. ~~Quyết định việc nới `resolveAppContainerPathByMetadataScan` (§8.6)~~ → **đã làm ở đợt audit
   2026-11-18** (§13): nới khi `WorseQuery.grantGroup != nil` và dùng traversal grant; cần xác minh
   trên máy thật.
5. Cân nhắc dùng `SandboxGrantRouter.release` ở nơi invalidate cache nếu sau này có TTL cho
   `activeGrantHandles` (hiện handles sống tới hết process, giống trước khi merge).
6. Cập nhật README mục tính năng + ảnh chụp Settings nếu cần.

---

## 10. Rollback

1. `git checkout -- Totorox/helpers/ContainerStore.swift Totorox/App.swift Totorox/Totorox-Bridging-Header.h`
   (và `SettingsView.swift`, 3 file `.strings`, `Totorox.entitlements` nếu muốn sạch hoàn toàn).
2. Xoá `Totorox/exploit/worse_query.{h,m}`, `Totorox/helpers/WorseQuery.swift`,
   `Totorox/helpers/SandboxGrantRouter.swift`, `TotoroxTests/WorseQueryTests.swift`.
3. Trên máy đã chạy bản có Tier 4: xoá key `totorox.useWorseQuery`, `totorox.worseQueryGroup`.
4. Nếu nghi `Library/Caches` của group còn là symlink: mở app bản cũ một lần (không có recover) thì
   không tự sửa — cần xoá symlink thủ công hoặc cài lại bản có `recoverAllGroups` chạy 1 lần.

---

## 11. Nhật ký thực hiện (để agent sau biết đang ở đâu)

| Bước | Nội dung | Kết quả |
|---|---|---|
| 1 | Dịch ngược `Exploit-v2.2.1.ipa` để lấy cơ chế `worse_query` | xong (plan §2) |
| 2 | Viết `WORSE_QUERY_INTEGRATION_PLAN.md` | xong |
| 3 | Chốt hướng: `bad_query` trước → memo RAM → `worse_query`; bỏ P0 gate | xong |
| 4 | `exploit/worse_query.h` + `.m` | xong, chưa biên dịch |
| 5 | `helpers/WorseQuery.swift` (+ state machine) | xong, chưa biên dịch |
| 6 | `helpers/SandboxGrantRouter.swift` | xong, chưa biên dịch |
| 7 | Nối `ContainerStore.grantContainerAccess` | xong |
| 8 | `recoverAllGroups()` lúc khởi động | xong |
| 9 | Bridging header + entitlements | xong |
| 10 | Settings toggle + 6 khoá localization × 3 ngôn ngữ | xong |
| 11 | Unit test (21 test) | xong, **chưa chạy** — đợt audit bổ sung 2 test (memo dựa trên lỗi mới + policy retry variant) |
| 12 | Build + chạy test + máy thật | **CHƯA — việc của agent kế tiếp** |
| 13 | Audit luồng + tối ưu tốc độ (đợt 2, 2026-11-18) | xong phần code, **chưa build** — xem §13 |

---

## 12. Bản đồ code nhanh

| Cần tìm gì | Ở đâu |
|---|---|
| Chuỗi quyết định Tầng 1 → 4 | `Totorox/helpers/SandboxGrantRouter.swift` `grant(path:)` |
| Memo `badQueryBlocked` | `Totorox/helpers/WorseQuery.swift` `struct SandboxTierState` |
| Điều kiện bật Tier 4 | `WorseQuery.grantGroup` (eligible + enabled + API + group có container) |
| Swap/restore/self-heal | `Totorox/exploit/worse_query.m` `WQSwapCachesAtPath` / `WQRestoreCachesAtPath` / `WQRecoverCachesAtPath` |
| Query private API | cùng file, hàm `worse_query()` (bước 4–12) |
| Đọc group từ chữ ký | cùng file, `WQCopyEntitlementAppGroups` / `WQSignatureAppGroups` |
| Điểm gọi grant duy nhất | `ContainerStore.grantContainerAccess` |
| Tự chữa lành lúc khởi động | `App.swift` `runEarlyPrivilegeInit` |
| UI + trạng thái | `SettingsView.worseQueryRow` + `WorseQuery.statusLocalizationKey` |
| Test | `TotoroxTests/WorseQueryTests.swift` |

---

## 13. Biên bản audit luồng & tốc độ (đợt 2, `2026-11-18`)

Bối cảnh: chủ dự án yêu cầu kiểm tra lại **toàn bộ** xem luồng Tier 1 → memo → Tier 4 đã đúng chưa và
đã "cực tốc" chưa. Phần này ghi lại **phát hiện**, **đã sửa gì**, **cái gì chưa xác minh được**.

### 13.1 Luồng trước audit — đúng ở đâu, sai ở đâu

Đúng:
- Chỉ có **một chokepoint** `ContainerStore.grantContainerAccess` (L920) cho mọi call site (`FileIOEngine`,
  `FolderExplorerView`, `OverwriteFileView`, `AppContainerScanner`, `ContainerStore`).
- Memo chỉ bật khi Tier 4 **thành công** cho cùng path (không tắt Tier 1 vì 1 lỗi path-specific).
- Handle Tier 1 được xác minh bằng `access(path, R_OK)` trước khi cache.

Sai / hở (đã sửa):
1. **`SandboxTierState.attemptOrder` là code chết** — chỉ test dùng, `SandboxGrantRouter.grant` tự viết
   lại chuỗi if/else. Hệ quả: khi memo bật mà Tier 4 hỏng giữa phiên (build bị vá, group bị xoá, user tắt
   toggle mà chưa reset) → `grant` trả lỗi ngay, **không thử lại Tier 1** → app mất quyền đọc container
   đến hết phiên. → Giờ router chạy đúng `attemptOrder`, Tier 1 là **last resort**.
2. **Handle Tier 4 không được xác minh.** `sandbox_extension_consume` có thể trả handle ≥ 0 cho token của
   *group container* (daemon resolve theo cache, không theo symlink) → router báo thành công, handle vô
   dụng được cache vào `activeGrantHandles`. → Giờ verify `access(path, R_OK)` cho **cả 2 tầng**, release
   handle nếu không phủ path.
3. **Memo dựa trên bằng chứng cũ.** `noteWorseQuerySuccess()` chỉ kiểm tra `lastBadQueryError < 0`, mà
   biến này không bao giờ được xoá khi Tier 1 thành công → một lỗi cũ của path trước có thể "gán tội" cho
   Tier 4 thành công của path khác. → Thêm `noteBadQuerySuccess()` (xoá bằng chứng) và
   `noteWorseQuerySuccess()` "tiêu thụ" bằng chứng (set về 0).
4. **Retry variant vô điều kiện.** `worse_query_try_both` luôn thử variant 1 (`1<<35`) sau khi variant 0
   fail, kể cả khi lỗi là `-1` (không có group container), `-2` (thiếu symbol), `-3` (query create),
   `-4` (swap symlink), `-7` (tham số sai) — những lỗi flags không thể sửa. Mỗi lần retry = thêm 1 round
   trip daemon + 1 lần swap/restore. → Thêm `worse_query_should_retry_any_path()`; chỉ retry với
   `-255/-5/-6` (và các mã âm lạ).
5. **Gate khám phá chặn Tier 4.** `AppContainerScanner` STAGE 3 và
   `ContainerStore.resolveAppContainerPathByMetadataScan` chỉ cho kernel sandbox escape → iOS 26 sideload
   (chỉ có Tier 4) **không liệt kê được container UUID thô** dù Tier 4 cấp traversal y như Tier 1. → Nới
   gate bằng `|| WorseQuery.grantGroup != nil` và đổi sang `enumerateDirectoriesWithTraversalGrant`.
6. **`grantGroup` tự kiểm tra gate mỗi lần gọi** (`isEnabled` = đọc `UserDefaults`, `isAPIAvailable` =
   `dispatch_once`) trước khi xem cache. → Đọc cache trước; chỉ chạy gate ở lần resolve đầu.
7. **`#ifdef TOTOROX_APP_GROUP` là code chết** (macro không được define ở đâu) → fallback group không bao
   giờ chạy. → Thay bằng hằng `kWQFallbackAppGroup = @"group.com.totorox.app"` (đúng group trong
   `Totorox.entitlements`), vẫn lọc qua `containerURL` nên không thể cấp quyền sai.

### 13.2 Chi phí mỗi lần grant (sau audit)

| Tình huống | Round trip daemon | Ghi chú |
|---|---|---|
| Path đã có trong `activeGrantHandles` | 0 | lock + dict lookup |
| Tier 1 thành công (TrollStore/iOS < 26) | 1 (`bad_query`) + 1 `access()` | `bad_query` tự `dlopen`+`dlsym` mỗi lần (chưa tối ưu, xem §13.4) |
| Tier 4 thành công, memo bật | 1 (`worse_query`) + 1 `access()` | swap + query + consume, đây là mức tối thiểu của cơ chế |
| Tier 4 fail kiểu `-5` trên build đã vá | 2 | variant 1 vẫn đáng thử vì flags khác nhau |
| Tier 4 fail kiểu `-1/-2/-4` | **1** (trước đây 2) | retry policy mới |

Kết luận tốc độ: **đạt mức tối thiểu của cơ chế** (1 round trip/path lạ khi backend hoạt động, 0 cho path
đã cache). Không thể nhanh hơn nếu vẫn dùng `container_query` per-path; muốn nhanh hơn nữa phải grant
**một lần cho cả cây** (`/var/mobile/Containers/Data/Application`) rồi đọc trực tiếp — hiện chỉ STAGE 3 và
metadata scan làm vậy, các view vẫn grant per-container.

### 13.3 File đã sửa ở đợt này

`Totorox/helpers/SandboxGrantRouter.swift`, `Totorox/helpers/WorseQuery.swift`,
`Totorox/exploit/worse_query.h`, `Totorox/exploit/worse_query.m`,
`Totorox/helpers/AppContainerScanner.swift`, `Totorox/helpers/ContainerStore.swift`,
`Totorox/views/SettingsView.swift`, `TotoroxTests/WorseQueryTests.swift`,
`TOTOROX_3.0_PROGRESS.md`, `WORSE_QUERY_PROGRESS.md`.

### 13.4 Chưa xác minh / rủi ro còn lại

- **Chưa build, chưa chạy 19 test** (host Windows không có Xcode). CI sẽ là nơi xác nhận.
- **Verify `access(R_OK)` cho Tier 4**: nếu token chỉ cấp traverse mà không cấp read (hoặc daemon trả token
  cho group thay vì target), grant bị coi là fail và fallback Tier 1 — an toàn nhưng có thể *giảm* tỉ lệ
  thành công so với "tin handle". Cần log máy thật để xác nhận không có false-negative.
- **Fallback group hard-code**: nếu sau này đổi group trong entitlements, phải đổi cả
  `kWQFallbackAppGroup` trong `worse_query.m`.
- **`bad_query` vẫn `dlopen`+`dlsym` mỗi lần gọi** (`exploit/bad_query.c`): tối ưu khả thi ~50–200 µs/lần
  bằng `dispatch_once` cache symbol, nhưng file này dùng chung nhiều luồng → **chưa sửa** trong đợt audit.
- **Không có negative cache** trong `grantContainerAccess`: path luôn fail sẽ được thử lại mỗi lần refresh.
  Chưa thêm vì dễ gây "kẹt" quyền sau khi user cài profile mới; nếu cần, dùng TTL ngắn (30–60 s).
- Tier 4 vẫn **không serialize được với process khác** đang đọc `Library/Caches` của cùng group.
- **`verifyAccess` với path chưa tồn tại**: khi `access(path)` trả `ENOENT`, code kiểm tra ancestor gần nhất;
  nếu extension chỉ phủ đúng path đích (chưa tạo) mà không phủ thư mục cha thì grant bị coi là fail
  (false-negative). Đây là hành vi **đã có từ trước đợt audit** (dùng cho cả 2 tầng) và có tác dụng phát hiện
  token rác trên iOS 26; nếu log máy thật cho thấy grant fail trên path sẽ-tạo, hướng sửa là coi `ENOENT` là
  "không kết luận" (accept handle) thay vì kiểm ancestor.
- **`requireWrite` + Tối ưu Container Read/Write (đợt 3, hoàn tất cùng phiên 2026-11-18):**
  - `SandboxGrantRouter.grant(path:requireWrite:)` + `verifyAccess(path:requireWrite:)`: kiểm tra `R_OK | W_OK` khi ghi, đồng thời kiểm tra `parent` khi file đích tồn tại với POSIX mode chỉ-đọc `0444` (tránh báo giả là sandbox chặn) và kiểm tra `nearestExistingAncestor(of:)` khi `ENOENT`.
  - `worse_query.m`: trong `WQSwapCachesAtPath` và `worse_query`, không còn chặn sớm Variant 0 (`WQ_VARIANT_PRIMARY`) khi `lstat(target_path)` gặp `EPERM`/`EACCES` trước lúc nhận token (chỉ từ chối `ENOENT`/`ENOTDIR` v.v. để `containermanagerd` tự resolve symlink với quyền daemon); cache `gGroupCachesByID` qua `worse_query_clear_cache()`; dùng POSIX `rmdir`/`unlink`/`symlink`/`mkdir` thay hot-path `NSFileManager`.
  - `ContainerStore.swift`: thêm `grantedAccessMask` (bit 0 = read, bit 1 = write) bảo vệ bằng `grantHandlesLock`, `containerRootComponent(in:)`, canonicalization O(1) thay `resolvingSymlinksInPath()` trên hot-path, tối ưu `readDataDirectly` (hỗ trợ tệp 0-byte, xử lý `EINTR`, 1 lần cấp phát `Data`), `shallowChildCount` kiểm byte đầu `d_name.0 == 46` không cấp phát `String`, và dùng shared locked `DateFormatter`/`NumberFormatter` trong `FileEntry`.
  - `TotoroxTests/WorseQueryTests.swift`: bổ sung `testNearestExistingAncestorWalksUpMissingSubtree` (tổng 22 test). Chưa biên dịch/chạy Xcode trên Windows; cần CI macOS xác nhận.


