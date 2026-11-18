# Kế hoạch tích hợp `worse_query` vào Totorox

> **Trạng thái:** ĐÃ TRIỂN KHAI P1–P3 (chưa build/không có máy thật) — xem `WORSE_QUERY_PROGRESS.md`
> để biết chính xác file nào đã đổi, phần nào còn chưa xác minh và việc tiếp theo.
> **Người soạn:** phiên REA ngày 2026-11-18, dựa trên dịch ngược `Exploit-v2.2.1.ipa`.
> **Đối tượng đọc:** agent/engineer thực thi. Đọc hết §2 và §11 trước khi viết dòng code đầu tiên.

---

## 0. TL;DR

**Có thể thêm.** Repo Totorox đã có đúng bộ khung cần thiết: `exploit/bad_query.c` dùng cùng
`libsystem_containermanager.dylib`, cùng 2 giá trị cờ, cùng `sandbox_extension_consume`.
Việc cần làm là thêm **một backend cấp quyền thứ ba** (`worse_query`) bên cạnh kernel escape và
`bad_query`, rồi chọn backend theo phiên bản iOS.

**Nhưng có 3 điều kiện cứng, sai một cái là tính năng vô dụng:**

1. **App Group entitlement phải có trong chữ ký.** `Totorox/Totorox.entitlements` hiện **không** có
   `com.apple.security.application-groups`. Không có key này → `containerURLForSecurityApplicationGroupIdentifier:`
   trả `nil` → `worse_query()` trả `-1` ngay. Đây là blocker #1, không phải việc của code.
2. **Phải xác minh trên thiết bị thật iOS 26.x / 27.0.** Không simulator, không suy luận được từ code.
3. **Chỉ dùng cho bản sideload/TrollStore.** Đây là private API + hoán đổi symlink trong container
   của app khác; không thể và không nên đưa vào build App Store.

**Khuyến nghị thứ tự:** làm **P0 (probe)** trước. Totorox đã có
`com.apple.security.exception.files.absolute-path.read-write = /`, nên rất có thể phần lớn đường dẫn
đã truy cập được mà không cần `worse_query`. Nếu probe cho thấy đã đọc/ghi được thì **không nên** thêm
cơ chế hoán đổi symlink (rủi ro phá App Group container) làm gì.

---

## 1. Mục tiêu / phạm vi

### Mục tiêu
- Trên iOS **26.x – 27.0** (nơi traversal `bad_query` và/hoặc `sandbox_escape` không còn hiệu lực),
  app vẫn đọc/ghi được file trong container của app khác (Data container + App Group).
- Không làm hỏng hành vi hiện có trên iOS 16–18.7.1 và iOS 26.0 (đường kernel escape / `bad_query`).
- Có chẩn đoán rõ ràng trong `LogView` để biết đang dùng backend nào, mã lỗi nào.

### Không thuộc phạm vi
- Không port AirLift / pairing-file.
- Không đụng `Totorox-Backend/` (FastAPI, `licenses.db`, admin subdomain guard) — tuyệt đối giữ nguyên.
- Không thêm UI mode phức tạp kiểu "Chế độ tiêu chuẩn mở rộng"; chỉ cần 1 toggle + log.
- Không hứa hỗ trợ mọi build iOS 27 beta; chỉ build có trong `ExploitSupportPolicy.verifiedIOS27Builds`.

---

## 2. Sự thật kỹ thuật đã xác minh (từ binary tham chiếu)

Nguồn: `Exploit-v2.2.1.ipa`, binary `Payload/bad_query.app/bad_query`,
sha256 `acf06960523b4ccc1bdec0d109def09dcf6a71cedabc485bf2210ec5615703b6` (arm64).

### 2.1 API & thứ tự gọi

```
dlopen("/usr/lib/system/libsystem_containermanager.dylib")
dlsym: container_query_create
       container_query_set_class
       container_query_set_group_identifiers
       container_query_operation_set_flags
       container_query_operation_set_part
       container_query_get_single_result
       container_query_free
       container_copy_sandbox_token
dlsym(RTLD_DEFAULT): sandbox_extension_consume / sandbox_extension_release
```

Trình tự trong `_worse_query` (`0x100015138`):

1. (nếu `arg3 & 1 == 0`) kiểm tra path bằng `fileSystemRepresentation`; sai → `-255`.
2. `<group> = [NSFileManager containerURLForSecurityApplicationGroupIdentifier:appGroup]`; `nil` → `-1`.
3. `caches = <group>/Library/Caches`.
4. `query = container_query_create()`; `nil` → `-3`.
5. `container_query_set_class(query, 7)`.
6. `container_query_set_group_identifiers(query, UTF8(appGroup))`.
7. `container_query_operation_set_part(query, 3)`.
8. `container_query_operation_set_flags(query, arg3 ? 1<<35 : 1<<39)`.
9. `removeItemAtPath:caches` → `createSymbolicLinkAtPath:caches withDestinationPath:<path>`; fail → `-4`.
10. `result = container_query_get_single_result(query)`; `nil` → `-5`.
11. `token = container_copy_sandbox_token(result)`; `nil` → `-6`.
12. `handle = sandbox_extension_consume(token)`.
13. `container_query_free`, free strings, **dựng lại `Library/Caches` thành thư mục thật**
    (`_worse_query` gọi helper `0x100015400`: `removeItemAtURL` + `createDirectoryAtURL:withIntermediateDirectories:NO`).
14. Trả `handle` (âm = lỗi từ `sandbox_extension_consume`).

`worse_query_release(handle)` = `sandbox_extension_release(handle)`, bỏ qua nếu `handle < 0`.

### 2.2 Hằng số cờ đã quan sát

| Nơi | Giá trị | Ghi chú |
|---|---|---|
| `worse_query`, `arg3 == 0` | `1 << 39` (`0x0000008000000000`) | trùng `bad_query(..., is_group=false)` |
| `worse_query`, `arg3 != 0` | `1 << 35` (`0x0000000800000000`) | trùng `bad_query(..., is_group=true)` |
| `MCMEnumerateIdentifiersForClass` (Totorox) | `1 << 32` (`0x100000000`) | chỉ để liệt kê identifier |

`container_query_set_part` luôn là `3` trong cả hai nhánh.

### 2.3 Gọi từ tầng Swift (để tham chiếu hành vi)

| Symbol tham chiếu | Vai trò |
|---|---|
| `BadQueryFileAccess.requestToken(for:)` → `worseQueryTryBoth(handle:trace:)` | đường chính |
| `worseQueryTryBoth` | thử lần lượt 2 bộ cờ; lần 2 dùng `arg3 = 1` (bỏ kiểm tra path, cho phép path chưa tồn tại) |
| `WQLSWithGrant` / `WQGrantPath` | duyệt `NSArray` 2 `NSNumber`, gọi `worse_query(path, group, boolValue, 0)` tới khi `handle > 0` |
| `FastContainerScan.consume(path:createIfMissing:)` | `arg3 = createIfMissing` |
| `releaseToken` / `releaseAllExtensions` | `worse_query_release` |

Cổng phiên bản trong bản tham chiếu:
- `worseQueryEligible` (`0x10002772c`) = `operatingSystemVersion.majorVersion > 25` → **iOS 26+**.
- `worseQueryTryBoth` còn so `majorVersion == 26` để chọn danh sách cờ.
- `IOSCompatibilityManager.shouldPreferWorseQuery` (`0x1001487d0`) **không có caller** — dead code, **đừng port**.

### 2.4 Entitlement

- Chữ ký tham chiếu khai báo `com.apple.security.application-groups` = `group.9a115986a8222d1f.{1..5}`.
- Fallback hard-code trong code: `group.cc.forcequit.worse-query` — chỉ là giá trị dự phòng, **không**
  phải group có thật trong chữ ký.
- Nếu chữ ký thiếu key: app log `App Group: chữ ký KHÔNG khai báo … worse_query không thể cấp quyền.`

### 2.5 Giới hạn của bằng chứng

- Provider REA native không chạy trên host Windows → toàn bộ phần Mach-O là phân tích tĩnh capstone,
  **chưa có chạy động**.
- Hệ quả: ngữ nghĩa thật của bit 35/39, việc sandbox có thật sự chấp nhận symlink, và hiệu lực trên
  từng build iOS **chưa được chứng minh**. Vì vậy P0/P4 (probe trên máy thật) là bắt buộc.

---

## 3. Đối chiếu với code hiện tại của Totorox

| File | Hiện có gì | Liên quan |
|---|---|---|
| `Totorox/exploit/bad_query.c/.h` | Query class 7/13 + `set_part_domain("../../..")`, flags `1<<35` / `1<<39`, consume token | **Khuôn mẫu trực tiếp**; `worse_query` chỉ thay `set_part_domain` bằng symlink |
| `Totorox/exploit/mcm_bridge.m/.h` | `MCMActivateContainerPath`, `MCMActivateContainer`, cache API qua `dispatch_once` | Tái dùng pattern load API + `container_object_sandbox_extension_activate` |
| `Totorox/helpers/SBX.swift` | `sandbox_extension_consume`, `sandbox_extension_issue_file` | Có thể dùng cho probe, nhưng `worse_query` nên tự dlsym |
| `Totorox/helpers/ContainerStore.swift` (~L917 `grantContainerAccess`) | cache `activeGrantHandles` + `NSLock`, gọi `bad_query` | **Điểm tích hợp chính** |
| `Totorox/helpers/KernelExploit.swift` | `requiresSandboxEscape = majorVersion >= 26` | Cần xem lại chính sách "fail nếu sandbox_escape fail trên iOS 26" |
| `Totorox/helpers/SupportPolicy.swift` | `supportsKernelExploit` (26.0), `isSupported` (26 ≤ 26.6.1, 27.0 beta) | Nơi khai báo backend theo version |
| `Totorox/helpers/Utils.swift` L25 `log(...)` + `views/LogView.swift` | log ring buffer + màn hình log | Chẩn đoán |
| `Totorox.entitlements` | `platform-application`, `no-container`, `absolute-path.read-write: /`… **thiếu app-groups** | Blocker #1 |
| `project.yml` | XcodeGen `sources: - path: Totorox` (tự nhận file mới), `CODE_SIGNING_ALLOWED: NO` | Không cần sửa gì cho file mới; bridging header thì có |
| `Totorox-Bridging-Header.h` | import các header C/ObjC | Phải thêm `exploit/worse_query.h` |

---

## 4. Kiến trúc đề xuất

```
                      ┌─────────────────────────────┐
   UI / FileManager ──│ ContainerStore.ensureAccess │
                      └──────────────┬──────────────┘
                                     │ cần grant cho path P
                     ┌───────────────▼────────────────┐
                     │ SandboxGrantRouter (Swift)     │
                     │  - chọn backend theo iOS       │
                     │  - probe + cache handle        │
                     └───┬───────────┬───────────┬────┘
             iOS ≤18.7   │  iOS 26+  │  fallback │
        ┌────────────────▼──┐ ┌──────▼───────┐ ┌─▼──────────────┐
        │ kernel escape      │ │ worse_query  │ │ bad_query      │
        │ (đã có)            │ │ (mới)        │ │ (đã có)        │
        └────────────────────┘ └──────┬───────┘ └────────────────┘
                                      │
                          ┌───────────▼─────────────┐
                          │ worse_query.m (C/ObjC)  │
                          │ swap symlink + consume  │
                          └─────────────────────────┘
```

Nguyên tắc:
- **Router chỉ là policy**, không chứa syscall. Ba backend độc lập, cùng contract
  `grant(path:) -> Int64` và `release(handle:)`.
- Mọi lần grant đều **cache theo canonical path** (đã có sẵn pattern trong `ContainerStore`).
- `worse_query` **không bao giờ** được gọi khi chưa có app group khả dụng — kiểm tra trước, log rõ.

---

## 5. Việc cần làm — theo phase

### P0 — Probe & quyết định (bắt buộc làm trước, ~0.5 ngày)

- [ ] **P0.1** Thêm `WorseQuery.probe()` trả về struct chẩn đoán (xem §6.3), hiển thị trong `LogView`
      hoặc một màn `Settings → Chẩn đoán`.
- [ ] **P0.2** Trên thiết bị thật iOS 26.x: log (a) `worse_query_available()`, (b) danh sách app group
      trong chữ ký, (c) `access("/var/mobile/Containers/Data/Application", R_OK)` và thử đọc 1 file bất kỳ
      trong container app khác **khi chưa bật worse_query**.
- [ ] **P0.3** Ghi kết quả vào issue/PR. **Quyết định:** nếu P0.2 đã đọc/ghi được → dừng, không triển khai
      (chỉ giữ probe). Nếu không → tiếp P1.

**Acceptance P0:** có log chứng minh 1 trong 2 trạng thái: "đã đủ quyền, không cần worse_query" hoặc
"bị chặn, cần worse_query" + group ID khả dụng thực tế trên máy.

### P1 — Thư viện C/ObjC (1–1.5 ngày)

- [ ] **P1.1** Tạo `Totorox/exploit/worse_query.h` (§6.1).
- [ ] **P1.2** Tạo `Totorox/exploit/worse_query.m` (§6.2) — toàn bộ logic swap/query/restore.
- [ ] **P1.3** Thêm `#import "exploit/worse_query.h"` vào `Totorox/Totorox-Bridging-Header.h`.
- [ ] **P1.4** Đảm bảo XcodeGen nhận file: chỉ cần chạy `xcodegen generate` (sources là thư mục).
- [ ] **P1.5** Unit test cho phần thuần path (`WQSwapCachesAtPath`, `WQRestoreCachesAtPath`) — xem §9.

**Acceptance P1:** build xanh; unit test xanh trên simulator; **không** gọi API private trong test.

### P2 — Router + tích hợp (1 ngày)

- [ ] **P2.1** `Totorox/helpers/WorseQuery.swift` (§6.3).
- [ ] **P2.2** Sửa `ContainerStore.grantContainerAccess` để đi qua router (§6.4).
- [ ] **P2.3** `SupportPolicy` thêm `prefersWorseQuery(major:minor:patch:)` và test biên (25/26/27).
- [ ] **P2.4** Gọi `WorseQuery.recoverAllGroups()` **một lần** khi app khởi động (self-heal symlink sót).
- [ ] **P2.5** `@AppStorage("totorox.useWorseQuery")` + toggle trong `SettingsView` (mặc định **bật**,
      có subtitle giải thích "chỉ iOS 26+; nếu lỗi hãy tắt").

**Acceptance P2:** trên iOS 26 thật, duyệt được container app khác; trên iOS 18 vẫn đi đường cũ;
tắt toggle → quay lại hành vi cũ **ngay** (không cần relaunch).

### P3 — Chẩn đoán & UX lỗi (0.5 ngày)

- [ ] **P3.1** Log mỗi lần grant: `backend=worse_query variant=1 group=… code=0`.
- [ ] **P3.2** Map mã lỗi → chuỗi người đọc được (bảng §7) và hiển thị khi mở thư mục thất bại.
- [ ] **P3.3** Cảnh báo rõ nếu chữ ký thiếu `application-groups` (đây là lỗi cấu hình, không phải bug code).

**Acceptance P3:** mọi nhánh lỗi của `worse_query()` đều có log tương ứng; không có "im lặng thất bại".

### P4 — Xác minh thiết bị & phát hành (1 ngày, phụ thuộc máy thật)

- [ ] **P4.1** Ma trận thử: iOS 18.7.1 / 26.0 / 26.5 / 26.6.1 / 27.0 beta có trong danh sách.
- [ ] **P4.2** Kiểm tra chéo: đọc metadata container, sửa 1 file nhỏ, xoá file, mở thư mục App Group.
- [ ] **P4.3** Kiểm tra "không phá": sau 50 lần grant, `<group>/Library/Caches` vẫn là **thư mục thật**;
      mở app nhóm đó (nếu có) vẫn hoạt động.
- [ ] **P4.4** Cập nhật `README.md` + `AGENTS.md` (cây thư mục thêm `worse_query.m`, mục tính năng).

**Acceptance P4:** bảng kết quả theo máy/build được ghi lại trong PR; không có hồi quy trên iOS ≤ 18.7.1.

---

## 6. Code cụ thể

### 6.1 `Totorox/exploit/worse_query.h`

```objc
#ifndef WORSE_QUERY_H
#define WORSE_QUERY_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Mã lỗi. Giữ đúng giá trị của bản tham chiếu Exploit 2.2.1 để dễ đối chiếu log.
enum {
    WQ_ERR_INVALID_PATH      = -255, /* -0xff */
    WQ_ERR_NO_GROUP_CONTAINER = -1,
    WQ_ERR_API_UNAVAILABLE   = -2,
    WQ_ERR_QUERY_CREATE      = -3,
    WQ_ERR_SYMLINK           = -4,
    WQ_ERR_NO_RESULT         = -5,
    WQ_ERR_NO_TOKEN          = -6,
};

/// API private đã nạp đủ symbol chưa.
bool worse_query_available(void);

/// Cấp 1 sandbox extension cho `path` thông qua App Group `app_group`.
/// variant: 0 = bộ cờ 1<<39 + yêu cầu path tồn tại; 1 = bộ cờ 1<<35 + cho phép path chưa tồn tại.
/// Trả handle > 0 khi thành công, hoặc mã lỗi âm ở trên.
int64_t worse_query(const char *path, const char *app_group, int variant);

/// Thử variant 0 rồi 1 (đúng hành vi worseQueryTryBoth). `used_variant` có thể NULL.
int64_t worse_query_try_both(const char *path, const char *app_group, int *used_variant);

/// Giải phóng handle. An toàn với handle < 0.
void worse_query_release(int64_t handle);

/// Tự chữa lành: nếu <group>/Library/Caches không phải thư mục thật thì dựng lại.
bool worse_query_recover(const char *app_group);

/// Mô tả lỗi gần nhất của thread hiện tại (dùng cho log).
const char *worse_query_last_error(void);

#ifdef __OBJC__
/// Danh sách app group khai báo trong chữ ký (rỗng nếu không đọc được).
NSArray<NSString *> *WQSignatureAppGroups(void);
/// Group ưu tiên = phần tử đầu tiên trong chữ ký, hoặc nil.
NSString *WQSignatureAppGroup(void);
#endif

#ifdef __cplusplus
}
#endif
#endif /* WORSE_QUERY_H */
```

> **Ghi chú thiết kế:** thêm 3 thứ so với bản tham chiếu — `try_both` (gom logic 2 bộ cờ),
> `recover` (chống crash để lại symlink), `last_error` (log). Không port
> `shouldPreferWorseQuery` vì bên tham chiếu nó là dead code.

### 6.2 `Totorox/exploit/worse_query.m`

Khung chính (agent điền đủ, giữ đúng thứ tự §2.1):

```objc
#import "worse_query.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <xpc/xpc.h>

typedef void   *(*WQQueryCreate)(void);
typedef void    (*WQSetClass)(void *, uint64_t);
typedef void    (*WQSetGroupIdentifiers)(void *, xpc_object_t);
typedef void    (*WQSetFlags)(void *, uint64_t);
typedef void    (*WQSetPart)(void *, uint64_t);
typedef void   *(*WQGetSingleResult)(void *);
typedef void    (*WQQueryFree)(void *);
typedef char   *(*WQCopyToken)(void *);
typedef int64_t (*WQConsume)(const char *);
typedef int     (*WQRelease)(int64_t);

typedef struct {
    bool available;
    WQQueryCreate create;
    WQSetClass setClass;
    WQSetGroupIdentifiers setGroupIdentifiers;
    WQSetFlags setFlags;
    WQSetPart setPart;
    WQGetSingleResult getSingleResult;
    WQQueryFree queryFree;
    WQCopyToken copyToken;
    WQConsume consume;
    WQRelease release;
} WQAPI;

static WQAPI gAPI;
static dispatch_once_t gOnce;
static NSLock *gSwapLock;          // serialize toàn bộ swap→query→restore
static __thread char gError[512];

static void WQSetError(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
```

Các hàm bắt buộc có (đặt `static`, unit-test được nhờ expose qua `NS_SWIFT_NAME` hoặc
một header test riêng — xem §9):

```objc
static void WQLoadAPI(void);                       // dispatch_once, dlsym như §2.1
static bool WQSwapCachesAtPath(NSString *caches,   // remove + symlink
                               NSString *target,
                               bool requireTargetExists);
static void WQRestoreCachesAtPath(NSString *caches); // xoá symlink/file, createDirectory YES
static int64_t WQQueryOnce(NSString *group, uint64_t flags, NSString *target);
```

`WQQueryOnce` = bước 4→12 của §2.1 (không chứa swap), trả handle hoặc mã lỗi.

`worse_query()` = khóa `gSwapLock` → `WQSwapCachesAtPath` → `WQQueryOnce` → `WQRestoreCachesAtPath`
→ mở khóa. Restore phải chạy **cả khi** query lỗi (không dùng `@try`; dùng biến trạng thái + một
nhãn `cleanup:` duy nhất).

Bắt buộc tuân thủ:

1. `WQSwapCachesAtPath` phải `lstat` trước; nếu đang là **thư mục** thì `removeItemAtPath:`;
   nếu đã là symlink thì ghi log `recovering stale symlink` rồi thay.
2. Nếu `requireTargetExists` và `lstat(target)` fail → trả `WQ_ERR_INVALID_PATH` **trước** khi swap.
3. `WQQueryOnce` phải `xpc_release(identifier)` và `container_query_free` trên **mọi** nhánh.
4. Không `dlclose` thư viện containermanager (giữ handle vĩnh viễn như `mcm_bridge.m`).
5. Không dùng `NSFileManager` trong critical section ngoài 2 hàm swap/restore (giảm thời gian giữ lock).
6. `worse_query_recover(group)` phải: nếu `<group>/Library/Caches` là symlink → xoá + tạo thư mục;
   nếu thiếu → tạo; nếu là thư mục → no-op.

### 6.3 `Totorox/helpers/WorseQuery.swift`

```swift
import Foundation

enum WorseQuery {
    struct Probe {
        var apiAvailable: Bool
        var signatureGroups: [String]
        var eligible: Bool          // iOS >= 26
        var lastError: String?
    }

    static var isEligible: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    static var isAvailable: Bool { worse_query_available() }

    static var signatureGroups: [String] { WQSignatureAppGroups() }

    static var preferredGroup: String? { WQSignatureAppGroup() }

    /// Toggle người dùng; mặc định bật.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "totorox.useWorseQuery") as? Bool ?? true
    }

    static func grant(path: String, group: String) -> Int64 {
        var used: Int32 = 0
        let h = path.withCString { p in
            group.withCString { g in
                worse_query_try_both(p, g, &used)
            }
        }
        log("worse_query: grant path=\(path) group=\(group) variant=\(used) code=\(h)")
        return h
    }

    static func release(_ handle: Int64) { worse_query_release(handle) }

    static func recoverAllGroups() {
        for g in signatureGroups { _ = g.withCString { worse_query_recover($0) } }
    }

    static func probe() -> Probe { /* §P0.1 */ }
}
```

### 6.4 Tích hợp vào `ContainerStore.grantContainerAccess`

Hiện tại (rút gọn, ~L917):

```swift
var pathC = clean.utf8CString.map { Int8($0) }
let handle = bad_query(&pathC, true, nil, false)
```

Đổi thành:

```swift
let handle = SandboxGrantRouter.grant(path: clean)
```

```swift
enum SandboxGrantRouter {
    static func grant(path: String) -> Int64 {
        if WorseQuery.isEligible, WorseQuery.isEnabled, WorseQuery.isAvailable,
           let group = WorseQuery.preferredGroup {
            let h = WorseQuery.grant(path: path, group: group)
            if h > 0 { return h }
        }
        var pathC = path.utf8CString.map { Int8($0) }
        return bad_query(&pathC, true, nil, false)
    }
}
```

**Quan trọng:** giữ nguyên cache `activeGrantHandles` + `grantHandlesLock` — router **không** tự cache,
để tránh 2 tầng cache lệch nhau. Release vẫn đi qua dispatcher:

```swift
static func releaseGrant(_ handle: Int64) {
    worse_query_release(handle)   // an toàn: bỏ qua handle < 0
}
```

(`worse_query_release` và `bad_query_release` cùng gọi `sandbox_extension_release`, nên dùng
`worse_query_release` cho mọi handle là hợp lý; ghi rõ trong comment.)

---

## 7. Bảng mã lỗi → thông điệp

| Mã | Nghĩa | Thông điệp cho người dùng | Hành động |
|---|---|---|---|
| `-1` | Không lấy được App Group container | "Chữ ký app không có App Group hợp lệ." | Lỗi cấu hình build/profile |
| `-2` | Thiếu symbol private | "iOS này không hỗ trợ cơ chế mở rộng." | Rơi về `bad_query` |
| `-3` | `container_query_create` fail | "Không tạo được truy vấn container." | Log + fallback |
| `-4` | Không tạo được symlink | "Không chuẩn bị được đường dẫn tạm." | Kiểm tra `Library/Caches` còn tồn tại |
| `-5` | Daemon trả no result | "Hệ thống từ chối cấp quyền." | Có thể do build iOS đã vá; báo log |
| `-6` | Không có sandbox token | "Không nhận được token." | Log |
| `-255` | Path không hợp lệ | "Đường dẫn không hợp lệ." | Kiểm tra input |
| `> 0` | Thành công | — | Cache handle |

---

## 8. Build / entitlement / đóng gói

### 8.1 `Totorox/Totorox.entitlements` — thêm

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.totorox.app</string>
</array>
```

**Điều kiện:** group này phải có trong provisioning profile dùng để ký. Với build unsigned trong CI
(`CODE_SIGNING_ALLOWED: NO`) thì entitlement chỉ có hiệu lực khi người dùng ký lại bằng profile
có group tương ứng (TrollStore/CoreTrust với entitlement injection, hoặc profile dev của họ).

### 8.2 `project.yml`

Không cần sửa cho file mới (XcodeGen lấy cả thư mục). **Chỉ** cần nếu chọn cách đưa group ID qua
build setting:

```yaml
# (tuỳ chọn, khuyến nghị) để không hard-code group trong code
GCC_PREPROCESSOR_DEFINITIONS:
  - "TOTOROX_APP_GROUP=\"$(TOTOROX_APP_GROUP)\""
```

Nếu dùng cách này, thêm `TOTOROX_APP_GROUP` vào `settings.base` + `.xcconfig` và đọc trong
`WQSignatureAppGroup()` làm fallback khi `SecTask` không đọc được.

### 8.3 Không được làm

- Không bật `com.apple.security.application-groups` rỗng `[]`.
- Không hard-code `group.cc.forcequit.worse-query` (group của app khác — sẽ fail và gây log nhiễu).
- Không thêm `-framework Security` chỉ để đọc entitlement; dùng `dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf")`.

---

## 9. Test plan

### 9.1 Unit test (chạy được trên simulator / CI)

| Test | Nội dung |
|---|---|
| `testSwapCreatesSymlink` | tạo temp dir `caches`, gọi `WQSwapCachesAtPath(caches, target, true)`; assert `lstat` là symlink và `readlink` = target |
| `testSwapRejectsMissingTarget` | `requireTargetExists = true`, target không tồn tại → trả lỗi, `caches` vẫn là thư mục |
| `testSwapReplacesExistingSymlink` | tạo symlink cũ → swap phải thay, không throw |
| `testRestoreRebuildsDirectory` | sau swap, `WQRestoreCachesAtPath` → là thư mục thật, rỗng |
| `testRestoreOnMissingPath` | path không tồn tại → tạo thư mục, trả true |
| `testRecoverIsIdempotent` | gọi `recover` 3 lần → vẫn là thư mục |
| `testSupportPolicyWorseQueryBoundary` | `prefersWorseQuery` đúng tại 25.9 / 26.0 / 27.0 |
| `testErrorMessages` | map mã → chuỗi không rỗng, không lộ đường dẫn nhạy cảm |

Để test được, expose các hàm path qua một header nội bộ `worse_query_testing.h` **chỉ** compile khi
`DEBUG`, hoặc khai báo `NS_SWIFT_NAME` trong `#if DEBUG`.

### 9.2 Checklist thiết bị thật (P4)

- [ ] iOS 26.0: mở container app bất kỳ, đọc `Info.plist`, ghi 1 file, xoá file.
- [ ] iOS 26.5/26.6.1: như trên.
- [ ] iOS 27.0 (build trong `verifiedIOS27Builds`): như trên.
- [ ] iOS 18.7.1: xác nhận **không** gọi worse_query (log không xuất hiện), hành vi không đổi.
- [ ] Sau 50 grant: `ls -l <group>/Library/Caches` là `drwx`, không phải `lrwx`.
- [ ] Kill app giữa lúc grant (debugger) → mở lại app → `recover` dựng lại thư mục, log có `recovering`.
- [ ] Tắt toggle → hành vi quay lại y như trước khi merge.

---

## 10. Rủi ro & cách giảm

| Rủi ro | Mức | Giảm thiểu |
|---|---|---|
| Chữ ký không có App Group → tính năng chết im lặng | Cao | Probe P0 + log rõ + cảnh báo UI |
| Hoán đổi symlink làm hỏng App Group của app khác (nếu dùng group chung) | Cao | Dùng group **riêng của Totorox**, không dùng group của app khác; serialize; restore ngay |
| Crash giữa swap → `Library/Caches` kẹt symlink | Cao | `worse_query_recover()` lúc khởi động + test kill |
| iOS 27 đã vá `container_query` với class 7 | Trung bình | Fallback `bad_query`/kernel; ghi rõ "chưa xác minh" |
| Đa luồng: 2 grant cùng lúc | Trung bình | `NSLock` trong `worse_query.m` + cache ở `ContainerStore` |
| Handle bị dùng sau khi container đổi UUID | Thấp | Giữ nguyên TTL/invalidation hiện có của `activeGrantHandles` |
| Người dùng hiểu nhầm "bật worse_query là có full quyền" | Thấp | Subtitle nói rõ: chỉ mở rộng phạm vi container, không phải kernel access |

**Không được** dựa vào `worse_query` để thay thế `sandbox_escape` cho các thao tác ngoài container
(ví dụ `/var/mobile/Library/Preferences`). Phạm vi thật chỉ là App Group container + những gì
symlink trỏ tới trong lúc token còn sống.

---

## 11. Quyết định cần chốt trước khi code

1. **Group ID dùng cái nào?** `group.com.totorox.app` (mới, sạch) hay tái dùng group có sẵn trong
   profile? → Ảnh hưởng trực tiếp tới việc ký app. **Đề xuất:** group riêng, khai báo trong
   `.entitlements` + `project.yml`.
2. **Có giữ toggle người dùng không**, hay auto theo version? **Đề xuất:** auto + toggle để tắt khi lỗi.
3. **`KernelExploit.run()` trên iOS 26 có nên "thành công một phần"** khi `sandbox_escape` fail nhưng
   `worse_query` grant được? **Đề xuất:** không đổi semantics hiện tại ở P2; chỉ cân nhắc ở P4 sau khi
   có số liệu thật.
4. **Có port `FastContainerScan`-style scan nhanh không?** **Đề xuất:** không, ngoài phạm vi.
5. **Ai xác minh thiết bị thật?** Không có máy → P4 bị block; khi đó merge P1–P3 sau toggle mặc định
   **tắt** và ghi rõ "chưa xác minh thiết bị".

---

## 12. Rollback

- Code: xoá `worse_query.m/.h`, `WorseQuery.swift`, đổi `SandboxGrantRouter.grant` về `bad_query`.
- Dữ liệu người dùng: xoá key `totorox.useWorseQuery`.
- Trạng thái máy: chạy `worse_query_recover()` cho mọi group (hoặc build khôi phục) để chắc chắn
  `Library/Caches` là thư mục thật.
- Không có migration DB, không đụng backend → rollback rẻ.

---

## 13. Definition of Done

- [ ] `worse_query_available()` + `probe()` hiển thị được trong app.
- [ ] Trên iOS 26 thật: duyệt/đọc/ghi container app khác thành công, log ghi `backend=worse_query`.
- [ ] Trên iOS ≤ 18.7.1: không có log worse_query, hành vi không đổi, test cũ xanh.
- [ ] 100% nhánh lỗi có log + thông điệp người dùng.
- [ ] `Library/Caches` của group luôn được dựng lại sau mỗi lần grant và sau khi kill app.
- [ ] Unit test mới xanh trên CI (`.github/workflows/build-and-test.yml`).
- [ ] `README.md` + `AGENTS.md` cập nhật (cây thư mục + mô tả backend).
- [ ] PR ghi rõ ma trận thiết bị đã thử và những máy **chưa** thử.

---

## 14. Tham chiếu bằng chứng

| Hạng mục | Giá trị |
|---|---|
| IPA | `Exploit-v2.2.1.ipa`, sha256 `f2e16f77af19cb7196f7abfa578fee97f8e75cf52a8a39946cbaec6371ba7202` |
| Binary | `Payload/bad_query.app/bad_query`, sha256 `acf06960523b4ccc1bdec0d109def09dcf6a71cedabc485bf2210ec5615703b6` |
| `_worse_query` | `0x100015138` |
| `_worse_query_release` | `0x1000154c4` |
| `___worse_query_load_api_block_invoke` | `0x10001550c` |
| helper dựng lại `Library/Caches` | `0x100015400` |
| `BadQueryFileAccess.worseQueryEligible` | `0x10002772c` (major > 25) |
| `worseQueryTryBoth` | `0x10002c260` |
| `WQLSWithGrant` / `WQGrantPath` | `0x10000d894` / `0x10000eab8` |
| `FastContainerScan.consume` | `0x1001321d4`, `0x100132278` |
| `shouldPreferWorseQuery` (dead code) | `0x1001487d0` |
| CFString `Library/Caches` | `0x100366540` |
| Chuỗi log/UI | `0x10029afe0`, `0x10029b090`, `0x1002a5af0`, `0x1002a6270` |
| Entitlement group trong profile tham chiếu | `group.9a115986a8222d1f.{1..5}` |
