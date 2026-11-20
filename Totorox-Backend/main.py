import gc
import hashlib
import hmac
import html
import json
import os
import plistlib
import re
import shutil
import threading
import time
import traceback
import uuid
from pathlib import Path
from urllib.parse import quote

from fastapi import FastAPI, Request, UploadFile, File, Form, HTTPException, Query
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response
from pydantic import BaseModel, Field
from slowapi import Limiter
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from starlette.concurrency import run_in_threadpool

from database import (
    MOD_STORAGE_DIR,
    authenticate_token,
    bind_device_udid,
    claim_next_merge_job,
    cleanup_expired_merge_jobs,
    complete_merge_job,
    consume_user_usage,
    create_merge_job,
    ensure_mods_table,
    fail_merge_job,
    get_merge_job,
    get_mod_by_id,
    get_user_by_username,
    increment_mod_download,
    init_db,
    list_mods,
    login_user,
    logout_user,
    recover_stale_merge_jobs,
    redeem_code,
    register_user,
)

from core_processor import (
    ConvertHeaderRequest,
    compute_overwrite_plan,
    convert_header as core_convert_header,
    merge_plan as core_merge_plan,
    PatchProjectLight,
)

app = FastAPI(title="Totorox Backend", version="3.0.0")

init_db()

# kích hoạt Admin Dashboard cùng Middleware khóa Subdomain
from admin import (
    admin_subdomain_middleware,
    ensure_admin_schema,
    router as admin_router,
)

ensure_admin_schema()
app.middleware("http")(admin_subdomain_middleware)
app.include_router(admin_router)

limiter = Limiter(key_func=get_remote_address, default_limits=["60/minute"])
app.state.limiter = limiter

# Web Store (totorox.io.vn): routing `/` -> store.html, API đơn hàng & webhook PayOS/OxaPay
from store import register_store

register_store(app, limiter)


@app.middleware("http")
async def attach_remote_address(request: Request, call_next):
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        request.scope["client"] = (forwarded.split(",")[0].strip(), 0)
    return await call_next(request)


PUBLIC_API_BASE_URL = os.environ.get(
    "TOTOROX_PUBLIC_API_URL",
    "https://api.totorox.io.vn",
).rstrip("/")

MAX_UPLOAD_BYTES = int(os.environ.get("TOTOROX_MAX_UPLOAD_BYTES", 100 * 1024 * 1024))
MAX_MERGE_UPLOAD_BYTES = int(os.environ.get("TOTOROX_MAX_MERGE_BYTES", 100 * 1024 * 1024))
MAX_MERGE_CHUNK_BYTES = 8 * 1024 * 1024
MAX_OVERWRITE_PLAN_BYTES = 8 * 1024 * 1024
MAX_MULTIPART_OVERHEAD_BYTES = 1024 * 1024

_UPLOAD_LIMITS = {
    "/api/v1/convert-header": MAX_UPLOAD_BYTES,
    "/api/v1/merge-plan": MAX_MERGE_UPLOAD_BYTES,
    "/api/v1/merge-plan/jobs": MAX_MERGE_UPLOAD_BYTES,
    "/api/v1/merge-plan/chunks": MAX_MERGE_CHUNK_BYTES,
    "/api/v1/overwrite-plan": MAX_OVERWRITE_PLAN_BYTES,
}


def _megabytes(limit: int) -> str:
    if limit >= 1024 * 1024:
        if limit % (1024 * 1024) == 0:
            return f"{limit // (1024 * 1024)}MB"
        return f"{limit / (1024 * 1024):.1f}MB"
    if limit >= 1024:
        return f"{limit // 1024}KB"
    return f"{limit}B"


def _too_large(limit: int) -> HTTPException:
    return HTTPException(status_code=413, detail=f"Tệp vượt quá giới hạn {_megabytes(limit)}.")


@app.middleware("http")
async def enforce_body_size(request: Request, call_next):
    """Chặn sớm theo `Content-Length` trước khi FastAPI parse body/multipart vào RAM."""
    limit = _UPLOAD_LIMITS.get(request.url.path.rstrip("/"))
    if limit is not None:
        raw_length = request.headers.get("content-length")
        if raw_length:
            try:
                length = int(raw_length)
            except ValueError:
                length = None
            if length is not None and length > limit + MAX_MULTIPART_OVERHEAD_BYTES:
                return JSONResponse(
                    status_code=413,
                    content={"detail": f"Tệp vượt quá giới hạn {_megabytes(limit)}."},
                )
    return await call_next(request)


API_HMAC_SECRET = os.environ.get(
    "TOTOROX_API_HMAC_SECRET",
    "d0b244628b4dc78ed0fd7097f188cb1dca7c5b8644ca84d2",
).strip()
HMAC_MAX_SKEW_SECONDS = max(15, int(os.environ.get("TOTOROX_HMAC_MAX_SKEW_SECONDS", 60)))
# Các endpoint upload tệp lớn (đi qua proxy có request buffering) có thể mất > 60s để đẩy xong body.
HMAC_UPLOAD_MAX_SKEW_SECONDS = max(
    HMAC_MAX_SKEW_SECONDS,
    int(os.environ.get("TOTOROX_HMAC_UPLOAD_MAX_SKEW_SECONDS", 300)),
)

_HMAC_UPLOAD_PATHS = {
    "/api/v1/convert-header",
    "/api/v1/merge-plan",
    "/api/v1/merge-plan/jobs",
    "/api/v1/merge-plan/chunks",
}

_HMAC_PROTECTED_PATHS = {
    "/api/v1/auth/register",
    "/api/v1/auth/login",
    "/api/v1/auth/logout",
    "/api/v1/auth/redeem",
    "/api/v1/auth/me",
    "/api/v1/overwrite-plan",
    "/api/v1/convert-header",
    "/api/v1/merge-plan",
    "/api/v1/merge-plan/jobs",
    "/api/v1/merge-plan/jobs/result",
    "/api/v1/merge-plan/chunks",
    "/api/v1/mods",
    "/api/v1/mods/download",
    "/api/v1/device/claim",
}

_REPLAY_NONCES: dict[str, int] = {}
_REPLAY_LOCK = threading.Lock()


def compute_api_hmac_signature(
    method: str,
    path: str,
    timestamp: str,
    nonce: str,
    hwid: str = "",
    authorization: str = "",
    secret: str | None = None,
) -> str:
    canonical = "\n".join(
        [
            method.upper(),
            path,
            timestamp.strip(),
            nonce.strip(),
            hwid.strip(),
            authorization.strip(),
        ]
    )
    key_bytes = (API_HMAC_SECRET if secret is None else secret).encode("utf-8")
    return hmac.new(key_bytes, canonical.encode("utf-8"), hashlib.sha256).hexdigest()


@app.middleware("http")
async def verify_api_hmac(request: Request, call_next):
    """Xác thực chữ ký HMAC-SHA256 + timestamp + nonce chống replay cho API app iOS."""
    path = request.url.path.rstrip("/")
    if path not in _HMAC_PROTECTED_PATHS or not API_HMAC_SECRET:
        return await call_next(request)

    ts_raw = request.headers.get("X-Timestamp", "").strip()
    nonce = request.headers.get("X-Nonce", "").strip()
    signature = request.headers.get("X-Signature", "").strip().lower()

    if not ts_raw or not nonce or len(nonce) < 8 or len(nonce) > 128 or len(signature) != 64:
        return JSONResponse(
            status_code=403,
            content={"detail": "Thiếu chữ ký xác thực yêu cầu (HMAC). Vui lòng cập nhật ứng dụng Totorox mới nhất."},
        )

    try:
        ts_val = int(ts_raw)
    except ValueError:
        return JSONResponse(
            status_code=403,
            content={"detail": "X-Timestamp không hợp lệ."},
        )

    allowed_skew = (
        HMAC_UPLOAD_MAX_SKEW_SECONDS
        if path in _HMAC_UPLOAD_PATHS
        else HMAC_MAX_SKEW_SECONDS
    )
    now = int(time.time())
    if abs(now - ts_val) > allowed_skew:
        return JSONResponse(
            status_code=403,
            content={"detail": "Yêu cầu đã hết hạn hoặc giờ thiết bị bị lệch. Vui lòng bật ngày giờ tự động."},
        )

    hwid_hdr = request.headers.get("X-HWID", "").strip()
    auth_hdr = request.headers.get("Authorization", "").strip()
    expected = compute_api_hmac_signature(
        request.method,
        request.url.path,
        ts_raw,
        nonce,
        hwid_hdr,
        auth_hdr,
    )
    if not hmac.compare_digest(expected, signature):
        return JSONResponse(
            status_code=403,
            content={"detail": "Chữ ký xác thực yêu cầu (HMAC) không hợp lệ."},
        )

    replay_key = f"{ts_raw}:{nonce}"
    with _REPLAY_LOCK:
        if len(_REPLAY_NONCES) > 1024:
            expired = [k for k, exp in _REPLAY_NONCES.items() if exp < now]
            for k in expired:
                _REPLAY_NONCES.pop(k, None)
        if _REPLAY_NONCES.get(replay_key, 0) >= now:
            return JSONResponse(
                status_code=403,
                content={"detail": "Yêu cầu bị trùng lặp (Replay detected)."},
            )
        _REPLAY_NONCES[replay_key] = now + allowed_skew

    # Force-update / kill-switch: bản IPA cũ thiếu hoặc build < MIN_REQUIRED_BUILD
    # → 426 Upgrade Required, dẫn về link Telegram.
    raw_build = (request.headers.get("X-App-Build") or "").strip()
    try:
        client_build = int(raw_build) if raw_build else 0
    except ValueError:
        client_build = 0
    if client_build < MIN_REQUIRED_BUILD:
        return JSONResponse(
            status_code=426,
            content={
                "detail": f"Bản ứng dụng của bạn đã quá cũ. Vui lòng tải bản mới tại \n{DOWNLOAD_URL}.",
            },
        )

    return await call_next(request)


@app.exception_handler(RateLimitExceeded)
async def rate_limit_exceeded_handler(request: Request, exc: RateLimitExceeded):
    return JSONResponse(
        status_code=429,
        content={"detail": "Quá nhiều yêu cầu. Vui lòng thử lại sau."},
    )


class AuthCredentialsBody(BaseModel):
    username: str
    password: str
    udid: str | None = None


class RedeemCodeBody(BaseModel):
    code: str
    udid: str | None = None


class OverwritePlanBody(BaseModel):
    source_paths: list[str] = Field(default_factory=list)
    target_paths: list[str] = Field(default_factory=list)
    target_bundle_id: str | None = None
    target_subfolder: str | None = None
    source_sizes: dict[str, int] | None = None
    udid: str | None = None


def _extract_bearer_token(
    request: Request,
    body_udid: str | None = None,
) -> tuple[str, str | None]:
    auth_header = request.headers.get("Authorization", "").strip()
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(
            status_code=401,
            detail="Thiếu header Authorization: Bearer <token>.",
        )
    token = auth_header[7:].strip()
    if not token:
        raise HTTPException(
            status_code=401,
            detail="Authorization Bearer token rỗng.",
        )
    header_udid = (
        request.headers.get("X-HWID")
        or request.headers.get("X-UDID")
        or ""
    ).strip()
    clean_body_udid = (body_udid or "").strip()
    if header_udid and clean_body_udid and header_udid != clean_body_udid:
        raise HTTPException(
            status_code=403,
            detail="UDID thiết bị không khớp giữa header và payload.",
        )
    effective_udid = (header_udid or clean_body_udid) or None
    return token, effective_udid


def _require_user(
    request: Request,
    *,
    body_udid: str | None = None,
    require_verified_udid: bool = False,
    require_active_plan: bool = False,
    require_quota: bool = False,
) -> dict:
    token, hwid = _extract_bearer_token(request, body_udid=body_udid)
    ok, status, msg, user = authenticate_token(
        token,
        hwid,
        require_verified_udid=require_verified_udid,
        require_active_plan=require_active_plan,
        require_quota=require_quota,
    )
    if not ok or user is None:
        raise HTTPException(status_code=status, detail=msg)
    return user


def _temporary_work_dir() -> Path:
    work_dir = Path("tmp") / uuid.uuid4().hex
    work_dir.mkdir(parents=True, exist_ok=True)
    return work_dir


async def _cleanup_work_dir(work_dir: Path) -> None:
    try:
        if work_dir.exists():
            shutil.rmtree(work_dir, ignore_errors=True)
        work_dir.parent.rmdir()
    except OSError:
        pass
    except Exception:
        pass


def _apply_user_usage_fields(payload: dict, user: dict) -> dict:
    for name in (
        "used_count",
        "max_uses",
        "remaining_uses",
        "expires_at",
        "daily_used",
        "daily_cap",
        "has_active_plan",
    ):
        if name in user:
            payload[name] = user[name]
    payload["user"] = user
    return payload


_UPLOAD_CHUNK_BYTES = 1024 * 1024
_GC_COLLECT_THRESHOLD_BYTES = 4 * 1024 * 1024


async def _save_upload_to_path(file: UploadFile, dest_path: Path, limit: int) -> int:
    """Ghi upload theo từng chunk 1 MiB xuống đĩa để tránh nhân đôi buffer trong RAM."""
    total = 0
    with dest_path.open("wb") as out:
        while True:
            chunk = await file.read(_UPLOAD_CHUNK_BYTES)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise _too_large(limit)
            out.write(chunk)
    return total


@app.get("/health")
async def health():
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Force Update / Kill Switch
# Tăng MIN_REQUIRED_BUILD trên VPS (env TOTOROX_MIN_BUILD) là ép toàn bộ
# client cũ bị khoá ngay — không cần deploy code mới.
# ---------------------------------------------------------------------------
MIN_REQUIRED_BUILD: int = int(os.environ.get("TOTOROX_MIN_BUILD", "2"))
DOWNLOAD_URL: str = os.environ.get(
    "TOTOROX_DOWNLOAD_URL",
    "https://t.me/+wurdGhvbcT0wZGJl",   # TODO: thay bằng link tải IPA thực tế
)


@app.get("/api/v1/bootstrap")
@limiter.limit("30/minute")
async def bootstrap(
    request: Request,
    x_app_build: str = None,
):
    """Kiểm tra phiên bản build; trả về cấu hình cốt lõi hoặc yêu cầu cập nhật.
    Header: X-App-Build (integer string, từ CFBundleVersion)
    """
    raw_build = (request.headers.get("X-App-Build") or "").strip()
    try:
        client_build = int(raw_build) if raw_build else 0
    except ValueError:
        client_build = 0

    if client_build < MIN_REQUIRED_BUILD:
        return JSONResponse(
            status_code=200,
            content={
                "status": "outdated",
                "force_update": True,
                "min_build": MIN_REQUIRED_BUILD,
                "download_url": DOWNLOAD_URL,
                "message": "Phiên bản này đã cũ. Vui lòng tải bản mới để tiếp tục sử dụng.",
            },
        )
    return JSONResponse(
        status_code=200,
        content={
            "status": "ok",
            "force_update": False,
            "min_build": MIN_REQUIRED_BUILD,
            "core_config": {
                "cdn_base": PUBLIC_API_BASE_URL,
            },
        },
    )


@app.post("/api/v1/auth/register")
@limiter.limit("20/minute")
async def auth_register(request: Request, body: AuthCredentialsBody):
    ok, status, msg, user, token = register_user(body.username, body.password, body.udid)
    if not ok:
        raise HTTPException(status_code=status, detail=msg)
    return {
        "ok": True,
        "message": msg,
        "token": token,
        "user": user,
    }


@app.post("/api/v1/auth/login")
@limiter.limit("30/minute")
async def auth_login(request: Request, body: AuthCredentialsBody):
    ok, status, msg, user, token = login_user(body.username, body.password, body.udid)
    if not ok:
        raise HTTPException(status_code=status, detail=msg)
    return {
        "ok": True,
        "message": msg,
        "token": token,
        "user": user,
    }


@app.post("/api/v1/auth/logout")
@limiter.limit("60/minute")
async def auth_logout(request: Request):
    user = _require_user(request, require_active_plan=False, require_quota=False)
    logout_user(user["id"])
    return {"ok": True}


@app.post("/api/v1/auth/redeem")
@limiter.limit("30/minute")
async def auth_redeem(request: Request, body: RedeemCodeBody):
    user = _require_user(
        request,
        body_udid=body.udid,
        require_verified_udid=True,
        require_active_plan=False,
        require_quota=False,
    )
    ok, status, msg, data = redeem_code(user["id"], body.code)
    if not ok or data is None:
        raise HTTPException(status_code=status, detail=msg)
    return {
        "ok": True,
        "message": msg,
        **data,
    }


@app.get("/api/v1/auth/me")
@limiter.limit("120/minute")
async def auth_me(request: Request):
    user = _require_user(request, require_active_plan=False, require_quota=False)
    return {
        "ok": True,
        "user": user,
    }


def _extract_apple_ota_plist(raw_body: bytes) -> dict | None:
    if not raw_body:
        return None
    start = raw_body.find(b"<?xml")
    if start == -1:
        start = raw_body.find(b"<plist")
    if start == -1:
        return None
    end = raw_body.find(b"</plist>", start)
    if end == -1:
        return None
    xml_bytes = raw_body[start : end + len(b"</plist>")]
    try:
        parsed = plistlib.loads(xml_bytes)
    except Exception:
        return None
    return parsed if isinstance(parsed, dict) else None


_UDID_CLAIMS: dict[str, dict] = {}
_UDID_CLAIM_LOCK = threading.Lock()
_UDID_CLAIM_TTL_SECONDS = 900


@app.get("/api/v1/device/profile")
@limiter.limit("60/minute")
async def device_profile(
    request: Request,
    username: str = Query(..., min_length=1, max_length=64),
    claim: str = Query(default="", max_length=128),
):
    clean_user = (username or "").strip()
    if not clean_user:
        raise HTTPException(status_code=400, detail="Thiếu tên đăng nhập.")

    user = get_user_by_username(clean_user)
    if user is None:
        raise HTTPException(status_code=404, detail="Tài khoản không tồn tại.")
    if user.get("is_banned"):
        raise HTTPException(status_code=403, detail="Tài khoản đã bị khóa.")

    clean_claim = (claim or "").strip()
    callback_url = (
        f"{PUBLIC_API_BASE_URL}/api/v1/device/callback"
        f"?username={quote(user['username'], safe='')}"
    )
    if clean_claim:
        callback_url += f"&claim={quote(clean_claim, safe='')}"
    profile_payload = {
        "PayloadContent": {
            "URL": callback_url,
            "DeviceAttributes": ["UDID", "PRODUCT", "VERSION"],
        },
        "PayloadOrganization": "Totorox",
        "PayloadDisplayName": "Totorox Device Verification",
        "PayloadVersion": 1,
        "PayloadUUID": str(
            uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.device.profile.{user['username'].lower()}")
        ).upper(),
        "PayloadIdentifier": "vn.io.totorox.profile-service",
        "PayloadDescription": "Xác minh UDID phần cứng thật để liên kết thiết bị với tài khoản Totorox.",
        "PayloadType": "Profile Service",
    }
    xml_bytes = plistlib.dumps(profile_payload, fmt=plistlib.FMT_XML, sort_keys=False)
    return Response(
        content=xml_bytes,
        media_type="application/x-apple-aspen-config",
        headers={
            "Content-Disposition": 'attachment; filename="totorox_udid.mobileconfig"',
            "Cache-Control": "no-store",
        },
    )


@app.post("/api/v1/device/callback")
@limiter.limit("60/minute")
async def device_callback(
    request: Request,
    username: str = Query(default=""),
    claim: str = Query(default="", max_length=128),
):
    raw_body = await request.body()
    plist_data = _extract_apple_ota_plist(raw_body)
    udid = ""
    if plist_data is not None:
        udid = str(plist_data.get("UDID") or plist_data.get("udid") or "").strip()

    clean_user = (username or "").strip()
    clean_claim = (claim or "").strip()
    if plist_data is None or not clean_user or not udid:
        status = "invalid"
        message = "Không đọc được thông tin UDID từ hồ sơ thiết bị Apple."
    else:
        status, message = bind_device_udid(clean_user, udid)
        if status == "ok" and clean_claim:
            now = int(time.time())
            with _UDID_CLAIM_LOCK:
                if len(_UDID_CLAIMS) > 1024:
                    expired = [k for k, v in _UDID_CLAIMS.items() if v["expires_at"] < now]
                    for k in expired:
                        _UDID_CLAIMS.pop(k, None)
                _UDID_CLAIMS[clean_claim] = {
                    "username": clean_user.lower(),
                    "udid": udid,
                    "expires_at": now + _UDID_CLAIM_TTL_SECONDS,
                }

    query_parts = [f"status={quote(status, safe='')}"]
    if status == "ok" and udid:
        query_parts.append(f"udid={quote(udid, safe='')}")
    if message:
        query_parts.append(f"message={quote(message, safe='')}")

    redirect_url = f"{PUBLIC_API_BASE_URL}/api/v1/device/complete?{'&'.join(query_parts)}"
    return RedirectResponse(url=redirect_url, status_code=301)


@app.get("/api/v1/device/claim")
@limiter.limit("60/minute")
async def device_claim(request: Request, claim: str = Query(..., min_length=8, max_length=128)):
    user = _require_user(request, require_active_plan=False, require_quota=False)
    clean_claim = claim.strip()
    now = int(time.time())
    with _UDID_CLAIM_LOCK:
        entry = _UDID_CLAIMS.get(clean_claim)
        if entry is None or entry["expires_at"] < now:
            _UDID_CLAIMS.pop(clean_claim, None)
            return {"ok": False, "udid": None}
        if entry["username"] != user["username"].lower():
            return {"ok": False, "udid": None}
        _UDID_CLAIMS.pop(clean_claim, None)
        return {"ok": True, "udid": entry["udid"]}


@app.get("/api/v1/device/complete", response_class=HTMLResponse)
@limiter.limit("120/minute")
async def device_complete(
    request: Request,
    status: str = Query(default="ok"),
    udid: str = Query(default=""),
    message: str = Query(default=""),
):
    clean_status = (status or "error").strip().lower()
    clean_udid = (udid or "").strip()
    clean_msg = (message or "").strip()

    safe_udid_for_link = clean_udid if clean_status == "ok" else ""
    deep_link = (
        f"totorox://udid-verified"
        f"?status={quote(clean_status, safe='')}"
        f"&udid={quote(safe_udid_for_link, safe='')}"
    )

    if clean_status == "ok":
        badge_bg = "rgba(34, 197, 94, 0.16)"
        badge_fg = "#4ADE80"
        badge_text = "ĐÃ XÁC MINH UDID"
        heading = "Xác minh thiết bị thành công"
        subtitle = clean_msg or "Thiết bị iPhone của bạn đã được liên kết an toàn với tài khoản Totorox."
    elif clean_status == "conflict":
        badge_bg = "rgba(245, 158, 11, 0.16)"
        badge_fg = "#FBBF24"
        badge_text = "TRÙNG THIẾT BỊ"
        heading = "UDID đã gắn tài khoản khác"
        subtitle = clean_msg or "Thiết bị này đã được liên kết với một tài khoản khác trước đó."
    elif clean_status == "mismatch":
        badge_bg = "rgba(239, 68, 68, 0.16)"
        badge_fg = "#F87171"
        badge_text = "SAI THIẾT BỊ"
        heading = "Tài khoản đã khóa thiết bị khác"
        subtitle = clean_msg or "Tài khoản này đang gắn với một iPhone khác. Hãy liên hệ Admin để Reset UDID."
    else:
        badge_bg = "rgba(239, 68, 68, 0.16)"
        badge_fg = "#F87171"
        badge_text = "XÁC MINH THẤT BẠI"
        heading = "Không thể xác minh thiết bị"
        subtitle = clean_msg or "Đã xảy ra lỗi khi đọc thông tin UDID từ Apple OTA. Vui lòng thử lại."

    udid_block = ""
    if clean_status == "ok" and clean_udid:
        udid_block = f"""
        <div class="udid-box">
          <div class="udid-label">UDID phần cứng đã xác nhận</div>
          <div class="udid-value">{html.escape(clean_udid)}</div>
        </div>
        """

    html_doc = f"""<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
  <title>Totorox — {html.escape(heading)}</title>
  <style>
    :root {{ color-scheme: dark; }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 24px;
      background: radial-gradient(circle at top, #172033 0%, #0B0F17 65%);
      color: #F8FAFC;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
    }}
    .card {{
      width: 100%;
      max-width: 440px;
      background: rgba(19, 26, 38, 0.92);
      border: 1px solid rgba(148, 163, 184, 0.18);
      border-radius: 20px;
      padding: 28px 24px;
      box-shadow: 0 24px 60px rgba(0, 0, 0, 0.55);
      text-align: center;
    }}
    .badge {{
      display: inline-block;
      padding: 6px 12px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.06em;
      background: {badge_bg};
      color: {badge_fg};
      margin-bottom: 16px;
    }}
    h1 {{
      margin: 0 0 10px;
      font-size: 22px;
      line-height: 1.3;
      font-weight: 700;
    }}
    p {{
      margin: 0 0 20px;
      color: #94A3B8;
      font-size: 14px;
      line-height: 1.55;
    }}
    .udid-box {{
      background: #0B0F17;
      border: 1px solid rgba(148, 163, 184, 0.16);
      border-radius: 12px;
      padding: 12px 14px;
      margin-bottom: 22px;
      text-align: left;
    }}
    .udid-label {{
      font-size: 11px;
      color: #64748B;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 6px;
    }}
    .udid-value {{
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 12px;
      color: #E2E8F0;
      word-break: break-all;
    }}
    .btn {{
      display: block;
      width: 100%;
      padding: 14px 18px;
      border-radius: 14px;
      background: linear-gradient(135deg, #2563EB, #3B82F6);
      color: #FFFFFF;
      font-size: 15px;
      font-weight: 700;
      text-decoration: none;
      box-shadow: 0 10px 24px rgba(37, 99, 235, 0.35);
    }}
    .hint {{
      margin-top: 14px;
      margin-bottom: 0;
      font-size: 12px;
      color: #64748B;
    }}
  </style>
</head>
<body>
  <main class="card">
    <div class="badge">{html.escape(badge_text)}</div>
    <h1>{html.escape(heading)}</h1>
    <p>{html.escape(subtitle)}</p>
    {udid_block}
    <a class="btn" id="openAppBtn" href="{html.escape(deep_link)}">Mở lại ứng dụng Totorox</a>
    <p class="hint">Nếu nút trên không mở được app (do dùng Chrome, LiveContainer hoặc chứng chỉ), hãy tự chuyển về ứng dụng Totorox — app sẽ tự động cập nhật UDID.</p>
  </main>
</body>
</html>"""
    return HTMLResponse(content=html_doc, headers={"Cache-Control": "no-store"})


@app.post("/api/v1/overwrite-plan")
@limiter.limit("120/minute")
async def overwrite_plan(request: Request, body: OverwritePlanBody):
    # Yêu cầu tài khoản đã xác minh UDID thật và kích hoạt gói còn hạn; KHÔNG trừ lượt.
    user = _require_user(
        request,
        body_udid=body.udid,
        require_verified_udid=True,
        require_active_plan=True,
        require_quota=False,
    )
    result = await run_in_threadpool(
        compute_overwrite_plan,
        body.source_paths,
        body.target_paths,
        target_bundle_id=body.target_bundle_id,
        target_subfolder=body.target_subfolder,
        source_sizes=body.source_sizes,
    )
    return JSONResponse(content=_apply_user_usage_fields(result, user))


@app.post("/api/v1/convert-header")
@limiter.limit("60/minute")
async def convert_header(
    request: Request,
    mode: str = Form(...),
    password: str | None = Form(default=None),
    udid: str | None = Form(default=None),
    file: UploadFile | None = File(None),
):
    chargeable = mode in ("to_zip", "from_zip")
    user = _require_user(
        request,
        body_udid=udid,
        require_verified_udid=True,
        require_active_plan=True,
        require_quota=chargeable,
    )

    work_dir = _temporary_work_dir()
    saved_path: Path | None = None
    accepted_bytes = 0
    req: ConvertHeaderRequest | None = None
    try:
        if file is not None:
            safe_name = Path(file.filename or "upload.bin").name or "upload.bin"
            saved_path = work_dir / safe_name
            accepted_bytes = await _save_upload_to_path(file, saved_path, MAX_UPLOAD_BYTES)

        data_bytes = saved_path.read_bytes() if saved_path and saved_path.exists() else b""
        if saved_path and saved_path.exists():
            saved_path.unlink(missing_ok=True)
        req = ConvertHeaderRequest(
            data=data_bytes,
            mode=mode,
            password=password,
        )
        del data_bytes
        try:
            result = await run_in_threadpool(core_convert_header, req)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        finally:
            req = None

        response_data = {
            "ok": result.get("ok", True),
            "mode": result.get("mode", mode),
            "password_protected": bool(password),
            "header": result.get("header", {}),
            "toc": result.get("toc", []),
            "note": result.get("note", ""),
        }
        for key in (
            "content_key_b64",
            "key_fingerprint",
            "package_bytes_b64",
            "payload_bytes_b64",
            "zip_bytes_b64",
            "package_id",
            "schema_version",
            "kdf_salt_b64",
            "kdf_iterations",
            "wrapped_content_key_b64",
            "public_content_key_b64",
            "rule_count",
            "payload_bytes",
            "payloads_included",
            "project_source",
        ):
            if key in result:
                response_data[key] = result[key]

        response_data["accepted_bytes"] = accepted_bytes

        # `inspect` miễn phí; chỉ trừ lượt trên tài khoản khi convert thành công.
        if chargeable and result.get("ok", True):
            ok, status, msg, updated_user = consume_user_usage(user["id"])
            if not ok or updated_user is None:
                raise HTTPException(status_code=status, detail=msg)
        else:
            updated_user = user

        return JSONResponse(content=_apply_user_usage_fields(response_data, updated_user))
    finally:
        req = None
        await _cleanup_work_dir(work_dir)
        if accepted_bytes >= _GC_COLLECT_THRESHOLD_BYTES:
            gc.collect()


MAX_CONCURRENT_MERGES = max(1, int(os.environ.get("TOTOROX_MERGE_CONCURRENCY", 1)))
MERGE_JOB_TTL_SECONDS = max(120, int(os.environ.get("TOTOROX_MERGE_JOB_TTL", 900)))
MAX_ACTIVE_MERGE_JOBS_PER_USER = max(1, int(os.environ.get("TOTOROX_MAX_JOBS_PER_USER", 3)))

_MERGE_PROCESS_LOCK = threading.Semaphore(MAX_CONCURRENT_MERGES)
_MERGE_JOB_WAKE = threading.Event()
_MERGE_WORKER_START_LOCK = threading.Lock()
_MERGE_WORKERS_STARTED = False
_MERGE_JOBS_ROOT = Path("tmp") / "merge_jobs"
_MERGE_UPLOADS_ROOT = Path("tmp") / "merge_uploads"
_UPLOAD_ID_RE = re.compile(r"^[a-f0-9]{16,64}$")
_MERGE_UPLOAD_TTL_SECONDS = 1800


def _run_merge_plan_locked(
    config: dict,
    *,
    config_bytes: bytes | None = None,
    include_zip_b64: bool = True,
) -> dict:
    with _MERGE_PROCESS_LOCK:
        return core_merge_plan(
            config,
            config_bytes=config_bytes,
            include_zip_b64=include_zip_b64,
        )


def _cleanup_expired_job_dirs() -> None:
    try:
        expired_ids = cleanup_expired_merge_jobs(MERGE_JOB_TTL_SECONDS)
    except Exception:
        expired_ids = []
    for jid in expired_ids:
        shutil.rmtree(_MERGE_JOBS_ROOT / jid, ignore_errors=True)
    if _MERGE_UPLOADS_ROOT.exists():
        cutoff = time.time() - _MERGE_UPLOAD_TTL_SECONDS
        for sub in _MERGE_UPLOADS_ROOT.iterdir():
            if not sub.is_dir():
                continue
            try:
                if sub.stat().st_mtime < cutoff:
                    shutil.rmtree(sub, ignore_errors=True)
            except OSError:
                pass


def _execute_queued_merge_job(job: dict) -> None:
    job_id = str(job["job_id"])
    job_dir = _MERGE_JOBS_ROOT / job_id
    input_path_raw = job.get("input_path")
    accepted_bytes = int(job.get("accepted_bytes") or 0)
    config_bytes: bytes | None = None
    try:
        raw_cfg = job.get("config_json") or "{}"
        config = json.loads(raw_cfg) if raw_cfg else {}
        if not isinstance(config, dict):
            raise ValueError("config_json phải là object JSON.")

        if input_path_raw:
            inp_path = Path(input_path_raw)
            if inp_path.is_file():
                config_bytes = inp_path.read_bytes()
                inp_path.unlink(missing_ok=True)

        result = _run_merge_plan_locked(
            config,
            config_bytes=config_bytes,
            include_zip_b64=False,
        )
        config_bytes = None

        bundle_bytes = result.pop("_bundle_bytes", None)
        if result.get("ok", True):
            ok, status, msg, _ = consume_user_usage(int(job["user_id"]))
            if not ok:
                shutil.rmtree(job_dir, ignore_errors=True)
                fail_merge_job(job_id, error_code=status, error_detail=msg)
                return

        job_dir.mkdir(parents=True, exist_ok=True)
        result_path = job_dir / "result_bundle.zip"
        if isinstance(bundle_bytes, (bytes, bytearray)):
            result_path.write_bytes(bundle_bytes)
        else:
            result_path.write_bytes(b"")
        del bundle_bytes

        result["accepted_bytes"] = accepted_bytes
        complete_merge_job(
            job_id,
            result_path=str(result_path),
            result_meta_json=json.dumps(result, ensure_ascii=False),
        )
    except ValueError as exc:
        shutil.rmtree(job_dir, ignore_errors=True)
        fail_merge_job(job_id, error_code=400, error_detail=str(exc))
    except Exception:
        traceback.print_exc()
        shutil.rmtree(job_dir, ignore_errors=True)
        fail_merge_job(
            job_id,
            error_code=500,
            error_detail="Máy chủ gặp lỗi khi xử lý gộp tệp mod.",
        )
    finally:
        config_bytes = None
        if accepted_bytes >= _GC_COLLECT_THRESHOLD_BYTES:
            gc.collect()


def _merge_worker_loop() -> None:
    last_cleanup = 0.0
    while True:
        try:
            now_mono = time.monotonic()
            if now_mono - last_cleanup >= 60.0:
                _cleanup_expired_job_dirs()
                last_cleanup = now_mono

            job = claim_next_merge_job()
            if job is not None:
                _execute_queued_merge_job(job)
                continue
        except Exception:
            pass
        _MERGE_JOB_WAKE.wait(timeout=1.0)
        _MERGE_JOB_WAKE.clear()


def _ensure_merge_workers_started(*, recover_stale: bool = False) -> None:
    global _MERGE_WORKERS_STARTED
    with _MERGE_WORKER_START_LOCK:
        if recover_stale:
            try:
                recover_stale_merge_jobs()
            except Exception:
                pass
        if _MERGE_WORKERS_STARTED:
            return
        _MERGE_JOBS_ROOT.mkdir(parents=True, exist_ok=True)
        for idx in range(MAX_CONCURRENT_MERGES):
            t = threading.Thread(
                target=_merge_worker_loop,
                name=f"totorox-merge-worker-{idx}",
                daemon=True,
            )
            t.start()
        _MERGE_WORKERS_STARTED = True


@app.on_event("startup")
def _startup_merge_workers() -> None:
    _ensure_merge_workers_started(recover_stale=True)


@app.post("/api/v1/merge-plan")
@limiter.limit("60/minute")
async def merge_plan(
    request: Request,
    file: UploadFile | None = File(None),
    config_json: str = Form(default=None),
    udid: str | None = Form(default=None),
):
    user = _require_user(
        request,
        body_udid=udid,
        require_verified_udid=True,
        require_active_plan=True,
        require_quota=True,
    )

    work_dir = _temporary_work_dir()
    saved_path: Path | None = None
    accepted_bytes = 0
    config_bytes: bytes | None = None
    try:
        if file is not None:
            safe_name = Path(file.filename or "config.3105").name or "config.3105"
            saved_path = work_dir / safe_name
            accepted_bytes = await _save_upload_to_path(file, saved_path, MAX_MERGE_UPLOAD_BYTES)

        config: dict = {}
        if config_json:
            if len(config_json.encode("utf-8")) > MAX_MERGE_UPLOAD_BYTES:
                raise _too_large(MAX_MERGE_UPLOAD_BYTES)
            try:
                config = json.loads(config_json)
            except (json.JSONDecodeError, ValueError) as exc:
                raise HTTPException(status_code=400, detail=f"config_json không hợp lệ: {exc}") from exc

        if saved_path and saved_path.exists():
            config_bytes = saved_path.read_bytes()
            saved_path.unlink(missing_ok=True)
        try:
            result = await run_in_threadpool(
                _run_merge_plan_locked,
                config,
                config_bytes=config_bytes,
                include_zip_b64=True,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        finally:
            config_bytes = None

        result["accepted_bytes"] = accepted_bytes

        if result.get("ok", True):
            ok, status, msg, updated_user = consume_user_usage(user["id"])
            if not ok or updated_user is None:
                raise HTTPException(status_code=status, detail=msg)
        else:
            updated_user = user

        return JSONResponse(content=_apply_user_usage_fields(result, updated_user))
    finally:
        config_bytes = None
        await _cleanup_work_dir(work_dir)
        if accepted_bytes >= _GC_COLLECT_THRESHOLD_BYTES:
            gc.collect()


def _validate_upload_id(raw_id: str) -> str:
    clean = (raw_id or "").strip().lower()
    if not _UPLOAD_ID_RE.match(clean):
        raise HTTPException(status_code=400, detail="upload_id không hợp lệ.")
    return clean


@app.post("/api/v1/merge-plan/chunks")
@limiter.limit("300/minute")
async def upload_merge_plan_chunk(
    request: Request,
    upload_id: str = Form(...),
    chunk_index: int = Form(..., ge=0, le=255),
    total_chunks: int = Form(..., ge=1, le=256),
    chunk: UploadFile = File(...),
    udid: str | None = Form(default=None),
):
    if chunk_index >= total_chunks:
        raise HTTPException(status_code=400, detail="chunk_index vượt quá total_chunks.")
    user = _require_user(
        request,
        body_udid=udid,
        require_verified_udid=True,
        require_active_plan=True,
        require_quota=True,
    )
    clean_upload_id = _validate_upload_id(upload_id)
    upload_dir = _MERGE_UPLOADS_ROOT / clean_upload_id
    upload_dir.mkdir(parents=True, exist_ok=True)
    meta_path = upload_dir / "meta.json"
    if meta_path.is_file():
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception as exc:
            raise HTTPException(status_code=400, detail="Metadata upload không hợp lệ.") from exc
        if int(meta.get("user_id") or -1) != int(user["id"]):
            raise HTTPException(status_code=403, detail="Không có quyền ghi vào upload_id này.")
    else:
        meta_path.write_text(
            json.dumps({"user_id": int(user["id"]), "created_at": int(time.time())}),
            encoding="utf-8",
        )

    part_path = upload_dir / f"part_{chunk_index:05d}.bin"
    received = await _save_upload_to_path(chunk, part_path, MAX_MERGE_CHUNK_BYTES)

    total_so_far = sum(
        p.stat().st_size for p in upload_dir.glob("part_*.bin") if p.is_file()
    )
    if total_so_far > MAX_MERGE_UPLOAD_BYTES:
        shutil.rmtree(upload_dir, ignore_errors=True)
        raise _too_large(MAX_MERGE_UPLOAD_BYTES)

    return {
        "ok": True,
        "upload_id": clean_upload_id,
        "chunk_index": chunk_index,
        "received_bytes": received,
    }


@app.post("/api/v1/merge-plan/jobs")
@limiter.limit("60/minute")
async def submit_merge_plan_job(
    request: Request,
    file: UploadFile | None = File(None),
    upload_id: str | None = Form(default=None),
    total_chunks: int | None = Form(default=None),
    config_json: str = Form(default=None),
    udid: str | None = Form(default=None),
):
    user = _require_user(
        request,
        body_udid=udid,
        require_verified_udid=True,
        require_active_plan=True,
        require_quota=True,
    )
    _ensure_merge_workers_started()

    clean_cfg = config_json or "{}"
    if len(clean_cfg.encode("utf-8")) > MAX_MERGE_UPLOAD_BYTES:
        raise _too_large(MAX_MERGE_UPLOAD_BYTES)
    try:
        parsed_cfg = json.loads(clean_cfg)
    except (json.JSONDecodeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=f"config_json không hợp lệ: {exc}") from exc
    if not isinstance(parsed_cfg, dict):
        raise HTTPException(status_code=400, detail="config_json phải là JSON object.")

    job_id = uuid.uuid4().hex
    job_dir = _MERGE_JOBS_ROOT / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    input_path: Path | None = None
    accepted_bytes = 0
    try:
        if upload_id:
            clean_uid = _validate_upload_id(upload_id)
            upload_dir = _MERGE_UPLOADS_ROOT / clean_uid
            meta_path = upload_dir / "meta.json"
            if not meta_path.is_file():
                raise HTTPException(status_code=404, detail="Phiên upload không tồn tại hoặc đã hết hạn.")
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if int(meta.get("user_id") or -1) != int(user["id"]):
                raise HTTPException(status_code=403, detail="Không có quyền sử dụng phiên upload này.")
            expected = int(total_chunks or 0)
            if expected <= 0 or expected > 256:
                raise HTTPException(status_code=400, detail="total_chunks không hợp lệ.")
            input_path = job_dir / "input.zip"
            with input_path.open("wb") as out_f:
                for idx in range(expected):
                    part_path = upload_dir / f"part_{idx:05d}.bin"
                    if not part_path.is_file():
                        raise HTTPException(status_code=400, detail=f"Thiếu mảnh dữ liệu #{idx}.")
                    with part_path.open("rb") as pf:
                        while True:
                            buf = pf.read(_UPLOAD_CHUNK_BYTES)
                            if not buf:
                                break
                            accepted_bytes += len(buf)
                            if accepted_bytes > MAX_MERGE_UPLOAD_BYTES:
                                raise _too_large(MAX_MERGE_UPLOAD_BYTES)
                            out_f.write(buf)
            shutil.rmtree(upload_dir, ignore_errors=True)
        elif file is not None:
            input_path = job_dir / "input.zip"
            accepted_bytes = await _save_upload_to_path(file, input_path, MAX_MERGE_UPLOAD_BYTES)

        ok, status, msg, job = create_merge_job(
            job_id=job_id,
            user_id=int(user["id"]),
            config_json=clean_cfg,
            input_path=str(input_path) if input_path else None,
            accepted_bytes=accepted_bytes,
            max_active_per_user=MAX_ACTIVE_MERGE_JOBS_PER_USER,
        )
        if not ok or job is None:
            shutil.rmtree(job_dir, ignore_errors=True)
            raise HTTPException(status_code=status, detail=msg)
    except Exception:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise

    _MERGE_JOB_WAKE.set()
    return {
        "ok": True,
        "job_id": job["job_id"],
        "status": job["status"],
        "position": job["position"],
        "queue_length": job["queue_length"],
        "poll_interval_ms": 1500,
    }


@app.get("/api/v1/merge-plan/jobs")
@limiter.limit("240/minute")
async def get_merge_plan_job_status(
    request: Request,
    job_id: str = Query(..., min_length=8, max_length=64),
):
    user = _require_user(
        request,
        require_verified_udid=True,
        require_active_plan=False,
        require_quota=False,
    )
    _ensure_merge_workers_started()

    job = get_merge_job(job_id.strip())
    if job is None or int(job["user_id"]) != int(user["id"]):
        raise HTTPException(status_code=404, detail="Không tìm thấy tác vụ gộp hoặc đã hết hạn.")

    st = job["status"]
    if st in ("queued", "processing"):
        return {
            "ok": True,
            "job_id": job["job_id"],
            "status": st,
            "position": int(job.get("position") or 0),
            "queue_length": int(job.get("queue_length") or 0),
        }

    if st == "failed":
        return {
            "ok": True,
            "job_id": job["job_id"],
            "status": "failed",
            "error_code": int(job.get("error_code") or 400),
            "detail": job.get("error_detail") or "Gộp thất bại.",
        }

    meta_raw = job.get("result_meta_json") or "{}"
    try:
        meta = json.loads(meta_raw)
    except (json.JSONDecodeError, ValueError):
        meta = {"ok": True}
    if not isinstance(meta, dict):
        meta = {"ok": True}

    result_path = job.get("result_path")
    has_result = bool(result_path and Path(result_path).is_file())
    meta["job_id"] = job["job_id"]
    meta["status"] = "done"
    meta["has_result_zip"] = has_result
    return JSONResponse(content=_apply_user_usage_fields(meta, user))


@app.get("/api/v1/merge-plan/jobs/result")
@limiter.limit("120/minute")
async def download_merge_plan_job_result(
    request: Request,
    job_id: str = Query(..., min_length=8, max_length=64),
):
    user = _require_user(
        request,
        require_verified_udid=True,
        require_active_plan=False,
        require_quota=False,
    )
    job = get_merge_job(job_id.strip())
    if job is None or int(job["user_id"]) != int(user["id"]):
        raise HTTPException(status_code=404, detail="Không tìm thấy kết quả gộp hoặc đã hết hạn.")
    if job["status"] != "done":
        raise HTTPException(status_code=409, detail="Tác vụ gộp chưa hoàn tất.")

    result_path = job.get("result_path")
    if not result_path or not Path(result_path).is_file():
        raise HTTPException(status_code=404, detail="Tệp kết quả không còn khả dụng.")

    return FileResponse(
        path=result_path,
        media_type="application/zip",
        filename=f"merge_{job['job_id'][:8]}.zip",
    )


# ============================================================================
# KHO MOD SKIN TRONG APP
# ============================================================================


class ModDownloadBody(BaseModel):
    mod_id: int = Field(..., ge=1)
    udid: str | None = None


@app.get("/api/v1/mods")
@limiter.limit("60/minute")
async def get_mod_catalog(request: Request, search: str = Query(default="")):
    _require_user(
        request,
        require_verified_udid=False,
        require_active_plan=False,
        require_quota=False,
    )
    ensure_mods_table()
    items = list_mods(include_inactive=False, search=search)
    public_items = [
        {
            "id": m["id"],
            "name": m["name"],
            "hero_name": m["hero_name"],
            "skin_name": m["skin_name"],
            "hero_id": m["hero_id"],
            "resource_version": m["resource_version"],
            "category": m["category"],
            "file_name": m["file_name"],
            "file_size": m["file_size"],
            "sha256": m["sha256"],
            "download_count": m["download_count"],
            "created_at": m["created_at"],
        }
        for m in items
    ]
    return {"ok": True, "mods": public_items}


@app.post("/api/v1/mods/download")
@limiter.limit("60/minute")
async def download_mod_file(request: Request, body: ModDownloadBody):
    user = _require_user(
        request,
        body_udid=body.udid,
        require_verified_udid=True,
        require_active_plan=True,
        require_quota=True,
    )
    mod = get_mod_by_id(body.mod_id)
    if mod is None or not mod["is_active"]:
        raise HTTPException(status_code=404, detail="Không tìm thấy gói mod trong kho.")

    storage_root = MOD_STORAGE_DIR.resolve()
    file_path = (storage_root / mod["stored_filename"]).resolve()
    if file_path.parent != storage_root or not file_path.is_file():
        raise HTTPException(status_code=404, detail="Tệp mod hiện không khả dụng trên máy chủ.")

    ok, status, msg, updated_user = consume_user_usage(user["id"])
    if not ok or updated_user is None:
        raise HTTPException(status_code=status, detail=msg)

    increment_mod_download(mod["id"])
    return FileResponse(
        path=str(file_path),
        media_type="application/zip",
        filename=mod["file_name"],
        headers={
            "X-Totorox-Remaining-Uses": str(updated_user["remaining_uses"]),
            "X-Totorox-Used-Count": str(updated_user["used_count"]),
        },
    )
