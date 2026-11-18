"""
app.py — Local FastAPI Desktop App Server cho Totorox Mod Studio (3.0).

Chạy 100% offline trên 127.0.0.1 (mặc định cổng 18305, tự tìm cổng rảnh nếu bận),
cung cấp 21 REST endpoint cho giao diện Mint UI (`studio.html`), hộp thoại chọn
file/thư mục gốc Windows (`tkinter.filedialog`), mở thư mục xuất bằng
`explorer /select,...`, và tự khởi chạy cửa sổ Desktop App qua Microsoft Edge `--app`.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import math
import ntpath
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import tkinter
import tkinter.filedialog
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
import zipfile
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, HTMLResponse
from starlette.datastructures import UploadFile

# ---------------------------------------------------------------------------
# Định vị đường dẫn & đồng bộ module globals với `studio_engine`
# (Tuyệt đối không đọc/ghi cấu hình, cache hoặc output/ lúc import!)
# ---------------------------------------------------------------------------

STUDIO_DIR = os.path.dirname(os.path.abspath(__file__))
if STUDIO_DIR not in sys.path:
    sys.path.insert(0, STUDIO_DIR)

BACKEND_DIR = os.path.abspath(os.path.join(STUDIO_DIR, "..", "Totorox-Backend"))
if os.path.isdir(BACKEND_DIR) and BACKEND_DIR not in sys.path:
    sys.path.append(BACKEND_DIR)

import studio_engine as se  # noqa: E402
import core_processor as cp  # noqa: E402

BUNDLE_DIR = se.BUNDLE_DIR
APP_DATA_DIR = se.APP_DATA_DIR
CONFIG_PATH = se.CONFIG_PATH
CATALOG_CACHE_PATH = se.CATALOG_CACHE_PATH
CUSTOM_BYPASS_SEED_PATH = se.CUSTOM_BYPASS_SEED_PATH
OUTPUT_DIR = se.OUTPUT_DIR

_PROVIDER_CACHE_LOCK = threading.Lock()
_PROVIDER_CACHE: dict[tuple[str, int, int], se.BaseResourceProvider] = {}
_TK_DIALOG_LOCK = threading.Lock()


def _decode_b64_strict(bval: str) -> bytes:
    cleaned = re.sub(r"\s+", "", str(bval))
    return base64.b64decode(cleaned, validate=True)


def _sync_engine_paths() -> None:
    """Đồng bộ biến đường dẫn (hỗ trợ test isolation & PyInstaller frozen mode)."""
    se.APP_DATA_DIR = APP_DATA_DIR
    se.CONFIG_PATH = CONFIG_PATH
    se.CATALOG_CACHE_PATH = CATALOG_CACHE_PATH
    se.CUSTOM_BYPASS_SEED_PATH = CUSTOM_BYPASS_SEED_PATH
    se.OUTPUT_DIR = OUTPUT_DIR
    if hasattr(se.CatalogIndexer, "CACHE_PATH"):
        se.CatalogIndexer.CACHE_PATH = CATALOG_CACHE_PATH


def _resolve_studio_html() -> str:
    candidates = [
        os.path.join(BUNDLE_DIR, "studio.html"),
        os.path.join(STUDIO_DIR, "studio.html"),
        os.path.join(se.STUDIO_DIR, "studio.html"),
    ]
    for cand in candidates:
        if os.path.isfile(cand):
            return cand
    raise FileNotFoundError("Không tìm thấy tệp giao diện studio.html.")


def _parse_bool(val: Any, default: bool = False) -> bool:
    if val is None:
        return default
    if isinstance(val, bool):
        return val
    if isinstance(val, (int, float)):
        return bool(val)
    s = str(val).strip().lower()
    if s in ("1", "true", "yes", "on", "y"):
        return True
    if s in ("0", "false", "no", "off", "n", ""):
        return False
    return default


def _parse_optional_bool(val: Any) -> bool | None:
    if val is None or val == "":
        return None
    return _parse_bool(val)


async def _parse_request_data(request: Request) -> tuple[dict[str, Any], dict[str, list[tuple[str, bytes]]]]:
    """
    Hỗ trợ đồng thời `application/json` và `multipart/form-data` trên cùng một route,
    đồng thời xử lý thân rỗng (như `POST /api/catalog/refresh`) thành `{}`.
    """
    ctype = (request.headers.get("content-type") or "").lower()
    fields: dict[str, Any] = {}
    files: dict[str, list[tuple[str, bytes]]] = {}

    if "multipart/form-data" in ctype or "application/x-www-form-urlencoded" in ctype:
        form = await request.form()
        try:
            for key, val in form.multi_items():
                if isinstance(val, UploadFile):
                    raw = await val.read()
                    files.setdefault(key, []).append((val.filename or "upload.bin", raw))
                else:
                    fields[key] = val
        finally:
            await form.close()
        return fields, files

    raw_body = await request.body()
    if not raw_body or not raw_body.strip():
        return fields, files
    try:
        parsed = json.loads(raw_body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=400, detail=f"Dữ liệu JSON không hợp lệ: {exc}") from exc
    if not isinstance(parsed, dict):
        raise HTTPException(status_code=400, detail="Body JSON phải là đối tượng (object).")
    return parsed, files


def _read_existing_file(path_str: str) -> tuple[str, bytes]:
    clean = str(path_str or "").strip()
    if not clean:
        raise HTTPException(status_code=400, detail="Đường dẫn tệp không được để trống.")
    if not os.path.exists(clean):
        raise HTTPException(status_code=404, detail=f"Không tìm thấy tệp: {clean}")
    if not os.path.isfile(clean):
        raise HTTPException(status_code=400, detail=f"Đường dẫn không phải tệp hợp lệ: {clean}")
    with open(clean, "rb") as f:
        return os.path.basename(clean), f.read()


def _resolve_input_bytes(
    fields: dict[str, Any],
    files: dict[str, list[tuple[str, bytes]]],
    *,
    file_field: str = "file",
    b64_keys: tuple[str, ...] = ("content_b64", "pkg_b64", "raw_b64", "data_b64"),
    path_keys: tuple[str, ...] = ("path", "file_path"),
    required: bool = True,
) -> tuple[bytes, str]:
    uploaded = files.get(file_field)
    if uploaded:
        fname, raw = uploaded[0]
        eff_name = str(fields.get("filename") or fname or "upload.bin")
        return raw, eff_name

    for bkey in b64_keys:
        bval = fields.get(bkey)
        if isinstance(bval, str) and bval.strip():
            try:
                raw = _decode_b64_strict(bval)
            except (binascii.Error, ValueError) as exc:
                raise HTTPException(status_code=400, detail=f"Chuỗi base64 ({bkey}) không hợp lệ: {exc}") from exc
            p_fallback = next((str(fields.get(pk) or "") for pk in path_keys if fields.get(pk)), "")
            eff_name = str(fields.get("filename") or (os.path.basename(p_fallback) if p_fallback else "buffer.bin"))
            return raw, eff_name

    for pk in path_keys:
        pval = fields.get(pk)
        if pval is not None and str(pval).strip():
            bname, raw = _read_existing_file(str(pval))
            eff_name = str(fields.get("filename") or bname)
            return raw, eff_name

    if required:
        raise HTTPException(status_code=400, detail="Thiếu dữ liệu đầu vào (file, content_b64 hoặc path).")
    return b"", str(fields.get("filename") or "")


def _get_provider(resources_path: str | None = None, *, bypass_cache: bool = False) -> se.BaseResourceProvider:
    _sync_engine_paths()
    eff_path = str(resources_path or "").strip()
    if not eff_path:
        cfg = se.load_studio_config()
        eff_path = str(cfg.get("resources_path") or "").strip()
    if not eff_path:
        raise HTTPException(
            status_code=400,
            detail="Chưa cấu hình đường dẫn Resources Gốc (.zip hoặc thư mục Resources).",
        )
    if not os.path.exists(eff_path):
        raise HTTPException(status_code=404, detail=f"Không tìm thấy Resources Gốc tại: {eff_path}")

    abs_p = os.path.abspath(eff_path)
    st = os.stat(abs_p)
    cache_key = (abs_p, int(st.st_mtime), int(st.st_size))

    if not bypass_cache:
        with _PROVIDER_CACHE_LOCK:
            cached = _PROVIDER_CACHE.get(cache_key)
            if cached is not None:
                return cached

    try:
        prov = se.BaseResourceProvider(abs_p)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, zipfile.BadZipFile) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    with _PROVIDER_CACHE_LOCK:
        _PROVIDER_CACHE[cache_key] = prov
    return prov


_WINDOWS_RESERVED_NAMES = frozenset(
    {"CON", "PRN", "AUX", "NUL"}
    | {f"COM{i}" for i in range(1, 10)}
    | {f"LPT{i}" for i in range(1, 10)}
)


def _safe_output_write(filename: str, data: bytes, output_dir: str | None = None) -> tuple[str, str]:
    target_dir = os.path.abspath(output_dir or OUTPUT_DIR)
    os.makedirs(target_dir, exist_ok=True)
    base_name = os.path.basename(str(filename or "").replace("\\", "/")).strip() or "output.bin"
    base_name = base_name.replace("\x00", "")
    base_name = re.sub(r'[<>:"/\\|?*]+', "_", base_name).strip(" .")
    if not base_name or base_name in (".", ".."):
        base_name = "output.bin"
    if base_name.split(".", 1)[0].rstrip(" ").upper() in _WINDOWS_RESERVED_NAMES:
        base_name = f"_{base_name}"
    out_path = os.path.abspath(os.path.join(target_dir, base_name))
    if os.path.commonpath([target_dir, out_path]) != target_dir:
        raise HTTPException(status_code=400, detail="Tên tệp xuất không hợp lệ.")
    with open(out_path, "wb") as f:
        f.write(data)
    return os.path.basename(out_path), out_path


def _make_download_url(filename_or_path: str) -> str:
    return f"/api/outputs/download?path={urllib.parse.quote(filename_or_path)}"


def _safe_download_path(raw_path: str) -> str:
    raw = str(raw_path or "").strip()
    if not raw or "\x00" in raw:
        raise HTTPException(status_code=400, detail="Đường dẫn tải xuống không hợp lệ.")
    norm_slash = raw.replace("\\", "/")
    parts = [p for p in norm_slash.split("/") if p]
    if ".." in parts:
        raise HTTPException(status_code=403, detail="Từ chối truy cập đường dẫn ngoài thư mục output.")
    out_root = os.path.abspath(OUTPUT_DIR)
    if os.path.isabs(raw):
        _, tail = ntpath.splitdrive(raw)
        if ":" in tail:
            raise HTTPException(status_code=403, detail="Từ chối truy cập đường dẫn chứa ký tự ':' không hợp lệ.")
        resolved = os.path.abspath(raw)
    else:
        if ":" in raw:
            raise HTTPException(status_code=403, detail="Từ chối truy cập đường dẫn chứa ký tự ':' không hợp lệ.")
        resolved = os.path.abspath(os.path.join(out_root, raw))
    try:
        common = os.path.commonpath([out_root, resolved])
    except ValueError as exc:
        raise HTTPException(status_code=403, detail="Từ chối truy cập khác ổ đĩa.") from exc
    if common != out_root or resolved == out_root:
        raise HTTPException(status_code=403, detail="Từ chối truy cập tệp ngoài thư mục output.")
    if not os.path.isfile(resolved):
        raise HTTPException(status_code=404, detail=f"Không tìm thấy tệp đầu ra: {raw}")
    return resolved


# ---------------------------------------------------------------------------
# FastAPI App & 21 Endpoints
# ---------------------------------------------------------------------------

app = FastAPI(title="Totorox Mod Studio", version="3.0.0", docs_url=None, redoc_url=None)


@app.get("/", response_class=HTMLResponse)
def serve_studio_ui() -> HTMLResponse:
    try:
        html_path = _resolve_studio_html()
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    with open(html_path, "r", encoding="utf-8") as f:
        content = f.read()
    return HTMLResponse(content=content, media_type="text/html; charset=utf-8")


def _compute_seed_status(prov: se.BaseResourceProvider | None = None) -> dict[str, Any] | None:
    try:
        seed = se.load_bypass_seed()
    except Exception as exc:
        return {
            "compatible": False,
            "severity": "error",
            "seed_mode": "unknown",
            "is_custom": os.path.exists(CUSTOM_BYPASS_SEED_PATH),
            "message": str(exc),
        }
    if prov is None:
        try:
            cfg = se.load_studio_config()
            rp = str(cfg.get("resources_path") or "").strip()
            if rp and os.path.exists(rp):
                prov = _get_provider(rp)
        except Exception:
            prov = None
    if prov is not None:
        return se.check_bypass_seed_compatibility(prov, seed)
    meta = seed.get("meta") or {}
    return {
        "compatible": True,
        "severity": "ok",
        "seed_mode": seed.get("seed_mode", "lua_only"),
        "is_custom": bool(seed.get("is_custom")),
        "seed_version": str(meta.get("version_txt") or meta.get("game_version") or ""),
        "resources_version": "",
        "message": f"Bypass Seed ({seed.get('seed_mode', 'lua_only')}) sẵn sàng.",
    }


@app.get("/api/health")
def api_health() -> dict[str, Any]:
    _sync_engine_paths()
    cfg = se.load_studio_config()
    return {
        "ok": True,
        "status": "ok",
        "version": "3.0.0",
        "frozen": bool(getattr(sys, "frozen", False)),
        "output_dir": OUTPUT_DIR,
        "resources_path": str(cfg.get("resources_path") or ""),
        "has_default_seed": os.path.exists(se.DEFAULT_BYPASS_SEED_PATH),
        "has_custom_seed": os.path.exists(CUSTOM_BYPASS_SEED_PATH),
        "seed_status": _compute_seed_status(),
    }


@app.get("/api/config")
def api_get_config() -> dict[str, Any]:
    _sync_engine_paths()
    os.makedirs(os.path.dirname(os.path.abspath(CONFIG_PATH)), exist_ok=True)
    cfg = se.load_studio_config()
    return {**cfg, "effective_output_dir": OUTPUT_DIR}


@app.post("/api/config")
async def api_post_config(request: Request) -> dict[str, Any]:
    _sync_engine_paths()
    fields, _ = await _parse_request_data(request)
    os.makedirs(os.path.dirname(os.path.abspath(CONFIG_PATH)), exist_ok=True)
    cfg = se.load_studio_config()
    for key in ("resources_path", "default_watermark", "theme", "output_dir"):
        if key in fields and fields[key] is not None:
            val = str(fields[key])
            if key == "theme" and val not in ("dark", "light"):
                raise HTTPException(status_code=400, detail="theme chỉ chấp nhận 'dark' hoặc 'light'.")
            if key == "output_dir" and not val.strip():
                cfg.pop("output_dir", None)
            else:
                cfg[key] = val
    saved = se.save_studio_config(cfg)
    return {"ok": True, **saved, "effective_output_dir": OUTPUT_DIR}


def _split_tcl_filelist(raw: str) -> list[str]:
    s = (raw or "").strip()
    if not s:
        return []
    out: list[str] = []
    i = 0
    n = len(s)
    while i < n:
        while i < n and s[i].isspace():
            i += 1
        if i >= n:
            break
        if s[i] == "{":
            depth = 1
            i += 1
            start = i
            while i < n and depth > 0:
                if s[i] == "{":
                    depth += 1
                elif s[i] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            item = s[start:i]
            if item:
                out.append(item)
            if i < n and s[i] == "}":
                i += 1
        else:
            start = i
            while i < n and not s[i].isspace():
                i += 1
            item = s[start:i]
            if item:
                out.append(item)
    return out


@app.post("/api/dialog/browse")
async def api_dialog_browse(request: Request) -> dict[str, Any]:
    fields, _ = await _parse_request_data(request)
    mode = str(fields.get("mode") or "file").strip().lower()
    title = str(fields.get("title") or "Chọn tệp / thư mục")
    initialdir = str(fields.get("initialdir") or "") or None
    defaultext = str(fields.get("defaultextension") or "") or None
    initialfile = str(fields.get("initialfile") or "") or None
    raw_ft = fields.get("filetypes")
    filetypes: list[tuple[str, str]] | None = None
    if isinstance(raw_ft, list) and raw_ft:
        parsed_ft: list[tuple[str, str]] = []
        for item in raw_ft:
            if isinstance(item, (list, tuple)) and len(item) >= 2:
                parsed_ft.append((str(item[0]), str(item[1])))
        if parsed_ft:
            filetypes = parsed_ft

    if mode not in ("file", "files", "dir", "folder", "directory", "save"):
        raise HTTPException(status_code=400, detail=f"Chế độ hộp thoại không hợp lệ: {mode!r}")

    def _run_tk_dialog() -> tuple[str, list[str]]:
        with _TK_DIALOG_LOCK:
            root = tkinter.Tk()
            try:
                root.withdraw()
                try:
                    root.attributes("-topmost", True)
                except Exception:
                    pass
                try:
                    root.lift()
                except Exception:
                    pass

                kwargs: dict[str, Any] = {"title": title}
                if initialdir and os.path.isdir(initialdir):
                    kwargs["initialdir"] = initialdir

                if mode == "file":
                    if filetypes:
                        kwargs["filetypes"] = filetypes
                    chosen = tkinter.filedialog.askopenfilename(**kwargs)
                    p = str(chosen or "")
                    return p, ([p] if p else [])
                if mode == "files":
                    if filetypes:
                        kwargs["filetypes"] = filetypes
                    chosen = tkinter.filedialog.askopenfilenames(**kwargs)
                    if isinstance(chosen, str):
                        if not chosen:
                            plist = []
                        else:
                            tk_obj = getattr(root, "tk", None)
                            if tk_obj is not None and hasattr(tk_obj, "splitlist"):
                                plist = [str(x) for x in tk_obj.splitlist(chosen) if x]
                            else:
                                plist = _split_tcl_filelist(chosen)
                    elif chosen:
                        plist = [str(x) for x in chosen if x]
                    else:
                        plist = []
                    return (plist[0] if plist else ""), plist
                if mode in ("dir", "folder", "directory"):
                    chosen = tkinter.filedialog.askdirectory(**kwargs)
                    p = str(chosen or "")
                    return p, ([p] if p else [])
                # mode == "save"
                if filetypes:
                    kwargs["filetypes"] = filetypes
                if defaultext:
                    kwargs["defaultextension"] = defaultext
                if initialfile:
                    kwargs["initialfile"] = initialfile
                chosen = tkinter.filedialog.asksaveasfilename(**kwargs)
                p = str(chosen or "")
                return p, ([p] if p else [])
            finally:
                try:
                    root.destroy()
                except Exception:
                    pass

    path_str, paths_list = await run_in_threadpool(_run_tk_dialog)
    cancelled = not path_str and not paths_list
    return {"ok": True, "cancelled": cancelled, "path": path_str, "paths": paths_list}


@app.post("/api/system/open-explorer")
async def api_open_explorer(request: Request) -> dict[str, Any]:
    fields, _ = await _parse_request_data(request)
    raw_path = str(fields.get("path") or "").strip()
    if not raw_path:
        raise HTTPException(status_code=400, detail="Thiếu đường dẫn path để mở trong Explorer.")
    norm = os.path.normpath(os.path.abspath(raw_path))
    if not os.path.exists(norm):
        raise HTTPException(status_code=404, detail=f"Đường dẫn không tồn tại: {norm}")
    try:
        subprocess.Popen(["explorer", f"/select,{norm}"])
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Không thể mở Windows Explorer: {exc}") from exc
    return {"ok": True, "path": norm}


@app.get("/api/catalog")
async def api_get_catalog(
    force_rebuild: bool = Query(default=False),
    resources_path: str | None = Query(default=None),
) -> dict[str, Any]:
    prov = await run_in_threadpool(lambda: _get_provider(resources_path, bypass_cache=force_rebuild))
    try:
        _sync_engine_paths()
        os.makedirs(os.path.dirname(os.path.abspath(CATALOG_CACHE_PATH)), exist_ok=True)
        cat = await run_in_threadpool(se.CatalogIndexer.build_or_load, prov, force_rebuild)
        return {**cat, "seed_status": _compute_seed_status(prov)}
    except (ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/catalog/refresh")
async def api_refresh_catalog(request: Request) -> dict[str, Any]:
    fields, _ = await _parse_request_data(request)
    res_path = fields.get("resources_path")
    prov = await run_in_threadpool(lambda: _get_provider(res_path, bypass_cache=True))
    try:
        _sync_engine_paths()
        os.makedirs(os.path.dirname(os.path.abspath(CATALOG_CACHE_PATH)), exist_ok=True)
        cat = await run_in_threadpool(se.CatalogIndexer.build_or_load, prov, True)
        return {**cat, "seed_status": _compute_seed_status(prov)}
    except (ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/resources/rescan")
async def api_resources_rescan(request: Request) -> dict[str, Any]:
    _sync_engine_paths()
    fields, _ = await _parse_request_data(request)
    game_dir_raw = str(fields.get("game_dir") or "").strip() or None
    res_path_raw = str(fields.get("resources_path") or "").strip() or None
    try:
        res = await run_in_threadpool(
            lambda: se.scan_local_resources(
                game_dir=game_dir_raw,
                update_config=True,
                current_resources_path=res_path_raw,
            )
        )
        with _PROVIDER_CACHE_LOCK:
            _PROVIDER_CACHE.clear()
        prov = await run_in_threadpool(lambda: _get_provider(res["resources_path"], bypass_cache=True))
        os.makedirs(os.path.dirname(os.path.abspath(CATALOG_CACHE_PATH)), exist_ok=True)
        catalog = await run_in_threadpool(se.CatalogIndexer.build_or_load, prov, True)
        return {**res, "catalog": catalog, "seed_status": _compute_seed_status(prov)}
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, RuntimeError, zipfile.BadZipFile) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/bypass-seed/import")
async def api_import_bypass_seed(request: Request) -> dict[str, Any]:
    _sync_engine_paths()
    fields, files = await _parse_request_data(request)
    raw_bytes, _ = _resolve_input_bytes(fields, files, required=True)
    os.makedirs(os.path.dirname(os.path.abspath(CUSTOM_BYPASS_SEED_PATH)), exist_ok=True)
    try:
        meta = await run_in_threadpool(se.import_bypass_seed_from_mod_zip, raw_bytes)
    except (ValueError, RuntimeError, zipfile.BadZipFile, cp.PatchPackageDecodeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, **meta, "seed_status": _compute_seed_status()}


@app.post("/api/mod/build")
async def api_mod_build(request: Request) -> dict[str, Any]:
    _sync_engine_paths()
    fields, _ = await _parse_request_data(request)
    res_path = fields.get("resources_path")
    prov = await run_in_threadpool(lambda: _get_provider(res_path))
    cfg = se.load_studio_config()
    opts = dict(fields)
    for bkey in (
        "apply_to_all_skins",
        "enable_skills",
        "enable_vfx",
        "enable_recall",
        "enable_born",
        "enable_sound",
        "enable_button",
        "enable_billboard",
        "is_mix",
    ):
        if bkey in opts and opts[bkey] is not None:
            if isinstance(opts[bkey], str):
                if not opts[bkey].strip():
                    opts[bkey] = None
                else:
                    opts[bkey] = _parse_bool(opts[bkey])
            else:
                opts[bkey] = _parse_bool(opts[bkey])

    for ikey in (
        "hero_id",
        "target_skin_id",
        "source_skin_id",
        "personal_button_id",
        "billboard_id",
        "kill_notify_id",
    ):
        if ikey in opts and opts[ikey] is not None and isinstance(opts[ikey], str):
            s_val = opts[ikey].strip()
            if not s_val:
                opts[ikey] = None
            else:
                try:
                    opts[ikey] = int(s_val)
                except ValueError as exc:
                    raise HTTPException(status_code=400, detail=f"Tham số '{ikey}' phải là số nguyên hợp lệ.") from exc

    if "camera_percent" in opts and opts["camera_percent"] is not None:
        raw_cam = opts["camera_percent"]
        if isinstance(raw_cam, bool):
            raise HTTPException(status_code=400, detail="Tham số 'camera_percent' phải là số hợp lệ.")
        if isinstance(raw_cam, str):
            cam_s = raw_cam.strip()
            if not cam_s:
                opts["camera_percent"] = 0
            else:
                try:
                    cam_f = float(cam_s)
                except ValueError as exc:
                    raise HTTPException(status_code=400, detail="Tham số 'camera_percent' phải là số hợp lệ.") from exc
                if not math.isfinite(cam_f):
                    raise HTTPException(status_code=400, detail="Tham số 'camera_percent' phải là số hữu hạn hợp lệ.")
                opts["camera_percent"] = int(cam_f) if cam_f.is_integer() else cam_f
        elif isinstance(raw_cam, (int, float)):
            cam_f = float(raw_cam)
            if not math.isfinite(cam_f):
                raise HTTPException(status_code=400, detail="Tham số 'camera_percent' phải là số hữu hạn hợp lệ.")
            opts["camera_percent"] = int(cam_f) if cam_f.is_integer() else cam_f
        else:
            raise HTTPException(status_code=400, detail="Tham số 'camera_percent' phải là số hợp lệ.")

    if "skill_mix" in opts and isinstance(opts["skill_mix"], str):
        sm_s = opts["skill_mix"].strip()
        if not sm_s:
            opts["skill_mix"] = {}
        else:
            try:
                parsed_sm = json.loads(sm_s)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail=f"skill_mix JSON không hợp lệ: {exc}") from exc
            if not isinstance(parsed_sm, dict):
                raise HTTPException(status_code=400, detail="Tham số 'skill_mix' phải là JSON object.")
            opts["skill_mix"] = parsed_sm

    if "replace_skin_ids" in opts and isinstance(opts["replace_skin_ids"], str):
        rs_s = opts["replace_skin_ids"].strip()
        if not rs_s:
            opts["replace_skin_ids"] = []
        elif rs_s.startswith("["):
            try:
                opts["replace_skin_ids"] = json.loads(rs_s)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail=f"replace_skin_ids JSON không hợp lệ: {exc}") from exc
        else:
            opts["replace_skin_ids"] = [x.strip() for x in rs_s.split(",") if x.strip()]

    if "skin_mappings" in opts and isinstance(opts["skin_mappings"], str):
        mp_s = opts["skin_mappings"].strip()
        if not mp_s:
            opts["skin_mappings"] = None
        else:
            try:
                opts["skin_mappings"] = json.loads(mp_s)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail=f"skin_mappings JSON không hợp lệ: {exc}") from exc

    if not opts.get("output_dir"):
        opts["output_dir"] = OUTPUT_DIR
    if "watermark_text" not in opts and cfg.get("default_watermark"):
        opts["watermark_text"] = cfg["default_watermark"]

    try:
        res = await run_in_threadpool(se.SkinModBuilder.build_mod, prov, opts)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, RuntimeError, KeyError, TypeError, zipfile.BadZipFile, cp.PatchPackageDecodeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return {"ok": True, "download_url": _make_download_url(res["filename"]), **res}


@app.post("/api/mod/batch-build")
async def api_mod_batch_build(request: Request) -> dict[str, Any]:
    _sync_engine_paths()
    fields, _ = await _parse_request_data(request)
    res_path = fields.get("resources_path")
    prov = await run_in_threadpool(lambda: _get_provider(res_path))
    cfg = se.load_studio_config()
    opts = dict(fields)

    if "items" in opts and isinstance(opts["items"], str):
        it_s = opts["items"].strip()
        try:
            opts["items"] = json.loads(it_s) if it_s else []
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail=f"items JSON không hợp lệ: {exc}") from exc
    if not isinstance(opts.get("items"), list) or not opts["items"]:
        raise HTTPException(status_code=400, detail="Cần ít nhất 1 tác vụ trong danh sách Mod Hàng Loạt.")

    if "merge_output" in opts and opts["merge_output"] is not None:
        opts["merge_output"] = _parse_bool(opts["merge_output"])

    if "camera_percent" in opts and opts["camera_percent"] is not None:
        raw_cam = opts["camera_percent"]
        if isinstance(raw_cam, bool):
            raise HTTPException(status_code=400, detail="Tham số 'camera_percent' phải là số hợp lệ.")
        try:
            cam_f = float(str(raw_cam).strip() or 0)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="Tham số 'camera_percent' phải là số hợp lệ.") from exc
        if not math.isfinite(cam_f):
            raise HTTPException(status_code=400, detail="Tham số 'camera_percent' phải là số hữu hạn hợp lệ.")
        opts["camera_percent"] = int(cam_f) if cam_f.is_integer() else cam_f

    if not opts.get("output_dir"):
        opts["output_dir"] = OUTPUT_DIR
    if "watermark_text" not in opts and cfg.get("default_watermark"):
        opts["watermark_text"] = cfg["default_watermark"]

    try:
        res = await run_in_threadpool(se.SkinModBuilder.build_batch_mods, prov, opts)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, RuntimeError, KeyError, TypeError, zipfile.BadZipFile, cp.PatchPackageDecodeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    if isinstance(res.get("results"), list):
        for r_item in res["results"]:
            if isinstance(r_item, dict) and r_item.get("filename"):
                r_item["download_url"] = _make_download_url(r_item["filename"])
    return {"ok": True, "download_url": _make_download_url(res["filename"]), **res}


@app.post("/api/inspector/inspect")
async def api_inspector_inspect(request: Request) -> dict[str, Any]:
    fields, files = await _parse_request_data(request)
    raw, filename = _resolve_input_bytes(fields, files, required=True)
    stem = str(fields.get("stem") or "")
    stem_override = str(fields.get("stem_override") or "")
    full_text = _parse_bool(fields.get("full_text"), default=False)
    try:
        info = await run_in_threadpool(
            lambda: se.BinaryInspector.inspect_bytes(
                raw,
                filename=filename,
                stem=stem,
                full_text=full_text,
                stem_override=stem_override,
            )
        )
    except (ValueError, KeyError, TypeError, zipfile.BadZipFile) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, **info}


@app.post("/api/inspector/repack")
async def api_inspector_repack(request: Request) -> dict[str, Any]:
    fields, files = await _parse_request_data(request)
    kind = str(fields.get("kind") or "").strip()
    if not kind:
        raise HTTPException(status_code=400, detail="Thiếu tham số 'kind'.")

    content_val = fields.get("content_text")
    if content_val is None:
        content_val = fields.get("content")
    if content_val is None:
        content_val = fields.get("content_json")
    if content_val is None:
        raise HTTPException(status_code=400, detail="Thiếu nội dung 'content_text' để đóng gói lại.")

    stem = str(fields.get("stem") or "").strip()
    encrypt_224a = _parse_bool(fields.get("encrypt_224a"), default=True)

    base_raw: bytes | None = None
    if files.get("base_file"):
        base_raw = files["base_file"][0][1]
    elif fields.get("base_raw_b64"):
        try:
            base_raw = _decode_b64_strict(str(fields["base_raw_b64"]))
        except (binascii.Error, ValueError) as exc:
            raise HTTPException(status_code=400, detail=f"base_raw_b64 không hợp lệ: {exc}") from exc
    elif fields.get("base_path"):
        _, base_raw = _read_existing_file(str(fields["base_path"]))

    try:
        out_bytes = await run_in_threadpool(
            lambda: se.BinaryInspector.repack_from_editor(
                kind,
                content_val,
                stem,
                encrypt_224a=encrypt_224a,
                base_raw=base_raw,
            )
        )
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    resp: dict[str, Any] = {
        "ok": True,
        "kind": kind,
        "stem": stem,
        "encrypt_224a": encrypt_224a,
        "size_bytes": len(out_bytes),
        "content_b64": base64.b64encode(out_bytes).decode("ascii"),
    }
    if _parse_bool(fields.get("save_output"), default=False) or fields.get("output_filename"):
        def_ext = ".xml" if (kind == "age_xml" and not encrypt_224a) else ".bytes"
        req_name = str(fields.get("output_filename") or f"{stem or 'repacked'}{def_ext}")
        out_name, out_path = _safe_output_write(req_name, out_bytes, fields.get("output_dir"))
        resp["filename"] = out_name
        resp["output_path"] = out_path
        resp["download_url"] = _make_download_url(out_name)
    return resp


@app.post("/api/inspector/pkg/entry")
async def api_inspector_pkg_entry(request: Request) -> dict[str, Any]:
    fields, files = await _parse_request_data(request)
    pkg_bytes, _ = _resolve_input_bytes(fields, files, required=True)
    entry_name = str(fields.get("entry_name") or "").strip()
    if not entry_name:
        raise HTTPException(status_code=400, detail="Thiếu tên entry_name.")
    full_text = _parse_bool(fields.get("full_text"), default=False)
    try:
        info = await run_in_threadpool(
            lambda: se.BinaryInspector.read_pkg_entry(pkg_bytes, entry_name, full_text=full_text)
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, zipfile.BadZipFile) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, **info}


@app.post("/api/inspector/pkg/update-entry")
async def api_inspector_pkg_update_entry(request: Request) -> dict[str, Any]:
    fields, files = await _parse_request_data(request)
    pkg_bytes, pkg_filename = _resolve_input_bytes(fields, files, required=True)
    entry_name = str(fields.get("entry_name") or "").strip()
    if not entry_name:
        raise HTTPException(status_code=400, detail="Thiếu tên entry_name.")

    payload: bytes | str
    if fields.get("new_raw_b64"):
        try:
            payload = _decode_b64_strict(str(fields["new_raw_b64"]))
        except (binascii.Error, ValueError) as exc:
            raise HTTPException(status_code=400, detail=f"new_raw_b64 không hợp lệ: {exc}") from exc
    elif fields.get("new_raw") is not None:
        payload = str(fields["new_raw"])
    elif fields.get("content_text") is not None:
        payload = str(fields["content_text"])
    else:
        raise HTTPException(status_code=400, detail="Thiếu nội dung mới (new_raw, content_text hoặc new_raw_b64).")

    encrypt_stem = fields.get("encrypt_stem")
    encrypt_stem_s = str(encrypt_stem).strip() if encrypt_stem is not None and str(encrypt_stem).strip() else None
    kind = fields.get("kind")
    kind_s = str(kind).strip() if kind is not None and str(kind).strip() else None
    encrypt_224a = _parse_optional_bool(fields.get("encrypt_224a"))
    allow_add = _parse_bool(fields.get("allow_add"), default=False)

    try:
        upd_pkg = await run_in_threadpool(
            lambda: se.BinaryInspector.update_pkg_entry(
                pkg_bytes,
                entry_name,
                payload,
                encrypt_stem=encrypt_stem_s,
                kind=kind_s,
                encrypt_224a=encrypt_224a,
                allow_add=allow_add,
            )
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, TypeError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    base_out = os.path.basename(str(fields.get("output_filename") or pkg_filename or "updated.pkg.bytes"))
    if not base_out.lower().endswith((".pkg.bytes", ".bytes", ".zip")):
        base_out += ".pkg.bytes"
    out_name, out_path = _safe_output_write(base_out, upd_pkg, fields.get("output_dir"))
    return {
        "ok": True,
        "filename": out_name,
        "output_path": out_path,
        "download_url": _make_download_url(out_name),
        "size_bytes": len(upd_pkg),
        "pkg_b64": base64.b64encode(upd_pkg).decode("ascii"),
    }


@app.post("/api/inspector/pkg/unpack")
async def api_inspector_pkg_unpack(request: Request) -> dict[str, Any]:
    fields, files = await _parse_request_data(request)
    pkg_bytes, pkg_filename = _resolve_input_bytes(fields, files, required=True)
    raw_out_dir = str(fields.get("out_dir") or fields.get("output_dir") or "").strip()
    if not raw_out_dir:
        stem = se.BinaryInspector.infer_stem(pkg_filename) or "pkg_unpacked"
        raw_out_dir = os.path.join(OUTPUT_DIR, f"{stem}_unpacked")
    try:
        res = await run_in_threadpool(se.BinaryInspector.unpack_pkg_to_dir, pkg_bytes, raw_out_dir)
    except (ValueError, zipfile.BadZipFile) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, **res}


@app.post("/api/inspector/pkg/pack")
async def api_inspector_pkg_pack(request: Request) -> dict[str, Any]:
    fields, _ = await _parse_request_data(request)
    src_dir = str(fields.get("src_dir") or "").strip()
    if not src_dir:
        raise HTTPException(status_code=400, detail="Thiếu đường dẫn thư mục nguồn src_dir.")
    try:
        packed = await run_in_threadpool(se.BinaryInspector.pack_dir_to_pkg, src_dir)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    dir_base = os.path.basename(os.path.normpath(src_dir)) or "packed"
    if dir_base.endswith("_unpacked"):
        dir_base = dir_base[: -len("_unpacked")] or "packed"
    req_name = str(fields.get("output_filename") or f"{dir_base}.pkg.bytes")
    if not req_name.lower().endswith((".pkg.bytes", ".bytes", ".zip")):
        req_name += ".pkg.bytes"
    out_name, out_path = _safe_output_write(req_name, packed, fields.get("output_dir"))
    return {
        "ok": True,
        "filename": out_name,
        "output_path": out_path,
        "download_url": _make_download_url(out_name),
        "size_bytes": len(packed),
        "pkg_b64": base64.b64encode(packed).decode("ascii"),
    }


@app.post("/api/inspector/crypto/0x224a")
async def api_inspector_crypto_224a(request: Request) -> dict[str, Any]:
    fields, files = await _parse_request_data(request)
    action = str(fields.get("action") or fields.get("mode") or "decrypt").strip().lower()
    stem = str(fields.get("stem") or "").strip()

    if action == "encrypt":
        raw, filename = _resolve_input_bytes(fields, files, required=False)
        if not raw and fields.get("content_text") is not None:
            raw = str(fields["content_text"]).encode("utf-8")
        if not raw:
            raise HTTPException(status_code=400, detail="Thiếu dữ liệu đầu vào để mã hóa 0x224A.")
        if not stem and filename:
            stem = se.BinaryInspector.infer_stem(filename)
        try:
            enc = await run_in_threadpool(se.BinaryInspector.encrypt_0x224a, raw, stem)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        b64 = base64.b64encode(enc).decode("ascii")
        resp: dict[str, Any] = {
            "ok": True,
            "action": "encrypt",
            "stem": stem,
            "size_bytes": len(enc),
            "content_b64": b64,
            "encrypted_b64": b64,
        }
        if _parse_bool(fields.get("save_output"), default=False):
            out_fn = str(fields.get("output_filename") or f"{stem or 'encrypted'}.bytes")
            out_name, out_path = _safe_output_write(out_fn, enc, fields.get("output_dir"))
            resp["filename"] = out_name
            resp["output_path"] = out_path
            resp["download_url"] = _make_download_url(out_name)
        return resp

    if action == "decrypt":
        raw, filename = _resolve_input_bytes(fields, files, required=True)
        if not stem and filename:
            stem = se.BinaryInspector.infer_stem(filename)
        try:
            dec = await run_in_threadpool(se.BinaryInspector.decrypt_0x224a, raw, stem)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        sanitized = {k: v for k, v in dec.items() if k != "decrypted_bytes"}
        return {"ok": True, "action": "decrypt", **sanitized}

    raise HTTPException(status_code=400, detail=f"Thao tác 0x224A không hợp lệ: {action!r}")


@app.post("/api/inspector/xml/tracks")
async def api_inspector_xml_tracks(request: Request) -> dict[str, Any]:
    fields, _ = await _parse_request_data(request)
    xml_text = fields.get("xml_text")
    if not isinstance(xml_text, str):
        raise HTTPException(status_code=400, detail="Thiếu chuỗi 'xml_text'.")
    action = str(fields.get("action") or fields.get("mode") or "").strip().lower()
    updates = fields.get("updates")
    if not action:
        action = "update" if updates is not None else "parse"

    try:
        if action == "update":
            updated_xml = await run_in_threadpool(
                se.BinaryInspector.update_xml_tracks, xml_text, updates or []
            )
            tracks = await run_in_threadpool(se.BinaryInspector.parse_xml_tracks, updated_xml)
            return {
                "ok": True,
                "track_count": len(tracks),
                "tracks": tracks,
                "xml_text": updated_xml,
            }
        if action == "parse":
            tracks = await run_in_threadpool(se.BinaryInspector.parse_xml_tracks, xml_text)
            return {"ok": True, "track_count": len(tracks), "tracks": tracks}
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    raise HTTPException(status_code=400, detail=f"Chế độ XML tracks không hợp lệ: {action!r}")


@app.post("/api/merge")
async def api_merge(request: Request) -> dict[str, Any]:
    _sync_engine_paths()
    fields, files = await _parse_request_data(request)

    inputs_list: list[Any] = []
    uploaded_files = files.get("files") or files.get("file") or []
    for fname, raw in uploaded_files:
        inputs_list.append((fname, raw))

    raw_paths = fields.get("paths")
    if isinstance(raw_paths, str):
        s_paths = raw_paths.strip()
        if s_paths:
            try:
                raw_paths = json.loads(s_paths)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail=f"paths JSON không hợp lệ: {exc}") from exc
            if not isinstance(raw_paths, list):
                raise HTTPException(status_code=400, detail="Tham số 'paths' phải là mảng JSON (list).")
        else:
            raw_paths = []
    elif raw_paths is not None and not isinstance(raw_paths, list):
        raise HTTPException(status_code=400, detail="Tham số 'paths' phải là danh sách (list).")

    if isinstance(raw_paths, list):
        for p in raw_paths:
            p_str = str(p or "").strip()
            if not p_str:
                continue
            if not os.path.exists(p_str):
                raise HTTPException(status_code=404, detail=f"Không tìm thấy gói mod đầu vào: {p_str}")
            inputs_list.append(p_str)

    raw_inputs = fields.get("inputs")
    if isinstance(raw_inputs, str):
        s_inputs = raw_inputs.strip()
        if s_inputs:
            try:
                raw_inputs = json.loads(s_inputs)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail=f"inputs JSON không hợp lệ: {exc}") from exc
            if not isinstance(raw_inputs, list):
                raise HTTPException(status_code=400, detail="Tham số 'inputs' phải là mảng JSON (list).")
        else:
            raw_inputs = []
    elif raw_inputs is not None and not isinstance(raw_inputs, list):
        raise HTTPException(status_code=400, detail="Tham số 'inputs' phải là danh sách (list).")

    if isinstance(raw_inputs, list):
        for idx, item in enumerate(raw_inputs):
            if isinstance(item, str):
                if not os.path.exists(item):
                    raise HTTPException(status_code=404, detail=f"Không tìm thấy gói mod đầu vào: {item}")
                inputs_list.append(item)
            elif isinstance(item, dict):
                if item.get("content_b64"):
                    try:
                        b = _decode_b64_strict(str(item["content_b64"]))
                    except (binascii.Error, ValueError) as exc:
                        raise HTTPException(status_code=400, detail=f"content_b64 mục {idx} lỗi: {exc}") from exc
                    inputs_list.append({
                        "name": str(item.get("filename") or item.get("name") or f"mod_{idx}.zip"),
                        "bytes": b,
                        "password": item.get("password"),
                    })
                else:
                    ip = str(item.get("path") or "").strip()
                    if ip and not os.path.exists(ip):
                        raise HTTPException(status_code=404, detail=f"Không tìm thấy gói mod đầu vào: {ip}")
                    inputs_list.append(item)

    if len(inputs_list) < 2:
        raise HTTPException(status_code=400, detail="Cần ít nhất 2 gói mod (.zip hoặc .3105) để thực hiện gộp.")

    raw_ipw = fields.get("input_passwords")
    input_passwords: dict[str, str] | None = None
    if isinstance(raw_ipw, dict):
        input_passwords = {str(k): str(v) for k, v in raw_ipw.items() if v is not None}
    elif isinstance(raw_ipw, str) and raw_ipw.strip():
        try:
            parsed_pw = json.loads(raw_ipw)
            if not isinstance(parsed_pw, dict):
                raise HTTPException(status_code=400, detail="Tham số 'input_passwords' phải là JSON object.")
            input_passwords = {str(k): str(v) for k, v in parsed_pw.items() if v is not None}
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail=f"input_passwords JSON không hợp lệ: {exc}") from exc

    if input_passwords:
        bn_counts: dict[str, int] = {}
        for fn, _ in uploaded_files:
            bn = os.path.basename(str(fn).replace("\\", "/"))
            if bn:
                bn_counts[bn] = bn_counts.get(bn, 0) + 1
        if isinstance(raw_paths, list):
            for p in raw_paths:
                p_str = str(p or "").strip()
                if p_str:
                    bn_p = os.path.basename(os.path.normpath(p_str))
                    if bn_p:
                        bn_counts[bn_p] = bn_counts.get(bn_p, 0) + 1
        if isinstance(raw_inputs, list):
            for item in raw_inputs:
                if isinstance(item, str) and item.strip():
                    bn_i = os.path.basename(os.path.normpath(item.strip()))
                    if bn_i:
                        bn_counts[bn_i] = bn_counts.get(bn_i, 0) + 1
                elif isinstance(item, dict):
                    ip_or_name = str(item.get("name") or item.get("filename") or item.get("path") or "").strip()
                    if ip_or_name:
                        bn_i = os.path.basename(ip_or_name.replace("\\", "/"))
                        if bn_i:
                            bn_counts[bn_i] = bn_counts.get(bn_i, 0) + 1

        for fn, _ in uploaded_files:
            bn = os.path.basename(str(fn).replace("\\", "/"))
            if fn not in input_passwords and bn in input_passwords and bn_counts.get(bn, 0) == 1:
                input_passwords[fn] = input_passwords[bn]
        if isinstance(raw_paths, list):
            for p in raw_paths:
                p_str = str(p or "").strip()
                if p_str and p_str not in input_passwords:
                    norm_p = os.path.normpath(p_str)
                    bn_p = os.path.basename(norm_p)
                    if norm_p in input_passwords:
                        input_passwords[p_str] = input_passwords[norm_p]
                    elif bn_p in input_passwords and bn_counts.get(bn_p, 0) == 1:
                        input_passwords[p_str] = input_passwords[bn_p]

    cfg = se.load_studio_config()
    wm = fields.get("watermark_text")
    if wm is None:
        wm = fields.get("custom_watermark")
    if wm is None:
        wm = cfg.get("default_watermark")

    out_name = fields.get("output_name")
    if out_name is None:
        out_name = fields.get("custom_filename")

    output_format = str(fields.get("output_format") or "zip")
    password = fields.get("password")
    out_dir = str(fields.get("output_dir") or "").strip() or OUTPUT_DIR
    raw_iso_hud = fields.get("isolate_hud_on_conflict")
    if raw_iso_hud is None:
        isolate_hud_on_conflict = True
    elif isinstance(raw_iso_hud, bool):
        isolate_hud_on_conflict = raw_iso_hud
    else:
        isolate_hud_on_conflict = str(raw_iso_hud).strip().lower() not in ("0", "false", "no", "off")

    try:
        res = await run_in_threadpool(
            lambda: se.OfflineMergerAndConverter.merge_mods(
                inputs_list,
                output_dir=out_dir,
                output_name=out_name,
                watermark_text=wm,
                output_format=output_format,
                password=password,
                input_passwords=input_passwords,
                isolate_hud_on_conflict=isolate_hud_on_conflict,
            )
        )
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, RuntimeError, zipfile.BadZipFile, cp.PatchPackageDecodeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return {"ok": True, "download_url": _make_download_url(res["filename"]), **res}


@app.post("/api/convert")
async def api_convert(request: Request) -> dict[str, Any]:
    _sync_engine_paths()
    fields, files = await _parse_request_data(request)
    raw, filename = _resolve_input_bytes(fields, files, required=True)
    target_format = str(fields.get("target_format") or "").strip()
    mode = fields.get("mode")
    mode_s = str(mode).strip() if mode is not None and str(mode).strip() else None
    if not target_format and not mode_s:
        target_format = "zip" if raw.startswith(b"3105PATCH\x00") else "3105"
    password = fields.get("password")
    password_s = str(password) if password is not None else None
    out_dir = str(fields.get("output_dir") or "").strip() or OUTPUT_DIR

    try:
        res = await run_in_threadpool(
            lambda: se.OfflineMergerAndConverter.convert_package(
                raw,
                filename,
                target_format,
                password=password_s,
                output_dir=out_dir,
                mode=mode_s,
            )
        )
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, RuntimeError, zipfile.BadZipFile, cp.PatchPackageDecodeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    resp: dict[str, Any] = {"ok": True, **res}
    if "filename" in res:
        resp["download_url"] = _make_download_url(res["filename"])
    return resp


@app.get("/api/outputs/download")
def api_outputs_download(path: str = Query(..., min_length=1)) -> FileResponse:
    resolved = _safe_download_path(path)
    return FileResponse(
        path=resolved,
        filename=os.path.basename(resolved),
        media_type="application/octet-stream",
    )


# ---------------------------------------------------------------------------
# Khởi chạy Desktop App & CLI (`--host`, `--port`, `--no-browser`)
# ---------------------------------------------------------------------------

def pick_free_port(preferred_port: int = 18305, host: str = "127.0.0.1") -> int:
    for cand in (preferred_port, 0):
        if cand < 0 or cand > 65535:
            continue
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind((host, cand))
                return int(s.getsockname()[1])
        except (OSError, OverflowError):
            continue
    return preferred_port


def find_msedge_exe() -> str | None:
    candidates = [
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe"),
        shutil.which("msedge") or "",
    ]
    for cand in candidates:
        if cand and os.path.isfile(cand):
            return cand
    return None


def launch_desktop_browser(url: str, health_url: str | None = None) -> None:
    if health_url:
        for _ in range(30):
            try:
                with urllib.request.urlopen(health_url, timeout=0.5) as resp:
                    if resp.status == 200:
                        break
            except Exception:
                time.sleep(0.1)
    edge = find_msedge_exe()
    if edge:
        try:
            subprocess.Popen([edge, f"--app={url}", "--new-window"], close_fds=True)
            return
        except Exception:
            pass
    webbrowser.open(url)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Totorox Mod Studio 3.0 — Offline Local Server")
    parser.add_argument("--host", default="127.0.0.1", help="Địa chỉ bind (mặc định: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=18305, help="Cổng lắng nghe (mặc định: 18305)")
    parser.add_argument("--no-browser", action="store_true", help="Không tự mở cửa sổ trình duyệt/Edge")
    args = parser.parse_args(argv)

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    port = pick_free_port(preferred_port=args.port, host=args.host)
    url = f"http://{args.host}:{port}"
    print(f"[Totorox Mod Studio 3.0] Đang chạy cục bộ tại {url}", flush=True)

    if not args.no_browser:
        t = threading.Timer(0.6, launch_desktop_browser, args=(url, f"{url}/api/health"))
        t.daemon = True
        t.start()

    uvicorn.run(app, host=args.host, port=port, log_level="warning")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        import traceback
        print("\n" + "=" * 60, flush=True)
        print("[LỖI] Totorox Mod Studio đã gặp lỗi:", flush=True)
        traceback.print_exc()
        print("=" * 60, flush=True)
        if getattr(sys, "frozen", False):
            input("\nNhấn Enter để đóng cửa sổ này...")
        sys.exit(1)
