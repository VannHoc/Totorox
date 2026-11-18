"""
studio_engine.py — Nhân xử lý Offline cho Totorox Mod Studio (Windows Desktop / Local App).

Bao gồm 4 phân hệ độc lập, chạy 100% offline trên máy cá nhân:
1. `CatalogIndexer`: Quét `Resources Gốc.zip` (hoặc thư mục `Resources/`), giải mã bảng ngôn ngữ Tiếng Việt (`languageMap_Xls.txt`) và các bảng `MSES` (`hero.bytes`, `heroSkin.bytes`, `ResSkinSeniorLabelCfg.bytes`, `ResPersonalButtonCfg.bytes`, `ResBillboardSkinCfg.bytes`, `BattleBank.bytes`) để lập danh mục Tướng, Skin, Nút bấm, Thông báo hạ gục.
2. `SkinModBuilder`: Tạo gói Mod Skin chuẩn 1-Click hoặc Mix Chiêu đa skin (Hiệu ứng đòn đánh/chiêu, Biến về, Tế đàn xuất hiện, Âm thanh/Lồng tiếng Wwise, Nút bấm cá nhân, Thông báo hạ, Cam xa 5%–30%, Watermark tùy chọn, chống lỗi mạng sạch không quảng cáo).
3. `BinaryInspector`: Giải mã/Mã hóa `0x224A` (`AES-128-CBC` theo stem + `Zstd` dict), đọc/sửa bảng `MSES`, giải nén/đóng gói `.pkg.bytes` (`STORE=0`), đọc/sửa `JTCom` JSON (`CActorInfo` / `AssetRef`) và chỉnh sửa track `AGE XML`.
4. `OfflineMergerAndConverter`: Gộp nhiều gói mod `.zip` offline bằng `core_processor.run_merge` và chuyển đổi `.zip ⇄ .3105` (có mật khẩu tùy chọn).
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import ntpath
import os
import re
import shutil
import struct
import sys
import tempfile
import time
import uuid
import zipfile
from typing import Any

import zstandard as zstd

# ---------------------------------------------------------------------------
# Định vị tài nguyên (hỗ trợ cả chạy Python trực tiếp lẫn đóng gói PyInstaller .exe)
# ---------------------------------------------------------------------------

STUDIO_DIR = os.path.dirname(os.path.abspath(__file__))
if getattr(sys, "frozen", False):
    BUNDLE_DIR = getattr(sys, "_MEIPASS", STUDIO_DIR)
    APP_DATA_DIR = os.path.dirname(os.path.abspath(sys.executable))
else:
    BUNDLE_DIR = STUDIO_DIR
    APP_DATA_DIR = STUDIO_DIR

BACKEND_CANDIDATES = [
    BUNDLE_DIR,
    STUDIO_DIR,
    os.path.abspath(os.path.join(STUDIO_DIR, "..", "Totorox-Backend")),
]
for _cand in BACKEND_CANDIDATES:
    if os.path.exists(os.path.join(_cand, "core_processor.py")) and _cand not in sys.path:
        sys.path.insert(0, _cand)

import core_processor as cp  # noqa: E402
import jtcom  # noqa: E402

# Đảm bảo core_processor tìm thấy từ điển Zstd khi đóng gói .exe
for _dict_cand in [
    os.path.join(BUNDLE_DIR, "aov_zstd_uncompressed.bin"),
    os.path.join(STUDIO_DIR, "assets", "aov_zstd_uncompressed.bin"),
    os.path.abspath(os.path.join(STUDIO_DIR, "..", "Totorox-Backend", "aov_zstd_uncompressed.bin")),
]:
    if os.path.exists(_dict_cand):
        cp.ZSTD_DICT_FILE = _dict_cand
        break

DEFAULT_BYPASS_SEED_PATH = (
    os.path.join(BUNDLE_DIR, "assets", "bypass_seed.zst")
    if os.path.exists(os.path.join(BUNDLE_DIR, "assets", "bypass_seed.zst"))
    else os.path.join(STUDIO_DIR, "assets", "bypass_seed.zst")
)
CUSTOM_BYPASS_SEED_PATH = os.path.join(APP_DATA_DIR, "custom_bypass_seed.zst")
CONFIG_PATH = os.path.join(APP_DATA_DIR, "studio_config.json")
CATALOG_CACHE_PATH = os.path.join(APP_DATA_DIR, "catalog_cache.json")
OUTPUT_DIR = os.path.join(APP_DATA_DIR, "output")
os.makedirs(OUTPUT_DIR, exist_ok=True)

_XLS_KEY_RE = re.compile(rb"([0-9A-F]{16}_##)")
_EXTRA_SKIN_ARRAY_RE = re.compile(r"\s*<Array\s+name=\"extraSkinId\"[^>]*>.*?</Array>", re.DOTALL)
_SKIN_ID_PROP_RE = re.compile(r'(<int\s+name="skinId"\s+value=")(\d+)("[^>]*/>)', re.IGNORECASE)
_NEGATE_PROP_RE = re.compile(r'\s*<bool\s+name="useNegateValue"\s+value="true"[^/]*/>', re.IGNORECASE)
_NEGATE_FALSE_RE = re.compile(r'(<bool\s+name="useNegateValue"\s+value=")false(")', re.IGNORECASE)
_NEGATE_ATTR_FALSE_RE = re.compile(r'(useNegateValue=")false(")', re.IGNORECASE)
_BEQUAL_FALSE_RE = re.compile(r'\s*<bool\s+name="bEqual"\s+value="false"[^/]*/>', re.IGNORECASE)
_BEQUAL_TRUE_RE = re.compile(r'(<bool\s+name="bEqual"\s+value=")true(")', re.IGNORECASE)
_RESOURCE_NAME_RE = re.compile(r'(<String\s+name="resourceName"\s+value=")([^"]*)(")', re.IGNORECASE)
_EVENT_NAME_RE = re.compile(r'(<String\s+name="eventName"\s+value=")([^"]*)(")', re.IGNORECASE)
_HEIGHT_RATE_RE = re.compile(r'(<float\s+name="heightRate"\s+value=")([^"]+)(")', re.IGNORECASE)

CATALOG_CACHE_VERSION = 4
DEFAULT_GAME_VERSION = "1.64.1"
DEFAULT_LOCAL_GAME_DIR = r"C:\Users\studi\OneDrive\Documents\Tools\game"


class ModAssetValidationError(RuntimeError, ValueError):
    """Lỗi thiếu hoặc sai lệch tài nguyên AOV/Bypass Seed trước khi đóng gói mod."""
    pass

_WINDOWS_RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}


def dummy_skin_id(skin_id: int) -> int:
    """Ánh xạ skin không dùng sang dải giả `235XX` (5 chữ số) hoặc `235XXXX` (7 chữ số)."""
    sid = int(skin_id)
    if sid >= 1_000_000:
        return 2350000 + (sid % 10000)
    return 23500 + (sid % 100)


def _sanitize_output_stem(raw_name: str | None, fallback_stem: str) -> str:
    """Làm sạch tên tệp đầu ra an toàn với Windows (Unicode Tiếng Việt, dấu chấm/khoảng trắng cuối, ký tự điều khiển, tên thiết bị dành riêng)."""
    def _clean_once(val: str) -> str:
        s = re.sub(r"[\x00-\x1f]+", "", val or "")
        s = s.strip()
        while True:
            low = s.lower()
            if low.endswith(".zip"):
                s = s[:-4]
            elif low.endswith(".3105"):
                s = s[:-5]
            else:
                break
        s = re.sub(r'[<>:"/\\|?*]+', "_", s)
        s = s.strip(" .")
        return s

    fb = _clean_once(fallback_stem) or "Totorox_Output"
    stem = _clean_once(raw_name or "") or fb
    if len(stem) > 120:
        stem = stem[:120].strip(" .") or fb
    if stem.split(".", 1)[0].upper() in _WINDOWS_RESERVED_NAMES:
        stem = f"_{stem}"
    return stem


# ---------------------------------------------------------------------------
# Quản lý cấu hình cục bộ (`studio_config.json`)
# ---------------------------------------------------------------------------

def _parse_version_txt_key(raw_txt: str) -> tuple[tuple[int, ...], int, str]:
    """Tách chuỗi `1.64.1.13|1802180` thành `(ver_tuple, build_num, cleaned_txt)` để so sánh phiên bản."""
    cleaned = (raw_txt or "").strip()
    if not cleaned:
        return ((0,), 0, "")
    left, _, right = cleaned.partition("|")
    ver_tuple = cp.parse_version_tuple(left.strip())
    build_digits = re.sub(r"[^0-9]", "", right.strip())
    build_num = int(build_digits) if build_digits else 0
    return (ver_tuple or (0,), build_num, cleaned)


def _read_zip_version_meta(zip_path: str) -> dict[str, Any]:
    """Đọc nhanh `version.txt` và `mtime` của một tệp `Resources *.zip` hoặc thư mục `Resources/` cục bộ."""
    abs_path = os.path.abspath(zip_path)
    mtime = float(os.path.getmtime(abs_path)) if os.path.exists(abs_path) else 0.0
    version_txt = ""
    ver_tuple: tuple[int, ...] = (0,)
    build_num = 0
    try:
        if os.path.isdir(abs_path):
            for r_dir, _, files in os.walk(abs_path):
                for fn in files:
                    if fn.lower() == "version.txt":
                        with open(os.path.join(r_dir, fn), "r", encoding="utf-8", errors="ignore") as f:
                            version_txt = f.read().strip()
                        break
                if version_txt:
                    break
        elif zipfile.is_zipfile(abs_path):
            with zipfile.ZipFile(abs_path, "r") as zf:
                cand_names = [
                    name
                    for name in zf.namelist()
                    if name.replace("\\", "/").rstrip("/").lower().endswith("/version.txt")
                    or name.replace("\\", "/").lower() == "version.txt"
                ]
                cand_names.sort(key=len)
                if cand_names:
                    version_txt = zf.read(cand_names[0]).decode("utf-8", errors="ignore").strip()
    except Exception:
        version_txt = ""
    if version_txt:
        ver_tuple, build_num, version_txt = _parse_version_txt_key(version_txt)
    return {
        "path": abs_path,
        "filename": os.path.basename(abs_path),
        "version_txt": version_txt,
        "ver_tuple": ver_tuple,
        "build_num": build_num,
        "mtime": mtime,
    }


def list_local_resources_candidates(game_dir: str | None = None) -> list[dict[str, Any]]:
    """Quét và xếp hạng toàn bộ tệp `Resources*.zip` trong thư mục `game/` cục bộ (mới nhất lên đầu)."""
    target_dir = os.path.abspath(game_dir) if game_dir is not None else os.path.abspath(DEFAULT_LOCAL_GAME_DIR)
    candidates: list[dict[str, Any]] = []
    if os.path.isdir(target_dir):
        for fname in os.listdir(target_dir):
            fpath = os.path.join(target_dir, fname)
            low = fname.lower()
            if os.path.isfile(fpath) and low.startswith("resources") and low.endswith(".zip"):
                candidates.append(_read_zip_version_meta(fpath))
    candidates.sort(
        key=lambda c: (
            c["ver_tuple"],
            c["build_num"],
            c["mtime"],
            c["filename"].lower(),
        ),
        reverse=True,
    )
    return candidates


def _is_under_dir(file_path: str, parent_dir: str) -> bool:
    try:
        fp = os.path.normcase(os.path.abspath(file_path))
        pd = os.path.normcase(os.path.abspath(parent_dir))
        return os.path.commonpath([fp, pd]) == pd
    except Exception:
        return False


def _auto_detect_base_resources(game_dir: str | None = None) -> str:
    candidates = list_local_resources_candidates(game_dir)
    if candidates:
        return candidates[0]["path"]
    if game_dir is not None:
        return ""
    fallback_candidates = [
        os.path.join(APP_DATA_DIR, "Resources Gốc.zip"),
        os.path.join(APP_DATA_DIR, "Resources.zip"),
        os.path.abspath(os.path.join(STUDIO_DIR, "..", "..", "game", "Resources Gốc.zip")),
    ]
    for p in fallback_candidates:
        if os.path.exists(p):
            return os.path.abspath(p)
    return ""


def load_studio_config() -> dict[str, Any]:
    cfg: dict[str, Any] = {
        "resources_path": "",
        "default_watermark": "Mod pack được tạo bởi Totorox Mod Studio",
        "theme": "dark",
    }
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                cfg.update(loaded)
        except Exception:
            pass
    cur_res = str(cfg.get("resources_path") or "").strip()
    if not cur_res or not os.path.exists(cur_res):
        detected = _auto_detect_base_resources()
        if detected:
            cfg["resources_path"] = detected
            save_studio_config(cfg)
    elif _is_under_dir(cur_res, DEFAULT_LOCAL_GAME_DIR):
        detected = _auto_detect_base_resources()
        if detected and os.path.normcase(os.path.abspath(detected)) != os.path.normcase(os.path.abspath(cur_res)):
            cur_meta = _read_zip_version_meta(cur_res)
            det_meta = _read_zip_version_meta(detected)
            cur_key = (cur_meta["ver_tuple"], cur_meta["build_num"], cur_meta["mtime"])
            det_key = (det_meta["ver_tuple"], det_meta["build_num"], det_meta["mtime"])
            if det_key > cur_key:
                cfg["resources_path"] = detected
                save_studio_config(cfg)
    return cfg


def save_studio_config(cfg: dict[str, Any]) -> dict[str, Any]:
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    return cfg


def scan_local_resources(
    game_dir: str | None = None,
    update_config: bool = True,
    current_resources_path: str | None = None,
) -> dict[str, Any]:
    """Quét lại Resources (tôn trọng đường dẫn tùy chỉnh đã lưu nếu nằm ngoài `game/` mặc định) và kiểm tra Bypass Seed."""
    cfg = load_studio_config()
    saved_res = str(current_resources_path or cfg.get("resources_path") or "").strip()

    best: dict[str, Any] | None = None
    candidates: list[dict[str, Any]] = []
    target_dir = ""
    if game_dir is None and saved_res and os.path.exists(saved_res) and not _is_under_dir(saved_res, DEFAULT_LOCAL_GAME_DIR):
        abs_saved = os.path.abspath(saved_res)
        if os.path.isfile(abs_saved):
            target_dir = os.path.dirname(abs_saved)
            best = _read_zip_version_meta(abs_saved)
            candidates = [best]
        elif os.path.isdir(abs_saved):
            target_dir = abs_saved
            dir_cands = list_local_resources_candidates(target_dir)
            if dir_cands:
                best = dir_cands[0]
                candidates = dir_cands
            else:
                # Cho phép thư mục Resources đã giải nén trực tiếp
                prov_dir = BaseResourceProvider(abs_saved)
                vtxt_raw = (
                    prov_dir.read("version.txt").decode("utf-8", errors="ignore").strip()
                    if prov_dir.has("version.txt")
                    else prov_dir.game_version
                )
                ver_t, bnum, clean_vt = _parse_version_txt_key(vtxt_raw)
                best = {
                    "path": abs_saved,
                    "filename": os.path.basename(abs_saved),
                    "version_txt": clean_vt,
                    "game_version": prov_dir.game_version,
                    "ver_tuple": ver_t,
                    "build_num": bnum,
                    "mtime": os.path.getmtime(abs_saved),
                }
                candidates = [best]

    if best is None:
        target_dir = os.path.abspath(game_dir) if game_dir is not None else os.path.abspath(DEFAULT_LOCAL_GAME_DIR)
        candidates = list_local_resources_candidates(target_dir)
        if not candidates:
            raise FileNotFoundError(
                f"Không tìm thấy tệp Resources *.zip nào trong thư mục cục bộ: {target_dir}"
            )
        best = candidates[0]

    prev_path = str(cfg.get("resources_path") or "").strip()
    changed = os.path.normcase(os.path.abspath(best["path"])) != (
        os.path.normcase(os.path.abspath(prev_path)) if prev_path else ""
    )
    if update_config:
        cfg["resources_path"] = best["path"]
        save_studio_config(cfg)

    seed_status: dict[str, Any] | None = None
    try:
        prov = BaseResourceProvider(best["path"])
        seed = load_bypass_seed()
        seed_status = check_bypass_seed_compatibility(prov, seed)
    except Exception as exc:
        seed_status = {
            "compatible": False,
            "severity": "warning",
            "mode": "unknown",
            "message": str(exc),
        }

    return {
        "ok": True,
        "game_dir": target_dir,
        "resources_path": best["path"],
        "filename": best["filename"],
        "version_txt": best["version_txt"],
        "changed": changed,
        "previous_path": prev_path,
        "candidate_count": len(candidates),
        "candidates": [
            {
                "path": c["path"],
                "filename": c["filename"],
                "version_txt": c["version_txt"],
                "mtime": int(c["mtime"]),
            }
            for c in candidates
        ],
        "seed_status": seed_status,
        "message": (
            f"Đã chọn {best['filename']} ({best['version_txt']})"
            if best["version_txt"]
            else f"Đã chọn {best['filename']}"
        ),
    }


# ---------------------------------------------------------------------------
# Đọc nguồn `Resources Gốc` (hỗ trợ cả `.zip` lẫn thư mục giải nén)
# ---------------------------------------------------------------------------

class BaseResourceProvider:
    """Truy cập lười (lazy) từng tệp trong `Resources Gốc.zip` hoặc thư mục `Resources/` siêu nhanh."""

    def __init__(self, source_path: str) -> None:
        if not source_path or not os.path.exists(source_path):
            raise FileNotFoundError(f"Không tìm thấy nguồn Resources gốc tại: {source_path!r}")
        self.source_path = os.path.abspath(source_path)
        self.is_dir = os.path.isdir(self.source_path)
        st = os.stat(self.source_path)
        self.fingerprint = f"{self.source_path}|{int(st.st_mtime)}|{st.st_size}"
        self.game_version = "1.64.1"
        self._rel_to_entry: dict[str, str] = {}
        self._rel_lower: dict[str, str] = {}
        self._nested_zip_bytes: bytes | None = None
        self._index_entries()

    @staticmethod
    def _extract_ver_from_txt(raw_txt: str) -> str | None:
        m = re.match(r"^\s*(\d+\.\d+\.\d+)", raw_txt or "")
        if m:
            return m.group(1)
        m2 = re.match(r"^\s*(\d+\.\d+)", raw_txt or "")
        return m2.group(1) if m2 else None

    def _index_entries(self) -> None:
        if self.is_dir:
            walk_root = self.source_path
            base_name = os.path.basename(self.source_path)
            if re.match(r"^\d+\.\d+(?:\.\d+)*$", base_name):
                self.game_version = base_name
            else:
                res_sub = os.path.join(self.source_path, "Resources")
                if os.path.isdir(res_sub):
                    ver_dirs = [
                        d for d in sorted(os.listdir(res_sub))
                        if re.match(r"^\d+\.\d+(?:\.\d+)*$", d)
                        and os.path.isdir(os.path.join(res_sub, d))
                        and os.listdir(os.path.join(res_sub, d))
                    ]
                    if ver_dirs:
                        ver_dirs.sort(
                            key=lambda v: tuple(int(x) for x in v.split(".") if x.isdigit()),
                            reverse=True,
                        )
                        self.game_version = ver_dirs[0]
                        walk_root = os.path.join(res_sub, self.game_version)
                else:
                    vtxt_p = os.path.join(self.source_path, "version.txt")
                    if os.path.isfile(vtxt_p):
                        try:
                            with open(vtxt_p, "r", encoding="utf-8", errors="ignore") as vf:
                                det = self._extract_ver_from_txt(vf.read())
                            if det:
                                self.game_version = det
                        except OSError:
                            pass

            hs_stat = ""
            for root, _, files in os.walk(walk_root):
                for fn in files:
                    full = os.path.join(root, fn)
                    rel_raw = os.path.relpath(full, self.source_path).replace("\\", "/")
                    np = cp.normalize_aov_path(rel_raw, self.game_version)
                    if np and np.startswith("Resources/"):
                        parts = np.split("/", 2)
                        if len(parts) == 3:
                            if re.match(r"^\d+\.\d+", parts[1]):
                                self.game_version = parts[1]
                            rel = parts[2]
                            self._rel_to_entry[rel] = full
                            self._rel_lower[rel.lower()] = rel
                            if rel.lower() == "databin/client/actor/heroskin.bytes":
                                try:
                                    hst = os.stat(full)
                                    hs_stat = f"|{int(hst.st_mtime)}:{hst.st_size}"
                                except OSError:
                                    pass
            self.fingerprint = f"{self.fingerprint}|{len(self._rel_to_entry)}{hs_stat}"
        else:
            with zipfile.ZipFile(self.source_path, "r") as zf:
                has_direct = False
                nested_cand: str | None = None
                all_infos = [i for i in zf.infolist() if not i.is_dir() and not cp._is_ignored_archive_entry(i.filename)]
                for info in all_infos:
                    np = cp.normalize_aov_path(info.filename)
                    if np and np.startswith("Resources/"):
                        parts = np.split("/", 2)
                        if len(parts) == 3:
                            has_direct = True
                            self.game_version = parts[1]
                            rel = parts[2]
                            self._rel_to_entry[rel] = info.filename
                            self._rel_lower[rel.lower()] = rel
                    elif info.filename.lower().endswith("resources.zip") and nested_cand is None:
                        nested_cand = info.filename

                if not has_direct and nested_cand:
                    self._nested_zip_bytes = zf.read(nested_cand)
                    with zipfile.ZipFile(io.BytesIO(self._nested_zip_bytes), "r") as izf:
                        nested_infos = [
                            i for i in izf.infolist() if not i.is_dir() and not cp._is_ignored_archive_entry(i.filename)
                        ]
                        for info in nested_infos:
                            np = cp.normalize_aov_path(info.filename)
                            if np and np.startswith("Resources/"):
                                parts = np.split("/", 2)
                                if len(parts) == 3:
                                    self.game_version = parts[1]
                                    rel = parts[2]
                                    self._rel_to_entry[rel] = info.filename
                                    self._rel_lower[rel.lower()] = rel
                        if not self._rel_to_entry:
                            for info in nested_infos:
                                if info.filename.replace("\\", "/").lstrip("/").lower() == "version.txt":
                                    det = self._extract_ver_from_txt(izf.read(info.filename).decode("utf-8", errors="ignore"))
                                    if det:
                                        self.game_version = det
                                    break
                            for info in nested_infos:
                                np = cp.normalize_aov_path(info.filename, self.game_version)
                                if np and np.startswith("Resources/"):
                                    parts = np.split("/", 2)
                                    if len(parts) == 3:
                                        rel = parts[2]
                                        self._rel_to_entry[rel] = info.filename
                                        self._rel_lower[rel.lower()] = rel

                if not has_direct and not self._rel_to_entry:
                    for info in all_infos:
                        if info.filename.replace("\\", "/").lstrip("/").lower() == "version.txt":
                            det = self._extract_ver_from_txt(zf.read(info.filename).decode("utf-8", errors="ignore"))
                            if det:
                                self.game_version = det
                            break
                    for info in all_infos:
                        np = cp.normalize_aov_path(info.filename, self.game_version)
                        if np and np.startswith("Resources/"):
                            parts = np.split("/", 2)
                            if len(parts) == 3:
                                rel = parts[2]
                                self._rel_to_entry[rel] = info.filename
                                self._rel_lower[rel.lower()] = rel

        if not self._rel_to_entry:
            raise ValueError("Nguồn dữ liệu không chứa cấu trúc Resources/<version>/ hợp lệ của Liên Quân Mobile.")

    def has(self, rel_path: str) -> bool:
        return rel_path in self._rel_to_entry or rel_path.lower() in self._rel_lower

    def resolve_case(self, rel_path: str) -> str | None:
        if rel_path in self._rel_to_entry:
            return rel_path
        return self._rel_lower.get(rel_path.lower())

    def read(self, rel_path: str) -> bytes:
        real_rel = self.resolve_case(rel_path)
        if real_rel is None:
            raise KeyError(f"Không tìm thấy tệp {rel_path!r} trong Resources gốc.")
        target = self._rel_to_entry[real_rel]
        if self.is_dir:
            with open(target, "rb") as f:
                return f.read()
        if self._nested_zip_bytes is not None:
            with zipfile.ZipFile(io.BytesIO(self._nested_zip_bytes), "r") as izf:
                return izf.read(target)
        with zipfile.ZipFile(self.source_path, "r") as zf:
            return zf.read(target)

    def list_rel_paths(self) -> list[str]:
        return sorted(self._rel_to_entry.keys())


# ---------------------------------------------------------------------------
# Quản lý Bypass Seed (chống lỗi mạng sạch 100%, không popup quảng cáo)
# ---------------------------------------------------------------------------

def load_bypass_seed() -> dict[str, Any]:
    seed_path = CUSTOM_BYPASS_SEED_PATH if os.path.exists(CUSTOM_BYPASS_SEED_PATH) else DEFAULT_BYPASS_SEED_PATH
    if not os.path.exists(seed_path):
        raise FileNotFoundError("Thiếu tệp bypass_seed.zst trong thư mục assets.")
    with open(seed_path, "rb") as f:
        raw_zst = f.read()
    store_zip = zstd.ZstdDecompressor().decompress(raw_zst, max_output_size=32 * 1024 * 1024)
    entries = {name: data for name, _, _, data in cp.parse_in_memory_zip(store_zip)}
    meta = json.loads(entries.get("seed_meta.json", b"{}").decode("utf-8", errors="ignore") or "{}")
    if "KernelLua.pkg.bytes" not in entries or "StableSystems_3.pkg.bytes" not in entries:
        raise RuntimeError("Tệp bypass_seed.zst thiếu KernelLua.pkg.bytes hoặc StableSystems_3.pkg.bytes.")
    has_vanhoc_hs = ("HeroSkin_1.dec" in entries) and ("HeroSkin_2.dec" in entries)
    seed_mode = str(meta.get("seed_mode") or ("vanhoc" if has_vanhoc_hs else "lua_only")).strip().lower()
    if seed_mode not in {"lua_only", "vanhoc"}:
        seed_mode = "vanhoc" if has_vanhoc_hs else "lua_only"
    if seed_mode == "vanhoc" and not has_vanhoc_hs:
        raise RuntimeError("Bypass Seed chế độ Kiana IFix thiếu HeroSkin_1.dec hoặc HeroSkin_2.dec.")
    return {
        "seed_path": seed_path,
        "is_custom": seed_path == CUSTOM_BYPASS_SEED_PATH,
        "seed_mode": seed_mode,
        "meta": meta,
        "KernelLua.pkg.bytes": cp.sanitize_lua_pkg("KernelLua.pkg.bytes", entries["KernelLua.pkg.bytes"]),
        "StableSystems_3.pkg.bytes": cp.sanitize_lua_pkg("StableSystems_3.pkg.bytes", entries["StableSystems_3.pkg.bytes"]),
        "HeroSkin_1.dec": entries.get("HeroSkin_1.dec"),
        "HeroSkin_2.dec": entries.get("HeroSkin_2.dec"),
    }


def check_bypass_seed_compatibility(
    provider: BaseResourceProvider, seed: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Kiểm tra mức độ khớp phiên bản/build giữa Bypass Seed hiện tại và `Resources Gốc`."""
    cur_seed = seed or load_bypass_seed()
    meta = cur_seed.get("meta") or {}
    seed_mode = str(cur_seed.get("seed_mode") or "lua_only").strip().lower()

    res_vtxt = (
        provider.read("version.txt").decode("utf-8", errors="ignore").strip()
        if provider.has("version.txt")
        else provider.game_version
    )
    res_ver_t, res_bnum, res_clean = _parse_version_txt_key(res_vtxt)

    seed_vtxt_raw = str(meta.get("version_txt") or meta.get("game_version") or "").strip()
    seed_ver_t, seed_bnum, seed_clean = _parse_version_txt_key(seed_vtxt_raw)
    if not seed_bnum and meta.get("build_number"):
        try:
            seed_bnum = int(meta["build_number"])
        except (TypeError, ValueError):
            seed_bnum = 0

    compatible = True
    severity = "ok"
    message = (
        f"Bypass Seed ({seed_mode}) khớp Resources {res_clean or provider.game_version}."
    )

    if res_ver_t != (0,) and seed_ver_t != (0,):
        if res_ver_t[:3] != seed_ver_t[:3]:
            compatible = False
            severity = "error"
            message = (
                f"Bypass Seed thuộc phiên bản {seed_clean}, không khớp Resources {res_clean}. "
                "Vui lòng nhập mod mẫu mùa mới để tránh lỗi game."
            )
        elif seed_mode == "vanhoc" and (
            seed_ver_t != res_ver_t or (seed_bnum > 0 and res_bnum > 0 and seed_bnum != res_bnum)
        ):
            compatible = False
            severity = "error"
            message = (
                f"Bypass Seed Kiana ({seed_clean}) lệch bản build Resources ({res_clean}), "
                "dễ gây lỗi dữ liệu trận đấu (#3). Hãy dùng seed 1.64.1.13 Lua-only hoặc seed Kiana đúng bản."
            )
        elif seed_mode == "lua_only" and (
            (len(seed_ver_t) >= 4 and len(res_ver_t) >= 4 and seed_ver_t != res_ver_t)
            or (seed_bnum > 0 and res_bnum > 0 and seed_bnum != res_bnum)
        ):
            compatible = False
            severity = "warning"
            message = (
                f"Bypass Seed Lua ({seed_clean}) khác build nhỏ của Resources ({res_clean}). "
                "Nếu game báo lỗi dữ liệu, hãy nhập mod mẫu bản mới nhất."
            )

    return {
        "compatible": compatible,
        "severity": severity,
        "seed_mode": seed_mode,
        "is_custom": bool(cur_seed.get("is_custom")),
        "seed_version": seed_clean,
        "resources_version": res_clean or provider.game_version,
        "message": message,
    }


def import_bypass_seed_from_mod_zip(zip_bytes: bytes) -> dict[str, Any]:
    """Trích xuất & khử sạch quảng cáo Bypass Seed (hỗ trợ cả Lua-only và Kiana IFix) từ gói mod mẫu."""
    mod = cp.load_mod_from_bytes("imported_seed.zip", zip_bytes)
    ver = mod["explicit_ver"] or "1.64.1"
    rel_files: dict[str, bytes] = {}
    for k, v in mod["raw_files"].items():
        np = cp.normalize_aov_path(k, ver)
        if np and np.startswith("Resources/"):
            parts = np.split("/", 2)
            if len(parts) == 3:
                rel_files[parts[2]] = v

    required = ["KernelLua.pkg.bytes", "StableSystems_3.pkg.bytes"]
    missing = [r for r in required if r not in rel_files]
    if missing:
        raise ValueError(f"Gói mod mẫu không đủ tệp bypass cần thiết: {', '.join(missing)}")

    klua = cp.ensure_pkg_stored(cp.sanitize_lua_pkg("KernelLua.pkg.bytes", rel_files["KernelLua.pkg.bytes"]))
    ss3 = cp.ensure_pkg_stored(cp.sanitize_lua_pkg("StableSystems_3.pkg.bytes", rel_files["StableSystems_3.pkg.bytes"]))
    seed_pkg_md5s = {
        "KernelLua.pkg.bytes": hashlib.md5(klua).hexdigest().lower(),
        "StableSystems_3.pkg.bytes": hashlib.md5(ss3).hexdigest().lower(),
    }

    seed_mode = "lua_only"
    hs1_dec: bytes | None = None
    hs2_dec: bytes | None = None
    if "Thanos/HeroSkin_1.bytes" in rel_files and "Thanos/HeroSkin_2.bytes" in rel_files:
        try:
            cand_hs1 = cp.pg_decrypt(rel_files["Thanos/HeroSkin_1.bytes"], "HeroSkin_1")
            cand_hs2 = cp.pg_decrypt(rel_files["Thanos/HeroSkin_2.bytes"], "HeroSkin_2")
            if cp.parse_kiana_hs1(cand_hs1) is not None:
                seed_mode = "vanhoc"
                b1 = bytearray(cand_hs1)
                cp.update_embedded_pkg_md5s(b1, seed_pkg_md5s)
                hs1_dec = bytes(b1)
                b2 = bytearray(cand_hs2)
                cp.update_embedded_pkg_md5s(b2, seed_pkg_md5s)
                hs2_dec = bytes(b2)
        except Exception:
            seed_mode = "lua_only"

    vtxt = rel_files.get("version.txt", b"").decode("utf-8", errors="ignore").strip()
    _, bnum, clean_vtxt = _parse_version_txt_key(vtxt)
    meta = {
        "game_version": ver,
        "version_txt": clean_vtxt,
        "build_number": bnum,
        "seed_mode": seed_mode,
        "imported_at": int(time.time()),
    }
    seed_entries = [
        ("KernelLua.pkg.bytes", 0, 0x21, klua),
        ("StableSystems_3.pkg.bytes", 0, 0x21, ss3),
        ("seed_meta.json", 0, 0x21, json.dumps(meta).encode("utf-8")),
    ]
    if seed_mode == "vanhoc" and hs1_dec is not None and hs2_dec is not None:
        seed_entries.extend(
            [
                ("HeroSkin_1.dec", 0, 0x21, hs1_dec),
                ("HeroSkin_2.dec", 0, 0x21, hs2_dec),
            ]
        )
    store_zip = cp.build_in_memory_store_zip(seed_entries)
    compressed = zstd.ZstdCompressor(level=10).compress(store_zip)
    with open(CUSTOM_BYPASS_SEED_PATH, "wb") as f:
        f.write(compressed)
    return meta


# ---------------------------------------------------------------------------
# 1. `CatalogIndexer` — Danh mục Tướng / Skin / Nút bấm / Thông báo hạ Tiếng Việt
# ---------------------------------------------------------------------------

def _decode_text_resource(raw: bytes) -> str:
    if len(raw) > 8 and raw[:2] == b"\x22\x4a":
        try:
            dec = cp.pg_decrypt(raw, "languageMap")
            if dec != raw and not (len(dec) > 8 and dec[:2] == b"\x22\x4a"):
                raw = dec
        except Exception:
            pass
        if len(raw) > 8 and raw[:2] == b"\x22\x4a":
            for cand in (raw[8:], raw):
                try:
                    raw = cp.decompress_with_dict(cand)
                    break
                except Exception:
                    pass
    return raw.decode("utf-8", errors="ignore")


def _extract_utf8_len_prefixed_string_entries(rec: bytes, start_off: int = 8) -> list[dict[str, Any]]:
    """Quét các chuỗi UTF-8 có tiền tố u32 độ dài (bao gồm byte null cuối) kèm offset trong bản ghi MSES."""
    out: list[dict[str, Any]] = []
    n = len(rec)
    pos = start_off
    while pos + 5 <= n:
        slen = struct.unpack_from("<I", rec, pos)[0]
        if 2 <= slen <= 160 and pos + 4 + slen <= n and rec[pos + 4 + slen - 1] == 0:
            chunk = rec[pos + 4 : pos + 4 + slen - 1]
            if chunk and all(b >= 0x20 or b in (0x09, 0x0A, 0x0D) or b >= 0x80 for b in chunk):
                try:
                    s = chunk.decode("utf-8").strip()
                    if s:
                        out.append({"offset": pos, "slen": slen, "text": s})
                        pos += 4 + slen
                        continue
                except UnicodeDecodeError:
                    pass
        pos += 1
    return out


def _extract_utf8_len_prefixed_strings(rec: bytes, start_off: int = 8) -> list[str]:
    """Quét các chuỗi UTF-8 có tiền tố u32 độ dài (bao gồm byte null cuối) trong bản ghi MSES."""
    return [item["text"] for item in _extract_utf8_len_prefixed_string_entries(rec, start_off)]


def _is_placeholder_label(text: str) -> bool:
    low = (text or "").strip().lower()
    if not low:
        return True
    if low in ("ex", "mặc định", "default", "none", "null"):
        return True
    if "[ex]" in low or "[dnt]" in low:
        return True
    if low.isdigit():
        return True
    return False


class CatalogIndexer:
    """Xây dựng và lưu đệm danh mục đầy đủ từ `Resources Gốc`."""

    @staticmethod
    def build_or_load(provider: BaseResourceProvider, force_rebuild: bool = False) -> dict[str, Any]:
        if not force_rebuild and os.path.exists(CATALOG_CACHE_PATH):
            try:
                with open(CATALOG_CACHE_PATH, "r", encoding="utf-8") as f:
                    cached = json.load(f)
                if (
                    cached.get("fingerprint") == provider.fingerprint
                    and cached.get("cache_version") == CATALOG_CACHE_VERSION
                ):
                    return cached
            except Exception:
                pass

        t0 = time.time()
        xls_map: dict[str, str] = {}
        for lang_rel in ("Languages/VN_Garena_VN/languageMap_Xls.txt", "Languages/VN_Garena_VN/languageMap.txt"):
            if provider.has(lang_rel):
                txt = _decode_text_resource(provider.read(lang_rel))
                for line in txt.splitlines():
                    if "=" in line:
                        k, v = line.split("=", 1)
                        ks = k.strip()
                        vs = v.strip()
                        if ks and vs:
                            xls_map[ks] = vs
                            if ks.endswith("_##"):
                                xls_map[ks[:-3]] = vs

        def resolve_xls_keys(raw_rec: bytes) -> list[str]:
            res: list[str] = []
            for m in _XLS_KEY_RE.finditer(raw_rec):
                k = m.group(1).decode("ascii")
                val = xls_map.get(k) or xls_map.get(k[:-3])
                if val and val not in res:
                    res.append(val)
            return res

        # 1. ResSkinSeniorLabelCfg (skin Huy Hoàng / Chí Tôn dùng hậu tố _HD)
        senior_skins: set[int] = set()
        if provider.has("Databin/Client/Actor/ResSkinSeniorLabelCfg.bytes"):
            tbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Actor/ResSkinSeniorLabelCfg.bytes"), "ResSkinSeniorLabelCfg"))
            if tbl:
                for rid, _ in tbl["recs"]:
                    senior_skins.add(int(rid))

        # 2. BattleBank (skin có gói âm thanh Wwise riêng — bao gồm cả mã tiến hóa 7 chữ số)
        skins_with_sound: set[int] = set()
        if provider.has("Databin/Client/Sound/BattleBank.bytes"):
            tbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Sound/BattleBank.bytes"), "BattleBank"))
            if tbl:
                for _, rraw in tbl["recs"]:
                    if len(rraw) >= 17:
                        slen = struct.unpack_from("<I", rraw, 8)[0]
                        skin_off = 12 + slen if (1 <= slen <= len(rraw) - 16 and rraw[12 + slen - 1] == 0) else 13
                        sid = struct.unpack_from("<I", rraw, skin_off)[0]
                        if 10000 <= sid <= 9999999:
                            skins_with_sound.add(int(sid))
                            if sid >= 1_000_000:
                                skins_with_sound.add(int(sid) // 100)

        # 3. Nút bấm cá nhân (ResPersonalButtonCfg + ResPersonalButtonShopCfg)
        btn_shop_names: dict[int, str] = {}
        if provider.has("Databin/Client/Huanhua/ResPersonalButtonShopCfg.bytes"):
            tbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Huanhua/ResPersonalButtonShopCfg.bytes"), "ResPersonalButtonShopCfg"))
            if tbl:
                for rid, rraw in tbl["recs"]:
                    strs = _extract_utf8_len_prefixed_strings(rraw, 8)
                    if strs:
                        btn_shop_names[int(rid)] = strs[0]

        personal_buttons: list[dict[str, Any]] = []
        skin_to_button: dict[int, int] = {}
        if provider.has("Databin/Client/Huanhua/ResPersonalButtonCfg.bytes"):
            tbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Huanhua/ResPersonalButtonCfg.bytes"), "ResPersonalButtonCfg"))
            if tbl:
                for rid, rraw in tbl["recs"]:
                    if len(rraw) >= 12:
                        skin_ref = struct.unpack_from("<I", rraw, 8)[0]
                        strs = _extract_utf8_len_prefixed_strings(rraw, 12)
                        name = btn_shop_names.get(int(rid)) or (strs[0] if strs else f"Nút bấm #{rid}")
                        personal_buttons.append({
                            "id": int(rid),
                            "skin_id": int(skin_ref),
                            "name": name,
                        })
                        if skin_ref and int(skin_ref) not in skin_to_button:
                            skin_to_button[int(skin_ref)] = int(rid)

        # 4. Thông báo hạ gục (ResBillboardSkinCfg)
        kill_broadcasts: list[dict[str, Any]] = []
        skin_to_kill_broadcast: dict[int, int] = {}
        if provider.has("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes"):
            tbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes"), "ResBillboardSkinCfg"))
            if tbl:
                for rid, rraw in tbl["recs"]:
                    if len(rraw) >= 16:
                        skin_ref = struct.unpack_from("<I", rraw, 12)[0]
                        kill_broadcasts.append({
                            "id": int(rid),
                            "skin_id": int(skin_ref),
                            "name": f"Thông báo hạ #{rid}",
                        })
                        if skin_ref and int(skin_ref) not in skin_to_kill_broadcast:
                            skin_to_kill_broadcast[int(skin_ref)] = int(rid)

        # 5. Danh sách Tướng hợp lệ có Actor_<H>_Infos.pkg.bytes (và kiểm tra Actor_<H>_Actions.pkg.bytes)
        valid_hero_ids: set[int] = set()
        valid_action_ids: set[int] = set()
        for rel in provider.list_rel_paths():
            m = re.match(r"^Prefab_Characters/Actor_(\d+)_Infos\.pkg\.bytes$", rel, re.IGNORECASE)
            if m:
                valid_hero_ids.add(int(m.group(1)))
            ma = re.match(r"^Ages/Prefab_Characters/Prefab_Hero/Actor_(\d+)_Actions\.pkg\.bytes$", rel, re.IGNORECASE)
            if ma:
                valid_action_ids.add(int(ma.group(1)))

        heroes_map: dict[int, dict[str, Any]] = {}
        if provider.has("Databin/Client/Actor/hero.bytes"):
            tbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Actor/hero.bytes"), "hero"))
            if tbl:
                for rid, rraw in tbl["recs"]:
                    hid = int(rid)
                    if hid not in valid_hero_ids:
                        continue
                    names = resolve_xls_keys(rraw)
                    code_m = re.search(rb"Prefab_Hero/(\d+_[A-Za-z0-9_]+)/", rraw)
                    hero_code = code_m.group(1).decode("utf-8", "ignore") if code_m else ""
                    if not hero_code and hid in valid_action_ids:
                        act_rel = f"Ages/Prefab_Characters/Prefab_Hero/Actor_{hid}_Actions.pkg.bytes"
                        if provider.has(act_rel):
                            try:
                                for ename, _, _, _ in cp.parse_in_memory_zip(provider.read(act_rel)):
                                    cm2 = re.match(r"^(\d+_[A-Za-z0-9_]+)/", ename.replace("\\", "/"))
                                    if cm2:
                                        hero_code = cm2.group(1)
                                        break
                            except Exception:
                                pass
                    if not hero_code:
                        hero_code = str(hid)
                    heroes_map[hid] = {
                        "hero_id": hid,
                        "name": names[0] if names else hero_code,
                        "title": names[1] if len(names) > 1 else "",
                        "code": hero_code,
                        "has_actions": hid in valid_action_ids,
                        "skins": [],
                    }

        # 6. Đọc nhãn bậc trang phục từ HeroSkinShop.bytes (VD: T6DirectSale -> Bậc A, T5 -> S, T2 -> SSS)
        skin_shop_pngs: dict[int, list[str]] = {}
        if provider.has("Databin/Client/Shop/HeroSkinShop.bytes"):
            sh_tbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Shop/HeroSkinShop.bytes"), "HeroSkinShop"))
            if sh_tbl:
                for rid, rraw in sh_tbl["recs"]:
                    pngs = [m.decode("ascii", "ignore").lower() for m in re.findall(rb"[A-Za-z0-9_]+\.png", rraw)]
                    if pngs:
                        skin_shop_pngs[int(rid)] = pngs

        def _classify_skin_tier(
            skin_idx: int, is_hd: bool, has_recall: bool, has_snd: bool, pngs: list[str], raw_rec: bytes
        ) -> tuple[str, int]:
            if skin_idx == 0:
                return ("Mặc định", 0)
            if is_hd:
                return ("Chí Tôn / HD", 5)
            has_sss_tags = b"Skin_Icon_Animation" in raw_rec and b"Skin_Icon_Atmosphere" in raw_rec
            if any(p.startswith(("t0", "t1")) or "sss" in p or "_1.png" in p for p in pngs):
                return ("SSS / Tuyệt Sắc", 4)
            if any(p.startswith("t2") for p in pngs):
                if any("limit" in p for p in pngs) and not has_sss_tags:
                    return ("SS+ Hữu hạn", 4)
                return ("SSS / Tuyệt Sắc", 4) if has_sss_tags else ("SS+ Hữu hạn", 4)
            if has_sss_tags:
                return ("SSS / Tuyệt Sắc", 4)
            if any(p.startswith("t3") for p in pngs):
                return ("SS Hữu hạn", 3) if any("limit" in p for p in pngs) else ("SS", 3)
            if any("ss_" in p or "_ss" in p for p in pngs) or (has_recall and b"Skin_Icon_Modelhuang" in raw_rec):
                return ("SS", 3)
            if any("splus" in p or "s+" in p for p in pngs):
                return ("S+ Hữu hạn", 2) if any("limit" in p for p in pngs) else ("S+", 2)
            if any(p.startswith("t4") for p in pngs):
                return ("S+ Hữu hạn", 2) if any("limit" in p for p in pngs) else ("S+", 2)
            if any(p.startswith("t5") or "_s_" in p for p in pngs) or has_recall or (
                has_snd and skin_idx > 0
            ) or b"Skin_Icon_Skill" in raw_rec:
                return ("Bậc S", 2)
            return ("Bậc A", 1)

        # 7. Danh sách Skin từ heroSkin.bytes (offset 16 = HeroName key, offset 44 = SkinName key)
        skin_name_lookup: dict[int, str] = {}
        hero_name_priority: dict[int, int] = {}
        if provider.has("Databin/Client/Actor/heroSkin.bytes"):
            tbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Actor/heroSkin.bytes"), "heroSkin"))
            if tbl:
                for rid, rraw in tbl["recs"]:
                    sid = int(rid)
                    if len(rraw) < 64:
                        continue
                    hid = struct.unpack_from("<I", rraw, 8)[0]
                    if hid not in heroes_map:
                        continue
                    skin_idx = struct.unpack_from("<I", rraw, 36)[0]
                    # Đọc chính xác khóa tên tướng tại offset 16 và khóa tên trang phục tại offset 44
                    h_key = rraw[16:35].decode("ascii", errors="ignore")
                    s_key = rraw[44:63].decode("ascii", errors="ignore")
                    h_resolved = (xls_map.get(h_key) or xls_map.get(h_key[:16]) or "").strip()
                    s_resolved = (xls_map.get(s_key) or xls_map.get(s_key[:16]) or "").strip()

                    # Không để skin placeholder (`[ex]`, `[ex][DNT]`, `Mặc định`, `EX`) ghi đè tên tướng chuẩn
                    if h_resolved and not _is_placeholder_label(h_resolved):
                        prio = 2 if skin_idx == 0 else 1
                        if prio > hero_name_priority.get(hid, 0):
                            heroes_map[hid]["name"] = h_resolved
                            hero_name_priority[hid] = prio

                    names = resolve_xls_keys(rraw)
                    h_name = heroes_map[hid]["name"]
                    if s_resolved:
                        s_name = "Mặc định" if (skin_idx == 0 and s_resolved == h_name) else s_resolved
                    elif len(names) >= 2:
                        s_name = names[1]
                    elif len(names) == 1:
                        s_name = "Mặc định" if skin_idx == 0 else names[0]
                    else:
                        s_name = "Mặc định" if skin_idx == 0 else f"Skin #{sid}"

                    is_placeholder = bool(
                        skin_idx > 0
                        and (
                            _is_placeholder_label(s_name)
                            or s_name == h_name
                            or s_name.startswith("Skin #")
                        )
                    )
                    has_recall = b"Skin_Icon_BackToTown" in rraw
                    is_hd = sid in senior_skins
                    has_snd = sid in skins_with_sound or skin_idx == 0
                    tier_label, tier_rank = _classify_skin_tier(
                        int(skin_idx), is_hd, has_recall, has_snd, skin_shop_pngs.get(sid, []), rraw
                    )
                    btn_id = skin_to_button.get(sid, 0)
                    kn_id = skin_to_kill_broadcast.get(sid, 0)
                    if not is_placeholder:
                        skin_name_lookup[sid] = f"{h_name} — {s_name}"

                    heroes_map[hid]["skins"].append({
                        "skin_id": sid,
                        "skin_index": int(skin_idx),
                        "name": s_name,
                        "is_default": skin_idx == 0,
                        "is_placeholder": is_placeholder,
                        "is_hd": is_hd,
                        "has_recall": has_recall,
                        "has_sound": has_snd,
                        "tier_label": tier_label,
                        "tier_rank": tier_rank,
                        "button_id": btn_id,
                        "kill_notify_id": kn_id,
                    })

        # Bổ sung tên skin dễ hiểu cho danh sách Nút bấm & Thông báo hạ
        for b in personal_buttons:
            s_lbl = skin_name_lookup.get(b["skin_id"])
            if s_lbl:
                b["skin_label"] = s_lbl
                if b["name"].startswith("Nút bấm #") or any("\u4e00" <= ch <= "\u9fff" for ch in b["name"]):
                    b["name"] = f"Nút bấm {s_lbl}"
            else:
                b["skin_label"] = f"Skin #{b['skin_id']}"

        for kb in kill_broadcasts:
            s_lbl = skin_name_lookup.get(kb["skin_id"])
            kb["skin_label"] = s_lbl or f"Skin #{kb['skin_id']}"
            if s_lbl:
                kb["name"] = f"Thông báo hạ — {s_lbl}"

        heroes_list = sorted(heroes_map.values(), key=lambda h: h["name"].lower())
        flat_skins: list[dict[str, Any]] = []
        for h in heroes_list:
            h["skins"].sort(key=lambda s: (s["skin_index"], s["skin_id"]))
            for s in h["skins"]:
                flat_skins.append({
                    "hero_id": h["hero_id"],
                    "hero_name": h["name"],
                    "hero_code": h["code"],
                    **s,
                })

        version_txt = ""
        if provider.has("version.txt"):
            version_txt = provider.read("version.txt").decode("utf-8", errors="ignore").strip()

        sorted_buttons = sorted(personal_buttons, key=lambda x: x["id"])
        sorted_billboards = sorted(kill_broadcasts, key=lambda x: x["id"])

        catalog = {
            "cache_version": CATALOG_CACHE_VERSION,
            "fingerprint": provider.fingerprint,
            "resources_path": provider.source_path,
            "game_version": provider.game_version,
            "version_txt": version_txt or provider.game_version,
            "indexed_in_ms": int((time.time() - t0) * 1000),
            "hero_count": len(heroes_list),
            "skin_count": sum(len(h["skins"]) for h in heroes_list),
            "heroes": heroes_list,
            "skins": flat_skins,
            "personal_buttons": sorted_buttons,
            "kill_broadcasts": sorted_billboards,
            "billboards": sorted_billboards,
        }
        try:
            with open(CATALOG_CACHE_PATH, "w", encoding="utf-8") as f:
                json.dump(catalog, f, ensure_ascii=False)
        except Exception:
            pass
        return catalog


# ---------------------------------------------------------------------------
# 2. `SkinModBuilder` — Bộ tạo Mod Skin 1-Click, Mix Chiêu & Cam Xa
# ---------------------------------------------------------------------------

def _skin_belongs_to_hero(skin_str: str, hero_id: int) -> bool:
    s = str(skin_str).strip()
    if not s.isdigit():
        return False
    hp = str(hero_id)
    return s.startswith(hp) and len(s) in (len(hp) + 2, len(hp) + 4)


_GENERIC_SOUND_EVENT_PREFIXES = (
    "Play_UI", "Play_Common", "Play_System", "Play_Buff", "Play_Item", "Play_Scene",
    "Stop_UI", "Stop_Common", "Stop_System", "Stop_Buff", "Stop_Item", "Stop_Scene",
)


def _rewrite_check_skin_id_track(
    raw: str,
    hero_id: int,
    active_str: str,
    dummy_active: str,
    event_type: str = "",
    is_common: bool = False,
    target_skin_ids: list[str] | None = None,
    existing_skins: list[str] | None = None,
    existing_filter_type: str | None = None,
    arr_ids: list[str] | None = None,
) -> str:
    """Đảo điều kiện `<int name="skinId" .../>` trên track `CheckSkinIdTick` (`bEqual`) / `CheckSkinIdVirtualTick` (`useNegateValue`)."""
    m_sid = _SKIN_ID_PROP_RE.search(raw)
    if not m_sid:
        return raw
    checked_val = m_sid.group(2)
    if checked_val == active_str:
        has_bequal_false = bool(_BEQUAL_FALSE_RE.search(raw))
        has_neg_true = bool(_NEGATE_PROP_RE.search(raw))
        is_tick = event_type == "CheckSkinIdTick"
        has_neg = has_bequal_false if is_tick else (has_neg_true or has_bequal_false)
        has_active_in_arr = bool(arr_ids and active_str in arr_ids)

        raw = _SKIN_ID_PROP_RE.sub(rf"\g<1>{dummy_active}\g<3>", raw, count=1)

        if has_neg:
            if is_common:
                # CommonActions chạy toàn cục cho 130+ tướng: giữ nguyên bEqual="false" / useNegateValue="true"
                # và thêm SkinAvatarFilterType="11" cho target_skin_ids để chỉ bỏ qua cho tướng đang mod.
                if target_skin_ids and existing_filter_type in (None, "11"):
                    cur_skins = existing_skins or []
                    other_skins = [s for s in cur_skins if not _skin_belongs_to_hero(s, hero_id)]
                    merged_skins = other_skins + [s for s in target_skin_ids if s not in other_skins]
                    if merged_skins != cur_skins or existing_filter_type != "11":
                        raw = cp.replace_skin_tags(raw, merged_skins, filter_type="11")
            elif has_active_in_arr:
                # Nếu skinIdArray cũng chứa active_str và sẽ được mở rộng sang target_skin_ids, giữ nguyên negation
                pass
            else:
                if is_tick:
                    raw = _BEQUAL_FALSE_RE.sub("", raw, count=1)
                else:
                    raw = _NEGATE_PROP_RE.sub("", raw, count=1)
                    if has_bequal_false:
                        raw = _BEQUAL_FALSE_RE.sub("", raw, count=1)
        else:
            if has_active_in_arr:
                # Track có cả skinId lẫn skinIdArray chứa active_str không phủ định (VD: HasteE1.xml trk 50):
                # chỉ đổi skinId -> dummy_active để skinIdArray (đã mở rộng target_skin_ids) khớp dương tính.
                pass
            else:
                if is_tick:
                    if _BEQUAL_TRUE_RE.search(raw):
                        raw = _BEQUAL_TRUE_RE.sub(r"\g<1>false\g<2>", raw, count=1)
                    else:
                        eol = "\r\n        " if "\r\n" in raw else ("\n        " if "\n" in raw else "")
                        raw = _SKIN_ID_PROP_RE.sub(
                            rf'\g<0>{eol}<bool name="bEqual" value="false" refParamName="" useRefParam="false" />',
                            raw,
                            count=1,
                        )
                else:
                    if _NEGATE_FALSE_RE.search(raw):
                        raw = _NEGATE_FALSE_RE.sub(r"\g<1>true\g<2>", raw, count=1)
                    elif _NEGATE_ATTR_FALSE_RE.search(raw):
                        raw = _NEGATE_ATTR_FALSE_RE.sub(r"\g<1>true\g<2>", raw, count=1)
                    else:
                        eol = "\r\n        " if "\r\n" in raw else ("\n        " if "\n" in raw else "")
                        raw = _SKIN_ID_PROP_RE.sub(
                            rf'\g<0>{eol}<bool name="useNegateValue" value="true" refParamName="" useRefParam="false" />',
                            raw,
                            count=1,
                        )
                if is_common and target_skin_ids and existing_filter_type in (None, "9"):
                    # CommonActions chạy toàn cục cho 130+ tướng: giới hạn SkinAvatarFilterType="9" cho target_skin_ids
                    # để track vừa phủ định (skinId=235XX, bEqual=false / useNegateValue=true) không rò rỉ sang tướng khác.
                    cur_skins = existing_skins or []
                    other_skins = [s for s in cur_skins if not _skin_belongs_to_hero(s, hero_id)]
                    merged_skins = other_skins + [s for s in target_skin_ids if s not in other_skins]
                    if merged_skins != cur_skins or existing_filter_type != "9":
                        raw = cp.replace_skin_tags(raw, merged_skins, filter_type="9")
    elif _skin_belongs_to_hero(checked_val, hero_id):
        d_other = str(dummy_skin_id(int(checked_val)))
        raw = _SKIN_ID_PROP_RE.sub(rf"\g<1>{d_other}\g<3>", raw, count=1)
    return raw


def _transform_action_xml_for_skin(
    xml_text: str,
    hero_id: int,
    active_skin_id: int,
    is_hd_skin: bool,
    target_skin_ids: list[str],
    rewrite_effects: bool = True,
    sound_skin_id: int | None = None,
    has_custom_sound: bool = False,
    action_filename: str = "",
    rpack_hashes: set[tuple[int, int]] | None = None,
) -> str:
    """
    Biến đổi một tệp AGE XML trong `Actor_<H>_Actions.pkg.bytes`:
      1. Đảo điều kiện `CheckSkinIdTick` / `CheckSkinIdVirtualTick` để nhánh `active_skin_id` luôn TRUE.
      2. Mở rộng `SkinOrAvatarList` / `skinIdArray` của `active_skin_id` sang `target_skin_ids` và đẩy skin khác về `235XX`.
      3. Đổi đường dẫn `resourceName` trên các track đang hoạt động sang prefab của `active_skin_id`.
      4. Nếu bật âm thanh và skin có bank Wwise riêng: thêm hậu tố `_Skin<idx>` vào `PlayHeroSoundTick`.
    """
    sp_res = cp.split_xml_tracks(xml_text)
    if not sp_res:
        return xml_text
    hdr, tracks, ftr = sp_res
    if not tracks:
        return xml_text

    active_str = str(active_skin_id)
    dummy_active = str(dummy_skin_id(active_skin_id))
    if sound_skin_id and hero_id * 100 < sound_skin_id < (hero_id + 1) * 100:
        snd_idx = sound_skin_id - hero_id * 100
    elif sound_skin_id and hero_id * 10000 < sound_skin_id < (hero_id + 1) * 10000:
        snd_idx = (sound_skin_id - hero_id * 10000) // 100
    else:
        snd_idx = 0

    skip_sound_suffix = False
    if action_filename:
        base_fn = os.path.basename(action_filename.replace("\\", "/"))
        m_pref = re.match(r"^(\d+)_", base_fn)
        if m_pref and _skin_belongs_to_hero(m_pref.group(1), hero_id):
            file_sid = int(m_pref.group(1))
            if file_sid != active_skin_id and file_sid != hero_id * 100:
                skip_sound_suffix = True

    out_raws: list[str] = []

    for trk in tracks:
        raw = trk["raw"]
        ev_type = trk.get("eventType") or ""
        flt = trk.get("filterType")
        skins = trk.get("skins") or []
        arr_ids = trk.get("skinArrayIds") or []

        # 1. Xử lý CheckSkinIdTick / CheckSkinIdVirtualTick (không continue để vẫn xử lý SkinOrAvatarList / skinIdArray)
        if "CheckSkinId" in ev_type:
            raw = _rewrite_check_skin_id_track(
                raw,
                hero_id,
                active_str,
                dummy_active,
                event_type=ev_type,
                is_common=False,
                target_skin_ids=target_skin_ids,
                existing_skins=skins,
                existing_filter_type=flt,
                arr_ids=arr_ids,
            )

        # 2. Xác định track có chạy cho `active_skin_id` không & cập nhật SkinOrAvatarList / skinIdArray
        track_runs_for_active = True
        hero_skins_in_track = [s for s in skins if _skin_belongs_to_hero(s, hero_id)]
        other_hero_skins = [s for s in skins if not _skin_belongs_to_hero(s, hero_id)]

        if flt == "9":  # Chỉ chạy cho các skin trong danh sách
            if skins:
                if active_str in hero_skins_in_track:
                    new_skins = other_hero_skins + [s for s in target_skin_ids if s not in other_hero_skins]
                    raw = cp.replace_skin_tags(raw, new_skins)
                elif hero_skins_in_track:
                    track_runs_for_active = False
                    remapped = other_hero_skins + [str(dummy_skin_id(int(s))) for s in hero_skins_in_track]
                    raw = cp.replace_skin_tags(raw, remapped)
                else:
                    track_runs_for_active = False
        elif flt == "11":  # Loại trừ các skin trong danh sách
            if active_str in hero_skins_in_track:
                track_runs_for_active = False
                new_skins = other_hero_skins + [s for s in target_skin_ids if s not in other_hero_skins]
                raw = cp.replace_skin_tags(raw, new_skins)
            elif hero_skins_in_track:
                remapped = other_hero_skins + [str(dummy_skin_id(int(s))) for s in hero_skins_in_track]
                raw = cp.replace_skin_tags(raw, remapped)

        if arr_ids:
            hero_arr = [s for s in arr_ids if _skin_belongs_to_hero(s, hero_id)]
            other_arr = [s for s in arr_ids if not _skin_belongs_to_hero(s, hero_id)]
            if active_str in hero_arr:
                raw = cp.replace_skin_id_array(raw, other_arr + target_skin_ids)
            elif hero_arr:
                if flt == "9" or not flt:
                    track_runs_for_active = False
                raw = cp.replace_skin_id_array(raw, other_arr + [str(dummy_skin_id(int(s))) for s in hero_arr])

        # 3. Đổi đường dẫn prefab hiệu ứng & tắt bAllowEmptyEffect trên track đang chạy
        if rewrite_effects and track_runs_for_active and "CheckSkinId" not in ev_type:
            if "resourceName" in raw:
                def _sub_res(m: re.Match[str]) -> str:
                    old_p = m.group(2)
                    if not old_p:
                        return m.group(0)
                    new_p = jtcom.rewrite_hero_effect_path(
                        old_p, hero_id, active_skin_id, is_hd_skin, rpack_hashes=rpack_hashes
                    )
                    return f"{m.group(1)}{new_p}{m.group(3)}"

                raw = _RESOURCE_NAME_RE.sub(_sub_res, raw)
            if 'bAllowEmptyEffect" value="true"' in raw:
                raw = raw.replace('bAllowEmptyEffect" value="true"', 'bAllowEmptyEffect" value="false"')

        # 4. Hậu tố âm thanh Wwise `_Skin<idx>` cho PlayHeroSoundTick trên skin mặc định XX00
        if (
            has_custom_sound
            and not skip_sound_suffix
            and snd_idx > 0
            and track_runs_for_active
            and ev_type == "PlayHeroSoundTick"
        ):
            raw = _EXTRA_SKIN_ARRAY_RE.sub("", raw)

            def _sub_ev(m: re.Match[str]) -> str:
                ev = m.group(2)
                if not ev or "_Skin" in ev or not (ev.startswith("Play_") or ev.startswith("Stop_")):
                    return m.group(0)
                if ev.startswith(_GENERIC_SOUND_EVENT_PREFIXES):
                    return m.group(0)
                return f"{m.group(1)}{ev}_Skin{snd_idx}{m.group(3)}"

            raw = _EVENT_NAME_RE.sub(_sub_ev, raw)

        out_raws.append(raw)

    sep = "\r\n    " if "\r\n" in xml_text else ("\n    " if "\n" in xml_text else "")
    return hdr + sep.join(out_raws) + ftr


def _transform_common_action_xml(
    xml_text: str,
    hero_id: int,
    active_skin_id: int,
    target_skin_ids: list[str],
) -> str:
    """Mở rộng `SkinOrAvatarList` & `skinIdArray` của `active_skin_id` trong `CommonActions.pkg.bytes` (`Back.xml`, `Born.xml`, `HasteE1.xml`)."""
    sp_res = cp.split_xml_tracks(xml_text)
    if not sp_res:
        return xml_text
    hdr, tracks, ftr = sp_res
    if not tracks:
        return xml_text

    active_str = str(active_skin_id)
    dummy_active = str(dummy_skin_id(active_skin_id))
    changed = False
    out_raws: list[str] = []

    for trk in tracks:
        raw = trk["raw"]
        ev_type = trk.get("eventType") or ""
        flt = trk.get("filterType")
        skins = trk.get("skins") or []
        arr_ids = trk.get("skinArrayIds") or []

        common_filter_applied = False
        if "CheckSkinId" in ev_type:
            new_raw = _rewrite_check_skin_id_track(
                raw,
                hero_id,
                active_str,
                dummy_active,
                event_type=ev_type,
                is_common=True,
                target_skin_ids=target_skin_ids,
                existing_skins=skins,
                existing_filter_type=flt,
                arr_ids=arr_ids,
            )
            if new_raw != raw:
                raw = new_raw
                changed = True
                if not skins and "<SkinOrAvatarList" in raw:
                    common_filter_applied = True
                elif (
                    target_skin_ids
                    and all(s in raw for s in target_skin_ids)
                    and ('SkinAvatarFilterType="11"' in raw or 'SkinAvatarFilterType="9"' in raw)
                ):
                    common_filter_applied = True

        hero_skins = [s for s in skins if _skin_belongs_to_hero(s, hero_id)]
        if hero_skins and not common_filter_applied:
            other_skins = [s for s in skins if not _skin_belongs_to_hero(s, hero_id)]
            if active_str in hero_skins:
                merged_skins = other_skins + [s for s in target_skin_ids if s not in other_skins]
            else:
                merged_skins = other_skins + [str(dummy_skin_id(int(s))) for s in hero_skins]
            if merged_skins != skins:
                raw = cp.replace_skin_tags(raw, merged_skins)
                changed = True

        hero_arr = [s for s in arr_ids if _skin_belongs_to_hero(s, hero_id)]
        if hero_arr:
            other_arr = [s for s in arr_ids if not _skin_belongs_to_hero(s, hero_id)]
            if active_str in hero_arr:
                merged_arr = other_arr + [s for s in target_skin_ids if s not in other_arr]
            else:
                merged_arr = other_arr + [str(dummy_skin_id(int(s))) for s in hero_arr]
            if merged_arr != arr_ids:
                raw = cp.replace_skin_id_array(raw, merged_arr)
                changed = True

        out_raws.append(raw)

    if not changed:
        return xml_text
    sep = "\r\n    " if "\r\n" in xml_text else ("\n    " if "\n" in xml_text else "")
    return hdr + sep.join(out_raws) + ftr


_TRACK_GUID_RE = re.compile(r'(<(?:Track|Event)\b[^>]*?\bguid=")([^"]+)(")', re.IGNORECASE)
_FILTER_ATTR_RE = re.compile(r'\s*\bSkinAvatarFilterType="[^"]*"', re.IGNORECASE)
_SKIN_ID_ARRAY_TAG_RE = re.compile(
    r'<Array\s+name="skinIdArray"[^>]*>.*?</Array>\s*',
    re.DOTALL | re.IGNORECASE,
)


def _clone_track_with_skin_filter(
    raw: str,
    filter_type: str,
    skin_ids: list[str],
    seed_key: str,
) -> str:
    """Nhân bản một `<Track>` kèm GUID mới (`uuid5`) và `SkinAvatarFilterType` chỉ định."""
    idx_counter = [0]

    def _sub_guid(m: re.Match[str]) -> str:
        idx_counter[0] += 1
        new_g = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.{seed_key}.{idx_counter[0]}.{m.group(2)}"))
        return f"{m.group(1)}{new_g}{m.group(3)}"

    cloned = _TRACK_GUID_RE.sub(_sub_guid, raw)
    cloned = _FILTER_ATTR_RE.sub("", cloned)
    return cp.replace_skin_tags(cloned, skin_ids, filter_type=filter_type)


def _merge_exclude_skin_filter(raw: str, exclude_ids: list[str]) -> str:
    """Bổ sung danh sách skin bị loại trừ vào `SkinAvatarFilterType="11"` trên track gốc."""
    sp = cp.split_xml_tracks(raw if "<Project" in raw else f"<Project><Action>{raw}</Action></Project>")
    existing = sp[1][0].get("skins", []) if (sp and sp[1]) else []
    merged = list(existing)
    for sid_s in exclude_ids:
        if sid_s not in merged:
            merged.append(sid_s)
    return cp.replace_skin_tags(raw, merged, filter_type="11")


def _update_check_skin_id_track_selective(
    raw: str,
    hero_id: int,
    ev_type: str,
    arr_ids: list[str],
    dst_to_src: dict[int, int],
) -> str:
    """Cập nhật có chọn lọc `CheckSkinIdTick`/`CheckSkinIdVirtualTick` giữ nguyên mọi skin không bị đè."""
    replaced_set = set(dst_to_src.keys())
    m_sid = _SKIN_ID_PROP_RE.search(raw)
    prop_sid = int(m_sid.group(2)) if m_sid else None
    orig_arr = [int(s) for s in arr_ids if str(s).strip().isdigit()]

    orig_checked_hero: list[int] = []
    if prop_sid is not None and _skin_belongs_to_hero(str(prop_sid), hero_id):
        orig_checked_hero.append(prop_sid)
    for v in orig_arr:
        if _skin_belongs_to_hero(str(v), hero_id) and v not in orig_checked_hero:
            orig_checked_hero.append(v)

    if not orig_checked_hero:
        return raw

    other_arr = [str(v) for v in orig_arr if not _skin_belongs_to_hero(str(v), hero_id)]
    new_hero: list[int] = []
    for v in orig_checked_hero:
        if v not in replaced_set and v not in new_hero:
            new_hero.append(v)
    for dst_sid, active_src in sorted(dst_to_src.items()):
        if active_src in orig_checked_hero and dst_sid not in new_hero:
            new_hero.append(dst_sid)

    if new_hero == orig_checked_hero:
        return raw

    upd = raw
    if not new_hero:
        if prop_sid is not None and _skin_belongs_to_hero(str(prop_sid), hero_id):
            d_val = str(dummy_skin_id(prop_sid))
            upd = _SKIN_ID_PROP_RE.sub(rf"\g<1>{d_val}\g<3>", upd, count=1)
        if _SKIN_ID_ARRAY_BLOCK_RE.search(upd):
            upd = cp.replace_skin_id_array(upd, other_arr)
        return upd

    has_hero_prop = prop_sid is not None and _skin_belongs_to_hero(str(prop_sid), hero_id)
    if len(new_hero) == 1 and has_hero_prop and not orig_arr:
        return _SKIN_ID_PROP_RE.sub(rf"\g<1>{new_hero[0]}\g<3>", upd, count=1)

    # Nếu cần kiểm tra nhiều skin (như 13118 + 13101), nâng CheckSkinIdTick -> CheckSkinIdVirtualTick
    if ev_type == "CheckSkinIdTick":
        upd = re.sub(r'eventType="CheckSkinIdTick"', 'eventType="CheckSkinIdVirtualTick"', upd, count=1)
        upd = re.sub(r'eventName="CheckSkinIdTick"', 'eventName="CheckSkinIdVirtualTick"', upd, count=1)
        if _BEQUAL_FALSE_RE.search(upd):
            upd = _BEQUAL_FALSE_RE.sub(
                '\n        <bool name="useNegateValue" value="true" refParamName="" useRefParam="false" />',
                upd,
                count=1,
            )
        upd = re.sub(r'\s*<bool\s+name="bEqual"\s+value="true"[^/]*/>', "", upd, flags=re.IGNORECASE)

    if has_hero_prop:
        upd = _SKIN_ID_PROP_RE.sub(rf"\g<1>{new_hero[0]}\g<3>", upd, count=1)
        arr_new = [str(x) for x in new_hero[1:]] + other_arr
    else:
        arr_new = [str(x) for x in new_hero] + other_arr

    if _SKIN_ID_ARRAY_BLOCK_RE.search(upd):
        upd = cp.replace_skin_id_array(upd, arr_new)
    elif arr_new:
        multiline = "\n" in upd
        eol = "\r\n        " if "\r\n" in upd else ("\n        " if multiline else "")
        inner_eol = "\r\n          " if "\r\n" in upd else ("\n          " if multiline else "")
        items_xml = inner_eol.join(f'<int value="{s}" />' for s in arr_new)
        arr_block = (
            f'{eol}<Array name="skinIdArray" refParamName="" useRefParam="false" type="int">'
            f'{inner_eol}{items_xml}{eol}</Array>'
        )
        ev_end = upd.rfind("</Event>")
        if ev_end >= 0:
            ls = upd.rfind("\n", 0, ev_end)
            prefix_indent = upd[ls + 1 : ev_end] if ls >= 0 else ""
            upd = upd[:ev_end] + arr_block.lstrip("\r\n") + ("\r\n" if "\r\n" in upd else "\n") + prefix_indent + upd[ev_end:]
    return upd


def _update_skin_filter_list_selective(
    raw: str,
    hero_id: int,
    ev_type: str,
    flt: str | None,
    skins: list[str],
    arr_ids: list[str],
    dst_to_src: dict[int, int],
) -> tuple[str, bool]:
    """Cập nhật `SkinOrAvatarList` & `skinIdArray` cho chế độ đè chọn lọc, trả `(updated_raw, changed)`."""
    replaced_set = set(dst_to_src.keys())
    changed = False
    hero_skins = [s for s in skins if _skin_belongs_to_hero(s, hero_id)]
    if hero_skins:
        other_skins = [s for s in skins if not _skin_belongs_to_hero(s, hero_id)]
        kept_hero = [s for s in hero_skins if int(s) not in replaced_set]
        added_hero = [str(dst) for dst, src in sorted(dst_to_src.items()) if str(src) in hero_skins]
        merged_hero = kept_hero + [s for s in added_hero if s not in kept_hero]
        final_skins = other_skins + merged_hero
        if flt == "9" and not final_skins:
            final_skins = [str(dummy_skin_id(int(s))) for s in hero_skins]
        if final_skins != skins:
            raw = cp.replace_skin_tags(raw, final_skins)
            changed = True

    if arr_ids and "CheckSkinId" not in ev_type:
        hero_arr = [s for s in arr_ids if _skin_belongs_to_hero(s, hero_id)]
        if hero_arr:
            other_arr = [s for s in arr_ids if not _skin_belongs_to_hero(s, hero_id)]
            kept_arr = [s for s in hero_arr if int(s) not in replaced_set]
            added_arr = [str(dst) for dst, src in sorted(dst_to_src.items()) if str(src) in hero_arr]
            merged_arr = kept_arr + [s for s in added_arr if s not in kept_arr]
            final_arr = other_arr + merged_arr
            if final_arr != arr_ids:
                raw = cp.replace_skin_id_array(raw, final_arr)
                changed = True
    return raw, changed


def _transform_action_xml_selective(
    xml_text: str,
    hero_id: int,
    dst_to_src: dict[int, int],
    senior_map: dict[int, bytes],
    rewrite_effects: bool = True,
    sound_by_dst: dict[int, int] | None = None,
    sound_skins_set: set[int] | None = None,
    enable_sound: bool = False,
    action_filename: str = "",
    rpack_hashes: set[tuple[int, int]] | None = None,
) -> str:
    """Biến đổi XML kỹ năng trong `Actor_<H>_Actions.pkg.bytes` cho chế độ đè chọn lọc từng skin."""
    sp_res = cp.split_xml_tracks(xml_text)
    if not sp_res or not sp_res[1]:
        return xml_text
    hdr, tracks, ftr = sp_res
    base_skin_id = hero_id * 100
    sound_map = sound_by_dst or {}
    snd_set = sound_skins_set or set()
    active_src_set = set(dst_to_src.values())

    # Nhận diện các track CheckSkinId (bằng cả id và guid) cùng cực tính (dương tính hay phủ định)
    check_skin_info: dict[str, tuple[list[int], bool]] = {}
    for t_idx, trk in enumerate(tracks):
        ev_t = trk.get("eventType") or ""
        if "CheckSkinId" in ev_t:
            raw_t = trk["raw"]
            m_sid = _SKIN_ID_PROP_RE.search(raw_t)
            checked_sids: list[int] = []
            if m_sid and _skin_belongs_to_hero(m_sid.group(2), hero_id):
                checked_sids.append(int(m_sid.group(2)))
            for s in trk.get("skinArrayIds") or []:
                if _skin_belongs_to_hero(str(s), hero_id) and int(s) not in checked_sids:
                    checked_sids.append(int(s))
            has_beq_false = bool(_BEQUAL_FALSE_RE.search(raw_t))
            has_neg_true = bool(_NEGATE_PROP_RE.search(raw_t))
            is_neg = has_beq_false if ev_t == "CheckSkinIdTick" else (has_neg_true or has_beq_false)
            check_skin_info[str(t_idx)] = (checked_sids, is_neg)
            if trk.get("guid"):
                check_skin_info[str(trk["guid"])] = (checked_sids, is_neg)

    # Lan truyền điều kiện CheckSkinId qua các track điều kiện trung gian (VD: CheckRandomRangeTick trong U1.xml)
    for t_idx, trk in enumerate(tracks):
        ev_t = trk.get("eventType") or ""
        if "CheckSkinId" in ev_t or "resourceName" in trk["raw"] or ev_t == "PlayHeroSoundTick":
            continue
        for m_c in re.finditer(r'<Condition\b[^>]*>', trk["raw"], re.IGNORECASE):
            tag = m_c.group(0)
            mid = re.search(r'\bid="([^"]+)"', tag)
            mguid = re.search(r'\bguid="([^"]+)"', tag)
            mstat = re.search(r'\bstatus="([^"]+)"', tag, re.IGNORECASE)
            cond_false = bool(mstat and mstat.group(1).lower() == "false")
            ref_info = None
            if mid and mid.group(1) in check_skin_info:
                ref_info = check_skin_info[mid.group(1)]
            elif mguid and mguid.group(1) in check_skin_info:
                ref_info = check_skin_info[mguid.group(1)]
            if ref_info:
                sids, is_neg = ref_info
                eff_neg = (not is_neg) if cond_false else is_neg
                check_skin_info[str(t_idx)] = (sids, eff_neg)
                if trk.get("guid"):
                    check_skin_info[str(trk["guid"])] = (sids, eff_neg)
                break

    def _classify_skin_conditions(raw_t: str) -> tuple[list[int], set[int]]:
        pos_sids: list[int] = []
        neg_sids: set[int] = set()
        for m_c in re.finditer(r'<Condition\b[^>]*>', raw_t, re.IGNORECASE):
            tag = m_c.group(0)
            mid = re.search(r'\bid="([^"]+)"', tag)
            mguid = re.search(r'\bguid="([^"]+)"', tag)
            mstat = re.search(r'\bstatus="([^"]+)"', tag, re.IGNORECASE)
            cond_false = bool(mstat and mstat.group(1).lower() == "false")
            ref_info = None
            if mid and mid.group(1) in check_skin_info:
                ref_info = check_skin_info[mid.group(1)]
            elif mguid and mguid.group(1) in check_skin_info:
                ref_info = check_skin_info[mguid.group(1)]
            if ref_info:
                sids, is_neg = ref_info
                eff_neg = (not is_neg) if cond_false else is_neg
                if eff_neg:
                    neg_sids.update(sids)
                else:
                    for s in sids:
                        if s not in pos_sids:
                            pos_sids.append(s)
        return pos_sids, neg_sids

    def _sound_idx_for(sid: int) -> int:
        if hero_id * 100 < sid < (hero_id + 1) * 100:
            return sid - hero_id * 100
        if hero_id * 10000 < sid < (hero_id + 1) * 10000:
            return (sid - hero_id * 10000) // 100
        return 0

    skip_sound_suffix = False
    if action_filename:
        base_fn = os.path.basename(action_filename.replace("\\", "/"))
        m_pref = re.match(r"^(\d+)_", base_fn)
        if m_pref and _skin_belongs_to_hero(m_pref.group(1), hero_id):
            file_sid = int(m_pref.group(1))
            if file_sid != base_skin_id:
                skip_sound_suffix = True

    out_raws: list[str] = []
    extra_tracks: list[str] = []
    changed = False

    for t_idx, trk in enumerate(tracks):
        raw = trk["raw"]
        ev_type = trk.get("eventType") or ""
        flt = trk.get("filterType")
        skins = trk.get("skins") or []
        arr_ids = trk.get("skinArrayIds") or []
        orig_hero_skins = [int(s) for s in skins if _skin_belongs_to_hero(s, hero_id)]

        if "CheckSkinId" in ev_type:
            upd_chk = _update_check_skin_id_track_selective(raw, hero_id, ev_type, arr_ids, dst_to_src)
            if upd_chk != raw:
                raw = upd_chk
                changed = True

        upd_flt, flt_changed = _update_skin_filter_list_selective(
            raw, hero_id, ev_type, flt, skins, arr_ids, dst_to_src
        )
        if flt_changed:
            raw = upd_flt
            changed = True

        pos_cond_sids, neg_cond_sids = _classify_skin_conditions(raw)
        sp_cur = cp.split_xml_tracks(f"<Project><Action>{raw}</Action></Project>")
        cur_skins = sp_cur[1][0].get("skins", []) if (sp_cur and sp_cur[1]) else skins
        cur_flt = sp_cur[1][0].get("filterType") if (sp_cur and sp_cur[1]) else flt

        # Nhánh 1: Track đã gắn riêng cho 1 skin dương tính (qua Condition(CheckSkinId==S) hoặc flt=="9" 1 skin)
        if rewrite_effects and "CheckSkinId" not in ev_type and "resourceName" in raw:
            dedicated_sid: int | None = None
            if len(pos_cond_sids) == 1:
                dedicated_sid = pos_cond_sids[0]
            elif flt == "9" and len(orig_hero_skins) == 1:
                dedicated_sid = orig_hero_skins[0]
            if dedicated_sid is not None and dedicated_sid in active_src_set and dedicated_sid != base_skin_id:
                is_hd_ded = dedicated_sid in senior_map

                def _sub_res_ded(m: re.Match[str]) -> str:
                    old_p = m.group(2)
                    if not old_p:
                        return m.group(0)
                    new_p = jtcom.rewrite_hero_effect_path(
                        old_p, hero_id, dedicated_sid, is_hd_ded, rpack_hashes=rpack_hashes
                    )
                    return f"{m.group(1)}{new_p}{m.group(3)}"

                new_ded_raw = _RESOURCE_NAME_RE.sub(_sub_res_ded, raw)
                if new_ded_raw != raw:
                    raw = new_ded_raw
                    changed = True
                if 'bAllowEmptyEffect" value="true"' in raw:
                    raw = raw.replace('bAllowEmptyEffect" value="true"', 'bAllowEmptyEffect" value="false"')
                    changed = True

        # Nhánh 2: Các track TriggerParticle/resourceName chung (không có Condition dương tính, có thể có Condition phủ định != S)
        if (
            rewrite_effects
            and "CheckSkinId" not in ev_type
            and "resourceName" in raw
            and not pos_cond_sids
            and cur_flt in (None, "11")
        ):
            excluded_already = (set(cur_skins) if cur_flt == "11" else set()) | {str(s) for s in neg_cond_sids}
            by_new_raw: dict[str, list[str]] = {}
            for dst_sid, active_src in sorted(dst_to_src.items()):
                dst_s = str(dst_sid)
                if dst_s in excluded_already or active_src == base_skin_id or active_src in neg_cond_sids:
                    continue
                is_hd_s = active_src in senior_map

                def _sub_res_sel(m: re.Match[str]) -> str:
                    old_p = m.group(2)
                    if not old_p:
                        return m.group(0)
                    new_p = jtcom.rewrite_hero_effect_path(
                        old_p, hero_id, active_src, is_hd_s, rpack_hashes=rpack_hashes
                    )
                    return f"{m.group(1)}{new_p}{m.group(3)}"

                cand_raw = _RESOURCE_NAME_RE.sub(_sub_res_sel, raw)
                if cand_raw != raw:
                    if 'bAllowEmptyEffect" value="true"' in cand_raw:
                        cand_raw = cand_raw.replace('bAllowEmptyEffect" value="true"', 'bAllowEmptyEffect" value="false"')
                    by_new_raw.setdefault(cand_raw, []).append(dst_s)

            if by_new_raw:
                all_branch_dsts = [s for grp in by_new_raw.values() for s in grp]
                raw = _merge_exclude_skin_filter(raw, all_branch_dsts)
                for b_idx, (cand_raw, dst_strs) in enumerate(by_new_raw.items()):
                    clone = _clone_track_with_skin_filter(
                        cand_raw, "9", dst_strs, f"{action_filename}.fx.{t_idx}.{b_idx}"
                    )
                    extra_tracks.append(clone)
                changed = True

        # Âm thanh Wwise trên PlayHeroSoundTick chung
        if (
            enable_sound
            and not skip_sound_suffix
            and ev_type == "PlayHeroSoundTick"
            and not pos_cond_sids
            and cur_flt in (None, "11")
        ):
            excluded_already = (set(cur_skins) if cur_flt == "11" else set()) | {str(s) for s in neg_cond_sids}
            by_snd_idx: dict[int, list[str]] = {}
            for dst_sid in sorted(dst_to_src.keys()):
                dst_s = str(dst_sid)
                if dst_s in excluded_already:
                    continue
                s_src = sound_map.get(dst_sid, dst_to_src[dst_sid])
                if s_src not in snd_set or s_src in neg_cond_sids:
                    continue
                s_idx = _sound_idx_for(s_src)
                if s_idx > 0:
                    by_snd_idx.setdefault(s_idx, []).append(dst_s)

            if by_snd_idx:
                all_snd_dsts = [s for grp in by_snd_idx.values() for s in grp]
                raw = _merge_exclude_skin_filter(raw, all_snd_dsts)
                for s_idx, dst_strs in sorted(by_snd_idx.items()):
                    def _sub_ev_sel(m: re.Match[str], si: int = s_idx) -> str:
                        ev = m.group(2)
                        if not ev or "_Skin" in ev or not (ev.startswith("Play_") or ev.startswith("Stop_")):
                            return m.group(0)
                        if ev.startswith(_GENERIC_SOUND_EVENT_PREFIXES):
                            return m.group(0)
                        return f"{m.group(1)}{ev}_Skin{si}{m.group(3)}"

                    snd_raw = _EXTRA_SKIN_ARRAY_RE.sub("", raw)
                    snd_raw = _EVENT_NAME_RE.sub(_sub_ev_sel, snd_raw)
                    if snd_raw != raw:
                        clone = _clone_track_with_skin_filter(
                            snd_raw, "9", dst_strs, f"{action_filename}.snd.{t_idx}.{s_idx}"
                        )
                        extra_tracks.append(clone)
                changed = True

        out_raws.append(raw)

    if not changed:
        return xml_text
    sep = "\r\n    " if "\r\n" in xml_text else ("\n    " if "\n" in xml_text else "")
    return hdr + sep.join(out_raws + extra_tracks) + ftr


def _transform_common_action_xml_selective(
    xml_text: str,
    hero_id: int,
    dst_to_src: dict[int, int],
) -> str:
    """Biến đổi `CommonActions` (`Back.xml`, `Born.xml`, `HasteE1.xml`, ...) giữ nguyên skin khác của tướng & mọi tướng khác."""
    sp_res = cp.split_xml_tracks(xml_text)
    if not sp_res or not sp_res[1]:
        return xml_text
    hdr, tracks, ftr = sp_res
    changed = False
    out_raws: list[str] = []

    for trk in tracks:
        raw = trk["raw"]
        ev_type = trk.get("eventType") or ""
        flt = trk.get("filterType")
        skins = trk.get("skins") or []
        arr_ids = trk.get("skinArrayIds") or []

        if "CheckSkinId" in ev_type:
            upd_chk = _update_check_skin_id_track_selective(raw, hero_id, ev_type, arr_ids, dst_to_src)
            if upd_chk != raw:
                raw = upd_chk
                changed = True

        upd_flt, flt_changed = _update_skin_filter_list_selective(
            raw, hero_id, ev_type, flt, skins, arr_ids, dst_to_src
        )
        if flt_changed:
            raw = upd_flt
            changed = True

        out_raws.append(raw)

    if not changed:
        return xml_text
    sep = "\r\n    " if "\r\n" in xml_text else ("\n    " if "\n" in xml_text else "")
    return hdr + sep.join(out_raws) + ftr


def _apply_recall_back_xml_selective(
    xml_text: str,
    hero_id: int,
    hero_code: str,
    recall_by_dst: dict[int, int],
    senior_map: dict[int, bytes],
    hs_map: dict[int, bytes],
    exclusive_cfg: dict[int, dict[str, str]],
    rpack_hashes: set[tuple[int, int]] | None = None,
) -> str:
    """Chèn hiệu ứng biến về riêng & ẩn vòng xanh mặc định đúng cho các `dst_sid` được chọn."""
    orig_sp = cp.split_xml_tracks(xml_text)
    orig_tracks = orig_sp[1] if orig_sp else []
    upd = _transform_common_action_xml_selective(xml_text, hero_id, recall_by_dst)

    custom_groups: dict[int, list[str]] = {}
    for dst_sid, r_src in sorted(recall_by_dst.items()):
        if r_src in hs_map and b"Skin_Icon_BackToTown" in hs_map[r_src]:
            custom_groups.setdefault(r_src, []).append(str(dst_sid))
    if not custom_groups:
        return upd

    sp_res = cp.split_xml_tracks(upd)
    if not sp_res or not sp_res[1]:
        return upd
    hdr, tracks, ftr = sp_res
    eol = "\r\n" if "\r\n" in upd else "\n"
    changed = upd != xml_text
    all_custom_dsts = [s for grp in custom_groups.values() for s in grp]
    replaced_strs = {str(d) for d in recall_by_dst.keys()}
    out_raws: list[str] = []

    for t in tracks:
        raw = t["raw"]
        ev_type = t.get("eventType") or ""
        flt = t.get("filterType")
        is_holiday = ev_type == "GetHolidayResourcePathTick" and flt in (None, "11")
        is_default_ring = (
            ev_type in ("TriggerParticle", "TriggerParticleTick")
            and flt == "11"
            and ("born_back_reborn/huijidi_01" in raw or "born_back_reborn/huicheng_tongyong_01" in raw)
        )
        if is_holiday or is_default_ring:
            skins = t.get("skins") or []
            kept = [s for s in skins if s not in replaced_strs]
            merged_skins = kept + [s for s in all_custom_dsts if s not in kept]
            if merged_skins != skins or flt != "11":
                raw = cp.replace_skin_tags(raw, merged_skins, filter_type="11")
                changed = True
        out_raws.append(raw)

    for r_src, dst_strs in sorted(custom_groups.items()):
        r_str = str(r_src)
        has_custom_particle = any(
            t.get("filterType") == "9"
            and t.get("eventType") in ("TriggerParticle", "TriggerParticleTick")
            and r_str in (t.get("skins") or [])
            for t in orig_tracks
        )
        if has_custom_particle:
            continue
        is_r_hd = r_src in senior_map
        fall_res = jtcom.rewrite_hero_effect_path(
            f"prefab_skill_effects/hero_skill_effects/{hero_code}/huijidi_01",
            hero_id,
            r_src,
            is_r_hd,
            rpack_hashes=rpack_hashes,
        )
        loop_res = jtcom.rewrite_hero_effect_path(
            f"prefab_skill_effects/hero_skill_effects/{hero_code}/huicheng_tongyong_01",
            hero_id,
            r_src,
            is_r_hd,
            rpack_hashes=rpack_hashes,
        )
        offset_str = (exclusive_cfg.get(r_src) or {}).get("recall_offset", "")
        bind_attrs = _format_vec3_attrs(offset_str, (0.0, -0.3, 0.0))
        skin_tags = "".join(f'<SkinOrAvatarList id="{s}" />' for s in dst_strs)
        tg1 = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.back.{r_src}.{','.join(dst_strs)}.tick.track"))
        eg1 = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.back.{r_src}.{','.join(dst_strs)}.tick.event"))
        tg2 = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.back.{r_src}.{','.join(dst_strs)}.dur.track"))
        eg2 = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.back.{r_src}.{','.join(dst_strs)}.dur.event"))
        trk_tick = (
            f'<Track trackName="Totorox_BackTick_{r_src}" eventType="TriggerParticleTick" '
            f'guid="{tg1}" enabled="true" useRefParam="false" refParamName="" r="0.000" g="0.000" b="0.000" '
            f'execOnForceStopped="false" execOnActionCompleted="false" stopAfterLastEvent="true" SkinAvatarFilterType="9">'
            f'<Event eventName="TriggerParticleTick" time="7.000" isDuration="false" guid="{eg1}">'
            f'<TemplateObject name="targetId" objectName="None" id="-1" isTemp="false" refParamName="" useRefParam="false" />'
            f'<TemplateObject name="objectSpaceId" objectName="self" id="0" isTemp="false" refParamName="" useRefParam="false" />'
            f'<String name="resourceName" value="{fall_res}" refParamName="" useRefParam="false" />'
            f'<Vector3 name="bindPosOffset" {bind_attrs} refParamName="" useRefParam="false" />'
            f'<float name="lifeTime" value="5.000" refParamName="" useRefParam="false" />'
            f'<Vector3i name="scalingInt" x="10000" y="10000" z="10000" refParamName="" useRefParam="false" />'
            f'<bool name="bUseHeroLocalForward" value="true" refParamName="" useRefParam="false" />'
            f'</Event>{skin_tags}</Track>'
        )
        trk_dur = (
            f'<Track trackName="Totorox_BackLoop_{r_src}" eventType="TriggerParticle" '
            f'guid="{tg2}" enabled="true" useRefParam="false" refParamName="" r="0.000" g="0.000" b="0.000" '
            f'execOnForceStopped="false" execOnActionCompleted="false" stopAfterLastEvent="true" SkinAvatarFilterType="9">'
            f'<Event eventName="TriggerParticle" time="0.000" length="7.000" isDuration="true" guid="{eg2}">'
            f'<TemplateObject name="targetId" objectName="self" id="0" isTemp="false" refParamName="" useRefParam="false" />'
            f'<TemplateObject name="objectSpaceId" objectName="self" id="0" isTemp="false" refParamName="" useRefParam="false" />'
            f'<String name="resourceName" value="{loop_res}" refParamName="" useRefParam="false" />'
            f'<Vector3 name="bindPosOffset" {bind_attrs} refParamName="" useRefParam="false" />'
            f'<Vector3i name="scalingInt" x="10000" y="10000" z="10000" refParamName="" useRefParam="false" />'
            f'<bool name="bEnableOptCull" value="false" refParamName="" useRefParam="false" />'
            f'<bool name="bTrailProtect" value="true" refParamName="" useRefParam="false" />'
            f'<String name="syncAnimationName" value="" refParamName="" useRefParam="false" />'
            f'<bool name="bApplySpecialEffect" value="true" refParamName="" useRefParam="false" />'
            f'<bool name="bOnlySetAlpha" value="true" refParamName="" useRefParam="false" />'
            f'<String name="customTagName" value="" refParamName="" useRefParam="false" />'
            f'</Event>{skin_tags}</Track>'
        )
        out_raws.extend([trk_tick, trk_dur])
        changed = True

    if not changed:
        return xml_text
    return hdr + f"{eol}    ".join(out_raws) + ftr


def _resolve_default_sprint_track_targets(tracks: list[dict[str, Any]]) -> list[tuple[int, str]]:
    """Tìm tối đa 2 track `jiasu_tongyong_01` mặc định (không trùng ID) cho `StopTracks` trong `HasteE1*.xml`."""
    fallback_targets = [
        (8, "412ea073-5944-46e4-ae5e-3037e855fda7"),
        (9, "aecced31-0011-43e4-a7f2-14f999d326b3"),
    ]
    resolved: list[tuple[int, str]] = []
    seen_ids: set[int] = set()
    for t in tracks:
        if (
            t.get("eventType") == "TriggerParticle"
            and t.get("filterType") is None
            and "jiasu_tongyong_01" in t["raw"].lower()
            and t.get("guid")
        ):
            tid = int(t["orig"])
            if tid not in seen_ids:
                seen_ids.add(tid)
                resolved.append((tid, str(t["guid"])))
                if len(resolved) >= 2:
                    break
    for fb_id, fb_guid in fallback_targets:
        if len(resolved) >= 2:
            break
        if fb_id not in seen_ids:
            seen_ids.add(fb_id)
            resolved.append((fb_id, fb_guid))
    return resolved


def _apply_sprint_haste_xml_selective(
    xml_text: str,
    hero_id: int,
    hero_code: str,
    born_by_dst: dict[int, int],
    senior_map: dict[int, bytes],
    exclusive_cfg: dict[int, dict[str, str]],
) -> str:
    """Chèn hiệu ứng gia tốc tế đàn riêng vào `HasteE1*.xml` đúng cho từng `dst_sid` được chọn."""
    orig_sp = cp.split_xml_tracks(xml_text)
    orig_tracks = orig_sp[1] if orig_sp else []
    upd = _transform_common_action_xml_selective(xml_text, hero_id, born_by_dst)

    born_groups: dict[int, list[str]] = {}
    for dst_sid, b_src in sorted(born_by_dst.items()):
        born_groups.setdefault(b_src, []).append(str(dst_sid))

    sp_res = cp.split_xml_tracks(upd)
    if not sp_res or not sp_res[1]:
        return upd
    hdr, tracks, ftr = sp_res
    eol = "\r\n" if "\r\n" in upd else "\n"
    out_raws = [t["raw"] for t in tracks]
    changed = upd != xml_text

    resolved_targets = _resolve_default_sprint_track_targets(tracks)
    trk_objs = "".join(f'<TrackObject id="{tid}" guid="{tguid}" />' for tid, tguid in resolved_targets)

    for b_src, dst_strs in sorted(born_groups.items()):
        b_str = str(b_src)
        has_custom_haste = any(
            t.get("filterType") == "9"
            and t.get("eventType") == "TriggerParticle"
            and b_str in (t.get("skins") or [])
            for t in orig_tracks
        )
        cfg = exclusive_cfg.get(b_src)
        if not cfg or has_custom_haste:
            continue
        custom_effects = [
            p.strip()
            for p in (cfg.get("sprint_effects") or "").split(",")
            if p.strip() and p.strip().lower() != "jiasu_tongyong_01"
        ]
        if not custom_effects:
            continue
        is_b_hd = b_src in senior_map
        bind_attrs = _format_vec3_attrs(cfg.get("sprint_offset", ""), (0.0, 0.7, -0.6))
        skin_tags = "".join(f'<SkinOrAvatarList id="{s}" />' for s in dst_strs)
        key_s = ",".join(dst_strs)
        for idx, eff_name in enumerate(custom_effects):
            res_path = jtcom.rewrite_hero_effect_path(
                f"prefab_skill_effects/hero_skill_effects/{hero_code}/{eff_name}",
                hero_id,
                b_src,
                is_b_hd,
            )
            tg = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.haste.{b_src}.{key_s}.{idx}.track"))
            eg = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.haste.{b_src}.{key_s}.{idx}.event"))
            trk_p = (
                f'<Track trackName="Totorox_Sprint_{b_src}_{idx}" eventType="TriggerParticle" '
                f'guid="{tg}" enabled="true" useRefParam="false" refParamName="" r="0.000" g="0.000" b="0.000" '
                f'execOnForceStopped="false" execOnActionCompleted="false" stopAfterLastEvent="true" SkinAvatarFilterType="9">'
                f'<Event eventName="TriggerParticle" time="0.000" length="5.000" isDuration="true" guid="{eg}">'
                f'<TemplateObject name="targetId" objectName="target" id="1" isTemp="false" refParamName="" useRefParam="false" />'
                f'<TemplateObject name="objectSpaceId" objectName="target" id="1" isTemp="false" refParamName="" useRefParam="false" />'
                f'<String name="resourceName" value="{res_path}" refParamName="" useRefParam="false" />'
                f'<Vector3 name="bindPosOffset" {bind_attrs} refParamName="" useRefParam="false" />'
                f'<Vector3i name="scalingInt" x="10000" y="10000" z="10000" refParamName="" useRefParam="false" />'
                f'<String name="syncAnimationName" value="" refParamName="" useRefParam="false" />'
                f'<String name="customTagName" value="" refParamName="" useRefParam="false" />'
                f'</Event>{skin_tags}</Track>'
            )
            out_raws.append(trk_p)
        st_tg = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.haste.{b_src}.{key_s}.stop.track"))
        st_eg = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.sel.haste.{b_src}.{key_s}.stop.event"))
        trk_stop = (
            f'<Track trackName="Totorox_StopDefaultSprint_{b_src}" eventType="StopTracks" '
            f'guid="{st_tg}" enabled="true" useRefParam="false" refParamName="" r="0.000" g="0.000" b="0.000" '
            f'execOnForceStopped="false" execOnActionCompleted="false" SkinAvatarFilterType="9">'
            f'<Event eventName="StopTracks" time="0.000" isDuration="false" guid="{st_eg}">'
            f'<Array name="trackIds" refParamName="" useRefParam="false" type="TrackObject">{trk_objs}</Array>'
            f'<bool name="alsoStopNotStartedTrack" value="true" refParamName="" useRefParam="false" />'
            f'</Event>{skin_tags}</Track>'
        )
        out_raws.append(trk_stop)
        changed = True

    if not changed:
        return xml_text
    return hdr + f"{eol}    ".join(out_raws) + ftr


def _parse_exclusive_battle_effects(provider: BaseResourceProvider) -> dict[int, dict[str, str]]:
    """Đọc `Databin/Client/Huanhua/ResSkinExclusiveBattleEffectCfg.bytes` (offset biến đổi từ byte 23)."""
    rel = "Databin/Client/Huanhua/ResSkinExclusiveBattleEffectCfg.bytes"
    if not provider.has(rel):
        return {}
    tbl = cp.parse_mses(cp.pg_decrypt(provider.read(rel), "ResSkinExclusiveBattleEffectCfg"))
    if not tbl:
        return {}
    out: dict[int, dict[str, str]] = {}
    for rid, rraw in tbl["recs"]:
        pos = 23
        if pos + 4 > len(rraw):
            continue
        l1 = struct.unpack_from("<I", rraw, pos)[0]
        if l1 < 1 or pos + 4 + l1 > len(rraw):
            continue
        recall_offset = rraw[pos + 4 : pos + 4 + l1 - 1].decode("utf-8", errors="ignore").strip()
        pos += 4 + l1 + 8
        if pos + 4 > len(rraw):
            continue
        l2 = struct.unpack_from("<I", rraw, pos)[0]
        if l2 < 1 or pos + 4 + l2 > len(rraw):
            continue
        sprint_effects = rraw[pos + 4 : pos + 4 + l2 - 1].decode("utf-8", errors="ignore").strip()
        pos += 4 + l2
        if pos + 4 > len(rraw):
            continue
        l3 = struct.unpack_from("<I", rraw, pos)[0]
        if l3 < 1 or pos + 4 + l3 > len(rraw):
            continue
        sprint_offset = rraw[pos + 4 : pos + 4 + l3 - 1].decode("utf-8", errors="ignore").strip()
        pos += 4 + l3
        sprint_tag = ""
        if pos + 4 <= len(rraw):
            l4 = struct.unpack_from("<I", rraw, pos)[0]
            if l4 >= 1 and pos + 4 + l4 <= len(rraw):
                sprint_tag = rraw[pos + 4 : pos + 4 + l4 - 1].decode("utf-8", errors="ignore").strip()
        out[int(rid)] = {
            "recall_offset": recall_offset,
            "sprint_effects": sprint_effects,
            "sprint_offset": sprint_offset,
            "sprint_tag": sprint_tag,
        }
    return out


def _format_vec3_attrs(vec_str: str, default: tuple[float, float, float]) -> str:
    parts = [p.strip() for p in (vec_str or "").split(",") if p.strip()]
    if len(parts) == 3:
        try:
            x, y, z = float(parts[0]), float(parts[1]), float(parts[2])
            return f'x="{x:.3f}" y="{y:.3f}" z="{z:.3f}"'
        except ValueError:
            pass
    dx, dy, dz = default
    return f'x="{dx:.3f}" y="{dy:.3f}" z="{dz:.3f}"'


def _apply_recall_back_xml(
    xml_text: str,
    hero_id: int,
    hero_code: str,
    recall_skin_id: int,
    is_recall_hd: bool,
    target_skin_ids: list[str],
    recall_has_custom_icon: bool,
    exclusive_cfg: dict[int, dict[str, str]],
    rpack_hashes: set[tuple[int, int]] | None = None,
) -> str:
    """
    R1.2: Biến đổi `commonresource/Back.xml`:
      - Luôn chạy `_transform_common_action_xml` để mở rộng track có sẵn của `recall_skin_id`.
      - Nếu skin có hiệu ứng biến về riêng (`Skin_Icon_BackToTown`):
        (a) Thêm `target_skin_ids` với `SkinAvatarFilterType="11"` vào các track vòng xanh mặc định
            (`GetHolidayResourcePathTick` hoặc `flt=11` `born_back_reborn/huijidi_01` / `huicheng_tongyong_01`).
        (b) Nếu `Back.xml` gốc chưa có track `TriggerParticle`/`TriggerParticleTick` `flt=9` của `recall_skin_id`,
            nối thêm 2 track chuẩn UUID (`uuid.uuid5`) trỏ tới `huijidi_01` & `huicheng_tongyong_01`.
    """
    orig_sp = cp.split_xml_tracks(xml_text)
    orig_tracks = orig_sp[1] if orig_sp else []
    recall_str = str(recall_skin_id)
    has_custom_particle = any(
        t.get("filterType") == "9"
        and t.get("eventType") in ("TriggerParticle", "TriggerParticleTick")
        and recall_str in (t.get("skins") or [])
        for t in orig_tracks
    )

    upd = _transform_common_action_xml(xml_text, hero_id, recall_skin_id, target_skin_ids)
    if not recall_has_custom_icon:
        return upd

    sp_res = cp.split_xml_tracks(upd)
    if not sp_res or not sp_res[1]:
        return upd
    hdr, tracks, ftr = sp_res
    eol = "\r\n" if "\r\n" in upd else "\n"
    changed = upd != xml_text
    out_raws: list[str] = []

    for t in tracks:
        raw = t["raw"]
        ev_type = t.get("eventType") or ""
        flt = t.get("filterType")
        is_holiday = ev_type == "GetHolidayResourcePathTick" and flt in (None, "11")
        is_default_ring = (
            ev_type in ("TriggerParticle", "TriggerParticleTick")
            and flt == "11"
            and ("born_back_reborn/huijidi_01" in raw or "born_back_reborn/huicheng_tongyong_01" in raw)
        )
        if is_holiday or is_default_ring:
            skins = t.get("skins") or []
            other_skins = [s for s in skins if not _skin_belongs_to_hero(s, hero_id)]
            merged_skins = other_skins + [s for s in target_skin_ids if s not in other_skins]
            new_raw = cp.replace_skin_tags(raw, merged_skins, filter_type="11")
            if new_raw != raw:
                raw = new_raw
                changed = True
        out_raws.append(raw)

    if not has_custom_particle:
        fall_res = jtcom.rewrite_hero_effect_path(
            f"prefab_skill_effects/hero_skill_effects/{hero_code}/huijidi_01",
            hero_id,
            recall_skin_id,
            is_recall_hd,
            rpack_hashes=rpack_hashes,
        )
        loop_res = jtcom.rewrite_hero_effect_path(
            f"prefab_skill_effects/hero_skill_effects/{hero_code}/huicheng_tongyong_01",
            hero_id,
            recall_skin_id,
            is_recall_hd,
            rpack_hashes=rpack_hashes,
        )
        offset_str = (exclusive_cfg.get(recall_skin_id) or {}).get("recall_offset", "")
        bind_attrs = _format_vec3_attrs(offset_str, (0.0, -0.3, 0.0))
        skin_tags = "".join(f'<SkinOrAvatarList id="{s}" />' for s in target_skin_ids)

        tg1 = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.back.{recall_skin_id}.tick.track"))
        eg1 = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.back.{recall_skin_id}.tick.event"))
        tg2 = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.back.{recall_skin_id}.dur.track"))
        eg2 = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.back.{recall_skin_id}.dur.event"))

        trk_tick = (
            f'<Track trackName="Totorox_BackTick_{recall_skin_id}" eventType="TriggerParticleTick" '
            f'guid="{tg1}" enabled="true" useRefParam="false" refParamName="" r="0.000" g="0.000" b="0.000" '
            f'execOnForceStopped="false" execOnActionCompleted="false" stopAfterLastEvent="true" SkinAvatarFilterType="9">'
            f'<Event eventName="TriggerParticleTick" time="7.000" isDuration="false" guid="{eg1}">'
            f'<TemplateObject name="targetId" objectName="None" id="-1" isTemp="false" refParamName="" useRefParam="false" />'
            f'<TemplateObject name="objectSpaceId" objectName="self" id="0" isTemp="false" refParamName="" useRefParam="false" />'
            f'<String name="resourceName" value="{fall_res}" refParamName="" useRefParam="false" />'
            f'<Vector3 name="bindPosOffset" {bind_attrs} refParamName="" useRefParam="false" />'
            f'<float name="lifeTime" value="5.000" refParamName="" useRefParam="false" />'
            f'<Vector3i name="scalingInt" x="10000" y="10000" z="10000" refParamName="" useRefParam="false" />'
            f'<bool name="bUseHeroLocalForward" value="true" refParamName="" useRefParam="false" />'
            f'</Event>{skin_tags}</Track>'
        )
        trk_dur = (
            f'<Track trackName="Totorox_BackLoop_{recall_skin_id}" eventType="TriggerParticle" '
            f'guid="{tg2}" enabled="true" useRefParam="false" refParamName="" r="0.000" g="0.000" b="0.000" '
            f'execOnForceStopped="false" execOnActionCompleted="false" stopAfterLastEvent="true" SkinAvatarFilterType="9">'
            f'<Event eventName="TriggerParticle" time="0.000" length="7.000" isDuration="true" guid="{eg2}">'
            f'<TemplateObject name="targetId" objectName="self" id="0" isTemp="false" refParamName="" useRefParam="false" />'
            f'<TemplateObject name="objectSpaceId" objectName="self" id="0" isTemp="false" refParamName="" useRefParam="false" />'
            f'<String name="resourceName" value="{loop_res}" refParamName="" useRefParam="false" />'
            f'<Vector3 name="bindPosOffset" {bind_attrs} refParamName="" useRefParam="false" />'
            f'<Vector3i name="scalingInt" x="10000" y="10000" z="10000" refParamName="" useRefParam="false" />'
            f'<bool name="bEnableOptCull" value="false" refParamName="" useRefParam="false" />'
            f'<bool name="bTrailProtect" value="true" refParamName="" useRefParam="false" />'
            f'<String name="syncAnimationName" value="" refParamName="" useRefParam="false" />'
            f'<bool name="bApplySpecialEffect" value="true" refParamName="" useRefParam="false" />'
            f'<bool name="bOnlySetAlpha" value="true" refParamName="" useRefParam="false" />'
            f'<String name="customTagName" value="" refParamName="" useRefParam="false" />'
            f'</Event>{skin_tags}</Track>'
        )
        out_raws.extend([trk_tick, trk_dur])
        changed = True

    if not changed:
        return xml_text
    return hdr + f"{eol}    ".join(out_raws) + ftr


def _apply_sprint_haste_xml(
    xml_text: str,
    hero_id: int,
    hero_code: str,
    born_skin_id: int,
    is_born_hd: bool,
    target_skin_ids: list[str],
    exclusive_cfg: dict[int, dict[str, str]],
) -> str:
    """
    R1.2: Biến đổi `commonresource/HasteE1.xml`:
      - Chạy `_transform_common_action_xml` trước.
      - Nếu `born_skin_id` có hiệu ứng gia tốc tế đàn riêng trong `ResSkinExclusiveBattleEffectCfg.bytes`
        và `HasteE1.xml` gốc chưa có track `TriggerParticle` `flt=9` của `born_skin_id`,
        nối thêm `TriggerParticle` + `StopTracks` (dừng track 8, 9 mặc định).
    """
    orig_sp = cp.split_xml_tracks(xml_text)
    orig_tracks = orig_sp[1] if orig_sp else []
    born_str = str(born_skin_id)
    has_custom_haste = any(
        t.get("filterType") == "9"
        and t.get("eventType") == "TriggerParticle"
        and born_str in (t.get("skins") or [])
        for t in orig_tracks
    )

    upd = _transform_common_action_xml(xml_text, hero_id, born_skin_id, target_skin_ids)
    cfg = exclusive_cfg.get(born_skin_id)
    if not cfg or has_custom_haste:
        return upd

    custom_effects = [
        p.strip()
        for p in (cfg.get("sprint_effects") or "").split(",")
        if p.strip() and p.strip().lower() != "jiasu_tongyong_01"
    ]
    if not custom_effects:
        return upd

    sp_res = cp.split_xml_tracks(upd)
    if not sp_res or not sp_res[1]:
        return upd
    hdr, tracks, ftr = sp_res
    eol = "\r\n" if "\r\n" in upd else "\n"

    # Phân giải động ID & GUID các track `jiasu_tongyong_01` mặc định (8,9 ở HasteE1; 9,12 ở HasteE1_leave)
    resolved_targets = _resolve_default_sprint_track_targets(tracks)

    bind_attrs = _format_vec3_attrs(cfg.get("sprint_offset", ""), (0.0, 0.7, -0.6))
    skin_tags = "".join(f'<SkinOrAvatarList id="{s}" />' for s in target_skin_ids)
    out_raws = [t["raw"] for t in tracks]

    for idx, eff_name in enumerate(custom_effects):
        res_path = jtcom.rewrite_hero_effect_path(
            f"prefab_skill_effects/hero_skill_effects/{hero_code}/{eff_name}",
            hero_id,
            born_skin_id,
            is_born_hd,
        )
        tg = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.haste.{born_skin_id}.{idx}.track"))
        eg = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.haste.{born_skin_id}.{idx}.event"))
        trk_p = (
            f'<Track trackName="Totorox_Sprint_{born_skin_id}_{idx}" eventType="TriggerParticle" '
            f'guid="{tg}" enabled="true" useRefParam="false" refParamName="" r="0.000" g="0.000" b="0.000" '
            f'execOnForceStopped="false" execOnActionCompleted="false" stopAfterLastEvent="true" SkinAvatarFilterType="9">'
            f'<Event eventName="TriggerParticle" time="0.000" length="5.000" isDuration="true" guid="{eg}">'
            f'<TemplateObject name="targetId" objectName="target" id="1" isTemp="false" refParamName="" useRefParam="false" />'
            f'<TemplateObject name="objectSpaceId" objectName="target" id="1" isTemp="false" refParamName="" useRefParam="false" />'
            f'<String name="resourceName" value="{res_path}" refParamName="" useRefParam="false" />'
            f'<Vector3 name="bindPosOffset" {bind_attrs} refParamName="" useRefParam="false" />'
            f'<Vector3i name="scalingInt" x="10000" y="10000" z="10000" refParamName="" useRefParam="false" />'
            f'<String name="syncAnimationName" value="" refParamName="" useRefParam="false" />'
            f'<String name="customTagName" value="" refParamName="" useRefParam="false" />'
            f'</Event>{skin_tags}</Track>'
        )
        out_raws.append(trk_p)

    st_tg = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.haste.{born_skin_id}.stop.track"))
    st_eg = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"totorox.haste.{born_skin_id}.stop.event"))
    trk_objs = "".join(f'<TrackObject id="{tid}" guid="{tguid}" />' for tid, tguid in resolved_targets)
    trk_stop = (
        f'<Track trackName="Totorox_StopDefaultSprint_{born_skin_id}" eventType="StopTracks" '
        f'guid="{st_tg}" enabled="true" useRefParam="false" refParamName="" r="0.000" g="0.000" b="0.000" '
        f'execOnForceStopped="false" execOnActionCompleted="false" SkinAvatarFilterType="9">'
        f'<Event eventName="StopTracks" time="0.000" isDuration="false" guid="{st_eg}">'
        f'<Array name="trackIds" refParamName="" useRefParam="false" type="TrackObject">{trk_objs}</Array>'
        f'<bool name="alsoStopNotStartedTrack" value="true" refParamName="" useRefParam="false" />'
        f'</Event>{skin_tags}</Track>'
    )
    out_raws.append(trk_stop)
    return hdr + f"{eol}    ".join(out_raws) + ftr


def _inject_camera_height_in_junglemark_xml(xml_text: str, camera_percent: float) -> str:
    """Bơm hoặc cập nhật `SetCameraHeightDuration0` (`heightRate = 1.100 * (1 + pct/100)`) vào `PassiveResource/junglemark.xml`."""
    rate = round(1.100 * (1.0 + float(camera_percent) / 100.0), 3)
    rate_str = f"{rate:.3f}"
    if "SetCameraHeightDuration" in xml_text and "heightRate" in xml_text:
        return _HEIGHT_RATE_RE.sub(rf"\g<1>{rate_str}\g<3>", xml_text)

    cam_track = (
        '<Track trackName="SetCameraHeightDuration0" eventType="SetCameraHeightDuration" '
        'guid="9489c796-894b-4c2e-9a95-acf27873964a" enabled="true" useRefParam="false" '
        'refParamName="" r="0.000" g="0.000" b="0.000" execOnForceStopped="false" '
        'execOnActionCompleted="false" stopAfterLastEvent="true">'
        '<Event eventName="SetCameraHeightDuration" time="0.000" length="1.000" isDuration="true" '
        'guid="422a1ed9-a12c-44b3-a9c5-3fe899d689dd">'
        '<int name="slerpTick" value="0" refParamName="" useRefParam="false" />'
        f'<float name="heightRate" value="{rate_str}" refParamName="" useRefParam="false" />'
        '<bool name="bOverride" value="true" refParamName="" useRefParam="false" />'
        '<bool name="leftTimeSlerpBack" value="true" refParamName="" useRefParam="false" />'
        '<bool name="cutBackOnExit" value="true" refParamName="" useRefParam="false" />'
        '<bool name="exitKeepCurrentValue" value="true" refParamName="" useRefParam="false" />'
        '<bool name="isSlerpBackWhenInterrupted" value="true" refParamName="" useRefParam="false" />'
        '<int name="slerpBackTick" value="1500" refParamName="" useRefParam="false" />'
        '<String name="refParamName" value="" refParamName="" useRefParam="false" />'
        "</Event></Track>"
    )
    sp_res = cp.split_xml_tracks(xml_text)
    if sp_res and sp_res[1]:
        hdr, tracks, ftr = sp_res
        eol = "\r\n" if "\r\n" in xml_text else "\n"
        return hdr + f"{eol}    ".join([t["raw"] for t in tracks] + [cam_track]) + ftr
    return xml_text


def _inject_camera_height_in_born_xml(xml_text: str, camera_percent: float) -> str:
    """Alias tương thích ngược cho `_inject_camera_height_in_junglemark_xml`."""
    return _inject_camera_height_in_junglemark_xml(xml_text, camera_percent)


def _patch_hs1_single(hs1_template_dec: bytes, hero_id: int, skin_id: int, pkg_md5s: dict[str, str]) -> bytes:
    lay = cp.parse_kiana_hs1(hs1_template_dec)
    if lay is None:
        raise ValueError("Template HeroSkin_1 không hợp lệ.")
    buf = bytearray(hs1_template_dec)
    # 3 vị trí hero_id & 1 vị trí skin_id trong bảng lệnh IFix của HeroSkin_1
    mp = lay["offA"] + 12
    struct.pack_into("<i", buf, mp + 20, int(hero_id))
    # Tìm bhid trong offB và offC
    for pos in range(lay["offB"] + 4, lay["endB"] - 8, 8):
        op, arg = struct.unpack_from("<Ii", buf, pos)
        if op == 0x8F and arg == lay["pairs"][0][0]:
            struct.pack_into("<i", buf, pos + 4, int(hero_id))
            break
    c56 = lay["offC"] + 4 + 56 * 8
    for pos in range(lay["offC"] + 4, c56, 8):
        op, arg = struct.unpack_from("<Ii", buf, pos)
        if op == 0x8F and arg == lay["pairs"][0][0]:
            struct.pack_into("<i", buf, pos + 4, int(hero_id))
            break
    struct.pack_into("<i", buf, lay["offC"] + 4 + 58 * 8 + 4, int(skin_id))
    cp.update_embedded_pkg_md5s(buf, pkg_md5s)
    return cp.pg_encrypt(bytes(buf), "HeroSkin_1")


def _patch_hs2_single(
    hs2_template_dec: bytes,
    hero_id: int,
    personal_button_id: int,
    kill_notify_id: int,
    pkg_md5s: dict[str, str],
) -> bytes:
    lay = cp.parse_kiana_hs2(hs2_template_dec)
    if lay is None:
        raise ValueError("Template HeroSkin_2 không hợp lệ.")
    buf = bytearray(hs2_template_dec)
    mp = lay["off"] + 4 + 58 * 8
    struct.pack_into("<i", buf, mp + 12, int(hero_id))
    struct.pack_into("<i", buf, mp + 44, int(personal_button_id))
    struct.pack_into("<i", buf, mp + 68, int(kill_notify_id))
    cp.update_embedded_pkg_md5s(buf, pkg_md5s)
    return cp.pg_encrypt(bytes(buf), "HeroSkin_2")


def _clone_heroskin_record(src_rec: bytes, dst_skin_id: int, src_skin_id: int, hero_id: int) -> bytes:
    """Sao chép bản ghi `heroSkin.bytes` từ `src_skin_id` sang `dst_skin_id` (khớp logic hoán đổi mã & index của Kiana)."""
    dst_idx = int(dst_skin_id) - int(hero_id) * 100
    src_idx = int(src_skin_id) - int(hero_id) * 100
    buf = bytearray(src_rec)

    # Trong heroSkin.bytes, skin mặc định `XX00` dùng mã avatar `30<hero_id>0` ở offset 64;
    # skin bậc nhỏ `idx < 10` dùng `30<hero_id><idx>` (VD 15009 -> 301509), giữ nguyên `30<src>head.jpg`.
    if 0 <= src_idx < 100:
        src_code = f"30{hero_id}{src_idx}".encode("ascii")
    else:
        src_code = f"30{src_skin_id}".encode("ascii")

    if dst_idx == 0:
        dst_code = f"30{hero_id}0".encode("ascii")
        if dst_code != src_code:
            old_tok = struct.pack("<I", len(src_code) + 1) + src_code + b"\x00"
            new_tok = struct.pack("<I", len(dst_code) + 1) + dst_code + b"\x00"
            buf = bytearray(bytes(buf).replace(old_tok, new_tok, 1))

    struct.pack_into("<II", buf, 0, len(buf) - 4, int(dst_skin_id))
    if len(buf) >= 40:
        new_idx = int(src_idx) if (dst_idx == 0 and src_idx > 0) else max(0, int(dst_idx))
        struct.pack_into("<I", buf, 36, new_idx)
    return bytes(buf)


def _remap_sound_table_for_hero(
    plain_mses: bytes,
    stem: str,
    hero_id: int,
    sound_skin_id: int,
    base_skin_id: int,
) -> bytes:
    """
    Đổi trường `skin_id` (u32) trong các bảng âm thanh (`BattleBank`, `LobbyBank`, `HeroSound`, `ChatSound`, `LobbySound`, `CoupleSound`):
      - Hỗ trợ cả mã 5 chữ số `[H*100, (H+1)*100)` lẫn mã tiến hóa 7 chữ số `[H*10000, (H+1)*10000)`.
      - Định vị chính xác tại offset `12 + slen` (tránh dương tính giả trên `ChatSound` / `CoupleSound` và vẫn xử lý bản ghi `rid` không bắt đầu bằng `hero_id` như `CoupleSound rid=141` hoặc `HeroSound rid=58411`).
      - Hỗ trợ các skin chỉ có bậc 7 chữ số không phải `*01` (VD `1320602`, `1420702`, `LobbyBank`/`LobbySound` `1503302..05`).
      - Bản ghi thuộc `sound_skin_id` -> đổi sang `base_skin_id` (`hero_id * 100`).
      - Bản ghi thuộc các skin khác của `hero_id` -> đổi sang `235XX` / `235XXXX` để không đè âm thanh.
    """
    tbl = cp.parse_mses(plain_mses)
    if not tbl:
        return plain_mses
    hp = str(hero_id)
    lo5, hi5 = hero_id * 100, (hero_id + 1) * 100
    lo7, hi7 = hero_id * 10000, (hero_id + 1) * 10000

    def _matches_hero_skin(val: int) -> bool:
        return (lo5 <= val < hi5) or (lo7 <= val < hi7)

    # Quét lượt 1 để xác định toàn bộ skin_id hợp lệ của tướng hiện có trong bảng này
    matches: dict[int, tuple[int, int]] = {}
    present_vals: set[int] = set()
    for idx, (rid, rraw) in enumerate(tbl["recs"]):
        if len(rraw) < 16:
            continue
        slen = struct.unpack_from("<I", rraw, 8)[0]
        skin_off = 12 + slen
        if 1 <= slen <= len(rraw) - 16 and rraw[skin_off - 1] == 0:
            val = struct.unpack_from("<I", rraw, skin_off)[0]
            if _matches_hero_skin(val):
                matches[idx] = (skin_off, val)
                present_vals.add(val)
        elif str(rid).startswith(hp):
            for off in range(8, len(rraw) - 3):
                val = struct.unpack_from("<I", rraw, off)[0]
                if _matches_hero_skin(val):
                    matches[idx] = (off, val)
                    present_vals.add(val)
                    break

    if not matches:
        return plain_mses

    target_vals: set[int] = set()
    if sound_skin_id < 1_000_000:
        target_vals.add(sound_skin_id)
        stages_7 = sorted(v for v in present_vals if sound_skin_id * 100 <= v < (sound_skin_id + 1) * 100)
        if stages_7:
            s1 = sound_skin_id * 100 + 1
            target_vals.add(s1 if s1 in stages_7 else stages_7[0])
    else:
        parent5 = sound_skin_id // 100
        if sound_skin_id in present_vals:
            target_vals.add(sound_skin_id)
        elif parent5 in present_vals:
            target_vals.add(parent5)
        else:
            stages_7 = sorted(v for v in present_vals if parent5 * 100 <= v < (parent5 + 1) * 100)
            if stages_7:
                target_vals.add(stages_7[0])

    new_recs: list[tuple[int, bytes]] = []
    for idx, (rid, rraw) in enumerate(tbl["recs"]):
        m = matches.get(idx)
        if m is None:
            new_recs.append((rid, rraw))
            continue
        skin_off, val = m
        buf = bytearray(rraw)
        new_val = base_skin_id if val in target_vals else dummy_skin_id(val)
        struct.pack_into("<I", buf, skin_off, int(new_val))
        new_recs.append((rid, bytes(buf)))
    tbl["recs"] = new_recs
    return cp.serialize_mses(tbl)


def _remap_sound_table_selective(
    plain_mses: bytes,
    stem: str,
    hero_id: int,
    sound_by_dst: dict[int, int],
) -> bytes:
    """
    Cập nhật bảng âm thanh Wwise cho chế độ đè chọn lọc:
      - Các skin KHÔNG nằm trong `sound_by_dst` giữ nguyên 100%.
      - Bản ghi cũ của `dst_sid` (khi bị đè bởi skin nguồn khác) được chuyển sang `dummy_skin_id(dst_sid)`.
      - Nhân bản toàn bộ bản ghi của `src_sid` sang `rid` mới gắn `skin_id = dst_sid`.
    """
    tbl = cp.parse_mses(plain_mses)
    if not tbl:
        return plain_mses
    hp = str(hero_id)
    lo5, hi5 = hero_id * 100, (hero_id + 1) * 100
    lo7, hi7 = hero_id * 10000, (hero_id + 1) * 10000

    def _matches_hero_skin(val: int) -> bool:
        return (lo5 <= val < hi5) or (lo7 <= val < hi7)

    matches: dict[int, tuple[int, int]] = {}
    present_vals: set[int] = set()
    recs_by_val: dict[int, list[tuple[int, int, bytes]]] = {}
    max_rid = 0
    existing_rids: set[int] = set()

    for idx, (rid, rraw) in enumerate(tbl["recs"]):
        existing_rids.add(int(rid))
        if int(rid) > max_rid:
            max_rid = int(rid)
        if len(rraw) < 16:
            continue
        slen = struct.unpack_from("<I", rraw, 8)[0]
        skin_off = 12 + slen
        found_pair: tuple[int, int] | None = None
        if 1 <= slen <= len(rraw) - 16 and rraw[skin_off - 1] == 0:
            val = struct.unpack_from("<I", rraw, skin_off)[0]
            if _matches_hero_skin(val):
                found_pair = (skin_off, val)
        elif str(rid).startswith(hp):
            for off in range(8, len(rraw) - 3):
                val = struct.unpack_from("<I", rraw, off)[0]
                if _matches_hero_skin(val):
                    found_pair = (off, val)
                    break
        if found_pair is not None:
            matches[idx] = found_pair
            present_vals.add(found_pair[1])
            recs_by_val.setdefault(found_pair[1], []).append((int(rid), found_pair[0], rraw))

    if not matches:
        return plain_mses

    # Với mỗi nguồn `src_sid`, chọn các `val` đại diện (5-chữ số hoặc bậc 7-chữ số ưu tiên *01)
    def _resolve_src_vals(src_sid: int) -> list[int]:
        out_v: list[int] = []
        if src_sid < 1_000_000:
            if src_sid in present_vals:
                out_v.append(src_sid)
            stages_7 = sorted(v for v in present_vals if src_sid * 100 <= v < (src_sid + 1) * 100)
            if stages_7:
                s1 = src_sid * 100 + 1
                pick = s1 if s1 in stages_7 else stages_7[0]
                if pick not in out_v:
                    out_v.append(pick)
        else:
            parent5 = src_sid // 100
            if src_sid in present_vals:
                out_v.append(src_sid)
            elif parent5 in present_vals:
                out_v.append(parent5)
            else:
                stages_7 = sorted(v for v in present_vals if parent5 * 100 <= v < (parent5 + 1) * 100)
                if stages_7:
                    out_v.append(stages_7[0])
        return out_v

    replaced_set = set(sound_by_dst.keys())
    new_recs: list[tuple[int, bytes]] = []
    for idx, (rid, rraw) in enumerate(tbl["recs"]):
        m = matches.get(idx)
        if m is None:
            new_recs.append((rid, rraw))
            continue
        skin_off, val = m
        val5 = val // 100 if val >= 1_000_000 else val
        if val5 in replaced_set and sound_by_dst[val5] != val5:
            buf = bytearray(rraw)
            struct.pack_into("<I", buf, skin_off, int(dummy_skin_id(val)))
            new_recs.append((rid, bytes(buf)))
        else:
            new_recs.append((rid, rraw))

    for dst_sid, src_sid in sorted(sound_by_dst.items()):
        if dst_sid == src_sid:
            continue
        next_rid = int(dst_sid) * 1000 + 900
        for sv in _resolve_src_vals(src_sid):
            for _, skin_off, orig_raw in recs_by_val.get(sv, []):
                while next_rid in existing_rids:
                    next_rid += 1
                assigned_rid = next_rid
                existing_rids.add(assigned_rid)
                next_rid += 1
                buf = bytearray(orig_raw)
                struct.pack_into("<I", buf, 4, assigned_rid)
                struct.pack_into("<I", buf, skin_off, int(dst_sid))
                new_recs.append((assigned_rid, bytes(buf)))

    tbl["recs"] = new_recs
    return cp.serialize_mses(tbl)


def _resolve_skin_override_plan(
    options: dict[str, Any],
    hero_id: int,
) -> tuple[int, dict[int, int], bool, bool]:
    """
    Phân giải cấu hình đè skin cho 1 tướng:
      Trả về `(main_source_skin_id, skin_mappings, apply_to_all_skins, is_selective_replace)`.
    """
    base_sid = hero_id * 100
    max_sid = (hero_id + 1) * 100

    def _validate_dst(sid: int) -> int:
        if not (base_sid <= sid < max_sid):
            raise ValueError(f"Skin bị đè {sid} không thuộc dải trang phục của tướng {hero_id}.")
        return sid

    def _validate_src(sid: int) -> int:
        if sid <= 0:
            raise ValueError("source_skin_id phải là số nguyên dương.")
        if sid < 1_000_000 and not (base_sid <= sid < max_sid):
            raise ValueError(f"Skin nguồn {sid} không thuộc dải trang phục của tướng {hero_id}.")
        return sid

    raw_src = (
        options.get("source_skin_id")
        if options.get("source_skin_id") is not None
        else options.get("target_skin_id")
    )
    fallback_src = int(raw_src) if raw_src is not None and str(raw_src).strip() != "" else None

    raw_mappings = options.get("skin_mappings")
    if isinstance(raw_mappings, str):
        s_rm = raw_mappings.strip()
        raw_mappings = json.loads(s_rm) if s_rm else None

    parsed_mappings: dict[int, int] = {}
    if isinstance(raw_mappings, dict) and raw_mappings:
        for k, v in raw_mappings.items():
            dst_sid = _validate_dst(int(k))
            src_sid = _validate_src(int(v))
            parsed_mappings[dst_sid] = src_sid
    elif isinstance(raw_mappings, list) and raw_mappings:
        for entry in raw_mappings:
            if not isinstance(entry, dict):
                raise ValueError("Mỗi phần tử trong skin_mappings phải là object.")
            d_val = entry.get("replace_skin_id")
            if d_val is None:
                d_val = entry.get("target_skin_id")
            if d_val is None:
                d_val = entry.get("dst_skin_id")
            s_val = entry.get("source_skin_id")
            if s_val is None:
                s_val = fallback_src
            if d_val is None or s_val is None:
                raise ValueError("Thiếu target/replace_skin_id hoặc source_skin_id trong skin_mappings.")
            parsed_mappings[_validate_dst(int(d_val))] = _validate_src(int(s_val))

    if not parsed_mappings:
        raw_replace = options.get("replace_skin_ids")
        if isinstance(raw_replace, str):
            sr = raw_replace.strip()
            if not sr:
                raw_replace = []
            elif sr.startswith("["):
                raw_replace = json.loads(sr)
            else:
                raw_replace = [x.strip() for x in sr.split(",") if x.strip()]
        if isinstance(raw_replace, (list, tuple, set)) and len(raw_replace) > 0:
            if fallback_src is None:
                raise ValueError("Thiếu source_skin_id khi chỉ định replace_skin_ids.")
            src_v = _validate_src(fallback_src)
            for item in raw_replace:
                parsed_mappings[_validate_dst(int(item))] = src_v

    if parsed_mappings:
        main_src = _validate_src(fallback_src) if fallback_src is not None else next(iter(parsed_mappings.values()))
        return main_src, parsed_mappings, False, True

    if fallback_src is None:
        raise ValueError("Thiếu hoặc sai định dạng hero_id / source_skin_id.")
    main_src = _validate_src(fallback_src)
    apply_all = bool(options.get("apply_to_all_skins", True))
    default_map = (
        {hero_id * 100 + i: main_src for i in range(46)}
        if apply_all
        else {base_sid: main_src}
    )
    return main_src, default_map, apply_all, False


def _extract_hero_rpack_hashes(rpack_raw: bytes, hero_id: int) -> set[tuple[int, int]]:
    """Trích xuất tập hợp cặp băm 64-bit `(h0, h1)` của mọi prefab thuộc tướng `hero_id` trong `RPack`."""
    try:
        u = cp.unpack_unityfs(rpack_raw)
        parsed = cp.parse_rpack(u)
        payload = u["payload"]
    except Exception:
        return set()
    hp = str(hero_id)
    hashes: set[tuple[int, int]] = set()
    for path, (_, hs, he) in parsed["recs"].items():
        low = path.lower()
        if not (low.startswith("assetbundle/battle/skin/") or low.startswith("assetbundle/show/skin/")):
            continue
        fn = os.path.basename(low)
        m = re.match(r"^(\d+)_", fn)
        if not m:
            continue
        digits = m.group(1)
        if (digits == hp or (digits.startswith(hp) and len(hp) < len(digits) <= len(hp) + 2)) and he > hs:
            pos = hs
            while pos + 12 <= he:
                h0, h1, elen = struct.unpack_from("<III", payload, pos)
                hashes.add((h0, h1))
                pos += 12 + ((elen + 3) & ~3)
    return hashes


def _patch_rpack_for_hero_battle_skins(rpack_raw: bytes, hero_id: int) -> bytes:
    """Đánh dấu `KianaMod\\0\\0\\0\\0` trên các record low-LOD 12-byte của `assetbundle/battle/skin/<H>*` và `assetbundle/show/skin/<H>*`, bảo toàn toàn bộ bảng băm prefab thật."""
    u = cp.unpack_unityfs(rpack_raw)
    parsed = cp.parse_rpack(u)
    payload = bytearray(u["payload"])
    marker12 = b"KianaMod\x00\x00\x00\x00"
    hp = str(hero_id)
    changed = False

    for path, (_, hs, he) in parsed["recs"].items():
        low = path.lower()
        if not (low.startswith("assetbundle/battle/skin/") or low.startswith("assetbundle/show/skin/")):
            continue
        fn = os.path.basename(low)
        m = re.match(r"^(\d+)_", fn)
        if not m:
            continue
        digits = m.group(1)
        if (digits == hp or (digits.startswith(hp) and len(hp) < len(digits) <= len(hp) + 2)) and (he - hs == 12):
            pos = hs
            while pos + 12 <= he:
                elen = struct.unpack_from("<I", payload, pos + 8)[0]
                if elen == 0:
                    payload[pos : pos + 12] = marker12
                    changed = True
                pos += 12 + ((elen + 3) & ~3)

    if not changed:
        return rpack_raw

    comp_payload = cp.lz4_compress_raw_fast(bytes(payload))
    new_comp_sz = len(comp_payload)
    new_uncomp_sz = len(payload)
    new_hdr = bytearray(u["header"])
    spos = u["size_pos"]
    if len(u["info_raw"]) == 93 and new_comp_sz < 0x01000000 and new_uncomp_sz < 0x01000000:
        tail = bytearray([0x1E, 0x00, 0x01, 0x00, 0xD1, 0x01, 0x00, 0x02, 0x00, 0x00])
        tail += struct.pack(">II", new_comp_sz, new_uncomp_sz)
        tail += bytes([0x10, 0x00, 0x00, 0x01, 0x00, 0x02, 0x0C, 0x00, 0x04, 0x24, 0x00, 0xF0, 0x17])
        tail += u["info_raw"][55:93]
        new_tail = bytes(tail)
        struct.pack_into(">III", new_hdr, spos + 8, len(new_tail), 93, 0x00C2)
    else:
        ir = bytearray(u["info_raw"])
        struct.pack_into(">HII", ir, 20, 2, new_comp_sz, new_uncomp_sz)
        if len(ir) >= 44:
            struct.pack_into(">I", ir, 40, new_uncomp_sz)
        new_tail = cp.lz4_compress_raw_fast(bytes(ir))
        struct.pack_into(">III", new_hdr, spos + 8, len(new_tail), len(ir), 0x00C2)

    total_sz = len(new_hdr) + len(comp_payload) + len(new_tail)
    struct.pack_into(">Q", new_hdr, spos, total_sz)
    return bytes(new_hdr) + comp_payload + new_tail


def _decode_aov_xml_bytes(edata: bytes, ename: str, stem: str = "") -> bytes:
    """Giải mã XML AOV (hỗ trợ `0x224A00EF`, `0x224A67xx`, `0x224A0000` và plain UTF-8)."""
    if len(edata) > 8 and edata[:2] == b"\x22\x4A":
        plain = cp.decode_aov_xml_if_needed(edata, ename)
        if len(plain) > 8 and plain[:2] == b"\x22\x4A":
            eff_stem = stem or os.path.splitext(os.path.basename(ename.replace("\\", "/")))[0]
            try:
                cand = cp.pg_decrypt(plain, eff_stem)
                cand.decode("utf-8")
                plain = cand
            except Exception:
                pass
        return plain
    return edata


def _ensure_actor_xml_encrypted_224a(edata: bytes, ename: str, stem: str) -> bytes:
    """Đảm bảo mọi XML trong `Actor_<H>_Actions.pkg.bytes` đều được mã hóa `0x224A67EF` (Zstd-dict + AES) theo `stem`."""
    plain = _decode_aov_xml_bytes(edata, ename, stem)
    if len(plain) > 8 and plain[:2] == b"\x22\x4A":
        return edata
    return cp.pg_encrypt(plain, stem, compress_zstd=True)


class SkinModBuilder:
    """Trình biên dịch gói Mod Skin hoàn chỉnh từ `BaseResourceProvider`."""

    @staticmethod
    def build_mod(provider: BaseResourceProvider, options: dict[str, Any]) -> dict[str, Any]:
        """
        `options`:
          - `mode`: `"skin"` (mặc định) hoặc `"camera_only"` (chỉ tạo gói Cam Xa siêu nhẹ 4 file)
          - `hero_id`: int (VD: `131`)
          - `source_skin_id` / `target_skin_id`: int (VD: `13118`)
          - `apply_to_all_skins`: bool (mặc định `True` — đè cho mọi skin của tướng đó để mặc skin nào cũng hiện)
          - `enable_skills` / `enable_vfx`: bool (`True`)
          - `enable_recall`: bool (`True`)
          - `enable_born`: bool (`True`)
          - `enable_sound`: bool (`True`)
          - `enable_button`: bool (`True`)
          - `enable_billboard`: bool (`True`)
          - `personal_button_id`: int (`0` = tắt, `None` = tự tra cứu theo skin nếu `enable_button=True`)
          - `kill_notify_id` / `billboard_id`: int (`0` = tắt, `None` = tự tra cứu theo skin nếu `enable_billboard=True`)
          - `camera_percent`: float (`0` = tắt, `5`..`30` = tăng độ cao camera %)
          - `is_mix`: bool (tùy chọn bật/tắt Mix Chiêu)
          - `skill_mix`: dict tùy chọn (`normal`/`attack`, `skill1`/`s1`, `skill2`/`s2`, `skill3`/`s3`, `passive`, `recall`, `born`, `sound`)
          - `watermark_text`: str
          - `output_format`: `"zip"` hoặc `"3105"`
          - `password`: str (tùy chọn khi `output_format == "3105"`)
          - `custom_filename`: str (tùy chọn)
          - `output_dir`: str (tùy chọn thư mục xuất)
        """
        t0 = time.time()
        warnings: list[str] = []
        seed = load_bypass_seed()
        seed_status = check_bypass_seed_compatibility(provider, seed)
        allow_seed_mismatch = bool(options.get("allow_seed_mismatch"))
        if not seed_status["compatible"]:
            if seed_status["severity"] == "error" and not allow_seed_mismatch:
                raise ModAssetValidationError(seed_status["message"])
            warnings.append(seed_status["message"])

        ver = provider.game_version
        mode = str(options.get("mode") or "skin").strip().lower()
        cam_pct = float(options.get("camera_percent") or 0.0)
        watermark_text = str(options.get("watermark_text") or "").strip()
        output_format = str(options.get("output_format") or "zip").strip().lower().lstrip(".")
        password = str(options.get("password") or "").strip() or None
        output_dir = str(options.get("output_dir") or "").strip() or None

        if not provider.has("version.txt"):
            raise ModAssetValidationError("Thiếu tệp 'version.txt' trong Resources gốc.")
        vtxt_bytes = provider.read("version.txt")
        if not vtxt_bytes.strip():
            raise ModAssetValidationError("Tệp 'version.txt' trong Resources gốc bị rỗng.")

        out_rel_files: dict[str, bytes] = {}
        klua_bytes = seed["KernelLua.pkg.bytes"]
        ss3_bytes = seed["StableSystems_3.pkg.bytes"]
        pkg_md5s = {
            "KernelLua.pkg.bytes": hashlib.md5(klua_bytes).hexdigest().lower(),
            "StableSystems_3.pkg.bytes": hashlib.md5(ss3_bytes).hexdigest().lower(),
        }

        out_rel_files["KernelLua.pkg.bytes"] = klua_bytes
        out_rel_files["StableSystems_3.pkg.bytes"] = ss3_bytes
        out_rel_files["version.txt"] = vtxt_bytes

        # Chế độ 1: Chỉ tạo gói Cam Xa độc lập (4 file gọn nhẹ — patch PassiveResource/junglemark.xml)
        if mode == "camera_only":
            if cam_pct <= 0:
                cam_pct = 15.0
            ca_rel = "Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes"
            if not provider.has(ca_rel):
                raise ModAssetValidationError(f"Thiếu tệp {ca_rel!r} trong Resources gốc.")
            ca_entries = cp.parse_in_memory_zip(provider.read(ca_rel))
            mod_mtime, mod_mdate = 0x5800, 0x5B72
            new_ca: list[tuple[str, int, int, bytes]] = []
            patched_jungle = False
            for ename, mt, md, edata in ca_entries:
                if ename.replace("\\", "/").lower().endswith("passiveresource/junglemark.xml"):
                    dec = _decode_aov_xml_bytes(edata, ename).decode("utf-8", errors="ignore")
                    updated = _inject_camera_height_in_junglemark_xml(dec, cam_pct)
                    new_ca.append((ename, mod_mtime, mod_mdate, updated.encode("utf-8")))
                    patched_jungle = True
                else:
                    new_ca.append((ename, mt, md, edata))
            if not patched_jungle:
                raise ModAssetValidationError("Không tìm thấy PassiveResource/junglemark.xml trong CommonActions.pkg.bytes.")
            out_rel_files[ca_rel] = cp.build_in_memory_store_zip(new_ca)
            base_label = f"Totorox_CamXa_{int(cam_pct) if cam_pct.is_integer() else cam_pct}pct"
            summary = {
                "mode": "camera_only",
                "seed_mode": seed["seed_mode"],
                "camera_percent": cam_pct,
                "target_xml": "PassiveResource/junglemark.xml",
                "output_format": output_format,
            }
            return SkinModBuilder._finalize_package(
                out_rel_files,
                ver,
                base_label,
                options.get("custom_filename"),
                output_format,
                password,
                t0,
                output_dir=output_dir,
                summary=summary,
                warnings=warnings,
            )

        # Chế độ 2: Tạo gói Mod Skin Tướng đầy đủ (1-Click, Đè chọn lọc từng skin, hoặc Mix Chiêu)
        raw_hero_id = options.get("hero_id")
        try:
            hero_id = int(raw_hero_id)
        except (TypeError, ValueError) as exc:
            raise ValueError("Thiếu hoặc sai định dạng hero_id / source_skin_id.") from exc
        if hero_id <= 0:
            raise ValueError("hero_id và source_skin_id phải là số nguyên dương.")

        source_skin_id, skin_mappings, apply_all, is_selective_replace = _resolve_skin_override_plan(options, hero_id)
        base_skin_id = hero_id * 100
        if options.get("enable_skills") is not None:
            enable_skills = bool(options.get("enable_skills"))
        elif options.get("enable_vfx") is not None:
            enable_skills = bool(options.get("enable_vfx"))
        else:
            enable_skills = True
        enable_recall = bool(options.get("enable_recall", True))
        enable_born = bool(options.get("enable_born", True))
        enable_sound = bool(options.get("enable_sound", True))

        is_mix_opt = options.get("is_mix")
        mix_raw = {} if is_mix_opt is False else (options.get("skill_mix") or {})
        is_mix = bool(is_mix_opt) if is_mix_opt is not None else bool(mix_raw)

        def slot_skin(*slot_names: str, default_sid: int | None = None) -> int:
            fb_sid = source_skin_id if default_sid is None else default_sid
            for slot_name in slot_names:
                v = mix_raw.get(slot_name)
                if v is not None and v != "":
                    try:
                        iv = int(v)
                        return iv if iv >= 10000 else fb_sid
                    except (TypeError, ValueError):
                        pass
            return fb_sid

        sound_skin_id = slot_skin("sound")
        recall_skin_id = slot_skin("recall")
        born_skin_id = slot_skin("born")

        # Nút bấm cá nhân & Thông báo hạ (mặc định True; hỗ trợ tắt qua enable_button=False hoặc personal_button_id=0)
        enable_button_opt = options.get("enable_button")
        enable_button = True if enable_button_opt is None else bool(enable_button_opt)
        if not enable_button:
            pbtn_id = 0
        elif options.get("personal_button_id") is not None:
            pbtn_id = int(options.get("personal_button_id") or 0)
        else:
            pbtn_id = 0
            btn_rel = "Databin/Client/Huanhua/ResPersonalButtonCfg.bytes"
            if provider.has(btn_rel):
                bt = cp.parse_mses(cp.pg_decrypt(provider.read(btn_rel), "ResPersonalButtonCfg"))
                if bt:
                    for brid, brraw in bt["recs"]:
                        if len(brraw) >= 12 and struct.unpack_from("<I", brraw, 8)[0] == source_skin_id:
                            pbtn_id = int(brid)
                            break

        enable_billboard_opt = options.get("enable_billboard")
        enable_billboard = True if enable_billboard_opt is None else bool(enable_billboard_opt)
        raw_bb_id = (
            options.get("billboard_id")
            if options.get("billboard_id") is not None
            else options.get("kill_notify_id")
        )
        if not enable_billboard:
            knotify_id = 0
        elif raw_bb_id is not None:
            knotify_id = int(raw_bb_id or 0)
        else:
            knotify_id = 0
            bb_rel = "Databin/Client/Huanhua/ResBillboardSkinCfg.bytes"
            if provider.has(bb_rel):
                bbt = cp.parse_mses(cp.pg_decrypt(provider.read(bb_rel), "ResBillboardSkinCfg"))
                if bbt:
                    for bbrid, bbrraw in bbt["recs"]:
                        if len(bbrraw) >= 16 and struct.unpack_from("<I", bbrraw, 12)[0] == source_skin_id:
                            knotify_id = int(bbrid)
                            break

        # Kiểm tra trước các tài nguyên bắt buộc để báo RuntimeError/ValueError rõ ràng
        infos_rel = f"Prefab_Characters/Actor_{hero_id}_Infos.pkg.bytes"
        act_rel = f"Ages/Prefab_Characters/Prefab_Hero/Actor_{hero_id}_Actions.pkg.bytes"
        ca_rel = "Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes"
        hs_rel = "Databin/Client/Actor/heroSkin.bytes"
        rp_rel = "assetbundle/resourcepackerinfosetall.assetbundle"
        required_rels = [infos_rel, act_rel, ca_rel, hs_rel, rp_rel]
        if seed["seed_mode"] == "lua_only":
            required_rels.extend(["Thanos/HeroSkin_1.bytes", "Thanos/HeroSkin_2.bytes"])
        for req_rel in required_rels:
            if not provider.has(req_rel):
                raise ModAssetValidationError(f"Thiếu tệp {req_rel!r} trong Resources gốc (tướng {hero_id}).")

        # Nạp metadata: hero_code, heroSkin.bytes (dùng chung), ResSkinSeniorLabelCfg, BattleBank, ResSkinExclusiveBattleEffectCfg
        hero_code = str(hero_id)
        if provider.has("Databin/Client/Actor/hero.bytes"):
            htbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Actor/hero.bytes"), "hero"))
            if htbl:
                for hrid, hrraw in htbl["recs"]:
                    if int(hrid) == hero_id:
                        cm = re.search(rb"Prefab_Hero/(\d+_[A-Za-z0-9_]+)/", hrraw)
                        if cm:
                            hero_code = cm.group(1).decode("utf-8", "ignore")
                        break

        hs_tbl = cp.parse_mses(cp.pg_decrypt(provider.read(hs_rel), "heroSkin"))
        hs_map: dict[int, bytes] = dict(hs_tbl["recs"]) if hs_tbl else {}
        recall_has_custom_icon = bool(
            recall_skin_id in hs_map and b"Skin_Icon_BackToTown" in hs_map[recall_skin_id]
        )
        exclusive_cfg = _parse_exclusive_battle_effects(provider)

        # Tra cứu bảng Senior HD & Sound Bank
        senior_map: dict[int, bytes] = {}
        if provider.has("Databin/Client/Actor/ResSkinSeniorLabelCfg.bytes"):
            stbl = cp.parse_mses(
                cp.pg_decrypt(provider.read("Databin/Client/Actor/ResSkinSeniorLabelCfg.bytes"), "ResSkinSeniorLabelCfg")
            )
            if stbl:
                senior_map = dict(stbl["recs"])

        sound_skins_set: set[int] = set()
        if provider.has("Databin/Client/Sound/BattleBank.bytes"):
            btbl = cp.parse_mses(cp.pg_decrypt(provider.read("Databin/Client/Sound/BattleBank.bytes"), "BattleBank"))
            if btbl:
                for _, rraw in btbl["recs"]:
                    if len(rraw) >= 17:
                        slen = struct.unpack_from("<I", rraw, 8)[0]
                        skin_off = 12 + slen if (1 <= slen <= len(rraw) - 16 and rraw[12 + slen - 1] == 0) else 13
                        sid_val = struct.unpack_from("<I", rraw, skin_off)[0]
                        if 10000 <= sid_val <= 9999999:
                            sound_skins_set.add(int(sid_val))
                            if sid_val >= 1_000_000:
                                sound_skins_set.add(int(sid_val) // 100)

        is_main_hd = source_skin_id in senior_map
        has_custom_sound = enable_sound and (sound_skin_id in sound_skins_set)
        rpack_raw_orig = provider.read(rp_rel)
        rpack_hashes = _extract_hero_rpack_hashes(rpack_raw_orig, hero_id)
        target_skin_ids = (
            [str(hero_id * 100 + i) for i in range(46)]
            if apply_all
            else ([str(s) for s in sorted(skin_mappings.keys())] if is_selective_replace else [str(base_skin_id)])
        )
        mod_mtime, mod_mdate = 0x5800, 0x5B72

        # 2.1. Prefab_Characters/Actor_<H>_Infos.pkg.bytes (Model 3D, Lobby Movie, Camera, Lighting)
        info_entries = cp.parse_in_memory_zip(provider.read(infos_rel))
        new_info_entries: list[tuple[str, int, int, bytes]] = []
        promoted_actor_count = 0
        for ename, mt, md, edata in info_entries:
            if "tutor" not in ename.lower() and ename.lower().endswith("_actorinfo.bytes"):
                stem = os.path.basename(ename.replace("\\", "/")).rsplit(".", 1)[0]
                plain = cp.pg_decrypt(edata, stem)
                promoted = jtcom.promote_skin_in_actorinfo(
                    plain,
                    hero_id=hero_id,
                    source_skin_id=source_skin_id,
                    is_hd_skin=is_main_hd,
                    author_label=watermark_text or "Totorox Mod Studio",
                    apply_to_all_skins=apply_all,
                    skin_mappings=(skin_mappings if is_selective_replace else None),
                    hd_skin_ids=set(senior_map.keys()),
                    rpack_hashes=rpack_hashes,
                )
                enc_info = cp.pg_encrypt(promoted, stem)
                new_info_entries.append((ename, mod_mtime, mod_mdate, enc_info))
                promoted_actor_count += 1
            else:
                new_info_entries.append((ename, mt, md, edata))
        if promoted_actor_count == 0:
            raise ModAssetValidationError(f"Không tìm thấy *_actorinfo.bytes hợp lệ trong {infos_rel}.")
        out_rel_files[infos_rel] = cp.build_in_memory_store_zip(new_info_entries)

        # 2.2. AssetRefs/Hero/<H>_AssetRef.bytes
        aref_rel = f"AssetRefs/Hero/{hero_id}_AssetRef.bytes"
        if provider.has(aref_rel):
            aref_plain = cp.pg_decrypt(provider.read(aref_rel), f"{hero_id}_AssetRef")
            need_aref = enable_skills and (
                any(s != base_skin_id for s in skin_mappings.values())
                if is_selective_replace
                else (source_skin_id != base_skin_id)
            )
            if need_aref:
                aref_plain = jtcom.transform_assetref_paths(
                    aref_plain,
                    hero_id,
                    source_skin_id,
                    is_main_hd,
                    skin_mappings=(skin_mappings if is_selective_replace else None),
                    hd_skin_ids=set(senior_map.keys()),
                    rpack_hashes=rpack_hashes,
                )
            out_rel_files[aref_rel] = cp.pg_encrypt(aref_plain, f"{hero_id}_AssetRef", compress_zstd=True)

        # 2.3. Ages/Prefab_Characters/Prefab_Hero/Actor_<H>_Actions.pkg.bytes
        recall_by_dst = {
            d: slot_skin("recall", default_sid=s)
            for d, s in skin_mappings.items()
        }
        born_by_dst = {
            d: slot_skin("born", default_sid=s)
            for d, s in skin_mappings.items()
        }
        sound_by_dst = {
            d: slot_skin("sound", default_sid=s)
            for d, s in skin_mappings.items()
        }

        act_entries = cp.parse_in_memory_zip(provider.read(act_rel))
        new_act_entries: list[tuple[str, int, int, bytes]] = []
        for ename, mt, md, edata in act_entries:
            fn_norm = ename.replace("\\", "/")
            fn_low = os.path.basename(fn_norm).lower()
            if not fn_low.endswith(".xml"):
                new_act_entries.append((ename, mt, md, edata))
                continue

            stem = os.path.splitext(os.path.basename(fn_norm))[0]
            m_sub_skin = re.match(r"^(\d+)(?:_|t\d|$)", stem, re.IGNORECASE)
            sub_file_sid: int | None = None
            if m_sub_skin and _skin_belongs_to_hero(m_sub_skin.group(1), hero_id):
                cand_fsid = int(m_sub_skin.group(1))
                if cand_fsid != base_skin_id:
                    sub_file_sid = cand_fsid

            if is_selective_replace:
                if "back" in fn_low and not enable_recall:
                    safe_data = _ensure_actor_xml_encrypted_224a(edata, ename, stem)
                    new_act_entries.append((ename, mt, md, safe_data))
                    continue
                if ("born" in fn_low or "sprint" in fn_low or "haste" in fn_low) and not enable_born:
                    safe_data = _ensure_actor_xml_encrypted_224a(edata, ename, stem)
                    new_act_entries.append((ename, mt, md, safe_data))
                    continue

                if "back" in fn_low:
                    dst_map = recall_by_dst
                elif "born" in fn_low or "sprint" in fn_low or "haste" in fn_low:
                    dst_map = born_by_dst
                elif re.match(r"^a(?:\d|p|ex|b\.)", fn_low) or "atk" in fn_low or "attack" in fn_low:
                    dst_map = {d: (slot_skin("normal", "attack", default_sid=s) if enable_skills else base_skin_id) for d, s in skin_mappings.items()}
                elif re.match(r"^s1", fn_low):
                    dst_map = {d: (slot_skin("skill1", "s1", default_sid=s) if enable_skills else base_skin_id) for d, s in skin_mappings.items()}
                elif re.match(r"^s2", fn_low):
                    dst_map = {d: (slot_skin("skill2", "s2", default_sid=s) if enable_skills else base_skin_id) for d, s in skin_mappings.items()}
                elif re.match(r"^(?:s[34]|u\d)", fn_low):
                    dst_map = {d: (slot_skin("skill3", "s3", default_sid=s) if enable_skills else base_skin_id) for d, s in skin_mappings.items()}
                elif re.match(r"^p\d", fn_low) or "passive" in fn_low or "imprint" in fn_low or "mark" in fn_low:
                    dst_map = {d: (slot_skin("passive", default_sid=s) if enable_skills else base_skin_id) for d, s in skin_mappings.items()}
                else:
                    dst_map = {d: (s if enable_skills else base_skin_id) for d, s in skin_mappings.items()}

                if sub_file_sid is not None:
                    dst_map = {d: s for d, s in dst_map.items() if s == sub_file_sid}
                    if not dst_map:
                        safe_data = _ensure_actor_xml_encrypted_224a(edata, ename, stem)
                        new_act_entries.append((ename, mt, md, safe_data))
                        continue

                xml_txt = _decode_aov_xml_bytes(edata, ename, stem).decode("utf-8", errors="ignore")
                updated_xml = _transform_action_xml_selective(
                    xml_txt,
                    hero_id=hero_id,
                    dst_to_src=dst_map,
                    senior_map=senior_map,
                    rewrite_effects=any(v != base_skin_id for v in dst_map.values()),
                    sound_by_dst=sound_by_dst if enable_sound else None,
                    sound_skins_set=sound_skins_set,
                    enable_sound=enable_sound,
                    action_filename=fn_low,
                    rpack_hashes=rpack_hashes,
                )
            else:
                # Phân loại slot kỹ năng để hỗ trợ Mix Chiêu đa skin
                if "back" in fn_low:
                    if not enable_recall:
                        safe_data = _ensure_actor_xml_encrypted_224a(edata, ename, stem)
                        new_act_entries.append((ename, mt, md, safe_data))
                        continue
                    chosen_sid = recall_skin_id
                elif "born" in fn_low or "sprint" in fn_low or "haste" in fn_low:
                    if not enable_born:
                        safe_data = _ensure_actor_xml_encrypted_224a(edata, ename, stem)
                        new_act_entries.append((ename, mt, md, safe_data))
                        continue
                    chosen_sid = born_skin_id
                elif re.match(r"^a(?:\d|p|ex|b\.)", fn_low) or "atk" in fn_low or "attack" in fn_low:
                    chosen_sid = slot_skin("normal", "attack") if enable_skills else base_skin_id
                elif re.match(r"^s1", fn_low):
                    chosen_sid = slot_skin("skill1", "s1") if enable_skills else base_skin_id
                elif re.match(r"^s2", fn_low):
                    chosen_sid = slot_skin("skill2", "s2") if enable_skills else base_skin_id
                elif re.match(r"^(?:s[34]|u\d)", fn_low):
                    chosen_sid = slot_skin("skill3", "s3") if enable_skills else base_skin_id
                elif re.match(r"^p\d", fn_low) or "passive" in fn_low or "imprint" in fn_low or "mark" in fn_low:
                    chosen_sid = slot_skin("passive") if enable_skills else base_skin_id
                else:
                    chosen_sid = source_skin_id if enable_skills else base_skin_id

                if sub_file_sid is not None and sub_file_sid != chosen_sid:
                    safe_data = _ensure_actor_xml_encrypted_224a(edata, ename, stem)
                    new_act_entries.append((ename, mt, md, safe_data))
                    continue

                if (
                    chosen_sid == base_skin_id
                    and not has_custom_sound
                    and source_skin_id == base_skin_id
                    and not mix_raw
                ):
                    safe_data = _ensure_actor_xml_encrypted_224a(edata, ename, stem)
                    new_act_entries.append((ename, mt, md, safe_data))
                    continue

                xml_txt = _decode_aov_xml_bytes(edata, ename, stem).decode("utf-8", errors="ignore")
                updated_xml = _transform_action_xml_for_skin(
                    xml_txt,
                    hero_id=hero_id,
                    active_skin_id=chosen_sid,
                    is_hd_skin=(chosen_sid in senior_map),
                    target_skin_ids=target_skin_ids,
                    rewrite_effects=(chosen_sid != base_skin_id),
                    sound_skin_id=sound_skin_id if enable_sound else None,
                    has_custom_sound=has_custom_sound,
                    action_filename=fn_low,
                    rpack_hashes=rpack_hashes,
                )

            if updated_xml != xml_txt:
                enc_xml = cp.pg_encrypt(updated_xml.encode("utf-8"), stem, compress_zstd=True)
                new_act_entries.append((ename, mod_mtime, mod_mdate, enc_xml))
            else:
                safe_data = _ensure_actor_xml_encrypted_224a(edata, ename, stem)
                new_act_entries.append((ename, mt, md, safe_data))
        out_rel_files[act_rel] = cp.build_in_memory_store_zip(new_act_entries)

        # 2.4. Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes (R1.2 Back.xml, HasteE1.xml, Born.xml, Cam Xa junglemark.xml)
        ca_entries = cp.parse_in_memory_zip(provider.read(ca_rel))
        new_ca_entries: list[tuple[str, int, int, bytes]] = []
        found_junglemark = False
        for ename, mt, md, edata in ca_entries:
            elow = ename.replace("\\", "/").lower()
            xml_txt: str | None = None
            modified = False

            if enable_recall and elow.endswith("commonresource/back.xml"):
                xml_txt = _decode_aov_xml_bytes(edata, ename).decode("utf-8", errors="ignore")
                if is_selective_replace:
                    upd = _apply_recall_back_xml_selective(
                        xml_txt,
                        hero_id=hero_id,
                        hero_code=hero_code,
                        recall_by_dst=recall_by_dst,
                        senior_map=senior_map,
                        hs_map=hs_map,
                        exclusive_cfg=exclusive_cfg,
                        rpack_hashes=rpack_hashes,
                    )
                else:
                    upd = _apply_recall_back_xml(
                        xml_txt,
                        hero_id=hero_id,
                        hero_code=hero_code,
                        recall_skin_id=recall_skin_id,
                        is_recall_hd=(recall_skin_id in senior_map),
                        target_skin_ids=target_skin_ids,
                        recall_has_custom_icon=recall_has_custom_icon,
                        exclusive_cfg=exclusive_cfg,
                        rpack_hashes=rpack_hashes,
                    )
                if upd != xml_txt:
                    xml_txt, modified = upd, True

            if enable_born and elow.endswith(("commonresource/hastee1.xml", "commonresource/hastee1_leave.xml")):
                xml_txt = _decode_aov_xml_bytes(edata, ename).decode("utf-8", errors="ignore")
                if is_selective_replace:
                    upd = _apply_sprint_haste_xml_selective(
                        xml_txt,
                        hero_id=hero_id,
                        hero_code=hero_code,
                        born_by_dst=born_by_dst,
                        senior_map=senior_map,
                        exclusive_cfg=exclusive_cfg,
                    )
                else:
                    upd = _apply_sprint_haste_xml(
                        xml_txt,
                        hero_id=hero_id,
                        hero_code=hero_code,
                        born_skin_id=born_skin_id,
                        is_born_hd=(born_skin_id in senior_map),
                        target_skin_ids=target_skin_ids,
                        exclusive_cfg=exclusive_cfg,
                    )
                if upd != xml_txt:
                    xml_txt, modified = upd, True

            if enable_born and (
                elow.endswith("commonresource/born.xml")
                or elow.endswith("commonresource/dead_born.xml")
                or elow.endswith("commonresource/hastee1_super.xml")
                or elow.endswith("commonresource/dance.xml")
            ):
                xml_txt = _decode_aov_xml_bytes(edata, ename).decode("utf-8", errors="ignore")
                if is_selective_replace:
                    upd = _transform_common_action_xml_selective(xml_txt, hero_id, born_by_dst)
                else:
                    upd = _transform_common_action_xml(xml_txt, hero_id, born_skin_id, target_skin_ids)
                if upd != xml_txt:
                    xml_txt, modified = upd, True

            if elow.endswith("passiveresource/junglemark.xml"):
                found_junglemark = True
                if cam_pct > 0:
                    xml_txt = _decode_aov_xml_bytes(edata, ename).decode("utf-8", errors="ignore")
                    upd_cam = _inject_camera_height_in_junglemark_xml(xml_txt, cam_pct)
                    if upd_cam != xml_txt:
                        xml_txt, modified = upd_cam, True

            if modified and xml_txt is not None:
                new_ca_entries.append((ename, mod_mtime, mod_mdate, xml_txt.encode("utf-8")))
            else:
                new_ca_entries.append((ename, mt, md, edata))
        if cam_pct > 0 and not found_junglemark:
            warnings.append("Không tìm thấy PassiveResource/junglemark.xml để áp dụng Cam Xa.")
        out_rel_files[ca_rel] = cp.build_in_memory_store_zip(new_ca_entries)

        # 2.5. Các bảng Databin MSES: heroSkin, HeroSkinShop, ResSkinSeniorLabelCfg, ResCharacterComponent, ResSkinMotionBaseCfg, skillmark
        # 2.5a. heroSkin.bytes (dùng lại hs_tbl, hs_map đã nạp ở trên)
        if hs_tbl:
            if is_selective_replace:
                base_src_swap = skin_mappings.get(base_skin_id)
                updated_hs = []
                for rid, rraw in hs_tbl["recs"]:
                    if rid in skin_mappings:
                        src_sid_for_rid = skin_mappings[rid]
                        src_rec = hs_map.get(src_sid_for_rid)
                        if src_rec:
                            if rid == src_sid_for_rid:
                                updated_hs.append((rid, rraw))
                            else:
                                updated_hs.append((rid, _clone_heroskin_record(src_rec, rid, src_sid_for_rid, hero_id)))
                        else:
                            warnings.append(f"Không tìm thấy bản ghi skin {src_sid_for_rid} trong heroSkin.bytes.")
                            updated_hs.append((rid, rraw))
                    elif base_src_swap is not None and base_src_swap != base_skin_id and rid == base_src_swap:
                        b_self = bytearray(rraw)
                        if len(b_self) >= 40:
                            struct.pack_into("<I", b_self, 36, 0)
                        updated_hs.append((rid, bytes(b_self)))
                    else:
                        updated_hs.append((rid, rraw))
                hs_tbl["recs"] = updated_hs
                out_rel_files[hs_rel] = cp.pg_encrypt(cp.serialize_mses(hs_tbl), "heroSkin")
            else:
                src_hs_rec = hs_map.get(source_skin_id)
                if src_hs_rec:
                    updated_hs: list[tuple[int, bytes]] = []
                    for rid, rraw in hs_tbl["recs"]:
                        if len(rraw) >= 12 and struct.unpack_from("<I", rraw, 8)[0] == hero_id:
                            if apply_all or rid == base_skin_id:
                                if rid == source_skin_id:
                                    b_self = bytearray(rraw)
                                    if len(b_self) >= 40:
                                        struct.pack_into("<I", b_self, 36, 0)
                                    updated_hs.append((rid, bytes(b_self)))
                                else:
                                    updated_hs.append((rid, _clone_heroskin_record(src_hs_rec, rid, source_skin_id, hero_id)))
                            else:
                                updated_hs.append((rid, rraw))
                        else:
                            updated_hs.append((rid, rraw))
                    hs_tbl["recs"] = updated_hs
                    out_rel_files[hs_rel] = cp.pg_encrypt(cp.serialize_mses(hs_tbl), "heroSkin")
                else:
                    warnings.append(f"Không tìm thấy bản ghi skin {source_skin_id} trong heroSkin.bytes.")

        # 2.5b. HeroSkinShop.bytes
        shop_rel = "Databin/Client/Shop/HeroSkinShop.bytes"
        if provider.has(shop_rel):
            sh_tbl = cp.parse_mses(cp.pg_decrypt(provider.read(shop_rel), "HeroSkinShop"))
            if sh_tbl:
                sh_map = dict(sh_tbl["recs"])
                if is_selective_replace:
                    updated_sh: list[tuple[int, bytes]] = []
                    for rid, rraw in sh_tbl["recs"]:
                        if rid in skin_mappings and rid != skin_mappings[rid]:
                            src_sh_rec = sh_map.get(skin_mappings[rid])
                            if src_sh_rec:
                                buf_sh = bytearray(src_sh_rec)
                                struct.pack_into("<II", buf_sh, 0, len(buf_sh) - 4, int(rid))
                                if len(buf_sh) >= 40:
                                    struct.pack_into("<I", buf_sh, 36, max(0, rid - hero_id * 100))
                                updated_sh.append((rid, bytes(buf_sh)))
                                continue
                        updated_sh.append((rid, rraw))
                    sh_tbl["recs"] = updated_sh
                    out_rel_files[shop_rel] = cp.pg_encrypt(cp.serialize_mses(sh_tbl), "HeroSkinShop")
                else:
                    src_sh_rec = sh_map.get(source_skin_id)
                    if src_sh_rec:
                        updated_sh = []
                        for rid, rraw in sh_tbl["recs"]:
                            if rid != source_skin_id and len(rraw) >= 12 and struct.unpack_from("<I", rraw, 8)[0] == hero_id:
                                if apply_all or rid == base_skin_id:
                                    buf_sh = bytearray(src_sh_rec)
                                    struct.pack_into("<II", buf_sh, 0, len(buf_sh) - 4, int(rid))
                                    if len(buf_sh) >= 40:
                                        struct.pack_into("<I", buf_sh, 36, max(0, rid - hero_id * 100))
                                    updated_sh.append((rid, bytes(buf_sh)))
                                    continue
                            updated_sh.append((rid, rraw))
                        sh_tbl["recs"] = updated_sh
                        out_rel_files[shop_rel] = cp.pg_encrypt(cp.serialize_mses(sh_tbl), "HeroSkinShop")

        # 2.5c. ResSkinSeniorLabelCfg.bytes (nếu skin đích là Huy Hoàng / Chí Tôn _HD)
        sen_rel = "Databin/Client/Actor/ResSkinSeniorLabelCfg.bytes"
        if provider.has(sen_rel):
            sen_tbl = cp.parse_mses(cp.pg_decrypt(provider.read(sen_rel), "ResSkinSeniorLabelCfg"))
            if sen_tbl:
                if is_selective_replace:
                    replaced_sen_set = set(skin_mappings.keys())
                    kept_sen = [(rid, r) for rid, r in sen_tbl["recs"] if int(rid) not in replaced_sen_set]
                    for dst_sid, src_sid in sorted(skin_mappings.items()):
                        if src_sid in senior_map:
                            b_sen = bytearray(senior_map[src_sid])
                            struct.pack_into("<II", b_sen, 0, len(b_sen) - 4, int(dst_sid))
                            kept_sen.append((int(dst_sid), bytes(b_sen)))
                    sen_tbl["recs"] = kept_sen
                elif is_main_hd and source_skin_id in senior_map:
                    src_sen = senior_map[source_skin_id]
                    kept_sen = [(rid, r) for rid, r in sen_tbl["recs"] if not _skin_belongs_to_hero(str(rid), hero_id)]
                    for tid_str in target_skin_ids:
                        tid = int(tid_str)
                        b_sen = bytearray(src_sen)
                        struct.pack_into("<II", b_sen, 0, len(b_sen) - 4, tid)
                        kept_sen.append((tid, bytes(b_sen)))
                    sen_tbl["recs"] = kept_sen
                out_rel_files[sen_rel] = cp.pg_encrypt(cp.serialize_mses(sen_tbl), "ResSkinSeniorLabelCfg")

        # 2.5d. ResCharacterComponent.bytes
        comp_rel = "Databin/Client/Character/ResCharacterComponent.bytes"
        if provider.has(comp_rel):
            comp_tbl = cp.parse_mses(cp.pg_decrypt(provider.read(comp_rel), "ResCharacterComponent"))
            if comp_tbl:
                if is_selective_replace:
                    comp_by_skin: dict[int, list[tuple[int, bytes]]] = {}
                    for rid, rraw in comp_tbl["recs"]:
                        sid_of_comp = int(rid) // 100
                        if base_skin_id <= sid_of_comp < (hero_id + 1) * 100:
                            comp_by_skin.setdefault(sid_of_comp, []).append((int(rid), rraw))
                    replaced_cset = set(skin_mappings.keys())
                    new_comp = [
                        (rid, rraw)
                        for rid, rraw in comp_tbl["recs"]
                        if (int(rid) // 100) not in replaced_cset
                    ]
                    for dst_sid, src_sid in sorted(skin_mappings.items()):
                        if dst_sid == src_sid:
                            for orig_rid, orig_raw in comp_by_skin.get(src_sid, []):
                                new_comp.append((orig_rid, orig_raw))
                            continue
                        for orig_rid, orig_raw in comp_by_skin.get(src_sid, []):
                            new_rid = dst_sid * 100 + (orig_rid % 100)
                            buf_c = bytearray(orig_raw)
                            struct.pack_into("<I", buf_c, 4, new_rid)
                            new_comp.append((new_rid, bytes(buf_c)))
                    comp_tbl["recs"] = new_comp
                else:
                    hp = str(hero_id)
                    sp = str(source_skin_id)
                    comp_tbl["recs"] = [
                        (rid, rraw)
                        for rid, rraw in comp_tbl["recs"]
                        if not str(rid).startswith(hp) or str(rid).startswith(sp)
                    ]
                out_rel_files[comp_rel] = cp.pg_encrypt(cp.serialize_mses(comp_tbl), "ResCharacterComponent")

        # 2.5e. ResSkinMotionBaseCfg.bytes
        mot_rel = "Databin/Client/Motion/ResSkinMotionBaseCfg.bytes"
        if provider.has(mot_rel):
            mot_tbl = cp.parse_mses(cp.pg_decrypt(provider.read(mot_rel), "ResSkinMotionBaseCfg"))
            if mot_tbl:
                mot_map = dict(mot_tbl["recs"])
                if is_selective_replace:
                    new_mots: list[tuple[int, bytes]] = []
                    for rid, rraw in mot_tbl["recs"]:
                        sid_of_mot = int(rid) // 100
                        if sid_of_mot in skin_mappings and len(rraw) >= 25:
                            src_mot = mot_map.get(skin_mappings[sid_of_mot] * 100 + 1)
                            if src_mot and len(src_mot) >= 25:
                                target_motion_u16 = struct.unpack_from("<H", src_mot, 21)[0]
                                mb = bytearray(rraw)
                                for m_off in range(21, len(mb) - 16, 29):
                                    if mb[m_off] != 0 or mb[m_off + 1] != 0:
                                        struct.pack_into("<H", mb, m_off, target_motion_u16)
                                new_mots.append((rid, bytes(mb)))
                                continue
                        new_mots.append((rid, rraw))
                    mot_tbl["recs"] = new_mots
                else:
                    src_mot = mot_map.get(source_skin_id * 100 + 1)
                    if src_mot and len(src_mot) >= 25:
                        target_motion_u16 = struct.unpack_from("<H", src_mot, 21)[0]
                        hp = str(hero_id)
                        new_mots = []
                        for rid, rraw in mot_tbl["recs"]:
                            if str(rid).startswith(hp) and len(rraw) >= 25:
                                mb = bytearray(rraw)
                                # Mỗi cụm cử động trong ResSkinMotionBaseCfg cách nhau 29 byte từ offset 21
                                for m_off in range(21, len(mb) - 16, 29):
                                    if mb[m_off] != 0 or mb[m_off + 1] != 0:
                                        struct.pack_into("<H", mb, m_off, target_motion_u16)
                                new_mots.append((rid, bytes(mb)))
                            else:
                                new_mots.append((rid, rraw))
                        mot_tbl["recs"] = new_mots
                out_rel_files[mot_rel] = cp.pg_encrypt(cp.serialize_mses(mot_tbl), "ResSkinMotionBaseCfg")

        # 2.5f. skillmark.bytes
        smark_rel = "Databin/Client/Skill/skillmark.bytes"
        if enable_skills and provider.has(smark_rel):
            sm_tbl = cp.parse_mses(cp.pg_decrypt(provider.read(smark_rel), "skillmark"))
            if sm_tbl:
                def _rewrite_skillmark_rec(buf_bytes: bytes, passive_sid_target: int) -> bytes:
                    out_b = bytearray()
                    pos = 8
                    out_b.extend(buf_bytes[:8])
                    n = len(buf_bytes)
                    while pos < n:
                        if pos + 5 <= n:
                            slen = struct.unpack_from("<I", buf_bytes, pos)[0]
                            if 10 <= slen <= 180 and pos + 4 + slen <= n and buf_bytes[pos + 4 + slen - 1] == 0:
                                raw_s = buf_bytes[pos + 4 : pos + 4 + slen - 1]
                                if b"hero_skill_effects/" in raw_s.lower():
                                    old_s = raw_s.decode("utf-8", errors="ignore")
                                    new_s = jtcom.rewrite_hero_effect_path(
                                        old_s, hero_id, passive_sid_target, passive_sid_target in senior_map,
                                        rpack_hashes=rpack_hashes,
                                    )
                                    if (passive_sid_target in senior_map) and new_s.endswith("_HD"):
                                        new_s = new_s[:-3] + "_hd"
                                    nb = new_s.encode("utf-8") + b"\x00"
                                    out_b.extend(struct.pack("<I", len(nb)) + nb)
                                    pos += 4 + slen
                                    continue
                        out_b.append(buf_bytes[pos])
                        pos += 1
                    struct.pack_into("<I", out_b, 0, len(out_b) - 4)
                    return bytes(out_b)

                if is_selective_replace:
                    passive_by_dst = {
                        d: slot_skin("passive", default_sid=s)
                        for d, s in skin_mappings.items()
                    }
                    new_sm: list[tuple[int, bytes]] = []
                    sm_by_rid = {int(r): b for r, b in sm_tbl["recs"]}
                    for rid, rraw in sm_tbl["recs"]:
                        if int(rid) in passive_by_dst:
                            new_sm.append((rid, _rewrite_skillmark_rec(rraw, passive_by_dst[int(rid)])))
                        else:
                            new_sm.append((rid, rraw))
                    base_sm_rec = sm_by_rid.get(base_skin_id)
                    if base_sm_rec is not None:
                        for dst_sid, p_src in sorted(passive_by_dst.items()):
                            if dst_sid not in sm_by_rid:
                                clone_sm = bytearray(_rewrite_skillmark_rec(base_sm_rec, p_src))
                                struct.pack_into("<I", clone_sm, 4, int(dst_sid))
                                new_sm.append((int(dst_sid), bytes(clone_sm)))
                    sm_tbl["recs"] = new_sm
                else:
                    passive_sid = slot_skin("passive")
                    new_sm = []
                    for rid, rraw in sm_tbl["recs"]:
                        if str(rid).startswith(str(hero_id)):
                            new_sm.append((rid, _rewrite_skillmark_rec(rraw, passive_sid)))
                        else:
                            new_sm.append((rid, rraw))
                    sm_tbl["recs"] = new_sm
                out_rel_files[smark_rel] = cp.pg_encrypt(cp.serialize_mses(sm_tbl), "skillmark")

        # 2.6. Các bảng Âm thanh & Giọng nói Wwise (khi bật `enable_sound`)
        need_sound_remap = (
            enable_sound
            and (
                any(v != base_skin_id for v in sound_by_dst.values())
                if is_selective_replace
                else (sound_skin_id != base_skin_id)
            )
        )
        if need_sound_remap:
            for snd_rel in (
                "Databin/Client/Sound/BattleBank.bytes",
                "Databin/Client/Sound/LobbyBank.bytes",
                "Databin/Client/Sound/HeroSound.bytes",
                "Databin/Client/Sound/ChatSound.bytes",
                "Databin/Client/Sound/LobbySound.bytes",
                "Databin/Client/Sound/CoupleSound.bytes",
            ):
                if provider.has(snd_rel):
                    stem = os.path.basename(snd_rel).rsplit(".", 1)[0]
                    plain = cp.pg_decrypt(provider.read(snd_rel), stem)
                    if is_selective_replace:
                        remapped = _remap_sound_table_selective(plain, stem, hero_id, sound_by_dst)
                    else:
                        remapped = _remap_sound_table_for_hero(plain, stem, hero_id, sound_skin_id, base_skin_id)
                    out_rel_files[snd_rel] = cp.pg_encrypt(remapped, stem)

        # 2.7. Thanos HeroSkin_1..4 (Lua-only: giữ nguyên file gốc chuẩn bản build; vanhoc: patch skin & MD5)
        if seed["seed_mode"] == "vanhoc":
            hs1_skin = skin_mappings.get(base_skin_id, source_skin_id) if is_selective_replace else source_skin_id
            out_rel_files["Thanos/HeroSkin_1.bytes"] = _patch_hs1_single(
                seed["HeroSkin_1.dec"], hero_id, hs1_skin, pkg_md5s
            )
            out_rel_files["Thanos/HeroSkin_2.bytes"] = _patch_hs2_single(
                seed["HeroSkin_2.dec"], hero_id, pbtn_id, knotify_id, pkg_md5s
            )
            for th_extra in ("Thanos/HeroSkin_3.bytes", "Thanos/HeroSkin_4.bytes"):
                if provider.has(th_extra):
                    out_rel_files[th_extra] = provider.read(th_extra)
        else:
            for th_rel in (
                "Thanos/HeroSkin_1.bytes",
                "Thanos/HeroSkin_2.bytes",
                "Thanos/HeroSkin_3.bytes",
                "Thanos/HeroSkin_4.bytes",
            ):
                if provider.has(th_rel):
                    out_rel_files[th_rel] = provider.read(th_rel)

        # 2.8. ResourcePackerInfoSetAll & ResourceVerificationInfoSetAll
        out_rel_files[rp_rel] = _patch_rpack_for_hero_battle_skins(rpack_raw_orig, hero_id)
        rv_rel = "assetbundle/resourceverificationinfosetall.assetbundle"
        if provider.has(rv_rel):
            out_rel_files[rv_rel] = provider.read(rv_rel)

        # 2.8b. ResBillboardSkinCfg.bytes: gắn skin bị đè vào bản ghi thông báo hạ gục của skin nguồn
        bbs_rel = "Databin/Client/Huanhua/ResBillboardSkinCfg.bytes"
        if enable_billboard and provider.has(bbs_rel):
            bbs_tbl = cp.parse_mses(cp.pg_decrypt(provider.read(bbs_rel), "ResBillboardSkinCfg"))
            if bbs_tbl:
                if is_selective_replace:
                    add_by_src: dict[int, list[int]] = {}
                    for d, s in skin_mappings.items():
                        if d != s:
                            add_by_src.setdefault(s, []).append(d)
                else:
                    add_by_src = {source_skin_id: [int(t) for t in target_skin_ids if int(t) != source_skin_id]}
                bbs_changed = False
                new_bbs: list[tuple[int, bytes]] = []
                for rid, rraw in bbs_tbl["recs"]:
                    if len(rraw) >= 16:
                        cnt = struct.unpack_from("<I", rraw, 8)[0]
                        if 0 < cnt <= 256 and len(rraw) >= 12 + cnt * 4:
                            sids = list(struct.unpack_from(f"<{cnt}I", rraw, 12))
                            extra_d: list[int] = []
                            if knotify_id and not is_selective_replace and int(rid) == knotify_id:
                                extra_d = add_by_src.get(source_skin_id, [])
                            else:
                                for s_src, dl in add_by_src.items():
                                    if s_src in sids:
                                        extra_d.extend(dl)
                            merged = sids + [x for x in dict.fromkeys(extra_d) if x not in sids]
                            if merged != sids:
                                tail = rraw[12 + cnt * 4 :]
                                body = struct.pack("<II", int(rid), len(merged)) + struct.pack(f"<{len(merged)}I", *merged) + tail
                                rraw = struct.pack("<I", len(body)) + body
                                bbs_changed = True
                    new_bbs.append((rid, rraw))
                if bbs_changed:
                    bbs_tbl["recs"] = new_bbs
                    out_rel_files[bbs_rel] = cp.pg_encrypt(cp.serialize_mses(bbs_tbl), "ResBillboardSkinCfg")

        # 2.8c. ResPersonalButtonCfg.bytes: sao chép & gán skin_id cho mọi skin bị đè để nút bấm cá nhân kích hoạt đồng nhất
        pbtn_rel = "Databin/Client/Huanhua/ResPersonalButtonCfg.bytes"
        if enable_button and provider.has(pbtn_rel):
            pbtn_tbl = cp.parse_mses(cp.pg_decrypt(provider.read(pbtn_rel), "ResPersonalButtonCfg"))
            if pbtn_tbl:
                if is_selective_replace:
                    pbtn_dst_to_src = {int(d): int(s) for d, s in skin_mappings.items() if int(d) != int(s)}
                elif pbtn_id > 0:
                    pbtn_dst_to_src = {
                        int(t): int(source_skin_id)
                        for t in target_skin_ids
                        if int(t) != int(source_skin_id)
                    }
                else:
                    pbtn_dst_to_src = {}

                if pbtn_dst_to_src:
                    recs_list = list(pbtn_tbl["recs"])
                    by_rid = {int(rid): rraw for rid, rraw in recs_list}
                    by_sid: dict[int, tuple[int, int, bytes]] = {}
                    for idx_r, (rid, rraw) in enumerate(recs_list):
                        if len(rraw) >= 12:
                            sid_val = struct.unpack_from("<I", rraw, 8)[0]
                            by_sid[int(sid_val)] = (idx_r, int(rid), rraw)
                    max_rid = max((int(rid) for rid, _ in recs_list), default=0)
                    pbtn_changed = False
                    for dst_sid, src_sid in sorted(pbtn_dst_to_src.items()):
                        tpl_raw: bytes | None = None
                        if src_sid == source_skin_id and pbtn_id > 0 and pbtn_id in by_rid:
                            tpl_raw = by_rid[pbtn_id]
                        elif src_sid in by_sid:
                            tpl_raw = by_sid[src_sid][2]
                        elif pbtn_id > 0 and pbtn_id in by_rid:
                            tpl_raw = by_rid[pbtn_id]
                        if not tpl_raw or len(tpl_raw) < 12:
                            continue
                        if dst_sid in by_sid:
                            exist_idx, exist_rid, _ = by_sid[dst_sid]
                            buf_pb = bytearray(tpl_raw)
                            struct.pack_into("<III", buf_pb, 0, len(buf_pb) - 4, int(exist_rid), int(dst_sid))
                            new_rec_b = bytes(buf_pb)
                            recs_list[exist_idx] = (int(exist_rid), new_rec_b)
                            by_sid[dst_sid] = (exist_idx, int(exist_rid), new_rec_b)
                            pbtn_changed = True
                        else:
                            max_rid += 1
                            buf_pb = bytearray(tpl_raw)
                            struct.pack_into("<III", buf_pb, 0, len(buf_pb) - 4, int(max_rid), int(dst_sid))
                            new_rec_b = bytes(buf_pb)
                            recs_list.append((int(max_rid), new_rec_b))
                            by_sid[dst_sid] = (len(recs_list) - 1, int(max_rid), new_rec_b)
                            pbtn_changed = True
                    if pbtn_changed:
                        pbtn_tbl["recs"] = recs_list
                out_rel_files[pbtn_rel] = cp.pg_encrypt(cp.serialize_mses(pbtn_tbl), "ResPersonalButtonCfg")

        # 2.9. Watermark trong languageMap.txt (nếu bật)
        lang_rel = "Languages/VN_Garena_VN/languageMap.txt"
        if watermark_text and provider.has(lang_rel):
            raw_lang = provider.read(lang_rel)
            plain_lang = _decode_text_resource(raw_lang).encode("utf-8")
            wm_line = f"Tip_WaterMark_Str = {watermark_text}".encode("utf-8")
            patched_lang, cnt = cp._TIP_WATERMARK_RE.subn(lambda m: m.group(1) + wm_line, plain_lang, count=1)
            if cnt == 0:
                patched_lang = plain_lang + b"\r\n" + wm_line
            out_rel_files[lang_rel] = patched_lang

        if is_selective_replace:
            sorted_dsts = sorted(skin_mappings.keys())
            if len(sorted_dsts) == 1:
                only_d = sorted_dsts[0]
                base_label = f"Totorox_Hero{hero_id}_{only_d}_to_{skin_mappings[only_d]}"
            else:
                base_label = f"Totorox_Hero{hero_id}_{len(sorted_dsts)}skins_Skin{source_skin_id}"
        else:
            base_label = f"Totorox_Hero{hero_id}_Skin{source_skin_id}"
        summary = {
            "mode": "skin",
            "seed_mode": seed["seed_mode"],
            "hero_id": hero_id,
            "hero_code": hero_code,
            "source_skin_id": source_skin_id,
            "target_skin_id": source_skin_id,
            "apply_to_all_skins": apply_all,
            "is_selective_replace": is_selective_replace,
            "replace_skin_ids": sorted(skin_mappings.keys()) if is_selective_replace else [],
            "skin_mappings": {str(k): v for k, v in sorted(skin_mappings.items())} if is_selective_replace else {},
            "is_mix": is_mix,
            "enable_skills": enable_skills,
            "enable_recall": enable_recall,
            "enable_born": enable_born,
            "enable_sound": enable_sound,
            "personal_button_id": pbtn_id,
            "kill_notify_id": knotify_id,
            "billboard_id": knotify_id,
            "camera_percent": cam_pct,
            "output_format": output_format,
        }
        return SkinModBuilder._finalize_package(
            out_rel_files,
            ver,
            base_label,
            options.get("custom_filename"),
            output_format,
            password,
            t0,
            output_dir=output_dir,
            summary=summary,
            warnings=warnings,
        )

    @staticmethod
    def build_batch_mods(
        provider: BaseResourceProvider,
        options: dict[str, Any],
    ) -> dict[str, Any]:
        """
        Tạo mod hàng loạt cho nhiều tướng hoặc nhiều cặp `Skin bị đè -> Skin nguồn`:
          - `merge_output=True` (khuyên dùng): Tự gom nhóm các cặp cùng tướng (tránh đè mất nhau) rồi gộp chung thành 1 gói cài đặt duy nhất (`.zip`/`.3105`).
          - `merge_output=False`: Xuất từng gói mod độc lập tương ứng với từng dòng tác vụ.
        """
        t0 = time.time()
        raw_items = options.get("items")
        if isinstance(raw_items, str):
            raw_items = json.loads(raw_items.strip()) if raw_items.strip() else []
        if not isinstance(raw_items, list) or not raw_items:
            raise ValueError("Danh sách mod hàng loạt (items) đang rỗng.")

        merge_output = bool(options.get("merge_output", True))
        output_format = str(options.get("output_format") or "zip").strip().lower().lstrip(".")
        password = str(options.get("password") or "").strip() or None
        watermark_text = str(options.get("watermark_text") or "").strip()
        custom_filename = str(options.get("custom_filename") or "").strip() or None
        output_dir = str(options.get("output_dir") or "").strip() or OUTPUT_DIR
        default_cam = float(options.get("camera_percent") or 0.0)
        allow_seed_mismatch = bool(options.get("allow_seed_mismatch", False))

        if not merge_output:
            built_items: list[dict[str, Any]] = []
            for idx, item in enumerate(raw_items):
                if not isinstance(item, dict):
                    raise ValueError(f"Mục hàng loạt thứ {idx + 1} không hợp lệ.")
                item_opts = dict(item)
                item_opts["mode"] = "skin"
                item_opts["output_dir"] = output_dir
                item_opts["output_format"] = output_format
                if password and not item_opts.get("password"):
                    item_opts["password"] = password
                if watermark_text and "watermark_text" not in item_opts:
                    item_opts["watermark_text"] = watermark_text
                if "camera_percent" not in item_opts:
                    item_opts["camera_percent"] = default_cam
                if allow_seed_mismatch:
                    item_opts["allow_seed_mismatch"] = True
                res = SkinModBuilder.build_mod(provider, item_opts)
                built_items.append(res)
            return {
                "ok": True,
                "mode": "batch",
                "merge_output": False,
                "item_count": len(built_items),
                "hero_count": len({int(r["summary"]["hero_id"]) for r in built_items if r.get("summary")}),
                "filename": built_items[-1]["filename"],
                "output_path": built_items[-1]["output_path"],
                "size_bytes": sum(int(r.get("size_bytes") or 0) for r in built_items),
                "results": built_items,
                "elapsed_ms": int((time.time() - t0) * 1000),
            }

        # merge_output=True: Gom nhóm theo hero_id để các cặp cùng tướng (VD 13101->13118 & 13102->13115)
        # được biên dịch cùng nhau trong 1 lần build, không bị run_merge đè mất cặp trước.
        grouped: dict[int, dict[str, Any]] = {}
        for idx, item in enumerate(raw_items):
            if not isinstance(item, dict):
                raise ValueError(f"Mục hàng loạt thứ {idx + 1} không hợp lệ.")
            hid = int(item.get("hero_id") or 0)
            if hid <= 0:
                raise ValueError(f"Mục hàng loạt thứ {idx + 1} thiếu hero_id hợp lệ.")
            src_sid, item_map, item_apply_all, item_sel = _resolve_skin_override_plan(item, hid)
            if hid not in grouped:
                grp_opts = dict(item)
                grp_opts["mode"] = "skin"
                grp_opts["source_skin_id"] = src_sid
                grp_opts.pop("target_skin_id", None)
                grp_opts.pop("replace_skin_ids", None)
                if item_sel or not item_apply_all:
                    grp_opts["skin_mappings"] = dict(item_map)
                    grp_opts["apply_to_all_skins"] = False
                else:
                    grp_opts["apply_to_all_skins"] = True
                    grp_opts.pop("skin_mappings", None)
                if "camera_percent" not in grp_opts:
                    grp_opts["camera_percent"] = default_cam
                if watermark_text:
                    grp_opts["watermark_text"] = watermark_text
                if allow_seed_mismatch:
                    grp_opts["allow_seed_mismatch"] = True
                grouped[hid] = grp_opts
            else:
                g = grouped[hid]
                prev_map = g.get("skin_mappings")
                if prev_map is None and g.get("apply_to_all_skins", True):
                    prev_src = int(g["source_skin_id"])
                    prev_map = {hid * 100 + i: prev_src for i in range(46)}
                elif prev_map is None:
                    prev_map = {hid * 100: int(g["source_skin_id"])}
                merged_map = dict(prev_map)
                merged_map.update(item_map)
                g["skin_mappings"] = merged_map
                g["apply_to_all_skins"] = False
                g["camera_percent"] = max(float(g.get("camera_percent") or 0.0), float(item.get("camera_percent") or default_cam))

        group_list = list(grouped.values())
        if len(group_list) == 1:
            only_opts = dict(group_list[0])
            only_opts["output_dir"] = output_dir
            only_opts["output_format"] = output_format
            only_opts["password"] = password
            if custom_filename:
                only_opts["custom_filename"] = custom_filename
            if watermark_text:
                only_opts["watermark_text"] = watermark_text
            res_single = SkinModBuilder.build_mod(provider, only_opts)
            return {
                **res_single,
                "mode": "batch",
                "merge_output": True,
                "item_count": len(raw_items),
                "hero_count": 1,
                "results": [res_single],
            }

        # Nhiều tướng -> build từng tướng vào thư mục tạm rồi merge chung sạch sẽ
        built_parts: list[dict[str, Any]] = []
        with tempfile.TemporaryDirectory(prefix="totorox_batch_") as tmp_dir:
            for hid, g_opts in grouped.items():
                part_opts = dict(g_opts)
                part_opts["output_dir"] = tmp_dir
                part_opts["output_format"] = "zip"
                part_opts["password"] = None
                part_opts["custom_filename"] = f"batch_hero_{hid}"
                part_res = SkinModBuilder.build_mod(provider, part_opts)
                built_parts.append(part_res)

            default_stem = f"Totorox_Batch_{len(grouped)}Tuong_{len(raw_items)}Skin"
            merged_res = OfflineMergerAndConverter.merge_mods(
                [p["output_path"] for p in built_parts],
                output_dir=output_dir,
                output_name=custom_filename or default_stem,
                watermark_text=watermark_text or None,
                output_format=output_format,
                password=password,
            )

        return {
            "ok": True,
            "mode": "batch",
            "merge_output": True,
            "item_count": len(raw_items),
            "hero_count": len(grouped),
            "filename": merged_res["filename"],
            "output_path": merged_res["output_path"],
            "size_bytes": merged_res["size_bytes"],
            "elapsed_ms": int((time.time() - t0) * 1000),
            "parts": [{"hero_id": p["summary"]["hero_id"], "summary": p["summary"]} for p in built_parts],
            "merge_plan": merged_res.get("merge_plan"),
        }

    @staticmethod
    def _finalize_package(
        out_rel_files: dict[str, bytes],
        ver: str,
        default_stem: str,
        custom_filename: str | None,
        output_format: str,
        password: str | None,
        t0: float,
        *,
        output_dir: str | None = None,
        summary: dict[str, Any] | None = None,
        warnings: list[str] | None = None,
    ) -> dict[str, Any]:
        # Kiểm tra đầu ra bắt buộc trước khi ghi đĩa để không xuất gói mod hỏng
        required_out = ["version.txt", "KernelLua.pkg.bytes", "StableSystems_3.pkg.bytes"]
        if summary and summary.get("mode") == "skin":
            hid = int(summary["hero_id"])
            required_out.extend([
                f"Prefab_Characters/Actor_{hid}_Infos.pkg.bytes",
                f"Ages/Prefab_Characters/Prefab_Hero/Actor_{hid}_Actions.pkg.bytes",
                "assetbundle/resourcepackerinfosetall.assetbundle",
                "Thanos/HeroSkin_1.bytes",
                "Thanos/HeroSkin_2.bytes",
            ])
        elif summary and summary.get("mode") == "camera_only":
            required_out.append("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        for req_path in required_out:
            blob = out_rel_files.get(req_path)
            if not blob:
                raise RuntimeError(f"Thiếu hoặc rỗng tệp bắt buộc trước khi đóng gói: {req_path}")

        # Làm sạch tên file đầu ra an toàn với Windows
        stem = _sanitize_output_stem(custom_filename, default_stem)

        # Đóng gói ZIP chuẩn Resources/<ver>/... (mọi .pkg.bytes bên trong đã ở trạng thái STORE=0)
        zip_buf = io.BytesIO()
        with zipfile.ZipFile(zip_buf, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for rel_path in sorted(out_rel_files.keys()):
                arc_path = f"Resources/{ver}/{rel_path}"
                zf.writestr(arc_path, out_rel_files[rel_path])
        zip_bytes = zip_buf.getvalue()

        if output_format == "3105":
            final_bytes = _encode_zip_to_3105(zip_bytes, stem, password=password)
            final_name = f"{stem}.3105"
        else:
            final_bytes = zip_bytes
            final_name = f"{stem}.zip"

        target_dir = os.path.abspath(output_dir) if output_dir else OUTPUT_DIR
        os.makedirs(target_dir, exist_ok=True)
        out_path = os.path.join(target_dir, final_name)
        with open(out_path, "wb") as f:
            f.write(final_bytes)

        return {
            "filename": final_name,
            "output_path": out_path,
            "size_bytes": len(final_bytes),
            "file_count": len(out_rel_files),
            "game_version": ver,
            "elapsed_ms": int((time.time() - t0) * 1000),
            "files": sorted(out_rel_files.keys()),
            "summary": summary or {},
            "warnings": list(warnings or []),
        }


# ---------------------------------------------------------------------------
# 3. `BinaryInspector` — Giải mã `0x224A`, xem/sửa `MSES`, `AGE XML`, `JTCom`, `.pkg.bytes`
# ---------------------------------------------------------------------------

_TRACK_SPAN_RE = re.compile(r"<Track\b[\s>].*?</Track>", re.DOTALL)
_TRACK_SKIN_TAG_RE = re.compile(r"<SkinOrAvatarList\b[^>]*/>")
_SKIN_ID_ARRAY_BLOCK_RE = re.compile(r'(<Array\s+name="skinIdArray"[^>]*>)(.*?)(</Array>)', re.DOTALL | re.IGNORECASE)
_OS_JUNK_NAMES = {".ds_store", "thumbs.db", "desktop.ini"}


def _xml_attr_escape(val: str) -> str:
    return (
        str(val)
        .replace("&", "&amp;")
        .replace('"', "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def _set_track_open_attr(track_raw: str, attr_name: str, attr_val: str | None) -> str:
    fe = track_raw.find(">")
    if fe < 0:
        return track_raw
    head = track_raw[:fe]
    tail = track_raw[fe:]
    pat = re.compile(rf'\s+{re.escape(attr_name)}="[^"]*"')
    if attr_val is None or attr_val == "":
        new_head = pat.sub("", head)
        return new_head + tail
    esc = _xml_attr_escape(attr_val)
    if pat.search(head):
        new_head = pat.sub(f' {attr_name}="{esc}"', head, count=1)
    else:
        new_head = f'{head} {attr_name}="{esc}"'
    return new_head + tail


def _replace_track_skins_preserving_eol(track_raw: str, new_ids: list[str]) -> str:
    eol = "\r\n" if "\r\n" in track_raw else "\n"
    multiline = "\n" in track_raw
    if not new_ids:
        if multiline:
            cleaned = re.sub(r"(?:\r?\n)?[ \t]*<SkinOrAvatarList\b[^>]*/>", "", track_raw)
            return cleaned
        return _TRACK_SKIN_TAG_RE.sub("", track_raw)

    if "<SkinOrAvatarList" in track_raw:
        first = track_raw.find("<SkinOrAvatarList")
        line_start = track_raw.rfind("\n", 0, first)
        indent = "      "
        if line_start >= 0:
            raw_indent = track_raw[line_start + 1 : first]
            if raw_indent.strip() == "":
                indent = raw_indent
        sep = f"{eol}{indent}" if multiline else ""
        block = sep.join(f'<SkinOrAvatarList id="{_xml_attr_escape(str(s))}" />' for s in new_ids)
        parts: list[str] = []
        pos = 0
        inserted = False
        while True:
            ts = track_raw.find("<SkinOrAvatarList", pos)
            if ts < 0:
                break
            te = track_raw.find("/>", ts)
            if te < 0:
                break
            te += 2
            if not inserted:
                parts.append(track_raw[pos:ts])
                parts.append(block)
                inserted = True
            else:
                between = track_raw[pos:ts]
                if not between.isspace() and between != "":
                    parts.append(between)
            pos = te
        parts.append(track_raw[pos:])
        return "".join(parts)

    ct = track_raw.rfind("</Track>")
    if ct < 0:
        return track_raw
    if not multiline:
        block = "".join(f'<SkinOrAvatarList id="{_xml_attr_escape(str(s))}" />' for s in new_ids)
        return track_raw[:ct] + block + track_raw[ct:]

    line_start = track_raw.rfind("\n", 0, ct)
    track_indent = track_raw[line_start + 1 : ct] if (line_start >= 0 and track_raw[line_start + 1 : ct].strip() == "") else "    "
    child_indent = track_indent + "  "
    block = f"{eol}{child_indent}".join(f'<SkinOrAvatarList id="{_xml_attr_escape(str(s))}" />' for s in new_ids)
    before = track_raw[:ct]
    if before.endswith((" ", "\t")):
        return before + f"  {block}{eol}{track_indent}" + track_raw[ct:]
    return before + f"{eol}{child_indent}{block}{eol}{track_indent}" + track_raw[ct:]


def _replace_skin_id_array_preserving_eol(track_raw: str, new_ids: list[str]) -> str:
    eol = "\r\n" if "\r\n" in track_raw else "\n"
    multiline = "\n" in track_raw
    if new_ids:
        if multiline:
            inner = f"{eol}          " + f"{eol}          ".join(f'<int value="{_xml_attr_escape(str(s))}" />' for s in new_ids) + f"{eol}        "
        else:
            inner = "".join(f'<int value="{_xml_attr_escape(str(s))}" />' for s in new_ids)
    else:
        inner = ""
    return _SKIN_ID_ARRAY_BLOCK_RE.sub(lambda m: m.group(1) + inner + m.group(3), track_raw, count=1)


def _apply_mses_record_edits(orig_raw: bytes | None, rec_spec: dict[str, Any]) -> tuple[int, bytes]:
    rid = int(rec_spec["rid"])
    if rec_spec.get("raw_hex"):
        buf = bytearray(bytes.fromhex(str(rec_spec["raw_hex"])))
    elif rec_spec.get("body_hex") is not None:
        buf = bytearray(struct.pack("<II", 0, rid) + bytes.fromhex(str(rec_spec["body_hex"])))
    elif orig_raw is not None:
        buf = bytearray(orig_raw)
    else:
        raise ValueError(f"Thiếu raw_hex/body_hex hoặc bản ghi gốc cho rid={rid}.")

    if len(buf) < 8:
        raise ValueError(f"Bản ghi MSES rid={rid} quá ngắn (< 8 byte).")

    edits = rec_spec.get("string_edits")
    if isinstance(edits, list):
        offset_edits = [
            ed for ed in edits
            if isinstance(ed, dict) and "offset" in ed and "text" in ed
        ]
        other_edits = [
            ed for ed in edits
            if isinstance(ed, dict) and not ("offset" in ed and "text" in ed)
        ]
        for ed in sorted(offset_edits, key=lambda e: int(e["offset"]), reverse=True):
            off = int(ed["offset"])
            if off < 8 or off + 4 > len(buf):
                raise ValueError(f"Offset chuỗi {off} nằm ngoài phạm vi bản ghi rid={rid}.")
            old_slen = struct.unpack_from("<I", buf, off)[0]
            if off + 4 + old_slen > len(buf):
                raise ValueError(f"Độ dài chuỗi cũ {old_slen} tại offset {off} không hợp lệ (rid={rid}).")
            nb = str(ed["text"]).encode("utf-8") + b"\x00"
            buf[off : off + 4 + old_slen] = struct.pack("<I", len(nb)) + nb
        for ed in other_edits:
            if "old" in ed and "new" in ed:
                ob = str(ed["old"]).encode("utf-8") + b"\x00"
                nb = str(ed["new"]).encode("utf-8") + b"\x00"
                old_tok = struct.pack("<I", len(ob)) + ob
                new_tok = struct.pack("<I", len(nb)) + nb
                raw_bytes = bytes(buf)
                idx = raw_bytes.find(old_tok, 8)
                if idx < 0:
                    raise ValueError(f"Không tìm thấy chuỗi {ed['old']!r} trong bản ghi rid={rid}.")
                buf[idx : idx + len(old_tok)] = new_tok

    struct.pack_into("<II", buf, 0, len(buf) - 4, rid)
    return rid, bytes(buf)


class BinaryInspector:
    """Bộ công cụ giải phẫu và chỉnh sửa trực tiếp các định dạng tệp nhị phân Liên Quân Mobile."""

    @staticmethod
    def infer_stem(filename: str) -> str:
        base = os.path.basename(filename.replace("\\", "/"))
        return base.rsplit(".", 1)[0] if "." in base else base

    @staticmethod
    def decrypt_0x224a(raw: bytes, stem: str = "") -> dict[str, Any]:
        if not isinstance(raw, (bytes, bytearray)):
            raise ValueError("Dữ liệu đầu vào phải là bytes.")
        raw_b = bytes(raw)
        is_224a = len(raw_b) > 8 and raw_b[:2] == b"\x22\x4A"
        if not is_224a:
            is_text = False
            text_content = ""
            try:
                text_content = raw_b.decode("utf-8")
                is_text = True
            except UnicodeDecodeError:
                pass
            return {
                "is_224a": False,
                "stem": stem,
                "encryption_mode": None,
                "b2": None,
                "b3": None,
                "declared_size": len(raw_b),
                "decrypted_bytes": raw_b,
                "decrypted_size": len(raw_b),
                "decrypted_b64": base64.b64encode(raw_b).decode("ascii"),
                "is_text": is_text,
                "text_content": text_content,
            }

        b2, b3 = raw_b[2], raw_b[3]
        declared_size = struct.unpack_from("<I", raw_b, 4)[0]
        try:
            plain = cp.pg_decrypt(raw_b, stem)
        except Exception as exc:
            raise ValueError(
                f"Giải mã 0x224A thất bại (stem={stem!r}, b2=0x{b2:02X}, b3=0x{b3:02X}): {exc}"
            ) from exc

        is_text = False
        text_content = ""
        try:
            text_content = plain.decode("utf-8")
            is_text = True
        except UnicodeDecodeError:
            pass

        return {
            "is_224a": True,
            "stem": stem,
            "encryption_mode": f"0x224A (b2=0x{b2:02X}, b3=0x{b3:02X})",
            "b2": b2,
            "b3": b3,
            "declared_size": declared_size,
            "decrypted_bytes": plain,
            "decrypted_size": len(plain),
            "decrypted_b64": base64.b64encode(plain).decode("ascii"),
            "is_text": is_text,
            "text_content": text_content,
        }

    @staticmethod
    def encrypt_0x224a(raw: bytes, stem: str) -> bytes:
        if not isinstance(raw, (bytes, bytearray)):
            raise ValueError("Dữ liệu đầu vào phải là bytes.")
        if stem is None:
            raise ValueError("Cần cung cấp stem để mã hóa 0x224A.")
        return cp.pg_encrypt(bytes(raw), str(stem))

    @staticmethod
    def parse_xml_tracks(xml_text: str) -> list[dict[str, Any]]:
        tracks_out: list[dict[str, Any]] = []
        for idx, m in enumerate(_TRACK_SPAN_RE.finditer(xml_text)):
            span_raw = m.group(0)
            parsed = cp.parse_track(span_raw, idx)
            res_names = [rm.group(2) for rm in _RESOURCE_NAME_RE.finditer(span_raw)]
            en_m = re.search(r'\benabled="([^"]*)"', span_raw[: span_raw.find(">") + 1] if ">" in span_raw else span_raw)
            tracks_out.append({
                "index": idx,
                "trackName": parsed["trackName"],
                "eventType": parsed["eventType"],
                "guid": parsed["guid"],
                "enabled": en_m.group(1) if en_m else "true",
                "filterType": parsed["filterType"],
                "skins": list(parsed["skins"]),
                "skinArrayIds": list(parsed["skinArrayIds"]),
                "hasSkinIdArray": 'name="skinIdArray"' in span_raw,
                "resourceNames": res_names,
                "resourceName": res_names[0] if res_names else "",
                "raw": span_raw,
            })
        return tracks_out

    @staticmethod
    def update_xml_tracks(xml_text: str, updates: list[dict[str, Any]] | dict[str, Any]) -> str:
        # Chuẩn hóa cấu trúc `updates`
        update_list: list[dict[str, Any]] = []
        if isinstance(updates, list):
            update_list = [u for u in updates if isinstance(u, dict)]
        elif isinstance(updates, dict):
            if isinstance(updates.get("tracks"), list):
                update_list = [u for u in updates["tracks"] if isinstance(u, dict)]
            elif isinstance(updates.get("updates"), list):
                update_list = [u for u in updates["updates"] if isinstance(u, dict)]
            elif "index" in updates or "guid" in updates:
                update_list = [updates]
            else:
                for k, v in updates.items():
                    if isinstance(v, dict):
                        item = dict(v)
                        if "index" not in item and str(k).isdigit():
                            item["index"] = int(k)
                        update_list.append(item)

        if not update_list:
            return xml_text

        matches = list(_TRACK_SPAN_RE.finditer(xml_text))
        if not matches:
            return xml_text

        by_idx: dict[int, dict[str, Any]] = {}
        by_guid: dict[str, dict[str, Any]] = {}
        for upd in update_list:
            if upd.get("index") is not None:
                by_idx[int(upd["index"])] = upd
            elif upd.get("guid"):
                by_guid[str(upd["guid"])] = upd

        replacements: list[tuple[int, int, str]] = []
        for idx, m in enumerate(matches):
            span_raw = m.group(0)
            parsed = cp.parse_track(span_raw, idx)
            upd = by_idx.get(idx) or (by_guid.get(parsed["guid"]) if parsed.get("guid") else None)
            if not upd:
                continue

            start, end = m.start(), m.end()
            if upd.get("delete"):
                # Xóa gọn cả khoảng trắng đầu dòng và 1 dấu xuống dòng liền sau
                del_start, del_end = start, end
                line_start = xml_text.rfind("\n", 0, start)
                if line_start >= 0 and xml_text[line_start + 1 : start].strip() == "":
                    del_start = line_start + 1
                if xml_text[del_end : del_end + 2] == "\r\n":
                    del_end += 2
                elif xml_text[del_end : del_end + 1] == "\n":
                    del_end += 1
                replacements.append((del_start, del_end, ""))
                continue

            if isinstance(upd.get("raw"), str):
                replacements.append((start, end, upd["raw"]))
                continue

            new_raw = span_raw
            if "filterType" in upd or "SkinAvatarFilterType" in upd:
                ft_val = upd["filterType"] if "filterType" in upd else upd["SkinAvatarFilterType"]
                new_raw = _set_track_open_attr(new_raw, "SkinAvatarFilterType", None if ft_val is None else str(ft_val))

            if "enabled" in upd and upd["enabled"] is not None:
                en_val = "true" if upd["enabled"] in (True, "true", "True", "1", 1) else "false"
                new_raw = _set_track_open_attr(new_raw, "enabled", en_val)

            if "trackName" in upd and upd["trackName"] is not None:
                new_raw = _set_track_open_attr(new_raw, "trackName", str(upd["trackName"]))

            if "skins" in upd and isinstance(upd["skins"], list):
                new_raw = _replace_track_skins_preserving_eol(new_raw, [str(s) for s in upd["skins"]])

            if "skinArrayIds" in upd and isinstance(upd["skinArrayIds"], list):
                new_raw = _replace_skin_id_array_preserving_eol(new_raw, [str(s) for s in upd["skinArrayIds"]])

            if "resourceNames" in upd and isinstance(upd["resourceNames"], list):
                rlist = [str(x) for x in upd["resourceNames"]]
                it = iter(rlist)

                def _sub_res_list(rm: re.Match[str]) -> str:
                    val = next(it, None)
                    if val is None:
                        return rm.group(0)
                    return f"{rm.group(1)}{_xml_attr_escape(val)}{rm.group(3)}"

                new_raw = _RESOURCE_NAME_RE.sub(_sub_res_list, new_raw)
            elif "resourceName" in upd and upd["resourceName"] is not None:
                rval = _xml_attr_escape(str(upd["resourceName"]))
                new_raw = _RESOURCE_NAME_RE.sub(lambda rm: f"{rm.group(1)}{rval}{rm.group(3)}", new_raw, count=1)

            if new_raw != span_raw:
                replacements.append((start, end, new_raw))

        if not replacements:
            return xml_text

        out_xml = xml_text
        for s, e, rep in sorted(replacements, key=lambda x: x[0], reverse=True):
            out_xml = out_xml[:s] + rep + out_xml[e:]
        return out_xml

    @staticmethod
    def inspect_bytes(
        raw: bytes,
        filename: str = "",
        stem: str = "",
        full_text: bool = False,
        *,
        stem_override: str = "",
    ) -> dict[str, Any]:
        explicit_stem = (stem or stem_override).strip()
        resolved_stem = explicit_stem or BinaryInspector.infer_stem(filename)
        info: dict[str, Any] = {
            "filename": filename,
            "stem": resolved_stem,
            "raw_size": len(raw),
            "magic_hex": raw[:16].hex(),
            "is_encrypted_224a": len(raw) > 8 and raw[:2] == b"\x22\x4A",
            "encryption_mode": None,
            "kind": "binary",
            "full_text": bool(full_text),
        }

        # 1. Gói .3105
        if raw.startswith(b"3105PATCH\x00"):
            meta = cp.inspect_patch_package_light(raw)
            info["kind"] = "3105_patch"
            info["patch_info"] = meta
            return info

        # 2. Gói ZIP hoặc .pkg.bytes (PK\x03\x04)
        if raw[:4] in (b"PK\x03\x04", b"PK\x05\x06"):
            entries_summary: list[dict[str, Any]] = []
            try:
                with zipfile.ZipFile(io.BytesIO(raw), "r") as zf:
                    for zi in zf.infolist():
                        if not zi.is_dir():
                            entries_summary.append({
                                "name": zi.filename,
                                "size": zi.file_size,
                                "compressed_size": zi.compress_size,
                                "compress_type": "STORE (0)" if zi.compress_type == 0 else f"DEFLATE ({zi.compress_type})",
                            })
            except zipfile.BadZipFile as exc:
                info["kind"] = "binary"
                info["error"] = f"Tệp ZIP/.pkg không hợp lệ: {exc}"
                info["zip_error"] = str(exc)
                info["hex_preview"] = raw[:2048].hex()
                return info
            info["kind"] = "pkg_archive" if filename.lower().endswith(".pkg.bytes") else "zip_archive"
            info["entry_count"] = len(entries_summary)
            info["entries_truncated"] = (not full_text) and len(entries_summary) > 400
            info["entries"] = entries_summary if full_text else entries_summary[:400]
            return info

        # 3. UnityFS AssetBundle
        if raw[:7] == b"UnityFS":
            info["kind"] = "unityfs"
            try:
                u = cp.unpack_unityfs(raw)
                info["unpacked_payload_size"] = len(u["payload"])
                if b"ResourcePackerInfoSetXML" in u["payload"]:
                    rp = cp.parse_rpack(u)
                    info["kind"] = "unityfs_rpack"
                    info["record_count"] = rp["rec_cnt"]
                    info["paths_truncated"] = (not full_text) and len(rp["ordered_paths"]) > 100
                    info["sample_paths"] = rp["ordered_paths"] if full_text else rp["ordered_paths"][:100]
            except Exception as exc:
                info["unpack_error"] = str(exc)
            return info

        # 4. Giải mã lớp 0x224A nếu có (an toàn trong try/except; tôn trọng stem chỉ định tường minh)
        plain = raw
        if info["is_encrypted_224a"]:
            b2, b3 = raw[2], raw[3]
            info["encryption_mode"] = f"0x224A (b2=0x{b2:02X}, b3=0x{b3:02X})"
            dec_ok = False
            if not explicit_stem:
                try:
                    cand_plain = cp.decode_aov_xml_if_needed(raw, filename)
                    if cand_plain != raw:
                        plain = cand_plain
                        dec_ok = True
                except Exception:
                    pass
            if not dec_ok:
                try:
                    plain = cp.pg_decrypt(raw, resolved_stem)
                except Exception as exc:
                    info["kind"] = "encrypted_224a"
                    info["decrypt_error"] = str(exc)
                    info["hex_preview"] = raw[:2048].hex()
                    return info
        info["decrypted_size"] = len(plain)

        # 4a. Bảng dữ liệu MSES
        if len(plain) >= 140 and plain[:4] == b"MSES":
            tbl = cp.parse_mses(plain)
            if tbl:
                info["kind"] = "mses_table"
                info["record_count"] = len(tbl["recs"])
                info["max_rec"] = tbl["max_rec"]
                info["has_md5"] = tbl["has_md5"]
                rec_lengths = {len(r[1]) for r in tbl["recs"]}
                info["is_variable_length"] = len(rec_lengths) > 1
                info["records_truncated"] = (not full_text) and len(tbl["recs"]) > 250
                rec_slice = tbl["recs"] if full_text else tbl["recs"][:250]
                recs_preview = []
                for rid, rraw in rec_slice:
                    str_entries = _extract_utf8_len_prefixed_string_entries(rraw, 8)
                    strs = [e["text"] for e in str_entries]
                    rec_obj: dict[str, Any] = {
                        "rid": rid,
                        "length": len(rraw),
                        "strings": strs if full_text else strs[:5],
                        "string_entries": str_entries if full_text else str_entries[:10],
                        "hex_preview": rraw[:64].hex(),
                    }
                    if full_text or len(tbl["recs"]) <= 250 or len(rraw) <= 2048:
                        rec_obj["raw_hex"] = rraw.hex()
                    recs_preview.append(rec_obj)
                info["records"] = recs_preview
                if full_text or len(tbl["recs"]) <= 250:
                    info["text_content"] = json.dumps(
                        {
                            "format": "mses_table",
                            "max_rec": tbl["max_rec"],
                            "has_md5": tbl["has_md5"],
                            "header_hex": bytes(tbl["hdr"]).hex(),
                            "footer_hex": tbl["ftr"].hex(),
                            "records": [
                                {
                                    "rid": r["rid"],
                                    "raw_hex": r.get("raw_hex", ""),
                                    "strings": r["string_entries"],
                                }
                                for r in recs_preview
                            ],
                        },
                        ensure_ascii=False,
                        indent=2,
                    )
                return info

        # 4b. Thanos HeroSkin_1 / HeroSkin_2 IFix
        hs1 = cp.parse_kiana_hs1(plain)
        if hs1:
            info["kind"] = "thanos_hs1"
            info["pairs"] = hs1["pairs"]
            info["embedded_pkgs"] = [
                m.decode("utf-8")
                for m in re.findall(rb"[A-Za-z0-9_]+\.pkg\.bytes [0-9a-fA-F]{32}", plain)
            ]
            return info
        hs2 = cp.parse_kiana_hs2(plain)
        if hs2:
            info["kind"] = "thanos_hs2"
            info["params"] = [
                {"hero_id": h, "personal_button_id": b, "kill_notify_id": p}
                for h, b, p in hs2["params"]
            ]
            return info

        # 4c. Cây nhị phân JTCom (CActorInfo / AssetRef)
        if len(plain) >= 24 and plain[8:12] == b"ROOT":
            try:
                tree, end = jtcom.parse_jt(plain, 0)
                if end == len(plain):
                    info["kind"] = "jtcom_tree"
                    info["text_content"] = json.dumps(jtcom.jt_to_jsonable(tree), ensure_ascii=False, indent=2)
                    return info
            except Exception:
                pass

        # 4d. Văn bản XML / Lua / LanguageMap
        try:
            txt = plain.decode("utf-8")
            if "<Track" in txt or "<Project" in txt or "<?xml" in txt:
                trks = BinaryInspector.parse_xml_tracks(txt)
                info["kind"] = "age_xml"
                info["track_count"] = len(trks)
                info["tracks_truncated"] = (not full_text) and len(trks) > 150
                trk_slice = trks if full_text else trks[:150]
                info["tracks_summary"] = [
                    {
                        "index": t["index"],
                        "trackName": t["trackName"],
                        "eventType": t["eventType"],
                        "guid": t["guid"],
                        "enabled": t["enabled"],
                        "filterType": t["filterType"],
                        "skins": t["skins"] if full_text else t["skins"][:12],
                        "skinArrayIds": t["skinArrayIds"] if full_text else t["skinArrayIds"][:12],
                        "resourceName": t["resourceName"],
                        "resourceNames": t["resourceNames"],
                    }
                    for t in trk_slice
                ]
                info["text_content"] = txt
                return info
            info["kind"] = "text"
            info["text_truncated"] = (not full_text) and len(txt) > 500_000
            info["text_content"] = txt if full_text else txt[:500_000]
            return info
        except UnicodeDecodeError:
            pass

        info["hex_preview"] = plain[:2048].hex()
        info["decrypted_b64"] = (
            base64.b64encode(plain).decode("ascii")
            if (full_text or len(plain) <= 10 * 1024 * 1024)
            else ""
        )
        return info

    @staticmethod
    def repack_from_editor(
        kind: str,
        content_text: str | dict[str, Any],
        stem: str,
        encrypt_224a: bool = True,
        base_raw: bytes | None = None,
    ) -> bytes:
        k = (kind or "").strip().lower()
        if k in ("jtcom_tree", "jtcom_json"):
            obj = json.loads(content_text) if isinstance(content_text, str) else content_text
            plain = jtcom.serialize_jt(jtcom.jsonable_to_jt(obj))
        elif k == "mses_table":
            obj = json.loads(content_text) if isinstance(content_text, str) else content_text
            if not isinstance(obj, dict):
                raise ValueError("Dữ liệu mses_table phải là JSON object.")

            base_tbl: dict[str, Any] | None = None
            if base_raw is not None:
                bplain = bytes(base_raw)
                if len(bplain) > 8 and bplain[:2] == b"\x22\x4A":
                    bplain = cp.pg_decrypt(bplain, stem)
                base_tbl = cp.parse_mses(bplain)

            recs_in = obj.get("records")
            if not isinstance(recs_in, list):
                raise ValueError("mses_table thiếu danh sách 'records'.")

            if "header_hex" in obj and obj["header_hex"]:
                hdr = bytearray(bytes.fromhex(str(obj["header_hex"])))
                if len(hdr) < 140:
                    raise ValueError("header_hex của mses_table phải đủ 140 byte.")
                ftr = bytes.fromhex(str(obj.get("footer_hex") or ""))
                has_md5 = bool(obj.get("has_md5", True))
                max_rec = int(obj.get("max_rec") or 0)
                base_map = {rid: rraw for rid, rraw in base_tbl["recs"]} if base_tbl else {}
                new_recs = [
                    _apply_mses_record_edits(base_map.get(int(r["rid"])), r)
                    for r in recs_in
                ]
                tbl = {"hdr": hdr, "has_md5": has_md5, "max_rec": max_rec, "recs": new_recs, "ftr": ftr}
            else:
                if base_tbl is None:
                    raise ValueError("Cập nhật mses_table cục bộ cần có base_raw hoặc header_hex.")
                edits_by_rid = {int(r["rid"]): r for r in recs_in if isinstance(r, dict) and "rid" in r}
                seen: set[int] = set()
                merged_recs: list[tuple[int, bytes]] = []
                for rid, rraw in base_tbl["recs"]:
                    if rid in edits_by_rid:
                        merged_recs.append(_apply_mses_record_edits(rraw, edits_by_rid[rid]))
                        seen.add(rid)
                    else:
                        merged_recs.append((rid, rraw))
                for rid, rspec in edits_by_rid.items():
                    if rid not in seen:
                        merged_recs.append(_apply_mses_record_edits(None, rspec))
                base_tbl["recs"] = merged_recs
                tbl = base_tbl

            plain = cp.serialize_mses(tbl)
        else:
            plain = content_text if isinstance(content_text, (bytes, bytearray)) else str(content_text).encode("utf-8")
        return cp.pg_encrypt(bytes(plain), stem) if encrypt_224a else bytes(plain)

    @staticmethod
    def list_pkg_entries(pkg_bytes: bytes) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        with zipfile.ZipFile(io.BytesIO(pkg_bytes), "r") as zf:
            for zi in zf.infolist():
                if zi.is_dir():
                    continue
                head = zf.read(zi.filename)[:2]
                out.append({
                    "name": zi.filename,
                    "size": zi.file_size,
                    "compressed_size": zi.compress_size,
                    "compress_type": zi.compress_type,
                    "compress_method": "STORE (0)" if zi.compress_type == 0 else f"DEFLATE ({zi.compress_type})",
                    "is_encrypted_224a": head == b"\x22\x4A",
                })
        return out

    @staticmethod
    def read_pkg_entry(pkg_bytes: bytes, entry_name: str, full_text: bool = False) -> dict[str, Any]:
        norm_target = entry_name.replace("\\", "/").lstrip("/")
        entries = cp.parse_in_memory_zip(pkg_bytes)
        for name, _, _, data in entries:
            if name == entry_name or name.replace("\\", "/").lstrip("/") == norm_target:
                return BinaryInspector.inspect_bytes(data, name, full_text=full_text)
        low_target = norm_target.lower()
        for name, _, _, data in entries:
            if name.replace("\\", "/").lstrip("/").lower() == low_target:
                return BinaryInspector.inspect_bytes(data, name, full_text=full_text)
        raise KeyError(f"Không tìm thấy mục {entry_name!r} trong gói .pkg.bytes.")

    @staticmethod
    def update_pkg_entry(
        pkg_bytes: bytes,
        entry_name: str,
        new_raw: bytes | str,
        encrypt_stem: str | None = None,
        *,
        kind: str | None = None,
        encrypt_224a: bool | None = None,
        allow_add: bool = False,
    ) -> bytes:
        entries = cp.parse_in_memory_zip(pkg_bytes)
        mod_mtime, mod_mdate = 0x5800, 0x5B72
        norm_target = entry_name.replace("\\", "/").lstrip("/")

        def _build_payload(old_data: bytes | None, target_name: str) -> bytes:
            if isinstance(new_raw, (bytes, bytearray)):
                if encrypt_stem:
                    return BinaryInspector.encrypt_0x224a(bytes(new_raw), encrypt_stem)
                if encrypt_224a is True:
                    return BinaryInspector.encrypt_0x224a(bytes(new_raw), BinaryInspector.infer_stem(target_name))
                return bytes(new_raw)
            # Chuỗi văn bản/JSON (hỗ trợ cả chữ ký cũ update_pkg_entry(pkg, name, text, "age_xml"))
            eff_kind = kind or (
                encrypt_stem
                if encrypt_stem in ("age_xml", "jtcom_tree", "jtcom_json", "mses_table", "text")
                else "age_xml"
            )
            was_enc = (old_data is not None and len(old_data) > 8 and old_data[:2] == b"\x22\x4A")
            do_enc = encrypt_224a if encrypt_224a is not None else was_enc
            use_stem = (
                encrypt_stem
                if (encrypt_stem and encrypt_stem not in ("age_xml", "jtcom_tree", "jtcom_json", "mses_table", "text"))
                else BinaryInspector.infer_stem(target_name)
            )
            return BinaryInspector.repack_from_editor(
                eff_kind,
                new_raw,
                use_stem,
                encrypt_224a=do_enc,
                base_raw=old_data,
            )

        matched_idx: int | None = None
        for idx, (name, mt, md, data) in enumerate(entries):
            if name == entry_name or name.replace("\\", "/").lstrip("/") == norm_target:
                matched_idx = idx
                break
        if matched_idx is None:
            low_target = norm_target.lower()
            for idx, (name, mt, md, data) in enumerate(entries):
                if name.replace("\\", "/").lstrip("/").lower() == low_target:
                    matched_idx = idx
                    break

        out_entries: list[tuple[str, int, int, bytes]] = []
        for idx, (name, mt, md, data) in enumerate(entries):
            if idx == matched_idx:
                out_entries.append((name, mod_mtime, mod_mdate, _build_payload(data, name)))
            else:
                out_entries.append((name, mt, md, data))

        if matched_idx is None:
            if allow_add:
                out_entries.append((norm_target, mod_mtime, mod_mdate, _build_payload(None, norm_target)))
            else:
                raise KeyError(f"Không tìm thấy mục {entry_name!r} trong gói .pkg.bytes.")
        return cp.build_in_memory_store_zip(out_entries)

    @staticmethod
    def unpack_pkg_to_dir(pkg_bytes: bytes, out_dir: str) -> dict[str, Any]:
        if not out_dir:
            raise ValueError("Thiếu đường dẫn thư mục đích out_dir.")
        out_dir_abs = os.path.abspath(out_dir)
        os.makedirs(out_dir_abs, exist_ok=True)
        written: list[str] = []

        with zipfile.ZipFile(io.BytesIO(pkg_bytes), "r") as zf:
            for zi in zf.infolist():
                if zi.is_dir():
                    continue
                raw_name = zi.filename
                if "\x00" in raw_name:
                    raise ValueError(f"Đường dẫn mục ZIP chứa ký tự null không hợp lệ: {raw_name!r}")
                norm = raw_name.replace("\\", "/")
                drv, _ = ntpath.splitdrive(raw_name)
                if drv or norm.startswith("/") or ":" in norm.split("/", 1)[0]:
                    raise ValueError(f"Từ chối đường dẫn tuyệt đối / chứa ổ đĩa (zip-slip): {raw_name!r}")
                segs = [s for s in norm.split("/") if s not in ("", ".")]
                if not segs or any(s == ".." for s in segs):
                    raise ValueError(f"Từ chối đường dẫn thoát thư mục (zip-slip): {raw_name!r}")
                dest_abs = os.path.abspath(os.path.join(out_dir_abs, *segs))
                if os.path.commonpath([out_dir_abs, dest_abs]) != out_dir_abs:
                    raise ValueError(f"Từ chối đường dẫn vượt ra ngoài thư mục đích: {raw_name!r}")
                os.makedirs(os.path.dirname(dest_abs), exist_ok=True)
                with open(dest_abs, "wb") as f:
                    f.write(zf.read(zi.filename))
                written.append("/".join(segs))

        return {
            "output_dir": out_dir_abs,
            "file_count": len(written),
            "files": written,
        }

    @staticmethod
    def pack_dir_to_pkg(src_dir: str) -> bytes:
        if not src_dir or not os.path.isdir(src_dir):
            raise FileNotFoundError(f"Không tìm thấy thư mục nguồn để đóng gói: {src_dir!r}")
        src_abs = os.path.abspath(src_dir)
        items: list[tuple[str, str]] = []
        for root, dirs, files in os.walk(src_abs):
            dirs[:] = sorted(d for d in dirs if d != "__MACOSX")
            for fn in sorted(files):
                if fn.lower() in _OS_JUNK_NAMES or fn.startswith("._"):
                    continue
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, src_abs).replace("\\", "/")
                items.append((rel, full))
        items.sort(key=lambda x: x[0])

        entries: list[tuple[str, int, int, bytes]] = []
        for rel, full in items:
            st = os.stat(full)
            lt = time.localtime(st.st_mtime)
            if lt.tm_year < 1980:
                mt, md = 0x5800, 0x5B72
            else:
                mt = (lt.tm_hour << 11) | (lt.tm_min << 5) | (lt.tm_sec // 2)
                md = ((lt.tm_year - 1980) << 9) | (lt.tm_mon << 5) | lt.tm_mday
            with open(full, "rb") as f:
                data = f.read()
            entries.append((rel, mt, md, data))
        return cp.build_in_memory_store_zip(entries)


# ---------------------------------------------------------------------------
# 4. `OfflineMergerAndConverter` — Gộp nhiều gói Mod & Đổi `.zip ⇄ .3105` Offline
# ---------------------------------------------------------------------------

def _encode_zip_to_3105(zip_bytes: bytes, title: str = "Totorox Mod", password: str | None = None) -> bytes:
    """Đóng gói `.zip` thành gói `.3105` (`3105PATCH` AES-256-GCM + PBKDF2 tùy chọn) 100% offline."""
    pw = (password or "").strip() or None
    project, _ = cp.parse_project_upload(zip_bytes)
    project.name = title or project.name
    project.author = "Totorox Mod Studio"
    project.is_private = bool(pw)
    plist_payload = cp._patch_project_to_plist_bytes(project)
    project.encrypted_payload = cp.patch_package_seal(
        plist_payload, project.content_key, project.id, project.schema_version
    )
    return cp.build_encoded_patch_package(project, password=pw)


def _decode_3105_to_zip(raw_3105: bytes, password: str | None = None) -> tuple[bytes, dict[str, Any]]:
    """Giải mã gói `.3105` về lại `.zip` hoàn chỉnh 100% offline."""
    pw = (password or "").strip() or None
    res = cp.convert_header({"data": raw_3105, "mode": "from_zip", "password": pw})
    b64 = res.get("zip_bytes_b64")
    if not b64:
        if res.get("ok"):
            raise ValueError("Gói .3105 không chứa encryptedPayload hợp lệ hoặc payload bị hỏng.")
        raise ValueError(res.get("note") or "Không thể giải mã payload của gói .3105.")
    return base64.b64decode(b64), res


class OfflineMergerAndConverter:
    """Gộp nhiều gói mod `.zip` và chuyển đổi `.zip ⇄ .3105` trực tiếp trên máy tính cá nhân."""

    @staticmethod
    def merge_mods(
        inputs: list[dict[str, Any] | str | os.PathLike[str] | tuple[str, bytes]],
        output_dir: str | None = None,
        output_name: str | None = None,
        watermark_text: str | None = None,
        output_format: str = "zip",
        password: str | None = None,
        input_passwords: dict[str, str] | None = None,
        *,
        custom_watermark: str | None = None,
        custom_filename: str | None = None,
        isolate_hud_on_conflict: bool = True,
    ) -> dict[str, Any]:
        if not inputs or len(inputs) < 2:
            raise ValueError("Cần chọn ít nhất 2 gói mod (.zip hoặc .3105) để thực hiện gộp.")

        pw_map = {str(k): str(v) for k, v in (input_passwords or {}).items() if v is not None}
        shared_pw = (password or "").strip() or None

        mod_inputs: list[dict[str, Any]] = []
        for idx, item in enumerate(inputs):
            orig_path = ""
            item_pw: str | None = None
            if isinstance(item, (str, os.PathLike)):
                orig_path = os.fspath(item)
                fname = os.path.basename(orig_path)
                with open(orig_path, "rb") as f:
                    raw = f.read()
            elif isinstance(item, dict):
                orig_path = str(item.get("path") or "")
                fname = str(item.get("name") or item.get("filename") or (os.path.basename(orig_path) if orig_path else f"mod_{idx}.zip"))
                raw_val = item.get("bytes") if item.get("bytes") is not None else item.get("data")
                if raw_val is not None:
                    raw = bytes(raw_val)
                elif orig_path:
                    with open(orig_path, "rb") as f:
                        raw = f.read()
                else:
                    raise ValueError(f"Mục đầu vào thứ {idx} thiếu dữ liệu bytes hoặc path.")
                if item.get("password") is not None:
                    item_pw = str(item["password"]).strip() or None
            elif isinstance(item, tuple) and len(item) == 2:
                fname, raw = str(item[0]), bytes(item[1])
            else:
                raise ValueError(f"Định dạng đầu vào không hợp lệ tại vị trí {idx}.")

            if item_pw is None:
                cands = [orig_path, os.path.abspath(orig_path) if orig_path else "", fname, str(idx)]
                for ck in cands:
                    if ck and ck in pw_map:
                        item_pw = pw_map[ck].strip() or None
                        break
            if item_pw is None:
                item_pw = shared_pw

            if raw.startswith(b"3105PATCH\x00"):
                zbytes, _ = _decode_3105_to_zip(raw, password=item_pw)
                base_n = os.path.splitext(fname)[0] + ".zip"
                mod_inputs.append(cp.load_mod_from_bytes(base_n, zbytes))
            else:
                mod_inputs.append(cp.load_mod_from_bytes(fname, raw))

        t0 = time.time()
        out_name, out_files, zip_bytes, loaded = cp.run_merge(
            mod_inputs,
            isolate_hud_on_conflict=isolate_hud_on_conflict,
        )
        plan_res = cp.build_merge_plan_result(out_name, out_files, zip_bytes, loaded, include_zip_b64=False)
        merge_plan_obj = plan_res.get("merge_plan") or {}

        # Ghi đè watermark cá nhân của người dùng nếu được nhập (tổng hợp languageMap.txt nếu các mod nguồn đều thiếu)
        eff_wm = (watermark_text if watermark_text is not None else custom_watermark) or ""
        if eff_wm.strip():
            wm_clean = eff_wm.strip()
            wm_line = f"Tip_WaterMark_Str = {wm_clean}".encode("utf-8")
            with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as in_zf:
                re_buf = io.BytesIO()
                found_lang = False
                archive_ver: str | None = None
                vtxt_ver: str | None = None
                updated_sizes: dict[str, int] = {}
                with zipfile.ZipFile(re_buf, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as out_zf:
                    for info in in_zf.infolist():
                        data = in_zf.read(info.filename)
                        np_entry = cp.normalize_aov_path(info.filename)
                        if archive_ver is None and np_entry and np_entry.startswith("Resources/"):
                            parts = np_entry.split("/", 2)
                            if len(parts) >= 2 and re.match(r"^\d+\.\d+", parts[1]):
                                archive_ver = parts[1]
                        if vtxt_ver is None and info.filename.replace("\\", "/").lower().endswith("version.txt"):
                            vtxt_ver = BaseResourceProvider._extract_ver_from_txt(
                                data.decode("utf-8", errors="ignore")
                            )
                        if info.filename.lower().endswith("languagemap.txt"):
                            found_lang = True
                            plain = _decode_text_resource(data).encode("utf-8")
                            patched, cnt = cp._TIP_WATERMARK_RE.subn(lambda m: m.group(1) + wm_line, plain, count=1)
                            data = patched if cnt > 0 else (plain + b"\r\n" + wm_line)
                            updated_sizes[info.filename] = len(data)
                        out_zf.writestr(info, data)

                    if not found_lang:
                        ver_seg = (
                            archive_ver
                            or vtxt_ver
                            or (loaded[0].get("ver") if loaded else None)
                            or DEFAULT_GAME_VERSION
                        )
                        lang_rel = "Languages/VN_Garena_VN/languageMap.txt"
                        synth_arc_path = f"Resources/{ver_seg}/{lang_rel}"
                        synth_lang: bytes | None = None

                        res_path = ""
                        if os.path.exists(CONFIG_PATH):
                            try:
                                with open(CONFIG_PATH, "r", encoding="utf-8") as cf:
                                    loaded_cfg = json.load(cf)
                                if isinstance(loaded_cfg, dict):
                                    cand_p = str(loaded_cfg.get("resources_path") or "")
                                    if cand_p and os.path.exists(cand_p):
                                        res_path = cand_p
                            except Exception:
                                pass
                        if not res_path:
                            res_path = _auto_detect_base_resources()

                        if res_path and os.path.exists(res_path):
                            try:
                                base_prov = BaseResourceProvider(res_path)
                                if base_prov.has(lang_rel):
                                    raw_lang = base_prov.read(lang_rel)
                                    plain_lang = _decode_text_resource(raw_lang).encode("utf-8")
                                    patched, cnt = cp._TIP_WATERMARK_RE.subn(
                                        lambda m: m.group(1) + wm_line, plain_lang, count=1
                                    )
                                    synth_lang = patched if cnt > 0 else (plain_lang + b"\r\n" + wm_line)
                            except Exception:
                                synth_lang = None

                        if synth_lang is None:
                            synth_lang = wm_line + b"\r\n"

                        out_zf.writestr(synth_arc_path, synth_lang)
                        updated_sizes[synth_arc_path] = len(synth_lang)
                zip_bytes = re_buf.getvalue()

                if updated_sizes and isinstance(merge_plan_obj.get("files"), list):
                    existing_paths = {f.get("path"): f for f in merge_plan_obj["files"] if isinstance(f, dict)}
                    for up_path, up_sz in updated_sizes.items():
                        if up_path in existing_paths:
                            existing_paths[up_path]["size"] = up_sz
                        else:
                            merge_plan_obj["files"].append({"path": up_path, "size": up_sz})
                    merge_plan_obj["files"].sort(key=lambda f: str(f.get("path") or ""))
                    merge_plan_obj["file_count"] = len(merge_plan_obj["files"])
                    merge_plan_obj["conflicts"] = merge_plan_obj["file_count"]

        # Khử lỗi Version Downgrade, bảo toàn/nâng cấp ResourcePacker & kiểm tra hợp lệ trước khi xuất
        res_path = ""
        if os.path.exists(CONFIG_PATH):
            try:
                with open(CONFIG_PATH, "r", encoding="utf-8") as cf:
                    l_cfg = json.load(cf)
                if isinstance(l_cfg, dict):
                    cand = str(l_cfg.get("resources_path") or "")
                    if cand and os.path.exists(cand):
                        res_path = cand
            except Exception:
                pass
        if not res_path:
            res_path = _auto_detect_base_resources()
        elif _is_under_dir(res_path, DEFAULT_LOCAL_GAME_DIR):
            newer_cand = _auto_detect_base_resources()
            if newer_cand and os.path.normcase(os.path.abspath(newer_cand)) != os.path.normcase(os.path.abspath(res_path)):
                cur_m = _read_zip_version_meta(res_path)
                new_m = _read_zip_version_meta(newer_cand)
                if (new_m["ver_tuple"], new_m["build_num"], new_m["mtime"]) > (
                    cur_m["ver_tuple"], cur_m["build_num"], cur_m["mtime"]
                ):
                    res_path = newer_cand

        base_prov: BaseResourceProvider | None = None
        cur_vtxt_bytes: bytes | None = None
        base_rpack_bytes: bytes | None = None
        if res_path and os.path.exists(res_path):
            try:
                base_prov = BaseResourceProvider(res_path)
                if base_prov.has("version.txt"):
                    v_cand = base_prov.read("version.txt")
                    if v_cand.strip():
                        cur_vtxt_bytes = v_cand
                if base_prov.has("assetbundle/resourcepackerinfosetall.assetbundle"):
                    base_rpack_bytes = base_prov.read("assetbundle/resourcepackerinfosetall.assetbundle")
            except Exception:
                base_prov = None

        merged_hids: set[int] = set()
        for lm in loaded:
            for hid_val in (lm.get("hids") or ()):
                merged_hids.add(int(hid_val))

        resolved_ver_seg: str | None = None
        if base_prov is not None:
            resolved_ver_seg = base_prov.game_version
        elif loaded and loaded[0].get("ver"):
            resolved_ver_seg = str(loaded[0].get("ver"))

        raw_items: list[tuple[zipfile.ZipInfo, str, bytes]] = []
        has_stale_hs1 = False
        with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as in_zf:
            for info in in_zf.infolist():
                if info.is_dir():
                    continue
                fn_norm = info.filename.replace("\\", "/")
                fn_low = fn_norm.lower()
                data = in_zf.read(info.filename)
                if resolved_ver_seg is None:
                    np_e = cp.normalize_aov_path(fn_norm)
                    if np_e and np_e.startswith("Resources/"):
                        parts_e = np_e.split("/", 2)
                        if len(parts_e) >= 2 and re.match(r"^\d+\.\d+", parts_e[1]):
                            resolved_ver_seg = parts_e[1]
                if fn_low.endswith("/thanos/heroskin_1.bytes") or fn_low == "thanos/heroskin_1.bytes" or fn_low.endswith("heroskin_1.bytes"):
                    if len(data) < 60_000:
                        has_stale_hs1 = True
                raw_items.append((info, fn_low, data))

        if not resolved_ver_seg:
            resolved_ver_seg = DEFAULT_GAME_VERSION

        # Xác định dữ liệu Thanos chuẩn (nếu gặp HeroSkin_1 cũ < 60KB thì thay bằng bộ Thanos chuẩn của Resources hoặc loại bỏ)
        base_thanos: dict[str, bytes] = {}
        if has_stale_hs1 and base_prov is not None:
            for th_name in (
                "Thanos/HeroSkin_1.bytes",
                "Thanos/HeroSkin_2.bytes",
                "Thanos/HeroSkin_3.bytes",
                "Thanos/HeroSkin_4.bytes",
            ):
                if base_prov.has(th_name):
                    base_thanos[th_name.lower()] = base_prov.read(th_name)

        clean_buf = io.BytesIO()
        clean_sizes: dict[str, int] = {}
        seen_vtxt = False
        seen_valid_rpack = False
        with zipfile.ZipFile(clean_buf, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as clean_zf:
            for info, fn_low, data in raw_items:
                # 1. Tránh hạ cấp version.txt — đồng bộ theo Resources gốc nếu có
                if fn_low.endswith("/version.txt") or fn_low == "version.txt":
                    seen_vtxt = True
                    out_vtxt = cur_vtxt_bytes if cur_vtxt_bytes is not None else data
                    clean_zf.writestr(info, out_vtxt)
                    clean_sizes[info.filename] = len(out_vtxt)
                    continue

                # 2. Xử lý Thanos cũ (< 60KB HeroSkin_1 của bản cũ): nâng từ base_prov nếu đủ hoặc bỏ qua
                is_thanos = any(
                    fn_low.endswith(x)
                    for x in (
                        "/thanos/heroskin_1.bytes", "/thanos/heroskin_2.bytes",
                        "/thanos/heroskin_3.bytes", "/thanos/heroskin_4.bytes",
                        "thanos/heroskin_1.bytes", "thanos/heroskin_2.bytes",
                        "thanos/heroskin_3.bytes", "thanos/heroskin_4.bytes",
                    )
                )
                if is_thanos and has_stale_hs1:
                    matched_th_key = next((tk for tk in base_thanos if fn_low.endswith(tk)), None)
                    if matched_th_key:
                        data = base_thanos[matched_th_key]
                        clean_zf.writestr(info.filename, data)
                        clean_sizes[info.filename] = len(data)
                    continue

                # 3. Bảo toàn ResourcePackerInfoSetAll (không xóa theo ngưỡng 5MB) & nâng cấp / đánh dấu battle+show skin
                if fn_low.endswith("resourcepackerinfosetall.assetbundle"):
                    try:
                        rp_parsed = cp.parse_rpack(cp.unpack_unityfs(data))
                        if rp_parsed is None:
                            raise ValueError("Invalid rpack table")
                    except Exception:
                        continue
                    if base_rpack_bytes is not None:
                        try:
                            base_rp = cp.parse_rpack(cp.unpack_unityfs(base_rpack_bytes))
                            if base_rp is not None and (
                                (base_rp["rec_cnt"], base_rp["pvk"]) != (rp_parsed["rec_cnt"], rp_parsed["pvk"])
                            ):
                                data = cp.merge_resource_packer([base_rpack_bytes, data], [set(), merged_hids])
                        except Exception:
                            pass
                    for hid_m in sorted(merged_hids):
                        data = _patch_rpack_for_hero_battle_skins(data, hid_m)
                    seen_valid_rpack = True
                    clean_zf.writestr(info, data)
                    clean_sizes[info.filename] = len(data)
                    continue

                # 4. Bảo toàn ResourceVerificationInfoSetAll hợp lệ (chỉ bỏ nếu là tệp rỗng/rác < 1KB)
                if fn_low.endswith("resourceverificationinfosetall.assetbundle"):
                    if len(data) < 1024:
                        continue
                    clean_zf.writestr(info, data)
                    clean_sizes[info.filename] = len(data)
                    continue

                clean_zf.writestr(info, data)
                clean_sizes[info.filename] = len(data)

            if not seen_valid_rpack and base_rpack_bytes is not None and merged_hids:
                synth_rp = base_rpack_bytes
                for hid_m in sorted(merged_hids):
                    synth_rp = _patch_rpack_for_hero_battle_skins(synth_rp, hid_m)
                rp_arc = f"Resources/{resolved_ver_seg}/assetbundle/resourcepackerinfosetall.assetbundle"
                clean_zf.writestr(rp_arc, synth_rp)
                clean_sizes[rp_arc] = len(synth_rp)

            if not seen_vtxt:
                if cur_vtxt_bytes is not None:
                    vtxt_arc = f"Resources/{resolved_ver_seg}/version.txt"
                    clean_zf.writestr(vtxt_arc, cur_vtxt_bytes)
                    clean_sizes[vtxt_arc] = len(cur_vtxt_bytes)
                else:
                    raise RuntimeError("Các gói mod đầu vào thiếu tệp version.txt và không tìm thấy Resources gốc.")

        # Kiểm tra đầu ra gộp hợp lệ trước khi ghi đĩa
        if not clean_sizes:
            raise RuntimeError("Gói mod sau khi gộp bị rỗng, hủy xuất tệp lỗi.")
        for c_path, c_sz in clean_sizes.items():
            c_low = c_path.replace("\\", "/").lower()
            if c_sz <= 0 and (
                c_low.endswith("version.txt")
                or c_low.endswith(".pkg.bytes")
                or c_low.endswith("resourcepackerinfosetall.assetbundle")
            ):
                raise RuntimeError(f"Tệp quan trọng trong gói gộp bị rỗng (0 byte): {c_path}")

        zip_bytes = clean_buf.getvalue()
        if isinstance(merge_plan_obj.get("files"), list):
            merge_plan_obj["files"] = [
                {"path": p, "size": sz} for p, sz in sorted(clean_sizes.items())
            ]
            merge_plan_obj["file_count"] = len(clean_sizes)
            merge_plan_obj["conflicts"] = len(clean_sizes)

        eff_out_name = output_name if output_name is not None else custom_filename
        default_merge_stem = os.path.splitext(os.path.basename(out_name))[0] or "Totorox_Merged"
        clean_stem = _sanitize_output_stem(eff_out_name, default_merge_stem)

        fmt = (output_format or "zip").strip().lower().lstrip(".")
        if fmt == "3105":
            final_bytes = _encode_zip_to_3105(zip_bytes, clean_stem, password=shared_pw)
            final_name = f"{clean_stem}.3105"
        else:
            final_bytes = zip_bytes
            final_name = f"{clean_stem}.zip"

        target_dir = os.path.abspath(output_dir) if output_dir else OUTPUT_DIR
        os.makedirs(target_dir, exist_ok=True)
        out_path = os.path.join(target_dir, final_name)
        with open(out_path, "wb") as f:
            f.write(final_bytes)

        return {
            "filename": final_name,
            "output_path": out_path,
            "size_bytes": len(final_bytes),
            "elapsed_ms": int((time.time() - t0) * 1000),
            "merge_plan": merge_plan_obj,
        }

    @staticmethod
    def convert_package(
        input_bytes: bytes,
        filename: str,
        target_format: str,
        password: str | None = None,
        output_dir: str | None = None,
        *,
        mode: str | None = None,
    ) -> dict[str, Any]:
        raw = bytes(input_bytes)
        clean_mode = (mode or target_format or "").strip().lower()
        if clean_mode == "inspect":
            return cp.inspect_patch_package_light(raw)

        pw = (password or "").strip() or None
        base_fn = os.path.basename(str(filename or "").replace("\\", "/"))
        stem = _sanitize_output_stem(base_fn, "Totorox_Patch")

        if clean_mode in ("3105", ".3105", "to_3105", "zip_to_3105", "encode"):
            out_bytes = _encode_zip_to_3105(raw, stem, password=pw)
            out_name = f"{stem}.3105"
            meta = cp.inspect_patch_package_light(out_bytes)
        elif clean_mode in ("zip", ".zip", "to_zip", "3105_to_zip", "decode", "from_zip"):
            out_bytes, meta = _decode_3105_to_zip(raw, password=pw)
            out_name = f"{stem}.zip"
        else:
            raise ValueError(f"Chế độ chuyển đổi không hợp lệ: {target_format!r}")

        target_dir = os.path.abspath(output_dir) if output_dir else OUTPUT_DIR
        os.makedirs(target_dir, exist_ok=True)
        out_path = os.path.join(target_dir, out_name)
        with open(out_path, "wb") as f:
            f.write(out_bytes)
        return {
            "filename": out_name,
            "output_path": out_path,
            "size_bytes": len(out_bytes),
            "metadata": meta,
        }
