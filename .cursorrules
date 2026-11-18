# AGENTS.md — Quy Tắc & Kiến Trúc Dự Án Totorox

Tài liệu này cung cấp bản đồ kiến trúc hệ thống, cấu trúc thư mục, schema database thực tế và các quy tắc bắt buộc cho mọi AI Agent khi làm việc trên repository **Totorox**.

---

## 1. Tổng quan Kiến trúc, Phiên bản & Hạ tầng Mạng

- **Phiên bản hiện hành của toàn dự án:** **`3.0`** (`MARKETING_VERSION = "3.0"` trong `project.yml`, bản build CI xuất ra `Totorox-3.0-unsigned.ipa` / artifact `Totorox-3.0-unsigned-ipa`, Backend FastAPI `3.0.0`).
- **Tài liệu theo dõi tiến độ trung tâm:** `TOTOROX_3.0_PROGRESS.md` (cùng các tài liệu thành phần như `WORSE_QUERY_PROGRESS.md`, `WORSE_QUERY_INTEGRATION_PLAN.md`, `HANDOFF_TO_NEW_AGENT.md`).
- **Tên miền chính:** `totorox.io.vn` (chạy qua Cloudflare Tunnel cố định).
- **`https://api.totorox.io.vn`**: Endpoint API chính phục vụ ứng dụng iOS (`Totorox/`).
- **`https://admin.totorox.io.vn`**: Giao diện Web Admin Dashboard (được bảo vệ bởi **Subdomain Guard Middleware** trong `admin.py`; mọi truy cập vào `/` hoặc `/admin/*` từ host không nằm trong `ALLOWED_ADMIN_HOSTS` như `api.totorox.io.vn` sẽ tự động trả về `404 Not Found`).

---

## 2. Cấu trúc Thư mục Dự án

```text
Totorox/
├── AGENTS.md                       # File quy tắc & bản đồ dự án cho AI Agent
├── .cursorrules                    # Bản sao đồng bộ quy tắc từ AGENTS.md
├── TOTOROX_3.0_PROGRESS.md         # Nhật ký tiến độ trung tâm của thế hệ Totorox 3.0 (BẮT BUỘC cập nhật)
├── WORSE_QUERY_INTEGRATION_PLAN.md # Kế hoạch kỹ thuật tích hợp Tầng 4 worse_query (iOS 26+)
├── WORSE_QUERY_PROGRESS.md         # Báo cáo tiến độ chi tiết module worse_query
├── HANDOFF_TO_NEW_AGENT.md         # Tài liệu bàn giao kiến trúc Hybrid iOS/Backend ban đầu
├── project.yml                     # Cấu hình XcodeGen cho app iOS (MARKETING_VERSION: "3.0")
├── .github/workflows/
│   └── build-and-test.yml          # CI chạy XCTest & đóng gói Totorox-3.0-unsigned.ipa
├── README.md
├── sever_security.md
├── Totorox/                        # Source code App iOS (Swift / Objective-C / C)
│   ├── App.swift, ContentView.swift, Info.plist, Totorox.entitlements
│   ├── engine/                     # Logic cốt lõi: AovModMergerEngine, FileIOEngine, PatchZipConverter
│   ├── helpers/                    # APIService, LicenseManager, DeviceIDManager, WorseQuery, SandboxGrantRouter, v.v.
│   ├── exploit/ & kexploit/        # Các module C/Obj-C (aov_zstd, bad_query, worse_query, mcm_bridge, kexploit_opa334, sandbox_escape, ...)
│   └── views/                      # Giao diện SwiftUI (ActivationView, MergeFileView, OverwriteFileView, PatchConverterView, ...)
├── TotoroxTests/                   # Unit test cho iOS Client (XCTest)
├── Totorox-Backend/                # Backend Python (FastAPI 3.0.0 + SQLite WAL)
│   ├── main.py                     # Core FastAPI server & API cho app iOS
│   ├── admin.py                    # Backend Web Admin Dashboard & Subdomain Guard Middleware
│   ├── admin.html                  # Giao diện Web Admin Dashboard (Tailwind CSS + Alpine.js)
│   ├── admin_keys.py               # Công cụ CLI quản trị dự phòng trên terminal
│   ├── store.py & store.html       # Web Store bán gói tự động (PayOS & OxaPay)
│   ├── database.py                 # Quản lý SQLite WAL (licenses.db), schema, auth, quota & redeem
│   ├── core_processor.py           # Xử lý mod (overwrite-plan, convert-header, merge-plan)
│   ├── aov_zstd_dict.py            # Từ điển Zstd
│   ├── test_backend.py             # Test suite chính cho Backend & Engine gộp mod
│   ├── test_store.py               # Test suite cho Web Store & Webhook thanh toán
│   ├── requirements.txt
│   └── licenses.db                 # File database SQLite (dùng chung cho main.py, admin.py, admin_keys.py)
├── scripts/                        # Script hỗ trợ build & test
└── analysis_3105/                  # Tài liệu & script phân tích kỹ thuật
```

---

## 3. Bản đồ Các File Quan Trọng trong `Totorox-Backend`

### `main.py` — Core FastAPI Server
Chứa cấu hình FastAPI, rate limiter (`slowapi`), kiểm soát giới hạn kích thước upload (`MAX_UPLOAD_BYTES`, `MAX_MERGE_UPLOAD_BYTES`, `MAX_OVERWRITE_PLAN_BYTES`), gắn `admin_subdomain_middleware` + `admin_router`, và các API cho app iOS:
- `GET /health`
- **Xác thực & Tài khoản:**
  - `POST /api/v1/auth/register`
  - `POST /api/v1/auth/login`
  - `POST /api/v1/auth/logout`
  - `POST /api/v1/auth/redeem` (bắt buộc đã xác minh `udid` phần cứng thật)
  - `GET /api/v1/auth/me`
- **Xác minh UDID phần cứng thật (Apple OTA Profile Service):**
  - `GET /api/v1/device/profile?username={username}` (trả về `.mobileconfig` XML `application/x-apple-aspen-config`)
  - `POST /api/v1/device/callback?username={username}` (parse XML plist trong body Apple, lưu `udid` + trả về `301` redirect)
  - `GET /api/v1/device/complete` (HTML Dark Mode tự redirect `totorox://udid-verified?...` + nút mở app)
- **Xử lý Mod (bắt buộc gói còn hạn/lượt & khớp `udid`):**
  - `POST /api/v1/overwrite-plan`
  - `POST /api/v1/convert-header`
  - `POST /api/v1/merge-plan`

### `admin.py` & `admin.html` — Web Admin Dashboard
Hệ thống quản trị web hoàn chỉnh (FastAPI + Tailwind CSS + Alpine.js), xác thực bằng HMAC token qua Cookie (`totorox_admin_session`) hoặc Bearer header. Đã có đầy đủ tính năng:
- Giao diện chính: `GET /`, `GET /admin`
- Phiên đăng nhập Admin: `POST /admin/api/login`, `POST /admin/api/logout`, `GET /admin/api/session`
- Thống kê tổng quan: `GET /admin/api/overview`
- Quản lý Redeem Code / Key:
  - Liệt kê & lọc: `GET /admin/api/keys`
  - Tạo key hàng loạt: `POST /admin/api/keys/generate`
  - Thu hồi (ban / `revoke`), khôi phục (`unrevoke`), và **Xóa vĩnh viễn (`delete`)**: `POST /admin/api/keys/{license_key}/action`
- Quản lý Người dùng (Users):
  - Tìm kiếm & liệt kê: `GET /admin/api/users`
  - Khóa / Mở khóa User: `POST /admin/api/users/{user_id}/ban`
  - Gia hạn ngày / cộng lượt dùng / set vô hạn: `POST /admin/api/users/{user_id}/extend`
  - Reset UDID / HWID thiết bị & đăng xuất phiên cũ: `POST /admin/api/users/{user_id}/reset-udid`

### `admin_keys.py` — Admin CLI (Terminal)
Công cụ dòng lệnh dự phòng dùng chung file SQLite `licenses.db` với `main.py` và `admin.py`. Các lệnh hiện có:
- `create` (`--days`, `--uses`/`--quota`, `--key`)
- `list`
- `users`
- `ban` (`--key`)
- `ban-user` (`--user`, `--unban`)
- `reset-hwid` (`--user`)
- `reset-usage` (`--user`)
- `extend` (`--user`, `--days`)

### `database.py` — Lớp Dữ liệu SQLite WAL
Cung cấp `get_connection()`, `init_db()`, cơ chế tự động migration cột thiếu, `register_user()`, `login_user()`, `logout_user()`, `get_user_by_username()`, `bind_device_udid()`, `authenticate_token()`, `consume_user_usage()`, `redeem_code()`.


### `store.py` & `store.html` — Web Store bán key tự động (`totorox.io.vn`)
- `store.py`: `register_store(app, limiter)` (gọi trong `main.py`) gắn middleware `/` -> `store.html` cho host `totorox.io.vn`/`www` (cấu hình `TOTOROX_STORE_HOSTS`; `/store` dùng để test local), API `GET /api/v1/store/packages`, `POST /api/v1/store/login` (token `st.` stateless, KHÔNG đổi `users.active_token` của app iOS), `GET /api/v1/store/me`, `POST /api/v1/store/create-order`, `GET /api/v1/store/orders/{order_code}`, `GET /api/v1/store/my-orders`, webhook `POST /api/v1/payment/payos-webhook` (HMAC-SHA256 trên `data`) và `POST /api/v1/payment/oxapay-webhook` (HMAC-SHA512 raw body, header `HMAC`, chỉ `status == "Paid"`).
- Biến môi trường: `PAYOS_CLIENT_ID`, `PAYOS_API_KEY`, `PAYOS_CHECKSUM_KEY`, `OXAPAY_MERCHANT_API_KEY`, `TOTOROX_STORE_URL`.
- `database.py`: bảng `orders` (`_ensure_orders_table`), `STORE_PACKAGES` (chỉnh giá/gói tại đây), `create_order`, `fulfill_order` (idempotent, cộng hạn/lượt vào `users`), `admin_list_orders`.
- Admin: `GET /admin/api/orders` + tab "Đơn hàng" trong `admin.html`; CLI `admin_keys.py orders`.
- Subdomain Isolation giữ nguyên: `/admin*` trên host store/api vẫn `404`; `/` trên host api vẫn `404`.

---

## 4. Schema SQLite Hiện Tại (`licenses.db`)

> **Lưu ý:** Schema được khởi tạo tại `init_db()` (`database.py`) và bổ sung cột/index admin tại `ensure_admin_schema()` (`admin.py`).

### Bảng `users`
| Cột | Kiểu & Ràng buộc | Mô tả |
| :--- | :--- | :--- |
| `id` | `INTEGER PRIMARY KEY AUTOINCREMENT` | ID tự tăng của user |
| `username` | `TEXT NOT NULL UNIQUE COLLATE NOCASE` | Tên đăng nhập (không phân biệt hoa thường) |
| `password_hash` | `TEXT NOT NULL` | Mật khẩu đã băm |
| `expires_at` | `INTEGER DEFAULT NULL` | Unix timestamp hết hạn gói (`NULL` = chưa có gói) |
| `max_uses` | `INTEGER NOT NULL DEFAULT 0` | Tổng lượt tối đa (`-1` = vô hạn, chịu giới hạn anti-spam ngày) |
| `used_count` | `INTEGER NOT NULL DEFAULT 0` | Tổng lượt đã sử dụng |
| `daily_used` | `INTEGER NOT NULL DEFAULT 0` | Số lượt đã dùng trong ngày |
| `daily_reset_date` | `TEXT DEFAULT NULL` | Ngày reset bộ đếm ngày |
| `active_token` | `TEXT DEFAULT NULL` | Token phiên đăng nhập hiện tại (Index: `idx_users_active_token`) |
| `hwid` | `TEXT DEFAULT NULL` | Mã thiết bị đồng bộ hiển thị cho Admin (`admin.py`, `admin_keys.py`) |
| `udid` | `TEXT DEFAULT NULL` | UDID phần cứng thật xác minh qua Apple OTA (Index: `idx_users_udid`) |
| `is_banned` | `INTEGER NOT NULL DEFAULT 0` | `1` = bị khóa, `0` = bình thường |
| `created_at` | `INTEGER NOT NULL` | Unix timestamp tạo tài khoản |

### Bảng `licenses` (Redeem Codes)
| Cột | Kiểu & Ràng buộc | Mô tả |
| :--- | :--- | :--- |
| `license_key` | `TEXT PRIMARY KEY` | Mã kích hoạt (VD: `TOTOROX-XXXX-XXXX-XXXX`) |
| `hwid` | `TEXT DEFAULT NULL` | Trường legacy (hiện HWID gắn theo `users.hwid`) |
| `expires_at` | `INTEGER DEFAULT NULL` | Trường legacy |
| `is_banned` | `INTEGER DEFAULT 0` | `1` = đã bị thu hồi / vô hiệu hóa |
| `max_uses` | `INTEGER DEFAULT -1` | Số lượt của mã (`-1` = vô hạn) |
| `used_count` | `INTEGER DEFAULT 0` | Trường legacy |
| `daily_used` | `INTEGER DEFAULT 0` | Trường legacy |
| `daily_reset_date` | `TEXT DEFAULT NULL` | Trường legacy |
| `duration_days` | `INTEGER DEFAULT NULL` | Số ngày cộng thêm khi user nạp mã |
| `redeemed_by` | `INTEGER DEFAULT NULL` | `users.id` của người đã nạp mã |
| `redeemed_at` | `INTEGER DEFAULT NULL` | Unix timestamp lúc nạp (Index: `idx_licenses_redeemed_at`) |
| `created_at` | `INTEGER DEFAULT NULL` | Unix timestamp lúc tạo mã (Index: `idx_licenses_created_at`) |
| `note` | `TEXT DEFAULT ''` | Ghi chú admin (thêm bởi `ensure_admin_schema()` trong `admin.py`) |

### Bảng `schema_meta`
| Cột | Kiểu & Ràng buộc | Mô tả |
| :--- | :--- | :--- |
| `key` | `TEXT PRIMARY KEY` | Tên khóa metadata |
| `value` | `TEXT NOT NULL` | Giá trị metadata |

---

## 5. Quy tắc Bắt Buộc Dành Cho AI Agent

1. **Đọc đủ ngữ cảnh trước khi trả lời hoặc viết code:**
   - Bất cứ khi nào được hỏi về tính năng quản trị, key/redeem code, user hoặc database, **BẮT BUỘC** phải đọc đồng thời cả `main.py`, `admin.py`, `database.py` và `admin_keys.py`.
   - Tuyệt đối không chỉ đọc mỗi `admin_keys.py` rồi kết luận hệ thống thiếu tính năng (ví dụ: chức năng xóa vĩnh viễn key, tạo key hàng loạt, thống kê, ghi chú `note` đều đã có sẵn trong `admin.py` và `admin.html`).

2. **Đồng bộ Database & Chức năng:**
   - Mọi thay đổi về cấu trúc bảng SQLite (thêm cột, đổi kiểu dữ liệu, thêm index) phải được kiểm tra và cập nhật đồng bộ trên cả `database.py`, `main.py`, `admin.py` và `admin_keys.py` để tránh xung đột dữ liệu hoặc lỗi thiếu cột khi chạy độc lập CLI/Server.

3. **Bảo toàn Subdomain Isolation:**
   - Tuyệt đối không được vô hiệu hóa, nới lỏng hoặc làm hỏng `admin_subdomain_middleware` và `require_admin` trong `admin.py` / `main.py`.
   - Mọi request tới `/` hoặc `/admin/*` xuất phát từ `api.totorox.io.vn` (hoặc bất kỳ host nào ngoài `ALLOWED_ADMIN_HOSTS`) **bắt buộc phải trả về `404 Not Found`**.

4. **Chuẩn Phiên bản `3.0` & Bắt buộc Cập nhật Tiến độ `.md` cho Đa Agent:**
   - Toàn bộ dự án hiện vận hành ở phiên bản **`3.0`** (bao gồm `MARKETING_VERSION: "3.0"` trong `project.yml` và tên gói build `Totorox-3.0-unsigned.ipa` trong `.github/workflows/build-and-test.yml`). Không quay ngược tên bản build hay version về `2.0`/`1.x`.
   - Trước khi bắt đầu làm việc, AI Agent phải đọc `TOTOROX_3.0_PROGRESS.md` (và các file `.md` liên quan như `WORSE_QUERY_PROGRESS.md`) để nắm trạng thái working tree của các Agent trước, tránh ghi đè hoặc revert nhầm code đang làm dở.
   - Làm dự án đến đâu **BẮT BUỘC** phải ghi chép cập nhật ngay đến đó vào `TOTOROX_3.0_PROGRESS.md` (hoặc tạo/cập nhật file `.md` chuyên biệt của hạng mục rồi liên kết vào `TOTOROX_3.0_PROGRESS.md`), nêu rõ: ngày thực hiện, nguyên nhân/mục tiêu, danh sách file đã sửa, kết quả chạy test và bước tiếp theo.
