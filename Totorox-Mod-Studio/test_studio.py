"""
Totorox Mod Studio — 4-Tier End-to-End & Contract Test Suite (Totorox 3.0)

Run:
    C:\\Users\\studi\\AppData\\Local\\Python\\pythoncore-3.15-64\\python.exe -m pytest Totorox-Mod-Studio/test_studio.py -v

Tiers:
    - Tier 1 (TestTier1_FeatureCoverage): >= 5 happy-path tests per feature F1-F12 (>= 60 tests)
    - Tier 2 (TestTier2_BoundaryAndCornerCases): >= 5 boundary/negative/Unicode tests per feature F1-F12 (>= 60 tests)
    - Tier 3 (TestTier3_CrossFeatureCombinations): >= 12 pairwise cross-feature integration tests
    - Tier 4 (TestTier4_RealWorldScenarios): >= 6 full real-data end-to-end scenarios

Isolation:
    All config, catalog cache, custom bypass seed, unpacked files, and generated mod outputs
    write strictly inside pytest `tmp_path`. Repo files (`studio_config.json`, `catalog_cache.json`,
    `assets/bypass_seed.zst`, `output/`, and `Resources Gốc.zip`) are verified unmodified.
"""

from __future__ import annotations

import base64
import hashlib
import importlib
import importlib.util
import io
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

import pytest
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# ---------------------------------------------------------------------------
# Path Setup (Never import `app` or read `studio.html` at module top-level)
# ---------------------------------------------------------------------------

STUDIO_DIR = Path(__file__).resolve().parent
REPO_ROOT = STUDIO_DIR.parent
BACKEND_DIR = REPO_ROOT / "Totorox-Backend"

for _p in (str(STUDIO_DIR), str(BACKEND_DIR)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import core_processor as cp  # noqa: E402
import jtcom  # noqa: E402
import studio_engine as se  # noqa: E402

GAME_DIR = Path(r"C:\Users\studi\OneDrive\Documents\Tools\game")
RESOURCES_ZIP = next(
    (
        GAME_DIR / n
        for n in ("Resources 18_11.zip", "Resources Gốc.zip", "Resources.zip")
        if (GAME_DIR / n).exists()
    ),
    GAME_DIR / "Resources Gốc.zip",
)
NAK_ZIP = GAME_DIR / "Nak.zip"
BILOW_ZIP = GAME_DIR / "Bilow.zip"
EDRAS_ZIP = GAME_DIR / "Edras Vấn Tâm Kiếm.zip"
THREE_HEROES_ZIP = GAME_DIR / "AOV_Mod_3Heroes_f9d6.zip"

EDGE_EXE = Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe")

PROTECTED_STUDIO_FILES = (
    STUDIO_DIR / "studio_config.json",
    STUDIO_DIR / "catalog_cache.json",
    STUDIO_DIR / "assets" / "bypass_seed.zst",
)
REPO_OUTPUT_DIR = STUDIO_DIR / "output"

# Mint Design Tokens from Totorox/views/DesignSystem.swift (Light & Dark)
MINT_LIGHT_TOKENS = (
    "#5BB9A8",  # mintAccent
    "#F9FAFC",  # pageBackground
    "#FFFFFF",  # cardBackground
    "#F4F3FD",  # searchBackground
    "#1E2430",  # textPrimary
    "#FF7A59",  # badgeText
    "#FFEFEA",  # badgeBackground
)
MINT_DARK_TOKENS = (
    "#4EC9B5",  # mintAccent
    "#0D1117",  # pageBackground
    "#161B24",  # cardBackground
    "#212836",  # searchBackground
    "#F1F5F9",  # textPrimary
    "#FF8F73",  # badgeText
    "#3D211B",  # badgeBackground
)
FORBIDDEN_CDN_HOSTS = (
    "cdn.tailwindcss.com",
    "cdn.jsdelivr.net",
    "unpkg.com",
    "fonts.googleapis.com",
    "fonts.gstatic.com",
    "cdnjs.cloudflare.com",
)


# ---------------------------------------------------------------------------
# Lazy M2 Guards (Zero Fake Passes)
# ---------------------------------------------------------------------------

def _require_app_module():
    app_path = STUDIO_DIR / "app.py"
    if not app_path.exists():
        if os.environ.get("TOTOROX_ALLOW_MISSING_M2") == "1":
            pytest.skip("TOTOROX_ALLOW_MISSING_M2=1 and M2 app.py not yet created")
        pytest.fail(f"M2 deliverable missing: {app_path}")
    mod = importlib.import_module("app")
    return mod


def _require_studio_html() -> str:
    html_path = STUDIO_DIR / "studio.html"
    if not html_path.exists():
        if os.environ.get("TOTOROX_ALLOW_MISSING_M2") == "1":
            pytest.skip("TOTOROX_ALLOW_MISSING_M2=1 and M2 studio.html not yet created")
        pytest.fail(f"M2 deliverable missing: {html_path}")
    return html_path.read_text(encoding="utf-8")


def _patch_module_paths(mod: Any, data_dir: Path, out_dir: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    replacements = {
        "APP_DATA_DIR": str(data_dir),
        "CONFIG_PATH": str(data_dir / "studio_config.json"),
        "CATALOG_CACHE_PATH": str(data_dir / "catalog_cache.json"),
        "CUSTOM_BYPASS_SEED_PATH": str(data_dir / "custom_bypass_seed.zst"),
        "OUTPUT_DIR": str(out_dir),
    }
    for attr, val in replacements.items():
        if hasattr(mod, attr):
            monkeypatch.setattr(mod, attr, val)


# ---------------------------------------------------------------------------
# Independent Binary & Crypto Oracle Helpers
# ---------------------------------------------------------------------------

def _sha256_or_none(path: Path) -> str | None:
    if not path.exists():
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_zip_tree(zip_bytes: bytes) -> dict[str, bytes]:
    tree: dict[str, bytes] = {}
    with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as zf:
        for zi in zf.infolist():
            if not zi.is_dir():
                tree[zi.filename] = zf.read(zi.filename)
    return tree


def strip_resources_prefix(zip_tree: dict[str, bytes]) -> tuple[str, dict[str, bytes]]:
    rel_map: dict[str, bytes] = {}
    ver = ""
    for full_path, data in zip_tree.items():
        norm = full_path.replace("\\", "/")
        np = cp.normalize_aov_path(norm)
        if np and np.startswith("Resources/"):
            parts = np.split("/", 2)
            if len(parts) == 3:
                if not ver:
                    ver = parts[1]
                rel_map[parts[2]] = data
                continue
        rel_map[norm] = data
    return ver, rel_map


def assert_pkg_stored_zero(pkg_bytes: bytes, label: str = ".pkg.bytes") -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    with zipfile.ZipFile(io.BytesIO(pkg_bytes), "r") as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            assert info.compress_type == zipfile.ZIP_STORED, (
                f"{label}:{info.filename} compress_type={info.compress_type} != ZIP_STORED(0)"
            )
            entries[info.filename] = zf.read(info.filename)
    return entries


def verify_0x224a_pkcs7(enc_bytes: bytes, stem: str) -> bytes:
    assert len(enc_bytes) > 8 and enc_bytes[:4] == b"\x22\x4A\x67\x00", (
        f"Bad 0x224A header for {stem}: {enc_bytes[:8].hex()}"
    )
    declared_len = struct.unpack_from("<I", enc_bytes, 4)[0]
    key = cp.derive_pkg_key(stem)
    dec = Cipher(algorithms.AES(key), modes.CBC(cp._AES128_CBC_IV), backend=default_backend()).decryptor()
    raw_pt = dec.update(enc_bytes[8:]) + dec.finalize()
    pad = raw_pt[-1]
    assert 1 <= pad <= 16 and raw_pt[-pad:] == bytes([pad]) * pad, (
        f"Invalid PKCS#7 padding for {stem}: pad={pad}"
    )
    plain = cp.pg_decrypt(enc_bytes, stem)
    assert len(plain) == declared_len, f"Length mismatch for {stem}: {len(plain)} != {declared_len}"
    return plain


def assert_actor_actions_encrypted(
    pkg_bytes: bytes,
    hero_id: int,
    *,
    allow_zstd_only: bool = False,
) -> dict[str, str]:
    entries = assert_pkg_stored_zero(pkg_bytes, f"Actor_{hero_id}_Actions.pkg.bytes")
    decoded: dict[str, str] = {}
    for ename, raw in entries.items():
        if not ename.lower().endswith(".xml"):
            continue
        assert len(raw) > 8 and raw[:2] == b"\x22\x4A", (
            f"Plain/unencrypted XML inside Actor_{hero_id}_Actions.pkg.bytes: {ename}"
        )
        b2, b3 = raw[2], raw[3]
        assert not (b2 == 0x00 and b3 == 0x00), (
            f"Unencrypted 0x224A0000 XML inside Actor_{hero_id}_Actions.pkg.bytes: {ename}"
        )
        if allow_zstd_only:
            assert b2 == 0x67 or (b2 == 0x00 and b3 == 0xEF), (
                f"Invalid 0x224A mode inside Actor_{hero_id}_Actions.pkg.bytes: {ename} (header={raw[:4].hex()})"
            )
        else:
            assert b2 == 0x67, (
                f"XML not AES-128-CBC 0x224A67xx encrypted inside Actor_{hero_id}_Actions.pkg.bytes: "
                f"{ename} (header={raw[:4].hex()})"
            )
        stem = os.path.splitext(os.path.basename(ename))[0]
        plain = verify_0x224a_pkcs7(raw, stem) if raw[:4] == b"\x22\x4A\x67\x00" else cp.pg_decrypt(raw, stem)
        txt = plain.decode("utf-8")
        assert any(tok in txt for tok in ("<Project", "<Action", "<?xml")), (
            f"Invalid XML after decrypt: {ename}"
        )
        decoded[ename] = txt
    assert decoded, f"No XML entries found in Actor_{hero_id}_Actions.pkg.bytes"
    return decoded


def verify_mses_table(enc_bytes: bytes, stem: str, *, require_md5: bool = True) -> dict[str, Any]:
    plain = cp.pg_decrypt(enc_bytes, stem)
    assert len(plain) >= 140 and plain[:4] == b"MSES", f"{stem} is not valid MSES"
    parsed = cp.parse_mses(plain)
    assert parsed is not None, f"parse_mses failed for {stem}"
    _, hdr_cnt = struct.unpack_from("<II", plain, 8)
    assert hdr_cnt == len(parsed["recs"]), f"{stem} MSES count mismatch: {hdr_cnt} != {len(parsed['recs'])}"
    if require_md5:
        assert parsed["has_md5"] is True, f"{stem} MSES missing or corrupted MD5 header (96:128)"
    if parsed["has_md5"]:
        expected_md5 = hashlib.md5(plain[140:]).hexdigest().lower()
        actual_md5 = plain[96:128].decode("ascii").lower()
        assert actual_md5 == expected_md5, f"{stem} MSES MD5 mismatch: {actual_md5} != {expected_md5}"
    return parsed


def assert_lua_kiana_clean(pkg_bytes: bytes, label: str = "Lua.pkg.bytes") -> None:
    entries = assert_pkg_stored_zero(pkg_bytes, label)
    for ename, data in entries.items():
        assert cp._KIANA_AD_GLOBAL_MARKER not in data, f"Kiana marker leaked in {label}:{ename}"
        assert b"raw.githubusercontent.com" not in data, f"GitHub ad URL leaked in {label}:{ename}"


def verify_heroskin_1_and_2(
    hs1_enc: bytes,
    hs2_enc: bytes,
    *,
    expected_hero_id: int | None = None,
    expected_skin_id: int | None = None,
    expected_button_id: int | None = None,
    expected_billboard_id: int | None = None,
    pkg_md5s: dict[str, str] | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    hs1_dec = cp.pg_decrypt(hs1_enc, "HeroSkin_1")
    hs2_dec = cp.pg_decrypt(hs2_enc, "HeroSkin_2")
    assert b"Project.Plugins_d" in hs1_dec and b"Project.Plugins_d" in hs2_dec
    lay1 = cp.parse_kiana_hs1(hs1_dec)
    lay2 = cp.parse_kiana_hs2(hs2_dec)
    assert lay1 is not None and lay1["pairs"], "HeroSkin_1 invalid IFix layout"
    assert lay2 is not None and lay2["params"], "HeroSkin_2 invalid IFix layout"
    if expected_hero_id is not None:
        assert lay1["pairs"][0][0] == expected_hero_id
        assert lay2["params"][0][0] == expected_hero_id
    if expected_skin_id is not None:
        assert lay1["pairs"][0][1] == expected_skin_id
    if expected_button_id is not None and expected_billboard_id is not None:
        assert (lay2["params"][0][1], lay2["params"][0][2]) == (expected_button_id, expected_billboard_id)
    if pkg_md5s:
        for dec_buf in (hs1_dec, hs2_dec):
            low = dec_buf.lower()
            for pkg_name, md5_hex in pkg_md5s.items():
                needle = (pkg_name.lower() + " ").encode("utf-8")
                if needle in low:
                    assert (needle + md5_hex.lower().encode("ascii")) in low, (
                        f"Stale MD5 for {pkg_name} in HeroSkin_1/2"
                    )
    return lay1, lay2


def verify_lua_only_thanos(
    rel_map: dict[str, bytes],
    provider: se.BaseResourceProvider,
) -> None:
    """Kiểm tra chế độ Lua-only mặc định giữ nguyên Thanos/HeroSkin_1..4.bytes chuẩn từ Resources."""
    assert "Thanos/HeroSkin_1.bytes" in rel_map and "Thanos/HeroSkin_2.bytes" in rel_map
    assert rel_map["Thanos/HeroSkin_1.bytes"] == provider.read("Thanos/HeroSkin_1.bytes")
    assert rel_map["Thanos/HeroSkin_2.bytes"] == provider.read("Thanos/HeroSkin_2.bytes")
    for extra in ("Thanos/HeroSkin_3.bytes", "Thanos/HeroSkin_4.bytes"):
        if provider.has(extra):
            assert rel_map[extra] == provider.read(extra)
    assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")
    assert_lua_kiana_clean(rel_map["StableSystems_3.pkg.bytes"], "StableSystems_3.pkg.bytes")


def verify_kiana_ifix_thanos(
    rel_map: dict[str, bytes],
    hero_id: int,
    skin_id: int,
    pbtn_id: int,
    knotify_id: int,
) -> None:
    """Kiểm tra chế độ kiana_ifix mặc định patch đúng HeroSkin_1/2, đồng bộ MD5 Lua và khử sạch quảng cáo."""
    assert "Thanos/HeroSkin_1.bytes" in rel_map and "Thanos/HeroSkin_2.bytes" in rel_map
    hs1_dec = cp.pg_decrypt(rel_map["Thanos/HeroSkin_1.bytes"], "HeroSkin_1")
    hs2_dec = cp.pg_decrypt(rel_map["Thanos/HeroSkin_2.bytes"], "HeroSkin_2")
    lay1 = cp.parse_kiana_hs1(hs1_dec)
    lay2 = cp.parse_kiana_hs2(hs2_dec)
    assert lay1 is not None and (hero_id, skin_id) in lay1["pairs"]
    assert lay2 is not None and (hero_id, pbtn_id, knotify_id) in lay2["params"]
    klua_md5 = hashlib.md5(rel_map["KernelLua.pkg.bytes"]).hexdigest().encode("ascii")
    ss3_md5 = hashlib.md5(rel_map["StableSystems_3.pkg.bytes"]).hexdigest().encode("ascii")
    assert klua_md5 in hs1_dec and ss3_md5 in hs1_dec
    assert klua_md5 in hs2_dec and ss3_md5 in hs2_dec
    assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")
    assert_lua_kiana_clean(rel_map["StableSystems_3.pkg.bytes"], "StableSystems_3.pkg.bytes")


def _build_mock_kiana_seed_zip(
    version_txt: str = "1.64.1.13|1802180",
    *,
    dirty_ads: bool = False,
) -> bytes:
    """Tạo gói mod mẫu hợp lệ có Kiana IFix (HeroSkin_1/2) & Lua để kiểm thử chế độ kiana_ifix."""
    base_seed = se.load_bypass_seed()
    klua_bytes = base_seed["KernelLua.pkg.bytes"]
    ss3_bytes = base_seed["StableSystems_3.pkg.bytes"]
    if dirty_ads:
        dirty_lua = b"\x1bLuaR_0x432312_ad_" + cp._KIANA_AD_GLOBAL_MARKER + b"https://raw.githubusercontent.com/test/ad.txt"
        klua_bytes = cp.build_in_memory_store_zip([("Lua_Signed/Init_lua.bytes", 0, 0x21, dirty_lua)])

    prefix = b"Project.Plugins_d\x00" + b"\x00" * 10
    arr_a = bytearray(12 * 8)
    struct.pack_into("<IIIIIiII", arr_a, 8, 0xA4, 1, 0xA7, 0x50, 0x8F, 131, 0xA6, 0)
    arr_b = bytearray(64 * 8)
    struct.pack_into("<Ii", arr_b, 0, 0x8F, 131)
    arr_c = bytearray(64 * 8)
    struct.pack_into("<Ii", arr_c, 0, 0x8F, 131)
    struct.pack_into("<IIIIIIII", arr_c, 56 * 8, 0xA6, 0, 0x86, 0, 0x8F, 13118, 0xAD, 0)
    md5_tail = b"\x00KernelLua.pkg.bytes " + b"0" * 32 + b" StableSystems_3.pkg.bytes " + b"0" * 32 + b"\x00"
    hs1_dec = (
        prefix
        + struct.pack("<I", 12) + bytes(arr_a) + b"\x00" * 4
        + struct.pack("<I", 64) + bytes(arr_b) + b"\x00" * 4
        + struct.pack("<I", 64) + bytes(arr_c)
        + md5_tail
    )
    assert cp.parse_kiana_hs1(hs1_dec) is not None

    arr2 = bytearray(70 * 8)
    struct.pack_into(
        "<IiIiIIIIIIiIIIIIIiII",
        arr2,
        58 * 8,
        0xA4, 1, 0x8F, 131, 0xA6, 0, 0x86, 0, 0xA4, 0, 0x8F, 21, 0x4B, 3, 0xA4, 0, 0x8F, 20, 0x4B, 2,
    )
    hs2_dec = prefix + struct.pack("<I", 70) + bytes(arr2) + md5_tail
    assert cp.parse_kiana_hs2(hs2_dec) is not None

    ver_folder = se.BaseResourceProvider._extract_ver_from_txt(version_txt) or "1.64.1"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(f"Resources/{ver_folder}/version.txt", version_txt.encode("utf-8"))
        zf.writestr(f"Resources/{ver_folder}/KernelLua.pkg.bytes", klua_bytes)
        zf.writestr(f"Resources/{ver_folder}/StableSystems_3.pkg.bytes", ss3_bytes)
        zf.writestr(f"Resources/{ver_folder}/Thanos/HeroSkin_1.bytes", cp.pg_encrypt(hs1_dec, "HeroSkin_1"))
        zf.writestr(f"Resources/{ver_folder}/Thanos/HeroSkin_2.bytes", cp.pg_encrypt(hs2_dec, "HeroSkin_2"))
    return buf.getvalue()


def _install_mock_kiana_seed(provider: se.BaseResourceProvider) -> dict[str, Any]:
    vtxt = (
        provider.read("version.txt").decode("utf-8", errors="ignore").strip()
        if provider.has("version.txt")
        else f"{provider.game_version}.13|1802180"
    )
    return se.import_bypass_seed_from_mod_zip(_build_mock_kiana_seed_zip(vtxt))


def verify_rpack_unityfs(rp_bytes: bytes, hero_id: int | None = None) -> dict[str, Any]:
    assert rp_bytes[:7] == b"UnityFS"
    u = cp.unpack_unityfs(rp_bytes)
    parsed = cp.parse_rpack(u)
    assert parsed["rec_cnt"] > 0 and parsed["recs"]
    sf = cp._parse_unity_sf_objects(bytes(u["payload"]))
    if sf is not None:
        doff, objs = sf
        for o in objs:
            assert doff + o["byteStart"] + o["byteSize"] <= len(u["payload"])
    if hero_id is not None:
        hp = str(hero_id)
        for path, (_, hs, he) in parsed["recs"].items():
            low = path.lower()
            if (low.startswith("assetbundle/battle/skin/") or low.startswith("assetbundle/show/skin/")) and re.match(
                rf"^{hp}\d{{1,2}}_", os.path.basename(low)
            ):
                if he - hs == 12 and struct.unpack_from("<I", u["payload"], hs + 8)[0] == 0:
                    assert bytes(u["payload"][hs : hs + 12]) == b"KianaMod\x00\x00\x00\x00"
    return parsed


def verify_3105_envelope(
    raw_3105: bytes,
    *,
    password: str | None = None,
    wrong_password: str = "wrong-pw-!@#",
) -> dict[str, bytes]:
    assert raw_3105[: len(cp._PACKAGE_MAGIC)] == cp._PACKAGE_MAGIC
    meta = cp.inspect_patch_package_light(raw_3105)
    assert meta["ok"] and meta["kind"] == "patch_package"
    if password is not None:
        assert meta["is_password_protected"] is True
        with pytest.raises(cp.PatchPackageDecodeError):
            cp.convert_header({"data": raw_3105, "mode": "from_zip", "password": wrong_password})
        with pytest.raises(cp.PatchPackageDecodeError):
            cp.convert_header({"data": raw_3105, "mode": "from_zip", "password": None})
    opened = cp.convert_header({"data": raw_3105, "mode": "from_zip", "password": password})
    assert opened["ok"] and "zip_bytes_b64" in opened
    zip_raw = base64.b64decode(opened["zip_bytes_b64"])
    return read_zip_tree(zip_raw)


def _extract_catalog_skins(catalog: dict[str, Any]) -> list[dict[str, Any]]:
    if isinstance(catalog.get("skins"), list) and catalog["skins"]:
        return catalog["skins"]
    skins: list[dict[str, Any]] = []
    for h in catalog.get("heroes") or []:
        skins.extend(h.get("skins") or [])
    return skins


def _extract_catalog_billboards(catalog: dict[str, Any]) -> list[dict[str, Any]]:
    if "billboards" in catalog:
        return catalog["billboards"]
    return catalog["kill_broadcasts"]


def _extract_decrypted_bytes(res: Any) -> bytes:
    if isinstance(res, (bytes, bytearray)):
        return bytes(res)
    if isinstance(res, dict):
        for k in ("plain_bytes", "plain", "data", "bytes", "raw"):
            v = res.get(k)
            if isinstance(v, (bytes, bytearray)):
                return bytes(v)
        for k in ("decrypted_b64", "plain_b64", "data_b64"):
            v = res.get(k)
            if isinstance(v, str) and v:
                return base64.b64decode(v)
        if isinstance(res.get("text"), str):
            return res["text"].encode("utf-8")
    raise AssertionError(f"Could not extract decrypted bytes from decrypt_0x224a result: {type(res)} / {res}")


def _extract_common_xml(rel_map: dict[str, bytes], xml_subpath: str) -> str:
    ca = rel_map["Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes"]
    entries = assert_pkg_stored_zero(ca, "CommonActions.pkg.bytes")
    for name, raw in entries.items():
        if name.lower().endswith(xml_subpath.lower()):
            return cp.decode_aov_xml_if_needed(raw, name).decode("utf-8")
    raise AssertionError(f"Missing {xml_subpath} inside CommonActions.pkg.bytes")


def _extract_actor_actions_pkg(rel_map: dict[str, bytes], hero_id: int) -> bytes:
    return rel_map[f"Ages/Prefab_Characters/Prefab_Hero/Actor_{hero_id}_Actions.pkg.bytes"]


def _extract_actorinfo_plain(rel_map: dict[str, bytes], hero_id: int) -> tuple[str, bytes]:
    pkg = rel_map[f"Prefab_Characters/Actor_{hero_id}_Infos.pkg.bytes"]
    entries = assert_pkg_stored_zero(pkg, f"Actor_{hero_id}_Infos.pkg.bytes")
    for ename, raw in entries.items():
        if "tutor" not in ename.lower() and ename.lower().endswith("_actorinfo.bytes"):
            stem = os.path.basename(ename).rsplit(".", 1)[0]
            return ename, cp.pg_decrypt(raw, stem)
    raise AssertionError(f"No *_actorinfo.bytes inside Actor_{hero_id}_Infos.pkg.bytes")


def _build_lightweight_extracted_resources(provider: se.BaseResourceProvider, dest_root: Path) -> Path:
    """Copy a minimal genuine subset of Resources Gốc.zip into `dest_root` for fast dir-provider tests."""
    ver = provider.game_version
    base = dest_root / "Resources" / ver
    wanted_prefixes = (
        "version.txt",
        "Languages/VN_Garena_VN/",
        "Databin/Client/Actor/",
        "Databin/Client/Huanhua/",
        "Databin/Client/Character/",
        "Databin/Client/Motion/",
        "Databin/Client/Skill/",
        "Databin/Client/Shop/",
        "Databin/Client/Sound/",
        "Prefab_Characters/Actor_131_Infos.pkg.bytes",
        "Prefab_Characters/Actor_150_Infos.pkg.bytes",
        "Prefab_Characters/Actor_546_Infos.pkg.bytes",
        "Prefab_Characters/Actor_548_Infos.pkg.bytes",
        "AssetRefs/Hero/131_AssetRef.bytes",
        "AssetRefs/Hero/150_AssetRef.bytes",
        "Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes",
        "Ages/Prefab_Characters/Prefab_Hero/Actor_131_Actions.pkg.bytes",
        "Ages/Prefab_Characters/Prefab_Hero/Actor_150_Actions.pkg.bytes",
        "Thanos/",
        "assetbundle/resourcepackerinfosetall.assetbundle",
        "assetbundle/resourceverificationinfosetall.assetbundle",
    )
    for rel in provider.list_rel_paths():
        if any(rel == wp or rel.startswith(wp) for wp in wanted_prefixes):
            out = base / Path(rel)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(provider.read(rel))
    return dest_root


def _read_zip_tree_from_build(res: dict[str, Any]) -> tuple[bytes, str, dict[str, bytes]]:
    out_path = Path(res["output_path"])
    assert out_path.exists(), f"Output file missing: {out_path}"
    raw = out_path.read_bytes()
    assert len(raw) == res["size_bytes"]
    ver, rel_map = strip_resources_prefix(read_zip_tree(raw))
    return raw, ver, rel_map


def _find_openapi_body_mode(app_mod: Any, path: str) -> str:
    schema = app_mod.app.openapi()
    post = (schema.get("paths") or {}).get(path, {}).get("post", {})
    content = ((post.get("requestBody") or {}).get("content")) or {}
    if "multipart/form-data" in content:
        return "multipart"
    return "json"


# ---------------------------------------------------------------------------
# Session & Function Fixtures (Strict Isolation)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def verify_repo_data_unmodified():
    if not RESOURCES_ZIP.exists():
        pytest.fail(f"Required base archive missing: {RESOURCES_ZIP}")

    before_hashes = {str(p): _sha256_or_none(p) for p in PROTECTED_STUDIO_FILES}
    before_output = sorted(p.name for p in REPO_OUTPUT_DIR.iterdir()) if REPO_OUTPUT_DIR.exists() else []
    yield
    after_hashes = {str(p): _sha256_or_none(p) for p in PROTECTED_STUDIO_FILES}
    after_output = sorted(p.name for p in REPO_OUTPUT_DIR.iterdir()) if REPO_OUTPUT_DIR.exists() else []
    assert after_hashes == before_hashes, f"Protected studio files mutated: {before_hashes} != {after_hashes}"
    assert after_output == before_output, f"Repo output/ mutated: {before_output} != {after_output}"


@pytest.fixture(scope="session")
def shared_provider() -> se.BaseResourceProvider:
    return se.BaseResourceProvider(str(RESOURCES_ZIP))


@pytest.fixture(scope="session")
def shared_catalog(shared_provider: se.BaseResourceProvider, tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    tmp_dir = tmp_path_factory.mktemp("session_catalog")
    cache_file = tmp_dir / "catalog_cache.json"
    orig_cache = se.CATALOG_CACHE_PATH
    orig_cls_cache = getattr(se.CatalogIndexer, "CACHE_PATH", None)
    se.CATALOG_CACHE_PATH = str(cache_file)
    if hasattr(se.CatalogIndexer, "CACHE_PATH"):
        se.CatalogIndexer.CACHE_PATH = str(cache_file)
    try:
        return se.CatalogIndexer.build_or_load(shared_provider, force_rebuild=True)
    finally:
        se.CATALOG_CACHE_PATH = orig_cache
        if orig_cls_cache is not None and hasattr(se.CatalogIndexer, "CACHE_PATH"):
            se.CatalogIndexer.CACHE_PATH = orig_cls_cache


@pytest.fixture(autouse=True)
def isolated_studio_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    data_dir = tmp_path / "app_data"
    out_dir = tmp_path / "output"
    data_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)

    _patch_module_paths(se, data_dir, out_dir, monkeypatch)
    if hasattr(se.CatalogIndexer, "CACHE_PATH"):
        monkeypatch.setattr(se.CatalogIndexer, "CACHE_PATH", str(data_dir / "catalog_cache.json"))
    if "app" in sys.modules:
        _patch_module_paths(sys.modules["app"], data_dir, out_dir, monkeypatch)

    return {"data_dir": data_dir, "out_dir": out_dir}


@pytest.fixture
def api_client(isolated_studio_env, monkeypatch: pytest.MonkeyPatch):
    from fastapi.testclient import TestClient

    app_mod = _require_app_module()
    _patch_module_paths(
        app_mod,
        isolated_studio_env["data_dir"],
        isolated_studio_env["out_dir"],
        monkeypatch,
    )
    with TestClient(app_mod.app) as client:
        yield client, app_mod


# ===========================================================================
# TIER 1: FEATURE COVERAGE (F1–F12, >= 5 cases each, >= 60 cases total)
# ===========================================================================

class TestTier1_FeatureCoverage:
    # --- F1: Resource Provider & Vietnamese Catalog ---

    def test_t1_f1_provider_loads_resources_zip_and_version(self, shared_provider: se.BaseResourceProvider):
        assert not shared_provider.is_dir
        assert shared_provider.game_version == "1.64.1"
        assert shared_provider.has("version.txt")
        vtxt = shared_provider.read("version.txt").decode("utf-8").strip()
        assert vtxt.startswith("1.64.1")
        assert len(shared_provider.list_rel_paths()) > 3000

    def test_t1_f1_provider_loads_extracted_directory(self, shared_provider: se.BaseResourceProvider, tmp_path: Path):
        extracted = _build_lightweight_extracted_resources(shared_provider, tmp_path / "extracted_base")
        dir_prov = se.BaseResourceProvider(str(extracted))
        assert dir_prov.is_dir
        assert dir_prov.game_version == shared_provider.game_version
        assert dir_prov.read("version.txt") == shared_provider.read("version.txt")
        assert dir_prov.has("Databin/Client/Actor/hero.bytes")

    def test_t1_f1_provider_resolve_case_and_has(self, shared_provider: se.BaseResourceProvider):
        resolved = shared_provider.resolve_case("databin/client/actor/heroskin.bytes")
        assert resolved == "Databin/Client/Actor/heroSkin.bytes"
        assert shared_provider.has("DATABIN/CLIENT/ACTOR/HEROSKIN.BYTES")

    def test_t1_f1_catalog_indexes_heroes_and_vietnamese_skins(self, shared_catalog: dict[str, Any]):
        heroes_by_id = {h["hero_id"]: h for h in shared_catalog["heroes"]}
        assert len(heroes_by_id) >= 130
        assert shared_catalog["game_version"] == "1.64.1"
        assert shared_catalog["version_txt"].startswith("1.64.1")
        assert heroes_by_id[131]["name"] == "Murad"
        assert heroes_by_id[150]["name"] == "Nakroth"
        assert heroes_by_id[190]["name"] == "Tulen"
        s131 = {s["skin_id"]: s for s in heroes_by_id[131]["skins"]}
        s150 = {s["skin_id"]: s for s in heroes_by_id[150]["skins"]}
        s190 = {s["skin_id"]: s for s in heroes_by_id[190]["skins"]}
        assert "Thiên Luân Kiếm Thánh" in s131[13118]["name"]
        assert "Thứ nguyên vệ thần" in s150[15009]["name"]
        assert "Thiên Cơ Bạch Trạch" in s190[19016]["name"]

    def test_t1_f1_catalog_indexes_buttons_billboards_and_senior_hd(self, shared_catalog: dict[str, Any]):
        heroes_by_id = {h["hero_id"]: h for h in shared_catalog["heroes"]}
        s13118 = next(s for s in heroes_by_id[131]["skins"] if s["skin_id"] == 13118)
        s15009 = next(s for s in heroes_by_id[150]["skins"] if s["skin_id"] == 15009)
        assert s13118["is_hd"] is True
        assert s15009["is_hd"] is False
        assert s13118["button_id"] == 20
        assert (s13118.get("billboard_id") or s13118.get("kill_notify_id")) == 21
        assert s15009["button_id"] == 52
        assert (s15009.get("billboard_id") or s15009.get("kill_notify_id")) == 45
        assert len(shared_catalog["personal_buttons"]) >= 80
        assert len(_extract_catalog_billboards(shared_catalog)) >= 60

    def test_t1_f1_catalog_cache_hit_and_force_rebuild(self, shared_provider: se.BaseResourceProvider, isolated_studio_env):
        cache_path = isolated_studio_env["data_dir"] / "catalog_cache.json"
        assert not cache_path.exists()
        cat1 = se.CatalogIndexer.build_or_load(shared_provider, force_rebuild=False)
        assert cache_path.exists()
        cat2 = se.CatalogIndexer.build_or_load(shared_provider, force_rebuild=False)
        assert cat2["fingerprint"] == cat1["fingerprint"]
        assert len(cat2["heroes"]) == len(cat1["heroes"])
        cat3 = se.CatalogIndexer.build_or_load(shared_provider, force_rebuild=True)
        assert len(cat3["heroes"]) == len(cat1["heroes"])

    # --- F2: 1-Click Skin Mod Builder ---

    def test_t1_f2_build_murad_13118_hd_outputs_valid_zip_and_actorinfo(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "enable_vfx": True,
                "enable_recall": True,
                "enable_born": True,
                "enable_sound": True,
                "enable_button": True,
                "enable_billboard": True,
                "personal_button_id": 20,
                "billboard_id": 21,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        assert Path(res["output_path"]).parent == isolated_studio_env["out_dir"]
        _, _, rel_map = _read_zip_tree_from_build(res)
        _, actorinfo_plain = _extract_actorinfo_plain(rel_map, 131)
        assert b"13118/" in actorinfo_plain or b"13119_" in actorinfo_plain
        assert b"_HD" in actorinfo_plain
        aref = cp.pg_decrypt(rel_map["AssetRefs/Hero/131_AssetRef.bytes"], "131_AssetRef")
        assert b"/13118/" in aref and b"_HD" in aref

    def test_t1_f2_build_nakroth_15009_standard_outputs_prefab_paths(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_vfx": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        aref = cp.pg_decrypt(rel_map["AssetRefs/Hero/150_AssetRef.bytes"], "150_AssetRef")
        assert b"/15009/" in aref
        assert b".prefab" in aref
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 150), 150)
        combined = "\n".join(xmls.values())
        assert "/15009/" in combined and ".prefab" in combined

    def test_t1_f2_build_tulen_19016_hd_updates_components_motion_senior_label(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 190,
                "target_skin_id": 19016,
                "enable_vfx": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        comp = verify_mses_table(rel_map["Databin/Client/Character/ResCharacterComponent.bytes"], "ResCharacterComponent")
        for rid, _ in comp["recs"]:
            if str(rid).startswith("190"):
                assert str(rid).startswith("19016")
        sen = verify_mses_table(rel_map["Databin/Client/Actor/ResSkinSeniorLabelCfg.bytes"], "ResSkinSeniorLabelCfg")
        sen_rids = {rid for rid, _ in sen["recs"]}
        assert 19000 in sen_rids and 19016 in sen_rids
        verify_mses_table(rel_map["Databin/Client/Motion/ResSkinMotionBaseCfg.bytes"], "ResSkinMotionBaseCfg")

    def test_t1_f2_build_updates_heroskin_and_heroskinshop_records(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        hs = verify_mses_table(rel_map["Databin/Client/Actor/heroSkin.bytes"], "heroSkin")
        shop = verify_mses_table(rel_map["Databin/Client/Shop/HeroSkinShop.bytes"], "HeroSkinShop")
        hs_map = dict(hs["recs"])
        assert b"301310" in hs_map[13100]
        assert dict(shop["recs"]).get(13100) is not None

    def test_t1_f2_build_custom_watermark_in_languagemap(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        wm = "Totorox Studio Test Watermark — Bản Đặc Biệt 3.0"
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "watermark_text": wm,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        lang_txt = rel_map["Languages/VN_Garena_VN/languageMap.txt"].decode("utf-8")
        assert f"Tip_WaterMark_Str = {wm}" in lang_txt

    def test_t1_f2_build_bypass_seed_and_rpack_kianamod_marker(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "personal_button_id": 52,
                "billboard_id": 45,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        verify_rpack_unityfs(rel_map["assetbundle/resourcepackerinfosetall.assetbundle"], hero_id=150)
        assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")
        assert_lua_kiana_clean(rel_map["StableSystems_3.pkg.bytes"], "StableSystems_3.pkg.bytes")

    # --- F3: Mix Chiêu (8 Independent Slots) ---

    def test_t1_f3_mix_eight_independent_slots_on_murad(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "is_mix": True,
                "enable_vfx": True,
                "enable_recall": True,
                "enable_born": True,
                "enable_sound": True,
                "skill_mix": {
                    "normal": 13116,
                    "skill1": 13112,
                    "skill2": 13109,
                    "skill3": 13118,
                    "passive": 13112,
                    "recall": 13109,
                    "born": 13116,
                    "sound": 13118,
                },
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/13116/" in by_base["a1.xml"]
        assert "/13112/" in by_base["s1.xml"]
        assert "/13109/" in by_base["s2.xml"]
        assert any("/13118/" in txt for k, txt in by_base.items() if k.startswith("u1"))

    def test_t1_f3_mix_passive_slot_drives_skillmark_bytes(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "is_mix": True,
                "enable_vfx": True,
                "skill_mix": {"passive": 13112},
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        sm = verify_mses_table(rel_map["Databin/Client/Skill/skillmark.bytes"], "skillmark")
        hero_recs = [rraw for rid, rraw in sm["recs"] if str(rid).startswith("131")]
        assert hero_recs
        assert any(b"/13112/" in rraw for rraw in hero_recs)

    def test_t1_f3_mix_recall_slot_drives_back_xml_only(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "is_mix": True,
                "enable_recall": True,
                "skill_mix": {"normal": 13116, "recall": 13109},
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        tracks = cp.split_xml_tracks(back_xml)[1]
        assert any(t["filterType"] == "9" and "13100" in t["skins"] and "13109" in repr(t["raw"]) for t in tracks)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/13116/" in by_base["a1.xml"]

    def test_t1_f3_mix_born_slot_drives_born_and_haste_xmls(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15015,
                "is_mix": True,
                "enable_born": True,
                "skill_mix": {"born": 15009},
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        haste_xml = _extract_common_xml(rel_map, "commonresource/HasteE1.xml")
        assert "T2_Spint" in haste_xml

    def test_t1_f3_mix_sound_slot_drives_sound_tables_and_playherosound(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15015,
                "is_mix": True,
                "enable_sound": True,
                "skill_mix": {"sound": 15009},
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 150), 150)
        assert any("_Skin9" in txt for txt in xmls.values())

    # --- F4: Recall (Back.xml) & Sprint (HasteE1.xml) ---

    def test_t1_f4_back_xml_hides_default_green_recall_with_flt11(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_recall": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        tracks = cp.split_xml_tracks(back_xml)[1]

        holiday_tracks = [t for t in tracks if t.get("eventType") == "GetHolidayResourcePathTick"]
        assert len(holiday_tracks) >= 2
        for t in holiday_tracks:
            assert t.get("filterType") == "11"
            assert "15000" in t["skins"] and "15009" in t["skins"]

        default_particle_tracks = [
            t
            for t in tracks
            if t.get("eventType") in ("TriggerParticle", "TriggerParticleTick")
            and t.get("filterType") == "11"
            and ("born_back_reborn/huijidi_01" in t["raw"] or "born_back_reborn/huicheng_tongyong_01" in t["raw"])
        ]
        assert len(default_particle_tracks) >= 2
        for t in default_particle_tracks:
            assert "15000" in t["skins"] and "15009" in t["skins"]

    def test_t1_f4_back_xml_appends_two_flt9_uuid5_tracks_when_absent(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_recall": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        tracks = cp.split_xml_tracks(back_xml)[1]

        flt9_huijidi = [
            t for t in tracks
            if t.get("filterType") == "9"
            and t.get("eventType") == "TriggerParticleTick"
            and "150_HanXin/15009/huijidi_01.prefab" in t["raw"]
            and "15000" in t["skins"]
        ]
        flt9_huicheng = [
            t for t in tracks
            if t.get("filterType") == "9"
            and t.get("eventType") == "TriggerParticle"
            and "150_HanXin/15009/huicheng_tongyong_01.prefab" in t["raw"]
            and "15000" in t["skins"]
        ]
        assert len(flt9_huijidi) == 1
        assert len(flt9_huicheng) == 1
        assert 'time="7.000"' in flt9_huijidi[0]["raw"]
        assert 'time="0.000"' in flt9_huicheng[0]["raw"] and 'length="7.000"' in flt9_huicheng[0]["raw"]
        for trk in (flt9_huijidi[0], flt9_huicheng[0]):
            guids = re.findall(r'guid="([0-9a-fA-F-]+)"', trk["raw"])
            assert len(guids) >= 2
            for g in guids:
                assert uuid.UUID(g).version == 5

    def test_t1_f4_back_xml_expands_existing_skin_tracks_for_13118(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "enable_recall": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        tracks = cp.split_xml_tracks(back_xml)[1]
        assert any(t.get("filterType") == "9" and "13100" in t["skins"] and "13118" in t["raw"] for t in tracks)

    def test_t1_f4_hastee1_xml_injects_sprint_particle_and_stop_tracks_8_9(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_born": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        haste_xml = _extract_common_xml(rel_map, "commonresource/HasteE1.xml")
        tracks = cp.split_xml_tracks(haste_xml)[1]
        sprint_particle = [
            t for t in tracks
            if t.get("eventType") == "TriggerParticle"
            and "T2_Spint" in t["raw"]
            and "15000" in t["skins"]
        ]
        stop_tracks = [
            t for t in tracks
            if t.get("eventType") == "StopTracks"
            and "15000" in t["skins"]
            and 'id="8"' in t["raw"]
            and 'id="9"' in t["raw"]
        ]
        assert len(sprint_particle) == 1
        assert len(stop_tracks) == 1

    def test_t1_f4_hastee1_xml_handles_19016_exclusive_sprint_effect(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 190,
                "target_skin_id": 19016,
                "enable_born": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        haste_xml = _extract_common_xml(rel_map, "commonresource/HasteE1.xml")
        tracks = cp.split_xml_tracks(haste_xml)[1]
        assert any("ZhuGeLiang_sprint_01_7s" in t["raw"] and "19000" in t["skins"] for t in tracks)
        assert any(t.get("eventType") == "StopTracks" and 'id="8"' in t["raw"] and "19000" in t["skins"] for t in tracks)

    # --- F5: Wwise Sound & 7-Digit ID Remap ---

    def test_t1_f5_remaps_all_six_sound_tables_for_15009(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_sound": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        for tbl_name in ("BattleBank", "LobbyBank", "HeroSound", "ChatSound", "LobbySound", "CoupleSound"):
            rel = f"Databin/Client/Sound/{tbl_name}.bytes"
            tbl = verify_mses_table(rel_map[rel], tbl_name)
            assert len(tbl["recs"]) > 0

    def test_t1_f5_remaps_7_digit_evolved_sound_ids_to_235xxxx(self, shared_provider: se.BaseResourceProvider):
        plain = cp.pg_decrypt(shared_provider.read("Databin/Client/Sound/BattleBank.bytes"), "BattleBank")
        remapped = se._remap_sound_table_for_hero(plain, "BattleBank", 150, 15009, 15000)
        tbl = cp.parse_mses(remapped)
        assert tbl is not None
        recs = dict(tbl["recs"])
        # BattleBank rid=150330120 originally stores u32 1503301 at offset 13
        assert struct.unpack_from("<I", recs[150330120], 13)[0] == 2353301
        assert struct.unpack_from("<I", recs[150330121], 13)[0] == 2353301
        # Selected skin 15009 is promoted to base skin 15000
        vals_15009 = [
            struct.unpack_from("<I", rraw, 13)[0]
            for rid, rraw in tbl["recs"]
            if str(rid).startswith("15009") and len(rraw) >= 17
        ]
        assert any(v == 15000 for v in vals_15009)

    def test_t1_f5_remaps_selected_7_digit_evolved_skin_to_base_skin_id(self, shared_provider: se.BaseResourceProvider):
        plain = cp.pg_decrypt(shared_provider.read("Databin/Client/Sound/BattleBank.bytes"), "BattleBank")
        remapped = se._remap_sound_table_for_hero(plain, "BattleBank", 150, 1503301, 15000)
        tbl = cp.parse_mses(remapped)
        assert tbl is not None
        recs = dict(tbl["recs"])
        assert struct.unpack_from("<I", recs[150330120], 13)[0] == 15000
        assert struct.unpack_from("<I", recs[150330220], 13)[0] == 2353302

    def test_t1_f5_playherosoundtick_appends_skin_suffix_and_strips_extraskinid(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_sound": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 150), 150)
        sound_xmls = [txt for txt in xmls.values() if "PlayHeroSoundTick" in txt]
        assert sound_xmls
        assert any("_Skin9" in txt for txt in sound_xmls)
        for txt in sound_xmls:
            for trk in cp.split_xml_tracks(txt)[1]:
                if trk["eventType"] == "PlayHeroSoundTick" and "_Skin9" in trk["raw"]:
                    assert "extraSkinId" not in trk["raw"]

    def test_t1_f5_other_hero_sound_records_remain_untouched(self, shared_provider: se.BaseResourceProvider):
        plain = cp.pg_decrypt(shared_provider.read("Databin/Client/Sound/BattleBank.bytes"), "BattleBank")
        orig_tbl = cp.parse_mses(plain)
        remapped = se._remap_sound_table_for_hero(plain, "BattleBank", 150, 15009, 15000)
        new_tbl = cp.parse_mses(remapped)
        assert orig_tbl and new_tbl
        for (o_rid, o_raw), (n_rid, n_raw) in zip(orig_tbl["recs"], new_tbl["recs"]):
            if not str(o_rid).startswith("150"):
                assert (o_rid, o_raw) == (n_rid, n_raw)

    # --- F6: Personal Button, Kill Billboard & jtcom Direct Path ---

    def test_t1_f6_heroskin2_encodes_13118_button_20_billboard_21(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        _install_mock_kiana_seed(shared_provider)
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "enable_button": True,
                "enable_billboard": True,
                "personal_button_id": 20,
                "billboard_id": 21,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        verify_heroskin_1_and_2(
            rel_map["Thanos/HeroSkin_1.bytes"],
            rel_map["Thanos/HeroSkin_2.bytes"],
            expected_hero_id=131,
            expected_skin_id=13118,
            expected_button_id=20,
            expected_billboard_id=21,
        )

    def test_t1_f6_heroskin2_encodes_15009_button_52_billboard_45(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        _install_mock_kiana_seed(shared_provider)
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_button": True,
                "enable_billboard": True,
                "personal_button_id": 52,
                "billboard_id": 45,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        verify_heroskin_1_and_2(
            rel_map["Thanos/HeroSkin_1.bytes"],
            rel_map["Thanos/HeroSkin_2.bytes"],
            expected_hero_id=150,
            expected_skin_id=15009,
            expected_button_id=52,
            expected_billboard_id=45,
        )

    def test_t1_f6_jtcom_rewrite_direct_skin_prefixed_path_hd(self):
        out = jtcom.rewrite_hero_effect_path(
            "prefab_skill_effects/hero_skill_effects/13118_Libai_sprint_02",
            hero_id=131,
            skin_id=13118,
            is_hd_skin=True,
        )
        assert out == "prefab_skill_effects/hero_skill_effects/13118_Libai_sprint_02_HD"

    def test_t1_f6_jtcom_rewrite_direct_skin_prefixed_path_standard(self):
        out = jtcom.rewrite_hero_effect_path(
            "prefab_skill_effects/hero_skill_effects/15009_Hanxin_sprint_01",
            hero_id=150,
            skin_id=15009,
            is_hd_skin=False,
        )
        assert out == "prefab_skill_effects/hero_skill_effects/15009_Hanxin_sprint_01.prefab"

    def test_t1_f6_jtcom_rewrite_standard_hero_subdir_paths(self):
        hd_out = jtcom.rewrite_hero_effect_path(
            "prefab_skill_effects/hero_skill_effects/131_libai/libai_attack_01",
            hero_id=131,
            skin_id=13118,
            is_hd_skin=True,
        )
        std_out = jtcom.rewrite_hero_effect_path(
            "prefab_skill_effects/hero_skill_effects/150_hanxin/hanxin_attack_01",
            hero_id=150,
            skin_id=15009,
            is_hd_skin=False,
        )
        assert hd_out == "prefab_skill_effects/hero_skill_effects/131_libai/13118/libai_attack_01_HD"
        assert std_out == "prefab_skill_effects/hero_skill_effects/150_hanxin/15009/hanxin_attack_01.prefab"

    def test_t1_f6_jtcom_lossless_binary_and_json_roundtrip_on_real_actorinfo(
        self, shared_provider: se.BaseResourceProvider
    ):
        entries = cp.parse_in_memory_zip(shared_provider.read("Prefab_Characters/Actor_131_Infos.pkg.bytes"))
        raw = next(d for n, _, _, d in entries if n.lower().endswith("131_libai_actorinfo.bytes"))
        plain = cp.pg_decrypt(raw, "131_LiBai_actorinfo")
        tree, end = jtcom.parse_jt(plain, 0)
        assert end == len(plain)
        assert jtcom.serialize_jt(tree) == plain
        json_obj = jtcom.jt_to_jsonable(tree)
        rebuilt = jtcom.serialize_jt(jtcom.jsonable_to_jt(json_obj))
        assert rebuilt == plain

    # --- F7: Cam Xa (Integrated & 4-File Standalone) ---

    def test_t1_f7_camera_only_produces_exact_four_files(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "camera_only",
                "camera_percent": 15,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        assert res["summary"]["target_xml"] == "PassiveResource/junglemark.xml"
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert set(rel_map.keys()) == {
            "KernelLua.pkg.bytes",
            "StableSystems_3.pkg.bytes",
            "Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes",
            "version.txt",
        }

    @pytest.mark.parametrize(
        "pct,expected_rate",
        [
            (5, "1.155"),
            (10, "1.210"),
            (15, "1.265"),
            (20, "1.320"),
            (25, "1.375"),
        ],
    )
    def test_t1_f7_camera_only_parametrized_height_rates(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env, pct: int, expected_rate: str
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "camera_only",
                "camera_percent": pct,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        cam_xml = _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert "SetCameraHeightDuration" in cam_xml
        assert f'heightRate" value="{expected_rate}"' in cam_xml

    def test_t1_f7_integrated_camera_in_skin_mod_preserves_skin_and_sets_height_rate(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "camera_percent": 15,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        cam_xml = _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert 'heightRate" value="1.265"' in cam_xml
        assert "Prefab_Characters/Actor_131_Infos.pkg.bytes" in rel_map

    def test_t1_f7_camera_only_born_xml_has_boverride_true_and_slerp_tick(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "camera_only",
                "camera_percent": 20,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        cam_xml = _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        tracks = cp.split_xml_tracks(cam_xml)[1]
        cam_trks = [t for t in tracks if t.get("eventType") == "SetCameraHeightDuration"]
        assert len(cam_trks) == 1
        assert 'name="bOverride" value="true"' in cam_trks[0]["raw"]
        assert 'name="slerpTick"' in cam_trks[0]["raw"]

    def test_t1_f7_camera_only_outputs_valid_3105_when_requested(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "camera_only",
                "camera_percent": 10,
                "output_format": "3105",
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        raw_3105 = Path(res["output_path"]).read_bytes()
        tree = verify_3105_envelope(raw_3105, password=None)
        _, rel_map = strip_resources_prefix(tree)
        cam_xml = _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert 'heightRate" value="1.210"' in cam_xml

    # --- F8: Package Format & Anti-Kiana Integrity ---

    def test_t1_f8_all_output_pkgs_are_zip_stored_zero(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        pkgs = [k for k in rel_map if k.lower().endswith(".pkg.bytes")]
        assert len(pkgs) >= 5
        for k in pkgs:
            assert_pkg_stored_zero(rel_map[k], k)

    def test_t1_f8_every_xml_in_actor_actions_pkg_is_0x224a_encrypted_with_stem(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        assert len(xmls) >= 50

    def test_t1_f8_every_databin_table_is_valid_mses_with_valid_md5(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 150, "target_skin_id": 15009, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        databins = [k for k in rel_map if k.startswith("Databin/") and k.endswith(".bytes")]
        assert len(databins) >= 6
        for k in databins:
            stem = os.path.basename(k).rsplit(".", 1)[0]
            verify_mses_table(rel_map[k], stem)

    def test_t1_f8_heroskin1_and_2_md5s_sync_with_kiana_clean_lua_pkgs(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        _install_mock_kiana_seed(shared_provider)
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "personal_button_id": 20,
                "billboard_id": 21,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        pkg_md5s = {
            "KernelLua.pkg.bytes": hashlib.md5(rel_map["KernelLua.pkg.bytes"]).hexdigest().lower(),
            "StableSystems_3.pkg.bytes": hashlib.md5(rel_map["StableSystems_3.pkg.bytes"]).hexdigest().lower(),
        }
        verify_heroskin_1_and_2(
            rel_map["Thanos/HeroSkin_1.bytes"],
            rel_map["Thanos/HeroSkin_2.bytes"],
            expected_hero_id=131,
            expected_skin_id=13118,
            expected_button_id=20,
            expected_billboard_id=21,
            pkg_md5s=pkg_md5s,
        )

    def test_t1_f8_zero_kiana_markers_or_github_urls_across_entire_output_zip(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 190, "target_skin_id": 19016, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")
        assert_lua_kiana_clean(rel_map["StableSystems_3.pkg.bytes"], "StableSystems_3.pkg.bytes")
        for k, raw in rel_map.items():
            assert cp._KIANA_AD_GLOBAL_MARKER not in raw, f"Kiana marker in {k}"
            assert b"raw.githubusercontent.com" not in raw, f"GitHub URL in {k}"

    # --- F9: Binary Inspector & Editor ---

    def test_t1_f9_decrypt_and_encrypt_0x224a_roundtrip_with_pkcs7(self, shared_provider: se.BaseResourceProvider):
        raw = shared_provider.read("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes")
        dec_res = se.BinaryInspector.decrypt_0x224a(raw, "ResBillboardSkinCfg")
        plain = _extract_decrypted_bytes(dec_res)
        assert plain[:4] == b"MSES"
        re_enc = se.BinaryInspector.encrypt_0x224a(plain, "ResBillboardSkinCfg")
        plain2 = verify_0x224a_pkcs7(re_enc, "ResBillboardSkinCfg")
        assert plain2 == plain

    def test_t1_f9_inspect_mses_and_repack_preserves_md5_and_header(self, shared_provider: se.BaseResourceProvider):
        raw = shared_provider.read("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes")
        orig_tbl = verify_mses_table(raw, "ResBillboardSkinCfg")
        insp = se.BinaryInspector.inspect_bytes(raw, "ResBillboardSkinCfg.bytes", full_text=True)
        assert insp["kind"] == "mses_table"
        assert insp["record_count"] == 67
        assert len(insp["records"]) == 67
        mses_doc = json.loads(insp["text_content"])
        assert mses_doc["format"] == "mses_table"
        assert mses_doc["has_md5"] is True
        assert len(bytes.fromhex(mses_doc["header_hex"])) == 140
        assert len(mses_doc["records"]) == 67
        repacked = se.BinaryInspector.repack_from_editor(
            "mses_table",
            insp["text_content"],
            "ResBillboardSkinCfg",
            encrypt_224a=True,
        )
        tbl = verify_mses_table(repacked, "ResBillboardSkinCfg")
        assert len(tbl["recs"]) == 67
        assert tbl["hdr"][:96] == orig_tbl["hdr"][:96]
        assert tbl["hdr"][128:140] == orig_tbl["hdr"][128:140]
        assert tbl["ftr"] == orig_tbl["ftr"]

    def test_t1_f9_pkg_list_read_unpack_pack_store_zero_and_update_entry(
        self, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        pkg = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/Actor_131_Actions.pkg.bytes")
        entries = se.BinaryInspector.list_pkg_entries(pkg)
        assert len(entries) >= 50
        first_name = entries[0]["name"] if isinstance(entries[0], dict) else entries[0]
        read_info = se.BinaryInspector.read_pkg_entry(pkg, first_name, full_text=True)
        assert read_info["kind"] == "age_xml"
        assert "<Project" in read_info["text_content"]

        unpack_dir = tmp_path / "unpacked_pkg"
        se.BinaryInspector.unpack_pkg_to_dir(pkg, str(unpack_dir))
        assert any(unpack_dir.rglob("*.xml"))
        repacked_pkg = se.BinaryInspector.pack_dir_to_pkg(str(unpack_dir))
        assert_pkg_stored_zero(repacked_pkg, "pack_dir_to_pkg")

        stem = os.path.splitext(os.path.basename(first_name))[0]
        updated_xml = read_info["text_content"].replace("</Project>", "<!-- edited -->\n</Project>")
        updated_pkg = se.BinaryInspector.update_pkg_entry(
            pkg, first_name, updated_xml.encode("utf-8"), encrypt_stem=stem
        )
        dec_entries = assert_actor_actions_encrypted(updated_pkg, 131, allow_zstd_only=True)
        assert "<!-- edited -->" in dec_entries[first_name]

    def test_t1_f9_inspect_and_repack_jtcom_json_preserves_binary_validity(
        self, shared_provider: se.BaseResourceProvider
    ):
        pkg = shared_provider.read("Prefab_Characters/Actor_131_Infos.pkg.bytes")
        entries = se.BinaryInspector.list_pkg_entries(pkg)
        names = [e["name"] if isinstance(e, dict) else e for e in entries]
        actor_entry = next(n for n in names if n.lower().endswith("131_libai_actorinfo.bytes"))
        info = se.BinaryInspector.read_pkg_entry(pkg, actor_entry, full_text=True)
        assert info["kind"] == "jtcom_tree"
        repacked = se.BinaryInspector.repack_from_editor("jtcom_tree", info["text_content"], "131_LiBai_actorinfo")
        repacked_alias = se.BinaryInspector.repack_from_editor("jtcom_json", info["text_content"], "131_LiBai_actorinfo")
        assert repacked_alias == repacked
        plain = verify_0x224a_pkcs7(repacked, "131_LiBai_actorinfo")
        tree, end = jtcom.parse_jt(plain, 0)
        assert end == len(plain)
        assert tree["name"] == "ROOT"

    def test_t1_f9_parse_and_update_age_xml_tracks(self, shared_provider: se.BaseResourceProvider):
        ca = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        back_info = se.BinaryInspector.read_pkg_entry(ca, "commonresource/Back.xml", full_text=True)
        tracks = se.BinaryInspector.parse_xml_tracks(back_info["text_content"])
        assert len(tracks) >= 80
        updated_xml = se.BinaryInspector.update_xml_tracks(
            back_info["text_content"],
            [
                {
                    "index": 24,
                    "filterType": "11",
                    "skins": list(dict.fromkeys((tracks[24].get("skins") or []) + ["15000", "15009"])),
                }
            ],
        )
        tracks2 = se.BinaryInspector.parse_xml_tracks(updated_xml)
        assert "15000" in tracks2[24]["skins"] and "15009" in tracks2[24]["skins"]

        # Verify <Array name="skinIdArray"> and resourceName updates on Hero action XML
        act = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/Actor_131_Actions.pkg.bytes")
        p1e5_info = se.BinaryInspector.read_pkg_entry(act, "131_LiBai/skill/P1E5.xml", full_text=True)
        p1e5_tracks = se.BinaryInspector.parse_xml_tracks(p1e5_info["text_content"])
        arr_idx = next(t["index"] for t in p1e5_tracks if t.get("hasSkinIdArray"))
        res_idx = next(t["index"] for t in p1e5_tracks if t.get("resourceName"))
        new_res = "prefab_skill_effects/hero_skill_effects/131_libai/13118/LiBai_buff_08_HD"
        upd_p1e5 = se.BinaryInspector.update_xml_tracks(
            p1e5_info["text_content"],
            [
                {"index": arr_idx, "skinArrayIds": ["13100", "13118"]},
                {"index": res_idx, "resourceName": new_res},
            ],
        )
        p1e5_tracks2 = se.BinaryInspector.parse_xml_tracks(upd_p1e5)
        assert p1e5_tracks2[arr_idx]["skinArrayIds"] == ["13100", "13118"]
        assert '<Array name="skinIdArray"' in upd_p1e5 and '<int value="13118" />' in upd_p1e5
        assert p1e5_tracks2[res_idx]["resourceName"] == new_res
        assert f'name="resourceName" value="{new_res}"' in upd_p1e5

    def test_t1_f9_inspect_unityfs_rpack_and_3105_header(self, shared_provider: se.BaseResourceProvider):
        rp_raw = shared_provider.read("assetbundle/resourcepackerinfosetall.assetbundle")
        rp_info = se.BinaryInspector.inspect_bytes(rp_raw, "resourcepackerinfosetall.assetbundle")
        assert rp_info["kind"] == "unityfs_rpack"
        assert rp_info["record_count"] > 100

        mini_zip_buf = io.BytesIO()
        with zipfile.ZipFile(mini_zip_buf, "w") as zf:
            zf.writestr("Resources/1.64.1/version.txt", b"1.64.1.12|1793129")
        conv = se.OfflineMergerAndConverter.convert_package(
            mini_zip_buf.getvalue(), "mini.zip", "3105", password="secret"
        )
        p_info = se.BinaryInspector.inspect_bytes(Path(conv["output_path"]).read_bytes(), "mini.3105")
        assert p_info["kind"] == "3105_patch"
        assert p_info["patch_info"]["is_password_protected"] is True

    # --- F10: Offline Merge & .zip <-> .3105 ---

    def test_t1_f10_merge_two_generated_hero_mods_to_zip(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        r1 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(out_dir)}
        )
        r2 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "skin", "hero_id": 150, "target_skin_id": 15009, "output_dir": str(out_dir)}
        )
        merged = se.OfflineMergerAndConverter.merge_mods(
            [r1["output_path"], r2["output_path"]],
            output_dir=str(out_dir),
            output_format="zip",
        )
        _, _, rel_map = _read_zip_tree_from_build(merged)
        assert "Prefab_Characters/Actor_131_Infos.pkg.bytes" in rel_map
        assert "Prefab_Characters/Actor_150_Infos.pkg.bytes" in rel_map
        assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")

    def test_t1_f10_merge_mods_with_custom_watermark_and_filename(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        r1 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(out_dir)}
        )
        r2 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "skin", "hero_id": 150, "target_skin_id": 15009, "output_dir": str(out_dir)}
        )
        wm = "Merge Custom Watermark Totorox 3.0"
        merged = se.OfflineMergerAndConverter.merge_mods(
            [r1["output_path"], r2["output_path"]],
            output_dir=str(out_dir),
            output_name="Combo_Murad_Nakroth",
            watermark_text=wm,
            output_format="zip",
        )
        assert merged["filename"] == "Combo_Murad_Nakroth.zip"
        _, _, rel_map = _read_zip_tree_from_build(merged)
        lang_txt = rel_map["Languages/VN_Garena_VN/languageMap.txt"].decode("utf-8")
        assert f"Tip_WaterMark_Str = {wm}" in lang_txt

    def test_t1_f10_convert_zip_to_3105_and_back_unencrypted(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        built = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "camera_only", "camera_percent": 15, "output_dir": str(out_dir)}
        )
        zip_bytes = Path(built["output_path"]).read_bytes()
        to_3105 = se.OfflineMergerAndConverter.convert_package(
            zip_bytes, built["filename"], target_format="3105", password=None, output_dir=str(out_dir)
        )
        raw_3105 = Path(to_3105["output_path"]).read_bytes()
        verify_3105_envelope(raw_3105, password=None)
        to_zip = se.OfflineMergerAndConverter.convert_package(
            raw_3105, to_3105["filename"], target_format="zip", password=None, output_dir=str(out_dir)
        )
        _, rel_map = strip_resources_prefix(read_zip_tree(Path(to_zip["output_path"]).read_bytes()))
        assert "Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes" in rel_map

    def test_t1_f10_convert_zip_to_3105_and_back_with_password(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        built = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "camera_only", "camera_percent": 10, "output_dir": str(out_dir)}
        )
        zip_bytes = Path(built["output_path"]).read_bytes()
        to_3105 = se.OfflineMergerAndConverter.convert_package(
            zip_bytes, built["filename"], target_format="3105", password="TotoroxSecret30!", output_dir=str(out_dir)
        )
        raw_3105 = Path(to_3105["output_path"]).read_bytes()
        verify_3105_envelope(raw_3105, password="TotoroxSecret30!")
        to_zip = se.OfflineMergerAndConverter.convert_package(
            raw_3105, to_3105["filename"], target_format="zip", password="TotoroxSecret30!", output_dir=str(out_dir)
        )
        assert zipfile.ZipFile(io.BytesIO(Path(to_zip["output_path"]).read_bytes())).testzip() is None

    def test_t1_f10_merge_output_directly_to_3105_with_password(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        r1 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(out_dir)}
        )
        r2 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "skin", "hero_id": 150, "target_skin_id": 15009, "output_dir": str(out_dir)}
        )
        merged = se.OfflineMergerAndConverter.merge_mods(
            [r1["output_path"], r2["output_path"]],
            output_dir=str(out_dir),
            output_format="3105",
            password="MergePw#3105",
        )
        assert merged["filename"].endswith(".3105")
        tree = verify_3105_envelope(Path(merged["output_path"]).read_bytes(), password="MergePw#3105")
        _, rel_map = strip_resources_prefix(tree)
        assert "Prefab_Characters/Actor_131_Infos.pkg.bytes" in rel_map
        assert "Prefab_Characters/Actor_150_Infos.pkg.bytes" in rel_map

    # --- F11: Local FastAPI Server (`app.py`) ---

    def test_t1_f11_get_root_and_health(self, api_client):
        client, _ = api_client
        r_root = client.get("/")
        assert r_root.status_code == 200
        assert "text/html" in r_root.headers.get("content-type", "")
        r_health = client.get("/api/health")
        assert r_health.status_code == 200
        data = r_health.json()
        assert data.get("ok") is True or data.get("status") in ("ok", "healthy")

    def test_t1_f11_get_and_post_config(self, api_client, isolated_studio_env):
        client, _ = api_client
        r_get = client.get("/api/config")
        assert r_get.status_code == 200
        cfg = r_get.json()
        assert isinstance(cfg, dict)
        r_post = client.post(
            "/api/config",
            json={
                "resources_path": str(RESOURCES_ZIP),
                "default_watermark": "HTTP Config Watermark",
                "theme": "light",
            },
        )
        assert r_post.status_code == 200
        saved = json.loads((isolated_studio_env["data_dir"] / "studio_config.json").read_text(encoding="utf-8"))
        assert saved["default_watermark"] == "HTTP Config Watermark"
        assert saved["theme"] == "light"

    def test_t1_f11_catalog_get_and_refresh(self, api_client):
        client, _ = api_client
        client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)})
        r_cat = client.get("/api/catalog")
        assert r_cat.status_code == 200
        cat = r_cat.json()
        assert len(cat["heroes"]) >= 130
        r_ref = client.post("/api/catalog/refresh")
        assert r_ref.status_code == 200
        assert len(r_ref.json()["heroes"]) >= 130

    def test_t1_f11_dialog_browse_mocked_tkinter_and_open_explorer_mocked_popen(
        self, api_client, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ):
        client, app_mod = api_client
        chosen = tmp_path / "chosen_mod.zip"
        chosen.write_bytes(b"PK\x05\x06" + b"\x00" * 18)

        class DummyTk:
            def withdraw(self):
                pass

            def attributes(self, *args, **kwargs):
                pass

            def wm_attributes(self, *args, **kwargs):
                pass

            def lift(self):
                pass

            def destroy(self):
                pass

        import tkinter
        import tkinter.filedialog as fd

        monkeypatch.setattr(tkinter, "Tk", DummyTk)
        monkeypatch.setattr(fd, "askopenfilename", lambda **kw: str(chosen))
        monkeypatch.setattr(fd, "askopenfilenames", lambda **kw: (str(chosen),))
        monkeypatch.setattr(fd, "askdirectory", lambda **kw: str(tmp_path))
        monkeypatch.setattr(fd, "asksaveasfilename", lambda **kw: str(chosen))

        r_browse = client.post("/api/dialog/browse", json={"mode": "file"})
        assert r_browse.status_code == 200
        body = r_browse.json()
        assert body.get("cancelled") is False
        assert body.get("path") == str(chosen)
        assert str(chosen) in (body.get("paths") or [])

        popen_calls = []

        class DummyProc:
            pid = 12345

        def fake_popen(cmd, *args, **kwargs):
            popen_calls.append((cmd, kwargs))
            return DummyProc()

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        if hasattr(app_mod, "subprocess"):
            monkeypatch.setattr(app_mod.subprocess, "Popen", fake_popen)

        r_exp = client.post("/api/system/open-explorer", json={"path": str(chosen)})
        assert r_exp.status_code == 200
        assert len(popen_calls) == 1
        cmd_str = " ".join(popen_calls[0][0]) if isinstance(popen_calls[0][0], (list, tuple)) else str(popen_calls[0][0])
        assert "explorer" in cmd_str.lower()
        assert os.path.normpath(str(chosen)) in cmd_str

    def test_t1_f11_api_mod_build_and_download_output(self, api_client, isolated_studio_env):
        client, _ = api_client
        client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)})
        r_build = client.post(
            "/api/mod/build",
            json={
                "mode": "camera_only",
                "camera_percent": 15,
                "custom_filename": "api_camxa_15",
                "output_format": "zip",
            },
        )
        assert r_build.status_code == 200
        bdata = r_build.json()
        out_path = Path(bdata["output_path"])
        assert out_path.exists()
        assert out_path.parent == isolated_studio_env["out_dir"]

        r_dl = client.get("/api/outputs/download", params={"path": bdata["filename"]})
        if r_dl.status_code == 404 or r_dl.status_code == 422:
            r_dl = client.get("/api/outputs/download", params={"path": str(out_path)})
        assert r_dl.status_code == 200
        assert r_dl.content == out_path.read_bytes()

    def test_t1_f11_api_inspector_routes_roundtrip(
        self, api_client, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        client, app_mod = api_client
        raw_mses = shared_provider.read("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes")
        mses_file = tmp_path / "ResBillboardSkinCfg.bytes"
        mses_file.write_bytes(raw_mses)

        if _find_openapi_body_mode(app_mod, "/api/inspector/inspect") == "multipart":
            r_insp = client.post(
                "/api/inspector/inspect",
                files={"file": ("ResBillboardSkinCfg.bytes", raw_mses, "application/octet-stream")},
                data={"full_text": "true"},
            )
        else:
            r_insp = client.post(
                "/api/inspector/inspect",
                json={
                    "path": str(mses_file),
                    "filename": "ResBillboardSkinCfg.bytes",
                    "content_b64": base64.b64encode(raw_mses).decode("ascii"),
                    "full_text": True,
                },
            )
        assert r_insp.status_code == 200
        assert r_insp.json()["kind"] == "mses_table"

        # /api/inspector/crypto/0x224a
        if _find_openapi_body_mode(app_mod, "/api/inspector/crypto/0x224a") == "multipart":
            r_dec = client.post(
                "/api/inspector/crypto/0x224a",
                files={"file": ("ResBillboardSkinCfg.bytes", raw_mses, "application/octet-stream")},
                data={"action": "decrypt", "mode": "decrypt", "stem": "ResBillboardSkinCfg"},
            )
        else:
            r_dec = client.post(
                "/api/inspector/crypto/0x224a",
                json={
                    "path": str(mses_file),
                    "action": "decrypt",
                    "mode": "decrypt",
                    "stem": "ResBillboardSkinCfg",
                    "content_b64": base64.b64encode(raw_mses).decode("ascii"),
                },
            )
        assert r_dec.status_code == 200

        # /api/inspector/xml/tracks
        ca = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        back_txt = cp.decode_aov_xml_if_needed(
            dict((n, d) for n, _, _, d in cp.parse_in_memory_zip(ca))["commonresource/Back.xml"],
            "commonresource/Back.xml",
        ).decode("utf-8")
        r_trk = client.post(
            "/api/inspector/xml/tracks",
            json={"action": "parse", "xml_text": back_txt},
        )
        assert r_trk.status_code == 200
        assert len(r_trk.json().get("tracks") or r_trk.json()) >= 80

    def test_t1_f11_api_inspector_repack_mses_roundtrip(
        self, api_client, shared_provider: se.BaseResourceProvider
    ):
        client, app_mod = api_client
        raw_mses = shared_provider.read("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes")
        insp = se.BinaryInspector.inspect_bytes(raw_mses, "ResBillboardSkinCfg.bytes", full_text=True)
        doc = json.loads(insp["text_content"])
        rec0 = bytearray(bytes.fromhex(doc["records"][0]["raw_hex"]))
        struct.pack_into("<I", rec0, 12, 13118)
        doc["records"][0]["raw_hex"] = rec0.hex()
        edited_json = json.dumps(doc)

        if _find_openapi_body_mode(app_mod, "/api/inspector/repack") == "multipart":
            r_rep = client.post(
                "/api/inspector/repack",
                data={
                    "kind": "mses_table",
                    "content_text": edited_json,
                    "stem": "ResBillboardSkinCfg",
                    "encrypt_224a": "true",
                },
            )
        else:
            r_rep = client.post(
                "/api/inspector/repack",
                json={
                    "kind": "mses_table",
                    "content_text": edited_json,
                    "stem": "ResBillboardSkinCfg",
                    "encrypt_224a": True,
                },
            )
        assert r_rep.status_code == 200
        if "application/json" in r_rep.headers.get("content-type", ""):
            payload = r_rep.json()
            b64 = payload.get("content_b64") or payload.get("bytes_b64") or payload.get("data_b64") or payload.get("raw_b64")
            assert b64, f"Expected base64 repacked payload in {payload}"
            repacked_bytes = base64.b64decode(b64)
        else:
            repacked_bytes = r_rep.content
        tbl = verify_mses_table(repacked_bytes, "ResBillboardSkinCfg")
        assert struct.unpack_from("<I", tbl["recs"][0][1], 12)[0] == 13118

    def test_t1_f11_api_inspector_pkg_entry_and_update_entry(
        self, api_client, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        client, app_mod = api_client
        pkg_bytes = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/Actor_131_Actions.pkg.bytes")
        pkg_file = tmp_path / "Actor_131_Actions.pkg.bytes"
        pkg_file.write_bytes(pkg_bytes)
        target_entry = "131_LiBai/skill/A1.xml"

        if _find_openapi_body_mode(app_mod, "/api/inspector/pkg/entry") == "multipart":
            r_entry = client.post(
                "/api/inspector/pkg/entry",
                files={"file": ("Actor_131_Actions.pkg.bytes", pkg_bytes, "application/octet-stream")},
                data={"entry_name": target_entry, "full_text": "true"},
            )
        else:
            r_entry = client.post(
                "/api/inspector/pkg/entry",
                json={
                    "path": str(pkg_file),
                    "pkg_b64": base64.b64encode(pkg_bytes).decode("ascii"),
                    "entry_name": target_entry,
                    "full_text": True,
                },
            )
        assert r_entry.status_code == 200
        entry_info = r_entry.json()
        assert entry_info["kind"] == "age_xml"
        assert "<Project" in entry_info["text_content"]

        updated_xml = entry_info["text_content"].replace("</Project>", "<!-- api-updated -->\n</Project>")
        if _find_openapi_body_mode(app_mod, "/api/inspector/pkg/update-entry") == "multipart":
            r_upd = client.post(
                "/api/inspector/pkg/update-entry",
                files={"file": ("Actor_131_Actions.pkg.bytes", pkg_bytes, "application/octet-stream")},
                data={
                    "entry_name": target_entry,
                    "new_raw": updated_xml,
                    "content_text": updated_xml,
                    "encrypt_stem": "A1",
                    "encrypt_224a": "true",
                    "kind": "age_xml",
                },
            )
        else:
            r_upd = client.post(
                "/api/inspector/pkg/update-entry",
                json={
                    "path": str(pkg_file),
                    "pkg_b64": base64.b64encode(pkg_bytes).decode("ascii"),
                    "entry_name": target_entry,
                    "new_raw": updated_xml,
                    "content_text": updated_xml,
                    "encrypt_stem": "A1",
                    "encrypt_224a": True,
                    "kind": "age_xml",
                },
            )
        assert r_upd.status_code == 200
        if "application/json" in r_upd.headers.get("content-type", ""):
            up_body = r_upd.json()
            if up_body.get("output_path") and Path(up_body["output_path"]).exists():
                upd_pkg_bytes = Path(up_body["output_path"]).read_bytes()
            else:
                b64 = up_body.get("pkg_b64") or up_body.get("content_b64") or up_body.get("bytes_b64") or up_body.get("data_b64")
                assert b64, f"Expected updated pkg payload in {up_body}"
                upd_pkg_bytes = base64.b64decode(b64)
        else:
            upd_pkg_bytes = r_upd.content
        decoded = assert_actor_actions_encrypted(upd_pkg_bytes, 131, allow_zstd_only=True)
        assert "<!-- api-updated -->" in decoded[target_entry]

    def test_t1_f11_api_inspector_pkg_unpack_and_pack(
        self, api_client, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        client, app_mod = api_client
        pkg_bytes = shared_provider.read("Prefab_Characters/Actor_131_Infos.pkg.bytes")
        pkg_file = tmp_path / "Actor_131_Infos.pkg.bytes"
        pkg_file.write_bytes(pkg_bytes)
        unpack_dir = tmp_path / "http_unpacked_infos"

        if _find_openapi_body_mode(app_mod, "/api/inspector/pkg/unpack") == "multipart":
            r_unp = client.post(
                "/api/inspector/pkg/unpack",
                files={"file": ("Actor_131_Infos.pkg.bytes", pkg_bytes, "application/octet-stream")},
                data={"out_dir": str(unpack_dir)},
            )
        else:
            r_unp = client.post(
                "/api/inspector/pkg/unpack",
                json={
                    "path": str(pkg_file),
                    "pkg_b64": base64.b64encode(pkg_bytes).decode("ascii"),
                    "out_dir": str(unpack_dir),
                },
            )
        assert r_unp.status_code == 200
        unp_body = r_unp.json()
        eff_dir = Path(unp_body.get("output_dir") or unpack_dir)
        assert eff_dir.is_dir() and any(eff_dir.rglob("*.bytes"))

        r_pck = client.post(
            "/api/inspector/pkg/pack",
            json={"src_dir": str(eff_dir)},
        )
        assert r_pck.status_code == 200
        if "application/json" in r_pck.headers.get("content-type", ""):
            pck_body = r_pck.json()
            if pck_body.get("output_path") and Path(pck_body["output_path"]).exists():
                packed_bytes = Path(pck_body["output_path"]).read_bytes()
            else:
                b64 = pck_body.get("pkg_b64") or pck_body.get("content_b64") or pck_body.get("bytes_b64") or pck_body.get("data_b64")
                assert b64, f"Expected packed pkg payload in {pck_body}"
                packed_bytes = base64.b64decode(b64)
        else:
            packed_bytes = r_pck.content
        packed_entries = assert_pkg_stored_zero(packed_bytes, "api_pkg_pack")
        assert len(packed_entries) == len(se.BinaryInspector.list_pkg_entries(pkg_bytes))

    def test_t1_f11_api_merge_convert_and_bypass_seed_import(
        self, api_client, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        client, app_mod = api_client
        out_dir = isolated_studio_env["out_dir"]
        m1 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(out_dir)}
        )
        m2 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "skin", "hero_id": 150, "target_skin_id": 15009, "output_dir": str(out_dir)}
        )

        # /api/bypass-seed/import (use self-contained built mod zip containing all 4 bypass files)
        seed_zip_bytes = Path(m1["output_path"]).read_bytes()
        if _find_openapi_body_mode(app_mod, "/api/bypass-seed/import") == "multipart":
            r_seed = client.post(
                "/api/bypass-seed/import",
                files={"file": (m1["filename"], seed_zip_bytes, "application/zip")},
            )
        else:
            r_seed = client.post("/api/bypass-seed/import", json={"path": m1["output_path"]})
        assert r_seed.status_code == 200
        assert (isolated_studio_env["data_dir"] / "custom_bypass_seed.zst").exists()

        # /api/convert
        if _find_openapi_body_mode(app_mod, "/api/convert") == "multipart":
            r_conv = client.post(
                "/api/convert",
                files={"file": (m1["filename"], Path(m1["output_path"]).read_bytes(), "application/zip")},
                data={"target_format": "3105", "password": "pw123"},
            )
        else:
            r_conv = client.post(
                "/api/convert",
                json={"path": m1["output_path"], "target_format": "3105", "password": "pw123"},
            )
        assert r_conv.status_code == 200

        # /api/merge
        if _find_openapi_body_mode(app_mod, "/api/merge") == "multipart":
            r_merge = client.post(
                "/api/merge",
                files=[
                    ("files", (m1["filename"], Path(m1["output_path"]).read_bytes(), "application/zip")),
                    ("files", (m2["filename"], Path(m2["output_path"]).read_bytes(), "application/zip")),
                ],
                data={"output_format": "zip"},
            )
        else:
            r_merge = client.post(
                "/api/merge",
                json={"paths": [m1["output_path"], m2["output_path"]], "output_format": "zip"},
            )
        assert r_merge.status_code == 200

    # --- F12: Offline Mint UI (`studio.html`) ---

    def test_t1_f12_studio_html_has_zero_external_cdn_links_or_imports(self):
        html = _require_studio_html()
        for host in FORBIDDEN_CDN_HOSTS:
            assert host not in html.lower(), f"Forbidden external CDN reference found: {host}"
        assert re.search(r'(?i)<script[^>]+src=["\'](?:https?:)?//', html) is None
        assert re.search(r'(?i)<link[^>]+href=["\'](?:https?:)?//', html) is None

    def test_t1_f12_studio_html_has_inlined_style_and_script(self):
        html = _require_studio_html()
        styles = re.findall(r"(?is)<style[^>]*>(.*?)</style>", html)
        scripts = re.findall(r"(?is)<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html)
        assert any(s.strip() for s in styles), "studio.html missing non-empty inline <style>"
        assert any(s.strip() for s in scripts), "studio.html missing non-empty inline <script>"

    def test_t1_f12_studio_html_contains_exact_light_and_dark_mint_tokens(self):
        html = _require_studio_html()
        styles = re.findall(r"(?is)<style[^>]*>(.*?)</style>", html)
        assert styles, "studio.html missing <style> block"
        css_body = re.sub(r"/\*.*?\*/", "", "\n".join(styles), flags=re.DOTALL).upper()
        for tok in MINT_LIGHT_TOKENS:
            assert tok.upper() in css_body, f"Missing Light Mint token {tok} in <style>"
        for tok in MINT_DARK_TOKENS:
            assert tok.upper() in css_body, f"Missing Dark Mint token {tok} in <style>"

    def test_t1_f12_studio_html_contains_theme_toggle_and_all_four_feature_areas_plus_handbook(self):
        html = _require_studio_html()
        no_comments = re.sub(r"<!--.*?-->", "", html, flags=re.DOTALL)
        low = no_comments.lower()
        assert "localstorage" in low
        assert "dark" in low and "light" in low
        for expected_text in ("1-Click", "Mix", "Inspector", "3105"):
            assert expected_text.lower() in low, f"Missing studio.html feature area indicator: {expected_text}"
        # Mod skin handbook & Vietnamese UI
        assert any(term in low for term in ("sổ tay", "logic mod", "nguyên lý"))

        class _ThemeBtnFinder(HTMLParser):
            def __init__(self):
                super().__init__()
                self.has_theme_btn = False

            def handle_starttag(self, tag, attrs):
                if tag.lower() == "button":
                    joined = " ".join(f"{k}={v}" for k, v in attrs if v).lower()
                    if any(w in joined for w in ("theme", "dark", "light")):
                        self.has_theme_btn = True

        finder = _ThemeBtnFinder()
        finder.feed(no_comments)
        assert finder.has_theme_btn or re.search(
            r"(?is)<button[^>]*>[^<]*(?:sáng|tối|theme|giao diện)[^<]*</button>", no_comments
        ), "Missing interactive theme toggle <button> outside HTML comments"

    def test_t1_f12_studio_html_playwright_edge_live_render_and_theme_switch(self, isolated_studio_env, monkeypatch):
        if not EDGE_EXE.exists() or importlib.util.find_spec("playwright") is None:
            pytest.skip("Microsoft Edge or playwright not installed")
        app_mod = _require_app_module()
        _require_studio_html()
        _patch_module_paths(app_mod, isolated_studio_env["data_dir"], isolated_studio_env["out_dir"], monkeypatch)

        import uvicorn
        from playwright.sync_api import sync_playwright

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]

        config = uvicorn.Config(app_mod.app, host="127.0.0.1", port=port, log_level="error")
        server = uvicorn.Server(config)
        thread = threading.Thread(target=server.run, daemon=True)
        thread.start()
        try:
            import urllib.request

            for _ in range(50):
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1) as resp:
                        if resp.status == 200:
                            break
                except Exception:
                    time.sleep(0.1)

            console_errors: list[str] = []
            page_errors: list[str] = []
            external_reqs: list[str] = []

            with sync_playwright() as p:
                browser = p.chromium.launch(executable_path=str(EDGE_EXE), headless=True, args=["--no-sandbox"])
                page = browser.new_page()
                page.on("console", lambda msg: console_errors.append(msg.text) if msg.type == "error" else None)
                page.on("pageerror", lambda err: page_errors.append(str(err)))
                page.on(
                    "request",
                    lambda req: external_reqs.append(req.url)
                    if not (
                        req.url.startswith(f"http://127.0.0.1:{port}/")
                        or req.url.startswith("data:")
                        or req.url.startswith("blob:")
                    )
                    else None,
                )
                page.goto(f"http://127.0.0.1:{port}/", wait_until="networkidle")
                assert len(page.content()) > 500
                toggle = page.locator("[data-theme-toggle], #themeToggle, #theme-toggle, button:has-text('Sáng'), button:has-text('Tối')").first
                assert toggle.count() > 0, "Theme toggle button not found in rendered studio.html"
                bg_before = page.evaluate("getComputedStyle(document.body).backgroundColor")
                toggle.click()
                bg_after = page.evaluate("getComputedStyle(document.body).backgroundColor")
                assert bg_before != bg_after
                browser.close()

            assert not console_errors, f"Console errors: {console_errors}"
            assert not page_errors, f"Uncaught page errors: {page_errors}"
            assert not external_reqs, f"External network requests leaked: {external_reqs}"
        finally:
            server.should_exit = True
            thread.join(timeout=5)


# ===========================================================================
# TIER 2: BOUNDARY & CORNER CASES (F1–F12, >= 5 cases each, >= 60 cases total)
# ===========================================================================

class TestTier2_BoundaryAndCornerCases:
    # --- F1 Boundaries ---

    def test_t2_f1_bijan_548_and_teeri_546_not_overwritten_by_ex_placeholder(self, shared_catalog: dict[str, Any]):
        heroes_by_id = {h["hero_id"]: h for h in shared_catalog["heroes"]}
        assert heroes_by_id[548]["name"] == "Bijan"
        assert heroes_by_id[546]["name"] == "Teeri"
        assert "[ex]" not in heroes_by_id[548]["name"].lower()
        assert "[ex]" not in heroes_by_id[546]["name"].lower()

    def test_t2_f1_provider_unicode_vietnamese_directory_path(
        self, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        uni_dir = tmp_path / "Thư Mục Tiếng Việt Có Dấu" / "Bản Gốc 3.0"
        _build_lightweight_extracted_resources(shared_provider, uni_dir)
        prov = se.BaseResourceProvider(str(uni_dir))
        cat = se.CatalogIndexer.build_or_load(prov, force_rebuild=True)
        heroes_by_id = {h["hero_id"]: h for h in cat["heroes"]}
        assert heroes_by_id[131]["name"] == "Murad"
        assert heroes_by_id[548]["name"] == "Bijan"

    def test_t2_f1_provider_missing_or_empty_path_raises(self, tmp_path: Path):
        with pytest.raises(FileNotFoundError):
            se.BaseResourceProvider("")
        with pytest.raises(FileNotFoundError):
            se.BaseResourceProvider(str(tmp_path / "does_not_exist.zip"))

    def test_t2_f1_provider_non_aov_zip_raises_value_error(self, tmp_path: Path):
        bad_zip = tmp_path / "not_aov.zip"
        with zipfile.ZipFile(bad_zip, "w") as zf:
            zf.writestr("readme.txt", b"hello")
        with pytest.raises(ValueError):
            se.BaseResourceProvider(str(bad_zip))

    def test_t2_f1_provider_corrupted_zip_raises_badzipfile(self, tmp_path: Path):
        corrupt = tmp_path / "corrupt.zip"
        corrupt.write_bytes(b"PK\x03\x04corrupted-truncated-bytes")
        with pytest.raises(zipfile.BadZipFile):
            se.BaseResourceProvider(str(corrupt))

    # --- F2 Boundaries ---

    def test_t2_f2_apply_to_all_skins_false_targets_only_xx00(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "apply_to_all_skins": False,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        flt9_tracks = [
            t for t in cp.split_xml_tracks(back_xml)[1]
            if t.get("filterType") == "9" and "150_HanXin/15009/" in t["raw"]
        ]
        assert flt9_tracks
        assert flt9_tracks[0]["skins"] == ["15000"]

    def test_t2_f2_custom_filename_strips_windows_illegal_chars_and_trailing_dots(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "camera_only",
                "camera_percent": 15,
                "custom_filename": '  CON<>:"/\\|?*.. .  ',
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        fn = res["filename"]
        assert not any(ch in fn for ch in '<>:"/\\|?*')
        stem = os.path.splitext(fn)[0]
        assert not stem.endswith(".") and not stem.endswith(" ")
        assert stem.upper() != "CON"
        assert Path(res["output_path"]).exists()

    def test_t2_f2_unicode_vietnamese_watermark_and_filename(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"] / "Gói Mod Tiếng Việt"
        out_dir.mkdir(parents=True, exist_ok=True)
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "watermark_text": "Bản Mod Murad Thiên Luân — Tiếng Việt Đầy Đủ",
                "custom_filename": "Murad Thiên Luân Kiếm Thánh 3.0",
                "output_dir": str(out_dir),
            },
        )
        assert Path(res["output_path"]).exists()
        assert "Thiên Luân" in res["filename"]

    def test_t2_f2_missing_hero_or_unknown_skin_raises(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        with pytest.raises((KeyError, ValueError)):
            se.SkinModBuilder.build_mod(
                shared_provider,
                {"mode": "skin", "hero_id": 999999, "target_skin_id": 99999901, "output_dir": str(isolated_studio_env["out_dir"])},
            )

    def test_t2_f2_import_bypass_seed_incomplete_zip_raises_value_error(self, tmp_path: Path):
        incomplete = io.BytesIO()
        with zipfile.ZipFile(incomplete, "w") as zf:
            zf.writestr("Resources/1.64.1/version.txt", b"1.64.1.12|1793129")
        with pytest.raises(ValueError):
            se.import_bypass_seed_from_mod_zip(incomplete.getvalue())

    # --- F3 Boundaries ---

    def test_t2_f3_mix_partial_slots_fallback_to_target_skin(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "is_mix": True,
                "skill_mix": {"skill1": 13112},
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/13112/" in by_base["s1.xml"]
        assert "/13118/" in by_base["a1.xml"]

    def test_t2_f3_mix_zero_or_invalid_slot_id_falls_back_gracefully(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "is_mix": True,
                "skill_mix": {"normal": 0, "skill1": "not-an-int", "skill2": None},
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/13118/" in by_base["a1.xml"]

    def test_t2_f3_mix_enable_vfx_false_preserves_base_skills_while_promoting_model(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_vfx": False,
                "enable_recall": False,
                "enable_born": False,
                "enable_sound": False,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        _, actorinfo_plain = _extract_actorinfo_plain(rel_map, 150)
        assert b"15010_" in actorinfo_plain or b"15009" in actorinfo_plain
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 150), 150)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/15009/" not in by_base["a1.xml"]

    def test_t2_f3_mix_same_skin_across_all_slots_matches_1click(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        slots = {k: 13118 for k in ("normal", "skill1", "skill2", "skill3", "passive", "recall", "born", "sound")}
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "is_mix": True,
                "skill_mix": slots,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/13118/" in by_base["a1.xml"] and any("/13118/" in txt for k, txt in by_base.items() if k.startswith("u1"))

    def test_t2_f3_mix_with_base_skin_slot_keeps_base_action_effects(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "is_mix": True,
                "skill_mix": {"normal": 13100, "skill1": 13118},
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/13118/" not in by_base["a1.xml"]
        assert "/13118/" in by_base["s1.xml"]

    # --- F4 Boundaries ---

    def test_t2_f4_enable_recall_false_leaves_back_xml_untouched(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        orig_ca = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        orig_back = cp.decode_aov_xml_if_needed(
            dict((n, d) for n, _, _, d in cp.parse_in_memory_zip(orig_ca))["commonresource/Back.xml"],
            "commonresource/Back.xml",
        ).decode("utf-8")

        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_recall": False,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        out_back = _extract_common_xml(rel_map, "commonresource/Back.xml")
        assert out_back == orig_back

    def test_t2_f4_enable_born_false_leaves_hastee1_and_born_untouched(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        orig_ca = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        orig_entries = {n: d for n, _, _, d in cp.parse_in_memory_zip(orig_ca)}
        orig_haste = cp.decode_aov_xml_if_needed(orig_entries["commonresource/HasteE1.xml"], "commonresource/HasteE1.xml").decode("utf-8")
        orig_born = cp.decode_aov_xml_if_needed(orig_entries["commonresource/Born.xml"], "commonresource/Born.xml").decode("utf-8")

        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_born": False,
                "camera_percent": 0,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert _extract_common_xml(rel_map, "commonresource/HasteE1.xml") == orig_haste
        assert _extract_common_xml(rel_map, "commonresource/Born.xml") == orig_born

    def test_t2_f4_skin_without_backtotown_icon_gets_no_custom_recall_tracks(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13100,
                "enable_recall": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        assert "131_LiBai/13100/" not in back_xml

    def test_t2_f4_skin_without_exclusive_sprint_cfg_gets_no_hastee1_injection(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        orig_ca = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        orig_haste = cp.decode_aov_xml_if_needed(
            {n: d for n, _, _, d in cp.parse_in_memory_zip(orig_ca)}["commonresource/HasteE1.xml"],
            "commonresource/HasteE1.xml",
        ).decode("utf-8")
        orig_cnt = len(cp.split_xml_tracks(orig_haste)[1])

        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13100,
                "enable_born": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        out_haste = _extract_common_xml(rel_map, "commonresource/HasteE1.xml")
        assert len(cp.split_xml_tracks(out_haste)[1]) == orig_cnt

    def test_t2_f4_back_xml_idempotent_no_duplicate_flt9_tracks_on_existing_skin(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13109,
                "enable_recall": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        tracks = cp.split_xml_tracks(back_xml)[1]
        huijidi_matches = [
            t for t in tracks
            if t.get("filterType") == "9" and "13109" in t["raw"] and "huijidi" in t["raw"].lower()
        ]
        assert len(huijidi_matches) <= 1

    # --- F5 Boundaries ---

    def test_t2_f5_sound_5digit_upper_boundary_xx99_remapped(self):
        rec_99 = struct.pack("<IIII", 12, 1509901, 0, 15099)
        hdr = bytearray(140)
        hdr[:4] = b"MSES"
        struct.pack_into("<II", hdr, 8, 12, 1)
        plain = bytes(hdr) + rec_99
        pre = cp.parse_mses(plain)
        assert pre is not None and len(pre["recs"]) == 1
        remapped = se._remap_sound_table_for_hero(plain, "BattleBank", 150, 15009, 15000)
        tbl = cp.parse_mses(remapped)
        assert tbl is not None and len(tbl["recs"]) == 1
        assert struct.unpack_from("<I", tbl["recs"][0][1], 12)[0] == 23599

    def test_t2_f5_sound_7digit_lower_and_upper_bounds(self):
        r_low = struct.pack("<IIII", 12, 1500001, 0, 1500000)
        r_high = struct.pack("<IIII", 12, 1509999, 0, 1509999)
        r_out = struct.pack("<IIII", 12, 1509998, 0, 1510000)
        hdr = bytearray(140)
        hdr[:4] = b"MSES"
        struct.pack_into("<II", hdr, 8, 12, 3)
        plain = bytes(hdr) + r_low + r_high + r_out
        pre = cp.parse_mses(plain)
        assert pre is not None and len(pre["recs"]) == 3
        remapped = se._remap_sound_table_for_hero(plain, "BattleBank", 150, 15009, 15000)
        tbl = cp.parse_mses(remapped)
        assert tbl is not None and len(tbl["recs"]) == 3
        assert [struct.unpack_from("<I", tbl["recs"][i][1], 12)[0] for i in range(3)] == [
            2350000,
            2359999,
            1510000,
        ]

    def test_t2_f5_couplesound_non_hero_record_with_15000_payload_untouched(self, shared_provider: se.BaseResourceProvider):
        plain = cp.pg_decrypt(shared_provider.read("Databin/Client/Sound/CoupleSound.bytes"), "CoupleSound")
        orig = cp.parse_mses(plain)
        remapped = se._remap_sound_table_for_hero(plain, "CoupleSound", 150, 15009, 15000)
        new_t = cp.parse_mses(remapped)
        assert orig and new_t
        for (o_rid, o_raw), (n_rid, n_raw) in zip(orig["recs"], new_t["recs"]):
            if not str(o_rid).startswith("150"):
                assert o_raw == n_raw

    def test_t2_f5_enable_sound_false_omits_sound_tables_and_skin_suffix(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_sound": False,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert not any(k.startswith("Databin/Client/Sound/") for k in rel_map)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 150), 150)
        assert not any("_Skin9" in txt for txt in xmls.values())

    def test_t2_f5_sound_skin_without_bank_does_not_corrupt_playherosound(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13101 if shared_provider.has("Databin/Client/Actor/heroSkin.bytes") else 13100,
                "enable_sound": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        assert all("<Project" in txt or "<Track" in txt or "<?xml" in txt for txt in xmls.values())

    # --- F6 Boundaries ---

    def test_t2_f6_jtcom_rewrite_empty_whitespace_and_non_hero_paths(self):
        assert jtcom.rewrite_hero_effect_path("   ", 131, 13118, True) == ""
        unchanged = "prefab_skill_effects/tongyong_effects/tongyong_hurt/born_back_reborn/huijidi_01"
        assert jtcom.rewrite_hero_effect_path(unchanged, 131, 13118, True) == unchanged

    def test_t2_f6_jtcom_rewrite_backslash_normalization_and_existing_hd_suffix(self):
        p = r"prefab_skill_effects\hero_skill_effects\13118_Libai_sprint_02_HD"
        assert jtcom.rewrite_hero_effect_path(p, 131, 13118, True) == (
            "prefab_skill_effects/hero_skill_effects/13118_Libai_sprint_02_HD"
        )
        p2 = r"prefab_skill_effects\hero_skill_effects\15009_bar.prefab"
        assert jtcom.rewrite_hero_effect_path(p2, 150, 15009, False) == (
            "prefab_skill_effects/hero_skill_effects/15009_bar.prefab"
        )

    def test_t2_f6_jtcom_parse_truncated_or_invalid_buffer_raises_value_error(self):
        with pytest.raises(ValueError):
            jtcom.parse_jt(b"\x10\x00\x00\x00")
        with pytest.raises(ValueError):
            jtcom.parse_jt(b"\x05\x00\x00\x00" + b"\x00" * 16)

    def test_t2_f6_zero_button_and_zero_billboard_ids_encoded_cleanly_in_hs2(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        _install_mock_kiana_seed(shared_provider)
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "enable_button": False,
                "enable_billboard": False,
                "personal_button_id": 0,
                "billboard_id": 0,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        verify_heroskin_1_and_2(
            rel_map["Thanos/HeroSkin_1.bytes"],
            rel_map["Thanos/HeroSkin_2.bytes"],
            expected_hero_id=131,
            expected_skin_id=13118,
            expected_button_id=0,
            expected_billboard_id=0,
        )

    def test_t2_f6_custom_override_button_and_billboard_ids_differ_from_catalog_default(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        _install_mock_kiana_seed(shared_provider)
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "enable_button": True,
                "enable_billboard": True,
                "personal_button_id": 75,
                "billboard_id": 59,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        verify_heroskin_1_and_2(
            rel_map["Thanos/HeroSkin_1.bytes"],
            rel_map["Thanos/HeroSkin_2.bytes"],
            expected_hero_id=131,
            expected_button_id=75,
            expected_billboard_id=59,
        )

    # --- F7 Boundaries ---

    def test_t2_f7_camera_percent_zero_in_skin_mode_omits_camera_track(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "camera_percent": 0,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        cam_xml = _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert "SetCameraHeightDuration" not in cam_xml

    def test_t2_f7_camera_percent_zero_in_camera_only_defaults_to_15(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "camera_only", "camera_percent": 0, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        cam_xml = _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert 'heightRate" value="1.265"' in cam_xml

    def test_t2_f7_camera_percent_extremes_5_and_25_exact_rounding(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        r5 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "camera_only", "camera_percent": 5, "output_dir": str(isolated_studio_env["out_dir"])}
        )
        r25 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "camera_only", "camera_percent": 25, "output_dir": str(isolated_studio_env["out_dir"])}
        )
        _, _, m5 = _read_zip_tree_from_build(r5)
        _, _, m25 = _read_zip_tree_from_build(r25)
        assert 'heightRate" value="1.155"' in _extract_common_xml(m5, "PassiveResource/junglemark.xml")
        assert 'heightRate" value="1.375"' in _extract_common_xml(m25, "PassiveResource/junglemark.xml")

    def test_t2_f7_inject_camera_updates_existing_setcameraheightduration_in_place(self):
        sample_xml = (
            "<Project><TemplateObjectList /><Action><Track eventType=\"SetCameraHeightDuration\">"
            "<Event eventName=\"SetCameraHeightDuration\"><float name=\"heightRate\" value=\"1.155\" /></Event>"
            "</Track></Action></Project>"
        )
        updated = se._inject_camera_height_in_born_xml(sample_xml, 25)
        assert updated.count("SetCameraHeightDuration0") == 0
        assert 'heightRate" value="1.375"' in updated

    def test_t2_f7_camera_percent_negative_in_skin_mode_does_not_inject_camera_track(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "camera_percent": -10,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert "SetCameraHeightDuration" not in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")

    # --- F8 Boundaries ---

    def test_t2_f8_actor_actions_with_no_changed_xmls_still_all_encrypted_0x224a(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13100,
                "enable_vfx": False,
                "enable_sound": False,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)

    def test_t2_f8_deflate_input_pkg_repacked_as_store_zero_after_merge(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        # Construct two valid mod zips where one contains a non-compliant ZIP_DEFLATED KernelLua.pkg.bytes,
        # then route both through OfflineMergerAndConverter.merge_mods and verify STORE=0 in merged output.
        out_dir = isolated_studio_env["out_dir"]
        r1 = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(out_dir)},
        )
        r2 = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 150, "target_skin_id": 15009, "output_dir": str(out_dir)},
        )
        deflated_mod_path = out_dir / "mod1_deflated_pkg.zip"
        with zipfile.ZipFile(r1["output_path"], "r") as zin, zipfile.ZipFile(
            deflated_mod_path, "w", compression=zipfile.ZIP_DEFLATED
        ) as zout:
            for zi in zin.infolist():
                data = zin.read(zi.filename)
                if zi.filename.lower().endswith("kernellua.pkg.bytes"):
                    pb = io.BytesIO()
                    with zipfile.ZipFile(pb, "w", compression=zipfile.ZIP_DEFLATED) as pzf:
                        for name, _, _, edata in cp.parse_in_memory_zip(data):
                            pzf.writestr(name, edata)
                    data = pb.getvalue()
                zout.writestr(zi.filename, data)

        merged = se.OfflineMergerAndConverter.merge_mods(
            [str(deflated_mod_path), r2["output_path"]],
            output_dir=str(out_dir),
            output_format="zip",
        )
        _, _, rel_map = _read_zip_tree_from_build(merged)
        pkgs = [k for k in rel_map if k.lower().endswith(".pkg.bytes")]
        assert pkgs
        for k in pkgs:
            assert_pkg_stored_zero(rel_map[k], f"merged:{k}")

    def test_t2_f8_sanitize_lua_preserves_fixreset_markers_0x432312_and_0x242424(self):
        fake_lua = b"\x1bLuaR" + b"_0x432312_and_0x242424" + cp._KIANA_AD_GLOBAL_MARKER + b"https://raw.githubusercontent.com/foo/lads.txt"
        pkg_buf = cp.build_in_memory_store_zip([("Lua_Signed/test.bytes", 0, 0x21, fake_lua)])
        cleaned = cp.sanitize_lua_pkg("KernelLua.pkg.bytes", pkg_buf)
        entries = assert_pkg_stored_zero(cleaned, "KernelLua.pkg.bytes")
        payload = entries["Lua_Signed/test.bytes"]
        assert b"_0x432312" in payload and b"_0x242424" in payload
        assert cp._KIANA_AD_GLOBAL_MARKER not in payload
        assert b"raw.githubusercontent.com" not in payload

    def test_t2_f8_version_txt_preserved_from_base_resources(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "camera_only", "camera_percent": 15, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert rel_map["version.txt"] == shared_provider.read("version.txt")

    def test_t2_f8_rpack_non_matching_hero_records_untouched(self, shared_provider: se.BaseResourceProvider):
        orig_rp = shared_provider.read("assetbundle/resourcepackerinfosetall.assetbundle")
        patched_rp = se._patch_rpack_for_hero_battle_skins(orig_rp, 131)
        orig_parsed = cp.parse_rpack(cp.unpack_unityfs(orig_rp))
        new_parsed = cp.parse_rpack(cp.unpack_unityfs(patched_rp))
        assert orig_parsed["rec_cnt"] == new_parsed["rec_cnt"]
        assert set(orig_parsed["recs"].keys()) == set(new_parsed["recs"].keys())

    # --- F9 Boundaries ---

    def test_t2_f9_inspect_full_text_true_exceeds_500kb_without_truncation(self):
        big_text = ("AOV_TEXT_LINE_1234567890_TIENG_VIET\n" * 20_000).encode("utf-8")
        assert len(big_text) > 600_000
        info = se.BinaryInspector.inspect_bytes(big_text, "languageMap_large.txt", full_text=True)
        assert info["kind"] == "text"
        assert len(info["text_content"].encode("utf-8")) == len(big_text)
        assert info["text_content"] == big_text.decode("utf-8")

    def test_t2_f9_decrypt_0x224a_truncated_header_or_wrong_stem_raises(self):
        with pytest.raises(ValueError):
            se.BinaryInspector.decrypt_0x224a(b"\x22\x4A\x67\x00\x10\x00\x00\x00\xAA\xBB\xCC\xDD", "BadTruncated")
        enc = se.BinaryInspector.encrypt_0x224a(b"<Project><Action /></Project>", "CorrectStem")
        with pytest.raises(ValueError):
            se.BinaryInspector.decrypt_0x224a(enc, "CompletelyWrongStem")
        with pytest.raises((ValueError, AssertionError)):
            verify_0x224a_pkcs7(enc, "CompletelyWrongStem")

    def test_t2_f9_read_and_update_pkg_entry_missing_entry_raises_key_error(
        self, shared_provider: se.BaseResourceProvider
    ):
        pkg = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        with pytest.raises(KeyError):
            se.BinaryInspector.read_pkg_entry(pkg, "commonresource/NonExistentTrack.xml")
        with pytest.raises(KeyError):
            se.BinaryInspector.update_pkg_entry(pkg, "commonresource/NonExistentTrack.xml", b"<Project/>")

    def test_t2_f9_update_xml_tracks_invalid_track_selector_raises(self, shared_provider: se.BaseResourceProvider):
        ca = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        back_txt = se.BinaryInspector.read_pkg_entry(ca, "commonresource/Back.xml", full_text=True)["text_content"]
        # Out-of-range index is a safe no-op; non-integer index raises ValueError
        unchanged = se.BinaryInspector.update_xml_tracks(back_txt, [{"index": 99999, "skins": ["15000"]}])
        assert unchanged == back_txt
        with pytest.raises(ValueError):
            se.BinaryInspector.update_xml_tracks(back_txt, [{"index": "not-an-int", "skins": ["15000"]}])

    def test_t2_f9_unpack_and_pack_pkg_with_unicode_vietnamese_directory(
        self, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        pkg = shared_provider.read("Prefab_Characters/Actor_131_Infos.pkg.bytes")
        uni_dir = tmp_path / "Giải Nén Tiếng Việt" / "Thư Mục Con"
        se.BinaryInspector.unpack_pkg_to_dir(pkg, str(uni_dir))
        packed = se.BinaryInspector.pack_dir_to_pkg(str(uni_dir))
        entries = assert_pkg_stored_zero(packed, "unicode_packed.pkg.bytes")
        assert len(entries) == len(se.BinaryInspector.list_pkg_entries(pkg))

    def test_t2_f9_repack_invalid_jtcom_json_or_corrupt_mses_raises(self):
        with pytest.raises((ValueError, KeyError, json.JSONDecodeError)):
            se.BinaryInspector.repack_from_editor("jtcom_tree", "{not valid json", "131_LiBai_actorinfo")
        with pytest.raises((ValueError, KeyError, TypeError, json.JSONDecodeError)):
            se.BinaryInspector.repack_from_editor("mses_table", "{}", "ResBillboardSkinCfg")

    # --- F10 Boundaries ---

    def test_t2_f10_merge_fewer_than_two_mods_raises_value_error(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        r1 = se.SkinModBuilder.build_mod(
            shared_provider, {"mode": "camera_only", "camera_percent": 15, "output_dir": str(out_dir)}
        )
        with pytest.raises(ValueError):
            se.OfflineMergerAndConverter.merge_mods([r1["output_path"]], output_dir=str(out_dir))

    def test_t2_f10_convert_3105_wrong_password_raises_error(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        r1 = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "camera_only", "camera_percent": 15, "output_format": "3105", "password": "right-password", "output_dir": str(out_dir)},
        )
        raw = Path(r1["output_path"]).read_bytes()
        with pytest.raises((ValueError, cp.PatchPackageDecodeError)):
            se.OfflineMergerAndConverter.convert_package(
                raw, r1["filename"], target_format="zip", password="wrong-password", output_dir=str(out_dir)
            )

    def test_t2_f10_convert_3105_missing_password_for_locked_package_raises(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        r1 = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "camera_only", "camera_percent": 10, "output_format": "3105", "password": "locked!", "output_dir": str(out_dir)},
        )
        raw = Path(r1["output_path"]).read_bytes()
        with pytest.raises((ValueError, cp.PatchPackageDecodeError)):
            se.OfflineMergerAndConverter.convert_package(
                raw, r1["filename"], target_format="zip", password=None, output_dir=str(out_dir)
            )

    def test_t2_f10_convert_corrupted_3105_magic_or_truncated_payload_raises(self, isolated_studio_env):
        with pytest.raises((ValueError, cp.PatchPackageDecodeError)):
            se.OfflineMergerAndConverter.convert_package(
                b"NOT3105MAGIC\x00\x01\x02", "broken.3105", target_format="zip", output_dir=str(isolated_studio_env["out_dir"])
            )
        with pytest.raises((ValueError, cp.PatchPackageDecodeError)):
            se.OfflineMergerAndConverter.convert_package(
                b"3105PATCH\x00\x01\x02", "truncated.3105", target_format="zip", output_dir=str(isolated_studio_env["out_dir"])
            )

    def test_t2_f10_merge_two_3105_inputs_with_different_input_passwords(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        m1 = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "output_format": "3105",
                "password": "pw_alpha",
                "output_dir": str(out_dir),
            },
        )
        m2 = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "output_format": "3105",
                "password": "pw_beta",
                "output_dir": str(out_dir),
            },
        )
        merged = se.OfflineMergerAndConverter.merge_mods(
            [m1["output_path"], m2["output_path"]],
            output_dir=str(out_dir),
            output_format="zip",
            input_passwords={
                m1["output_path"]: "pw_alpha",
                m1["filename"]: "pw_alpha",
                m2["output_path"]: "pw_beta",
                m2["filename"]: "pw_beta",
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(merged)
        assert "Prefab_Characters/Actor_131_Infos.pkg.bytes" in rel_map
        assert "Prefab_Characters/Actor_150_Infos.pkg.bytes" in rel_map

    def test_t2_f10_unicode_vietnamese_filename_zip_to_3105_roundtrip(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        built = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "camera_only",
                "camera_percent": 15,
                "custom_filename": "Gói Cam Xa Tiếng Việt 3.0",
                "output_dir": str(out_dir),
            },
        )
        conv1 = se.OfflineMergerAndConverter.convert_package(
            Path(built["output_path"]).read_bytes(), built["filename"], target_format="3105", output_dir=str(out_dir)
        )
        assert conv1["filename"].endswith(".3105")
        conv2 = se.OfflineMergerAndConverter.convert_package(
            Path(conv1["output_path"]).read_bytes(), conv1["filename"], target_format="zip", output_dir=str(out_dir)
        )
        assert Path(conv2["output_path"]).exists()

    # --- F11 Boundaries ---

    def test_t2_f11_outputs_download_rejects_path_traversal_4xx(self, api_client):
        client, _ = api_client
        for evil in ("../../studio_config.json", "../app.py", "..\\..\\Totorox-Backend\\main.py"):
            r = client.get("/api/outputs/download", params={"path": evil})
            assert 400 <= r.status_code < 500, f"Path traversal not rejected for {evil!r}: {r.status_code}"

    def test_t2_f11_mod_build_invalid_hero_or_missing_fields_returns_4xx(self, api_client):
        client, _ = api_client
        client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)})
        r = client.post("/api/mod/build", json={"mode": "skin", "hero_id": 999999, "target_skin_id": 99999901})
        assert 400 <= r.status_code < 500

    def test_t2_f11_convert_wrong_password_returns_4xx(
        self, api_client, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        client, app_mod = api_client
        built = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "camera_only",
                "camera_percent": 15,
                "output_format": "3105",
                "password": "correct",
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        if _find_openapi_body_mode(app_mod, "/api/convert") == "multipart":
            r = client.post(
                "/api/convert",
                files={"file": (built["filename"], Path(built["output_path"]).read_bytes(), "application/octet-stream")},
                data={"target_format": "zip", "password": "wrong"},
            )
        else:
            r = client.post(
                "/api/convert",
                json={"path": built["output_path"], "target_format": "zip", "password": "wrong"},
            )
        assert 400 <= r.status_code < 500

    def test_t2_f11_merge_single_file_returns_4xx(
        self, api_client, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        client, app_mod = api_client
        built = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "camera_only", "camera_percent": 15, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        if _find_openapi_body_mode(app_mod, "/api/merge") == "multipart":
            r = client.post(
                "/api/merge",
                files=[("files", (built["filename"], Path(built["output_path"]).read_bytes(), "application/zip"))],
            )
        else:
            r = client.post("/api/merge", json={"paths": [built["output_path"]]})
        assert 400 <= r.status_code < 500

    def test_t2_f11_open_explorer_nonexistent_path_returns_4xx(self, api_client, tmp_path: Path):
        client, _ = api_client
        r = client.post("/api/system/open-explorer", json={"path": str(tmp_path / "missing_file.zip")})
        assert 400 <= r.status_code < 500

    def test_t2_f11_dialog_browse_cancelled_returns_empty_cleanly(self, api_client, monkeypatch: pytest.MonkeyPatch):
        client, _ = api_client

        class DummyTk:
            def withdraw(self):
                pass

            def attributes(self, *args, **kwargs):
                pass

            def wm_attributes(self, *args, **kwargs):
                pass

            def lift(self):
                pass

            def destroy(self):
                pass

        import tkinter
        import tkinter.filedialog as fd

        monkeypatch.setattr(tkinter, "Tk", DummyTk)
        monkeypatch.setattr(fd, "askopenfilename", lambda **kw: "")
        r = client.post("/api/dialog/browse", json={"mode": "file"})
        assert r.status_code == 200
        body = r.json()
        assert not body.get("path") and not body.get("paths")

    # --- F12 Boundaries ---

    def test_t2_f12_studio_html_zero_remote_img_iframe_audio_video_sources(self):
        html = _require_studio_html()

        class _AssetScanner(HTMLParser):
            def __init__(self):
                super().__init__()
                self.bad: list[str] = []

            def handle_starttag(self, tag, attrs):
                for k, v in attrs:
                    if k in ("src", "href", "poster") and v:
                        if re.match(r"(?i)^(?:https?:)?//", v.strip()):
                            self.bad.append(f"<{tag} {k}={v!r}>")

        scanner = _AssetScanner()
        scanner.feed(html)
        assert not scanner.bad, f"Remote resource tags found in studio.html: {scanner.bad}"

    def test_t2_f12_studio_html_zero_css_import_or_url_http_references(self):
        html = _require_studio_html()
        styles = re.findall(r"(?is)<style[^>]*>(.*?)</style>", html)
        assert styles, "studio.html missing <style> block"
        css_body = re.sub(r"/\*.*?\*/", "", "\n".join(styles), flags=re.DOTALL)
        for target in (css_body, html):
            assert re.search(r"(?i)@import\s+(?:url\()?['\"]?(?:https?:)?//", target) is None
            assert re.search(r"(?i)url\(\s*['\"]?(?:https?:)?//", target) is None

    def test_t2_f12_studio_html_valid_utf8_vietnamese_diacritics_and_charset(self):
        html = _require_studio_html()
        assert "utf-8" in html.lower()
        no_comments = re.sub(r"<!--.*?-->", "", html, flags=re.DOTALL)
        assert any(ch in no_comments for ch in ("Tướng", "Giao diện", "Biến về", "Chỉnh sửa"))

    def test_t2_f12_studio_html_uses_relative_api_paths_not_hardcoded_external_domain(self):
        html = _require_studio_html()
        assert "totorox.io.vn" not in html.lower()
        scripts = re.findall(r"(?is)<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html)
        assert scripts, "studio.html missing inline <script>"
        script_body = "\n".join(scripts)
        assert "/api/" in script_body
        # Reject any http(s):// or ws(s):// URL in <script> (allowing only standard XML/SVG namespace URIs)
        urls_in_js = [
            u
            for u in re.findall(r"(?i)(?:https?|wss?)://[^\s'\"`)<>]+", script_body)
            if not u.lower().startswith("http://www.w3.org/")
        ]
        assert not urls_in_js, f"External network URL(s) found inside <script>: {urls_in_js}"

    def test_t2_f12_studio_html_has_accessible_controls_for_theme_and_tabs(self):
        html = _require_studio_html()
        no_comments = re.sub(r"<!--.*?-->", "", html, flags=re.DOTALL)

        class _ControlsScanner(HTMLParser):
            def __init__(self):
                super().__init__()
                self.button_count = 0
                self.has_theme_control = False

            def handle_starttag(self, tag, attrs):
                if tag.lower() == "button":
                    self.button_count += 1
                    joined = " ".join(f"{k}={v}" for k, v in attrs if v).lower()
                    if any(tok in joined for tok in ("theme", "dark", "light")):
                        self.has_theme_control = True

        scanner = _ControlsScanner()
        scanner.feed(no_comments)
        assert scanner.button_count >= 2, "studio.html must contain interactive <button> controls for tabs and theme"
        assert scanner.has_theme_control or re.search(
            r"(?is)<button[^>]*>[^<]*(?:sáng|tối|theme|giao diện)[^<]*</button>", no_comments
        ), "studio.html missing theme toggle <button> control"


# ===========================================================================
# TIER 3: CROSS-FEATURE COMBINATIONS (>= 12 pairwise tests)
# ===========================================================================

class TestTier3_CrossFeatureCombinations:
    def test_t3_01_1click_plus_camxa_plus_watermark_plus_3105_passworded(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        wm = "Pairwise 1-Click + CamXa 20% + 3105"
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "camera_percent": 20,
                "watermark_text": wm,
                "output_format": "3105",
                "password": "Pairwise3105Password!",
                "personal_button_id": 20,
                "billboard_id": 21,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        tree = verify_3105_envelope(Path(res["output_path"]).read_bytes(), password="Pairwise3105Password!")
        _, rel_map = strip_resources_prefix(tree)
        assert 'heightRate" value="1.320"' in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert f"Tip_WaterMark_Str = {wm}" in rel_map["Languages/VN_Garena_VN/languageMap.txt"].decode("utf-8")
        assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)

    def test_t3_02_mix_8slots_plus_recall_plus_born_haste_plus_sound_plus_button_billboard(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15015,
                "is_mix": True,
                "enable_vfx": True,
                "enable_recall": True,
                "enable_born": True,
                "enable_sound": True,
                "enable_button": True,
                "enable_billboard": True,
                "personal_button_id": 52,
                "billboard_id": 45,
                "skill_mix": {
                    "normal": 15009,
                    "skill1": 15012,
                    "skill2": 15015,
                    "skill3": 15016,
                    "passive": 15012,
                    "recall": 15009,
                    "born": 15009,
                    "sound": 15009,
                },
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert "150_HanXin/15009/huijidi_01.prefab" in _extract_common_xml(rel_map, "commonresource/Back.xml")
        assert "T2_Spint" in _extract_common_xml(rel_map, "commonresource/HasteE1.xml")
        assert res["summary"]["seed_mode"] == "vanhoc"
        assert res["summary"]["personal_button_id"] == 52
        assert res["summary"]["billboard_id"] == 45
        verify_kiana_ifix_thanos(rel_map, 150, 15015, 52, 45)

    def test_t3_03_build_mod_then_inspect_actor_actions_decrypt_edit_xml_repack_store_zero(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        pkg = _extract_actor_actions_pkg(rel_map, 131)
        entries = se.BinaryInspector.list_pkg_entries(pkg)
        target_name = next(
            (e["name"] if isinstance(e, dict) else e)
            for e in entries
            if (e["name"] if isinstance(e, dict) else e).lower().endswith("a1.xml")
        )
        read_res = se.BinaryInspector.read_pkg_entry(pkg, target_name, full_text=True)
        tracks = se.BinaryInspector.parse_xml_tracks(read_res["text_content"])
        assert len(tracks) > 0
        edited_xml = se.BinaryInspector.update_xml_tracks(
            read_res["text_content"],
            [{"index": 0, "trackName": "EditedByInspector"}],
        )
        repacked_pkg = se.BinaryInspector.update_pkg_entry(
            pkg, target_name, edited_xml.encode("utf-8"), encrypt_stem="A1"
        )
        decoded = assert_actor_actions_encrypted(repacked_pkg, 131)
        assert "EditedByInspector" in decoded[target_name]

    def test_t3_04_build_two_3105_mods_different_passwords_merge_and_convert_back_to_zip(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        p1 = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_format": "3105", "password": "pw1", "output_dir": str(out_dir)},
        )
        p2 = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 190, "target_skin_id": 19016, "output_format": "3105", "password": "pw2", "output_dir": str(out_dir)},
        )
        merged_3105 = se.OfflineMergerAndConverter.merge_mods(
            [p1["output_path"], p2["output_path"]],
            output_dir=str(out_dir),
            output_format="3105",
            password="merged_pw",
            input_passwords={p1["output_path"]: "pw1", p2["output_path"]: "pw2"},
        )
        back_zip = se.OfflineMergerAndConverter.convert_package(
            Path(merged_3105["output_path"]).read_bytes(),
            merged_3105["filename"],
            target_format="zip",
            password="merged_pw",
            output_dir=str(out_dir),
        )
        _, rel_map = strip_resources_prefix(read_zip_tree(Path(back_zip["output_path"]).read_bytes()))
        assert "Prefab_Characters/Actor_131_Infos.pkg.bytes" in rel_map
        assert "Prefab_Characters/Actor_190_Infos.pkg.bytes" in rel_map

    def test_t3_05_inspector_mses_edit_repack_0x224a_plus_jtcom_json_edit_plus_pkg_repack(
        self, shared_provider: se.BaseResourceProvider
    ):
        # MSES edit + 0x224A repack (preserve header/footer & mutate record 0 skin ref)
        raw_bill = shared_provider.read("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes")
        mses_info = se.BinaryInspector.inspect_bytes(raw_bill, "ResBillboardSkinCfg.bytes", full_text=True)
        mses_doc = json.loads(mses_info["text_content"])
        rec0 = bytearray(bytes.fromhex(mses_doc["records"][0]["raw_hex"]))
        assert len(rec0) == 16
        struct.pack_into("<I", rec0, 12, 13118)
        mses_doc["records"][0]["raw_hex"] = rec0.hex()
        repacked_mses = se.BinaryInspector.repack_from_editor(
            "mses_table",
            json.dumps(mses_doc),
            "ResBillboardSkinCfg",
            encrypt_224a=True,
        )
        tbl = verify_mses_table(repacked_mses, "ResBillboardSkinCfg")
        assert struct.unpack_from("<I", tbl["recs"][0][1], 12)[0] == 13118

        # JTCom JSON edit + .pkg.bytes update_pkg_entry STORE=0
        infos_pkg = shared_provider.read("Prefab_Characters/Actor_131_Infos.pkg.bytes")
        entries = se.BinaryInspector.list_pkg_entries(infos_pkg)
        actor_entry = next(
            (e["name"] if isinstance(e, dict) else e)
            for e in entries
            if (e["name"] if isinstance(e, dict) else e).lower().endswith("131_libai_actorinfo.bytes")
        )
        jt_info = se.BinaryInspector.read_pkg_entry(infos_pkg, actor_entry, full_text=True)
        jt_obj = json.loads(jt_info["text_content"])
        for ch in jt_obj.get("children", []):
            if ch.get("name") == "ActorName":
                for attr in ch.get("attrs", []):
                    if attr.get("key") == "V":
                        attr["value"] = "Murad Edited"
        new_jt_bytes = se.BinaryInspector.repack_from_editor(
            "jtcom_tree", json.dumps(jt_obj), "131_LiBai_actorinfo", encrypt_224a=False
        )
        upd_pkg = se.BinaryInspector.update_pkg_entry(
            infos_pkg, actor_entry, new_jt_bytes, encrypt_stem="131_LiBai_actorinfo"
        )
        pkg_entries = assert_pkg_stored_zero(upd_pkg, "Actor_131_Infos.pkg.bytes")
        plain = verify_0x224a_pkcs7(pkg_entries[actor_entry], "131_LiBai_actorinfo")
        assert b"Murad Edited" in plain

    def test_t3_06_unicode_provider_dir_plus_catalog_plus_15009_7digit_sound_plus_haste(
        self, shared_provider: se.BaseResourceProvider, tmp_path: Path, isolated_studio_env
    ):
        uni_root = tmp_path / "Dữ Liệu Game Việt Hóa"
        _build_lightweight_extracted_resources(shared_provider, uni_root)
        prov = se.BaseResourceProvider(str(uni_root))
        cat = se.CatalogIndexer.build_or_load(prov, force_rebuild=True)
        assert any(h["hero_id"] == 150 and h["name"] == "Nakroth" for h in cat["heroes"])
        res = se.SkinModBuilder.build_mod(
            prov,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_sound": True,
                "enable_born": True,
                "enable_recall": True,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        bb = verify_mses_table(rel_map["Databin/Client/Sound/BattleBank.bytes"], "BattleBank")
        assert struct.unpack_from("<I", dict(bb["recs"])[150330120], 13)[0] == 2353301
        assert "T2_Spint" in _extract_common_xml(rel_map, "commonresource/HasteE1.xml")

    def test_t3_07_api_config_catalog_build_download_inspect_convert_e2e(self, api_client, isolated_studio_env):
        client, app_mod = api_client
        assert client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)}).status_code == 200
        assert client.get("/api/catalog").status_code == 200
        rb = client.post(
            "/api/mod/build",
            json={"mode": "camera_only", "camera_percent": 20, "custom_filename": "e2e_api_cam"},
        )
        assert rb.status_code == 200
        out_path = Path(rb.json()["output_path"])
        dl = client.get("/api/outputs/download", params={"path": rb.json()["filename"]})
        if dl.status_code in (404, 422):
            dl = client.get("/api/outputs/download", params={"path": str(out_path)})
        assert dl.status_code == 200

        if _find_openapi_body_mode(app_mod, "/api/convert") == "multipart":
            rc = client.post(
                "/api/convert",
                files={"file": ("e2e_api_cam.zip", dl.content, "application/zip")},
                data={"target_format": "3105", "password": "e2epw"},
            )
        else:
            rc = client.post(
                "/api/convert",
                json={"path": str(out_path), "target_format": "3105", "password": "e2epw"},
            )
        assert rc.status_code == 200
        raw_3105 = Path(rc.json()["output_path"]).read_bytes()
        verify_3105_envelope(raw_3105, password="e2epw")

    def test_t3_08_api_build_two_mods_then_merge_with_custom_watermark(self, api_client, isolated_studio_env):
        client, app_mod = api_client
        client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)})
        r1 = client.post("/api/mod/build", json={"mode": "skin", "hero_id": 131, "target_skin_id": 13118})
        r2 = client.post("/api/mod/build", json={"mode": "skin", "hero_id": 150, "target_skin_id": 15009})
        assert r1.status_code == 200 and r2.status_code == 200
        p1, p2 = r1.json()["output_path"], r2.json()["output_path"]
        wm = "API Merged Watermark 3.0"

        if _find_openapi_body_mode(app_mod, "/api/merge") == "multipart":
            rm = client.post(
                "/api/merge",
                files=[
                    ("files", (Path(p1).name, Path(p1).read_bytes(), "application/zip")),
                    ("files", (Path(p2).name, Path(p2).read_bytes(), "application/zip")),
                ],
                data={"watermark_text": wm, "output_format": "zip"},
            )
        else:
            rm = client.post(
                "/api/merge",
                json={"paths": [p1, p2], "watermark_text": wm, "output_format": "zip"},
            )
        assert rm.status_code == 200
        _, rel_map = strip_resources_prefix(read_zip_tree(Path(rm.json()["output_path"]).read_bytes()))
        assert f"Tip_WaterMark_Str = {wm}" in rel_map["Languages/VN_Garena_VN/languageMap.txt"].decode("utf-8")

    def test_t3_09_import_bypass_seed_from_sample_mod_then_build_kiana_clean_mod(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        # Build a self-contained sample mod zip with a synthetic Kiana marker in KernelLua.pkg.bytes
        # to verify import_bypass_seed_from_mod_zip extracts, sanitizes, and persists custom_bypass_seed.zst
        base_mod = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 150, "target_skin_id": 15009, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        dirty_mod_buf = io.BytesIO()
        with zipfile.ZipFile(base_mod["output_path"], "r") as zin, zipfile.ZipFile(
            dirty_mod_buf, "w", compression=zipfile.ZIP_DEFLATED
        ) as zout:
            for zi in zin.infolist():
                data = zin.read(zi.filename)
                if zi.filename.lower().endswith("kernellua.pkg.bytes"):
                    k_entries = cp.parse_in_memory_zip(data)
                    dirty_lua = b"\x1bLuaR" + cp._KIANA_AD_GLOBAL_MARKER + b"https://raw.githubusercontent.com/evil/ad.txt"
                    k_entries.append(("Lua_Signed/test_kiana.bytes", 0, 0x21, dirty_lua))
                    data = cp.build_in_memory_store_zip(k_entries)
                zout.writestr(zi.filename, data)

        meta = se.import_bypass_seed_from_mod_zip(dirty_mod_buf.getvalue())
        assert meta["game_version"] == "1.64.1"
        assert (isolated_studio_env["data_dir"] / "custom_bypass_seed.zst").exists()
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")

    def test_t3_10_camera_only_4file_merged_with_skin_mod_preserves_camera_and_skin(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]
        skin = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "skin", "hero_id": 150, "target_skin_id": 15009, "camera_percent": 0, "output_dir": str(out_dir)},
        )
        cam = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "camera_only", "camera_percent": 25, "output_dir": str(out_dir)},
        )
        merged = se.OfflineMergerAndConverter.merge_mods(
            [skin["output_path"], cam["output_path"]], output_dir=str(out_dir), output_format="zip"
        )
        _, _, rel_map = _read_zip_tree_from_build(merged)
        assert 'heightRate" value="1.375"' in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert "Prefab_Characters/Actor_150_Infos.pkg.bytes" in rel_map

    def test_t3_11_inspector_unpack_pkg_to_dir_edit_multiple_xml_tracks_pack_and_verify(
        self, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        pkg = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        unpack_dir = tmp_path / "ca_unpacked"
        se.BinaryInspector.unpack_pkg_to_dir(pkg, str(unpack_dir))
        back_file = next(unpack_dir.rglob("Back.xml"))
        back_plain = cp.decode_aov_xml_if_needed(back_file.read_bytes(), "commonresource/Back.xml").decode("utf-8")
        upd = se.BinaryInspector.update_xml_tracks(
            back_plain,
            [{"index": 7, "filterType": "11", "skins": ["15000", "15009"]}],
        )
        back_file.write_bytes(se.BinaryInspector.encrypt_0x224a(upd.encode("utf-8"), "Back"))
        repacked = se.BinaryInspector.pack_dir_to_pkg(str(unpack_dir))
        entries = assert_pkg_stored_zero(repacked, "CommonActions.pkg.bytes")
        dec_back = cp.decode_aov_xml_if_needed(entries["commonresource/Back.xml"], "commonresource/Back.xml").decode("utf-8")
        trks = se.BinaryInspector.parse_xml_tracks(dec_back)
        assert "15009" in trks[7]["skins"]

    def test_t3_12_tulen_19016_hd_mix_with_custom_button_billboard_and_camxa_25pct(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 190,
                "target_skin_id": 19016,
                "is_mix": True,
                "skill_mix": {"normal": 19015, "skill1": 19016, "recall": 19016, "born": 19016},
                "enable_button": True,
                "enable_billboard": True,
                "personal_button_id": 75,
                "billboard_id": 59,
                "camera_percent": 25,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        assert 'heightRate" value="1.375"' in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert res["summary"]["seed_mode"] == "vanhoc"
        assert res["summary"]["personal_button_id"] == 75
        assert res["summary"]["billboard_id"] == 59
        verify_kiana_ifix_thanos(rel_map, 190, 19016, 75, 59)


# ===========================================================================
# TIER 4: REAL-WORLD END-TO-END SCENARIOS (>= 6 full scenarios)
# ===========================================================================

class TestTier4_RealWorldScenarios:
    def test_t4_scenario1_murad_13118_hd_full_pack_e2e(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        wm = "Totorox Studio Scenario 1 — Murad 13118 HD"
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "enable_vfx": True,
                "enable_recall": True,
                "enable_born": True,
                "enable_sound": True,
                "enable_button": True,
                "enable_billboard": True,
                "personal_button_id": 20,
                "billboard_id": 21,
                "camera_percent": 15,
                "watermark_text": wm,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        for k, data in rel_map.items():
            if k.lower().endswith(".pkg.bytes"):
                assert_pkg_stored_zero(data, k)
        assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        assert 'heightRate" value="1.265"' in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert "13118" in _extract_common_xml(rel_map, "commonresource/Back.xml")
        assert "13118_Libai_sprint_01_loop" in _extract_common_xml(rel_map, "commonresource/HasteE1.xml")
        assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")
        assert_lua_kiana_clean(rel_map["StableSystems_3.pkg.bytes"], "StableSystems_3.pkg.bytes")
        assert res["summary"]["seed_mode"] == "vanhoc"
        verify_kiana_ifix_thanos(rel_map, 131, 13118, 20, 21)
        verify_rpack_unityfs(rel_map["assetbundle/resourcepackerinfosetall.assetbundle"], hero_id=131)
        assert f"Tip_WaterMark_Str = {wm}" in rel_map["Languages/VN_Garena_VN/languageMap.txt"].decode("utf-8")

    def test_t4_scenario2_nakroth_15009_standard_plus_7digit_sound_and_sprint_e2e(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "enable_vfx": True,
                "enable_recall": True,
                "enable_born": True,
                "enable_sound": True,
                "enable_button": True,
                "enable_billboard": True,
                "personal_button_id": 52,
                "billboard_id": 45,
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        _, _, rel_map = _read_zip_tree_from_build(res)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 150), 150)
        assert any("/15009/" in t and ".prefab" in t for t in xmls.values())
        assert any("_Skin9" in t for t in xmls.values())
        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        assert "150_HanXin/15009/huijidi_01.prefab" in back_xml
        assert "150_HanXin/15009/huicheng_tongyong_01.prefab" in back_xml
        haste_xml = _extract_common_xml(rel_map, "commonresource/HasteE1.xml")
        assert "T2_Spint" in haste_xml and 'id="8"' in haste_xml and 'id="9"' in haste_xml
        bb = verify_mses_table(rel_map["Databin/Client/Sound/BattleBank.bytes"], "BattleBank")
        assert struct.unpack_from("<I", dict(bb["recs"])[150330120], 13)[0] == 2353301
        assert res["summary"]["seed_mode"] == "vanhoc"
        verify_kiana_ifix_thanos(rel_map, 150, 15009, 52, 45)

    def test_t4_scenario3_mix_chieu_8slots_camxa_20pct_3105_encrypted_roundtrip(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        res = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "is_mix": True,
                "skill_mix": {
                    "normal": 13116,
                    "skill1": 13112,
                    "skill2": 13109,
                    "skill3": 13118,
                    "passive": 13112,
                    "recall": 13109,
                    "born": 13116,
                    "sound": 13118,
                },
                "camera_percent": 20,
                "output_format": "3105",
                "password": "Scenario3Password!",
                "output_dir": str(isolated_studio_env["out_dir"]),
            },
        )
        raw_3105 = Path(res["output_path"]).read_bytes()
        tree = verify_3105_envelope(raw_3105, password="Scenario3Password!")
        _, rel_map = strip_resources_prefix(tree)
        assert 'heightRate" value="1.320"' in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/13116/" in by_base["a1.xml"]
        assert "/13112/" in by_base["s1.xml"]
        assert "/13109/" in by_base["s2.xml"]

    def test_t4_scenario4_offline_merge_real_sample_mods_nak_and_edras_kiana_clean(self, isolated_studio_env):
        if not NAK_ZIP.exists() or not EDRAS_ZIP.exists():
            pytest.skip("Real sample mods Nak.zip / Edras Vấn Tâm Kiếm.zip not found")
        wm = "Totorox Studio Real Merge — Nakroth + Edras"
        merged = se.OfflineMergerAndConverter.merge_mods(
            [str(NAK_ZIP), str(EDRAS_ZIP)],
            output_dir=str(isolated_studio_env["out_dir"]),
            output_name="Real_Merge_Nak_Edras",
            watermark_text=wm,
            output_format="zip",
        )
        _, _, rel_map = _read_zip_tree_from_build(merged)
        for k, data in rel_map.items():
            if k.lower().endswith(".pkg.bytes"):
                assert_pkg_stored_zero(data, k)
        assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")
        assert_lua_kiana_clean(rel_map["StableSystems_3.pkg.bytes"], "StableSystems_3.pkg.bytes")
        assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 150), 150, allow_zstd_only=True)
        assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 595), 595, allow_zstd_only=True)
        lang_txt = rel_map["Languages/VN_Garena_VN/languageMap.txt"].decode("utf-8")
        assert f"Tip_WaterMark_Str = {wm}" in lang_txt

    def test_t4_scenario5_deep_binary_inspector_unpack_edit_xml_mses_repack_roundtrip(
        self, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        act_pkg = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/Actor_131_Actions.pkg.bytes")
        unpack_dir = tmp_path / "actor_131_unpack"
        se.BinaryInspector.unpack_pkg_to_dir(act_pkg, str(unpack_dir))
        a1_path = next(unpack_dir.rglob("A1.xml"))
        a1_dec = _extract_decrypted_bytes(se.BinaryInspector.decrypt_0x224a(a1_path.read_bytes(), "A1")).decode("utf-8")
        edited_a1 = se.BinaryInspector.update_xml_tracks(a1_dec, [{"index": 0, "trackName": "Scenario5Track"}])
        a1_path.write_bytes(se.BinaryInspector.encrypt_0x224a(edited_a1.encode("utf-8"), "A1"))

        p1e5_path = next(unpack_dir.rglob("P1E5.xml"))
        p1e5_dec = _extract_decrypted_bytes(se.BinaryInspector.decrypt_0x224a(p1e5_path.read_bytes(), "P1E5")).decode("utf-8")
        p1e5_trks = se.BinaryInspector.parse_xml_tracks(p1e5_dec)
        arr_idx = next(t["index"] for t in p1e5_trks if t.get("hasSkinIdArray"))
        res_idx = next(t["index"] for t in p1e5_trks if t.get("resourceName"))
        edited_p1e5 = se.BinaryInspector.update_xml_tracks(
            p1e5_dec,
            [
                {"index": arr_idx, "skinArrayIds": ["13100", "13118"]},
                {"index": res_idx, "resourceName": "prefab_skill_effects/hero_skill_effects/131_libai/13118/LiBai_buff_08_HD"},
            ],
        )
        p1e5_path.write_bytes(se.BinaryInspector.encrypt_0x224a(edited_p1e5.encode("utf-8"), "P1E5"))

        repacked_pkg = se.BinaryInspector.pack_dir_to_pkg(str(unpack_dir))
        decoded = assert_actor_actions_encrypted(repacked_pkg, 131, allow_zstd_only=True)
        assert any("Scenario5Track" in txt for txt in decoded.values())
        p1e5_out = next(txt for name, txt in decoded.items() if name.lower().endswith("p1e5.xml"))
        assert '<Array name="skinIdArray"' in p1e5_out and '<int value="13118" />' in p1e5_out
        assert 'value="prefab_skill_effects/hero_skill_effects/131_libai/13118/LiBai_buff_08_HD"' in p1e5_out

        raw_bill = shared_provider.read("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes")
        mses_info = se.BinaryInspector.inspect_bytes(raw_bill, "ResBillboardSkinCfg.bytes", full_text=True)
        assert mses_info["record_count"] == 67
        mses_doc = json.loads(mses_info["text_content"])
        rec0 = bytearray(bytes.fromhex(mses_doc["records"][0]["raw_hex"]))
        struct.pack_into("<I", rec0, 12, 13118)
        mses_doc["records"][0]["raw_hex"] = rec0.hex()
        repacked_mses = se.BinaryInspector.repack_from_editor(
            "mses_table", json.dumps(mses_doc), "ResBillboardSkinCfg", encrypt_224a=True
        )
        tbl = verify_mses_table(repacked_mses, "ResBillboardSkinCfg")
        assert struct.unpack_from("<I", tbl["recs"][0][1], 12)[0] == 13118

    def test_t4_scenario6_full_http_server_e2e_workflow(self, api_client, isolated_studio_env):
        client, app_mod = api_client
        assert client.get("/").status_code == 200
        assert client.get("/api/health").status_code == 200
        assert client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)}).status_code == 200
        cat = client.get("/api/catalog").json()
        assert any(h["hero_id"] == 131 and h["name"] == "Murad" for h in cat["heroes"])
        rb = client.post(
            "/api/mod/build",
            json={
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "camera_percent": 15,
                "watermark_text": "Scenario 6 HTTP E2E",
                "output_format": "3105",
                "password": "HttpE2ePassword!",
            },
        )
        assert rb.status_code == 200
        raw_3105 = Path(rb.json()["output_path"]).read_bytes()
        tree = verify_3105_envelope(raw_3105, password="HttpE2ePassword!")
        _, rel_map = strip_resources_prefix(tree)
        assert 'heightRate" value="1.265"' in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")
        assert_lua_kiana_clean(rel_map["KernelLua.pkg.bytes"], "KernelLua.pkg.bytes")


# ===========================================================================
# TIER 5: ADVERSARIAL HARDENING (T5-01 .. T5-12)
# ===========================================================================

class TestTier5_AdversarialHardening:
    def test_t5_frozen_pyinstaller_meipass_resource_resolution(self, tmp_path: Path):
        meipass = tmp_path / "_internal_meipass"
        (meipass / "assets").mkdir(parents=True, exist_ok=True)
        exe_dir = tmp_path / "dist_exe_dir"
        exe_dir.mkdir(parents=True, exist_ok=True)

        shutil.copy2(STUDIO_DIR / "studio.html", meipass / "studio.html")
        shutil.copy2(STUDIO_DIR / "assets" / "bypass_seed.zst", meipass / "assets" / "bypass_seed.zst")
        shutil.copy2(BACKEND_DIR / "aov_zstd_uncompressed.bin", meipass / "aov_zstd_uncompressed.bin")
        shutil.copy2(BACKEND_DIR / "core_processor.py", meipass / "core_processor.py")
        shutil.copy2(STUDIO_DIR / "jtcom.py", meipass / "jtcom.py")
        shutil.copy2(STUDIO_DIR / "studio_engine.py", meipass / "studio_engine.py")
        shutil.copy2(STUDIO_DIR / "app.py", meipass / "app.py")

        fake_exe = exe_dir / "TotoroxModStudio.exe"
        fake_exe.write_bytes(b"")

        probe = f"""
import os, sys
meipass = {repr(str(meipass))}
exe_path = {repr(str(fake_exe))}
sys.frozen = True
sys._MEIPASS = meipass
sys.executable = exe_path
sys.path = [meipass] + [p for p in sys.path if "Totorox-Mod-Studio" not in p and "Totorox-Backend" not in p]

import studio_engine as se
import core_processor as cp
import app as app_mod
from fastapi.testclient import TestClient

assert os.path.abspath(se.BUNDLE_DIR) == os.path.abspath(meipass), se.BUNDLE_DIR
assert os.path.abspath(se.APP_DATA_DIR) == os.path.abspath(os.path.dirname(exe_path)), se.APP_DATA_DIR
assert os.path.abspath(cp.ZSTD_DICT_FILE) == os.path.abspath(os.path.join(meipass, "aov_zstd_uncompressed.bin")), cp.ZSTD_DICT_FILE
assert os.path.abspath(se.DEFAULT_BYPASS_SEED_PATH) == os.path.abspath(os.path.join(meipass, "assets", "bypass_seed.zst")), se.DEFAULT_BYPASS_SEED_PATH

with TestClient(app_mod.app) as client:
    rh = client.get("/api/health")
    assert rh.status_code == 200, rh.text
    hd = rh.json()
    assert hd["frozen"] is True, hd
    assert hd["has_default_seed"] is True, hd
    ru = client.get("/")
    assert ru.status_code == 200
    assert "Totorox Mod Studio" in ru.text

enc = se.BinaryInspector.encrypt_0x224a(b"<Project><Action/></Project>", "A1")
dec = se.BinaryInspector.decrypt_0x224a(enc, "A1")
assert dec["text_content"] == "<Project><Action/></Project>"
print("FROZEN_SIM_OK")
"""
        env = dict(os.environ)
        env["PYTHONUTF8"] = "1"
        env.pop("PYTHONPATH", None)
        proc = subprocess.run(
            [sys.executable, "-c", probe],
            cwd=str(tmp_path),
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert proc.returncode == 0, f"Frozen simulation failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        assert "FROZEN_SIM_OK" in proc.stdout

    def test_t5_api_mod_build_rejects_nonfinite_camera_percent(
        self, api_client, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        client, _ = api_client
        assert client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)}).status_code == 200

        for bad_val in ("nan", "inf", "-inf", "NaN", "Infinity", "abc", True):
            r_json = client.post(
                "/api/mod/build",
                json={"mode": "camera_only", "camera_percent": bad_val},
            )
            assert r_json.status_code == 400, f"Expected 400 for JSON camera_percent={bad_val!r}, got {r_json.status_code}: {r_json.text}"

        for bad_str in ("nan", "inf", "-inf", "NaN", "Infinity", "abc"):
            r_form = client.post(
                "/api/mod/build",
                data={"mode": "camera_only", "camera_percent": bad_str},
            )
            assert r_form.status_code == 400, f"Expected 400 for Form camera_percent={bad_str!r}, got {r_form.status_code}: {r_form.text}"

        r_raw = client.post(
            "/api/mod/build",
            content=b'{"mode":"camera_only","camera_percent":1e309}',
            headers={"Content-Type": "application/json"},
        )
        assert r_raw.status_code == 400, f"Expected 400 for 1e309, got {r_raw.status_code}: {r_raw.text}"

        # Valid SkinModBuilder.build_mod still works cleanly
        valid = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "camera_only", "camera_percent": 15, "output_dir": str(isolated_studio_env["out_dir"])},
        )
        _, _, rel_map = _read_zip_tree_from_build(valid)
        assert 'heightRate" value="1.265"' in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")

    def test_t5_api_mod_build_multipart_form_coercion(self, api_client):
        client, _ = api_client
        assert client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)}).status_code == 200

        r = client.post(
            "/api/mod/build",
            data={
                "mode": "skin",
                "hero_id": "131",
                "target_skin_id": "13118",
                "apply_to_all_skins": "false",
                "enable_sound": "false",
                "is_mix": "true",
                "camera_percent": "10",
                "skill_mix": json.dumps({"skill1": 13112}),
            },
        )
        assert r.status_code == 200, r.text
        body = r.json()
        summary = body.get("summary") or {}
        assert summary.get("apply_to_all_skins") is False
        assert summary.get("enable_sound") is False
        assert summary.get("is_mix") is True
        assert summary.get("camera_percent") == 10

        _, _, rel_map = _read_zip_tree_from_build(body)
        xmls = assert_actor_actions_encrypted(_extract_actor_actions_pkg(rel_map, 131), 131)
        by_base = {os.path.basename(k).lower(): v for k, v in xmls.items()}
        assert "/13112/" in by_base["s1.xml"]
        assert "Databin/Client/Sound/BattleBank.bytes" not in rel_map

        back_xml = _extract_common_xml(rel_map, "commonresource/Back.xml")
        flt9_tracks = [
            t for t in cp.split_xml_tracks(back_xml)[1]
            if t.get("filterType") == "9" and "131_LiBai/13118/" in t["raw"]
        ]
        assert flt9_tracks
        assert "13100" in flt9_tracks[0]["skins"]
        assert "13101" not in flt9_tracks[0]["skins"]

    def test_t5_merge_duplicate_basename_3105_different_passwords(
        self, api_client, shared_provider: se.BaseResourceProvider, isolated_studio_env, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ):
        client, app_mod = api_client
        dir_a = tmp_path / "dirA"
        dir_b = tmp_path / "dirB"
        dir_a.mkdir(parents=True, exist_ok=True)
        dir_b.mkdir(parents=True, exist_ok=True)

        m1 = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "target_skin_id": 13118,
                "output_format": "3105",
                "password": "pwA",
                "custom_filename": "dup_mod",
                "output_dir": str(dir_a),
            },
        )
        m2 = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 150,
                "target_skin_id": 15009,
                "output_format": "3105",
                "password": "pwB",
                "custom_filename": "dup_mod",
                "output_dir": str(dir_b),
            },
        )
        p1, p2 = Path(m1["output_path"]), Path(m2["output_path"])
        assert p1.name == "dup_mod.3105" and p2.name == "dup_mod.3105"

        # (a) Engine path-keyed merge
        merged_eng = se.OfflineMergerAndConverter.merge_mods(
            [str(p1), str(p2)],
            output_dir=str(isolated_studio_env["out_dir"]),
            output_format="zip",
            input_passwords={str(p1): "pwA", str(p2): "pwB"},
        )
        _, _, rel_eng = _read_zip_tree_from_build(merged_eng)
        assert "Prefab_Characters/Actor_131_Infos.pkg.bytes" in rel_eng
        assert "Prefab_Characters/Actor_150_Infos.pkg.bytes" in rel_eng

        # (b) Multipart API upload with duplicate filenames + index-keyed passwords
        r_mp = client.post(
            "/api/merge",
            files=[
                ("files", ("dup_mod.3105", p1.read_bytes(), "application/octet-stream")),
                ("files", ("dup_mod.3105", p2.read_bytes(), "application/octet-stream")),
            ],
            data={"input_passwords": json.dumps({"0": "pwA", "1": "pwB"}), "output_format": "zip"},
        )
        assert r_mp.status_code == 200, r_mp.text
        _, _, rel_mp = _read_zip_tree_from_build(r_mp.json())
        assert "Prefab_Characters/Actor_131_Infos.pkg.bytes" in rel_mp
        assert "Prefab_Characters/Actor_150_Infos.pkg.bytes" in rel_mp

        # (c) Path-based API merge with unique-basename fallback guard
        r_paths = client.post(
            "/api/merge",
            json={
                "paths": [str(p1), str(p2)],
                "input_passwords": {str(p1): "pwA", str(p2): "pwB", "dup_mod.3105": "pwB"},
                "output_format": "zip",
            },
        )
        assert r_paths.status_code == 200, r_paths.text
        _, _, rel_paths = _read_zip_tree_from_build(r_paths.json())
        assert "Prefab_Characters/Actor_131_Infos.pkg.bytes" in rel_paths
        assert "Prefab_Characters/Actor_150_Infos.pkg.bytes" in rel_paths

        # (d) studio.html static checks (.check-row CSS & unique basename pwMap guard)
        html = _require_studio_html()
        assert ".check-row" in html and "nameCounts[x.name] === 1" in html

        # (e) Live Playwright verification of duplicate-basename .3105 merge in Edge UI
        if EDGE_EXE.exists() and importlib.util.find_spec("playwright") is not None:
            import uvicorn
            import urllib.request
            from playwright.sync_api import sync_playwright

            _patch_module_paths(app_mod, isolated_studio_env["data_dir"], isolated_studio_env["out_dir"], monkeypatch)
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind(("127.0.0.1", 0))
                port = s.getsockname()[1]
            server = uvicorn.Server(uvicorn.Config(app_mod.app, host="127.0.0.1", port=port, log_level="error"))
            th = threading.Thread(target=server.run, daemon=True)
            th.start()
            try:
                for _ in range(50):
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1) as resp:
                            if resp.status == 200:
                                break
                    except Exception:
                        time.sleep(0.1)

                with sync_playwright() as pw:
                    browser = pw.chromium.launch(executable_path=str(EDGE_EXE), headless=True, args=["--no-sandbox"])
                    page = browser.new_page()
                    page.goto(f"http://127.0.0.1:{port}/", wait_until="networkidle")
                    page.locator('[data-tab="merge"]').click()
                    page.set_input_files("#mergeFileInput", str(p1))
                    page.set_input_files("#mergeFileInput", str(p2))
                    pw_inputs = page.locator('#mergeQueueList input[type="password"]')
                    assert pw_inputs.count() == 2
                    pw_inputs.nth(0).fill("pwA")
                    pw_inputs.nth(1).fill("pwB")
                    with page.expect_response(lambda res: "/api/merge" in res.url and res.request.method == "POST") as resp_info:
                        page.locator("#runMergeBtn").click()
                    merge_resp = resp_info.value
                    assert merge_resp.status == 200, merge_resp.text()
                    browser.close()
            finally:
                server.should_exit = True
                th.join(timeout=5)

    def test_t5_unicode_vietnamese_zip_provider_and_download_headers(
        self, api_client, shared_provider: se.BaseResourceProvider, isolated_studio_env, tmp_path: Path
    ):
        client, _ = api_client
        extracted_src = _build_lightweight_extracted_resources(shared_provider, tmp_path / "src_uni_extract")
        uni_zip = tmp_path / "Thư Mục Tiếng Việt" / "Tài Nguyên Gốc 3.0.zip"
        uni_zip.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(uni_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for f in extracted_src.rglob("*"):
                if f.is_file():
                    zf.write(f, f.relative_to(extracted_src).as_posix())

        prov_uni = se.BaseResourceProvider(str(uni_zip))
        assert prov_uni.game_version == "1.64.1"
        assert prov_uni.has("version.txt")

        nested_outer_zip = tmp_path / "Outer_With_Nested_Resources.zip"
        with zipfile.ZipFile(nested_outer_zip, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.write(uni_zip, "Package/Resources.zip")
        prov_nested = se.BaseResourceProvider(str(nested_outer_zip))
        assert prov_nested.game_version == "1.64.1"
        assert prov_nested.read("version.txt") == shared_provider.read("version.txt")

        assert client.post("/api/config", json={"resources_path": str(RESOURCES_ZIP)}).status_code == 200
        rb = client.post(
            "/api/mod/build",
            json={"mode": "camera_only", "camera_percent": 15, "custom_filename": "Gói Mod Tiếng Việt 3.0"},
        )
        assert rb.status_code == 200, rb.text
        bdata = rb.json()
        out_path = Path(bdata["output_path"])
        rdl = client.get("/api/outputs/download", params={"path": bdata["filename"]})
        assert rdl.status_code == 200
        assert rdl.content == out_path.read_bytes()
        cd = rdl.headers.get("content-disposition", "")
        assert "filename*=utf-8''" in cd.lower(), f"Missing RFC 5987 UTF-8 header: {cd}"

    def test_t5_outputs_download_ads_crossdrive_subdir_and_null_rejection(self, api_client, isolated_studio_env):
        client, _ = api_client
        out_dir = isolated_studio_env["out_dir"]
        valid_file = out_dir / "valid.zip"
        valid_file.write_bytes(b"PK\x05\x06" + b"\x00" * 18)
        sub_dir = out_dir / "subdir"
        sub_dir.mkdir(parents=True, exist_ok=True)
        nested_file = sub_dir / "nested.zip"
        nested_file.write_bytes(b"PK\x05\x06" + b"\x00" * 18)

        assert client.get("/api/outputs/download", params={"path": "subdir"}).status_code == 404
        assert client.get("/api/outputs/download", params={"path": "missing.zip"}).status_code == 404
        assert client.get("/api/outputs/download", params={"path": "valid.zip::$DATA"}).status_code == 403
        assert client.get("/api/outputs/download", params={"path": r"Z:\evil.zip"}).status_code == 403
        assert client.get("/api/outputs/download", params={"path": "mod\x00.zip"}).status_code == 400

        r_sub = client.get("/api/outputs/download", params={"path": "subdir/nested.zip"})
        assert r_sub.status_code == 200
        assert r_sub.content == nested_file.read_bytes()

        r_abs = client.get("/api/outputs/download", params={"path": str(valid_file)})
        assert r_abs.status_code == 200
        assert r_abs.content == valid_file.read_bytes()

    def test_t5_unpack_pkg_zip_slip_rejection_engine_and_api(self, api_client, tmp_path: Path):
        client, _ = api_client
        for evil_entry in ("../../evil.txt", "C:/evil.txt", "/abs/evil.txt"):
            evil_pkg = cp.build_in_memory_store_zip([(evil_entry, 0x5800, 0x5B72, b"pwn")])
            dest_dir = tmp_path / "unpack_target"
            with pytest.raises(ValueError):
                se.BinaryInspector.unpack_pkg_to_dir(evil_pkg, str(dest_dir))
            assert not (tmp_path / "evil.txt").exists()

            r = client.post(
                "/api/inspector/pkg/unpack",
                json={
                    "content_b64": base64.b64encode(evil_pkg).decode("ascii"),
                    "filename": "evil.pkg.bytes",
                    "out_dir": str(dest_dir),
                },
            )
            assert r.status_code == 400, f"Expected 400 for zip-slip entry {evil_entry!r}, got {r.status_code}"

        # pack_dir_to_pkg skips OS junk files and __MACOSX
        src_dir = tmp_path / "pack_src"
        (src_dir / "__MACOSX").mkdir(parents=True, exist_ok=True)
        (src_dir / "good.txt").write_bytes(b"clean")
        for junk in (".DS_Store", "Thumbs.db", "desktop.ini", "._ghost", "__MACOSX/meta.bin"):
            (src_dir / junk).write_bytes(b"junk")
        packed = se.BinaryInspector.pack_dir_to_pkg(str(src_dir))
        entries = assert_pkg_stored_zero(packed, "clean_pack.pkg.bytes")
        assert list(entries.keys()) == ["good.txt"]

    def test_t5_3105_tampered_gcm_payload_and_corrupt_zip_errors(
        self, api_client, shared_provider: se.BaseResourceProvider, isolated_studio_env
    ):
        client, _ = api_client
        out_dir = isolated_studio_env["out_dir"]
        built = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "camera_only",
                "camera_percent": 15,
                "output_format": "3105",
                "password": "StrongPassword3105!",
                "output_dir": str(out_dir),
            },
        )
        raw_3105 = bytearray(Path(built["output_path"]).read_bytes())
        raw_3105[-20] ^= 0xFF
        tampered = bytes(raw_3105)
        tampered_path = out_dir / "tampered.3105"
        tampered_path.write_bytes(tampered)

        with pytest.raises((ValueError, cp.PatchPackageDecodeError)):
            se.OfflineMergerAndConverter.convert_package(
                tampered, "tampered.3105", target_format="zip", password="StrongPassword3105!", output_dir=str(out_dir)
            )
        valid_zip = se.SkinModBuilder.build_mod(
            shared_provider,
            {"mode": "camera_only", "camera_percent": 10, "output_format": "zip", "output_dir": str(out_dir)},
        )
        with pytest.raises((ValueError, cp.PatchPackageDecodeError)):
            se.OfflineMergerAndConverter.merge_mods(
                [str(tampered_path), valid_zip["output_path"]],
                output_dir=str(out_dir),
                password="StrongPassword3105!",
            )

        r_tampered = client.post(
            "/api/convert",
            files={"file": ("tampered.3105", tampered, "application/octet-stream")},
            data={"target_format": "zip", "password": "StrongPassword3105!"},
        )
        assert r_tampered.status_code == 400

        # Auto-detect target_format="zip" when omitted on valid .3105 input
        r_auto = client.post(
            "/api/convert",
            files={"file": (built["filename"], Path(built["output_path"]).read_bytes(), "application/octet-stream")},
            data={"password": "StrongPassword3105!"},
        )
        assert r_auto.status_code == 200, r_auto.text
        assert r_auto.json()["filename"].endswith(".zip")

        # Invalid target_format or corrupt zip returns 400
        r_bad_fmt = client.post(
            "/api/convert",
            files={"file": (built["filename"], Path(built["output_path"]).read_bytes(), "application/octet-stream")},
            data={"target_format": "rar", "password": "StrongPassword3105!"},
        )
        assert r_bad_fmt.status_code == 400

        r_bad_zip = client.post(
            "/api/convert",
            files={"file": ("broken.zip", b"not-a-zip-payload", "application/zip")},
            data={"target_format": "3105"},
        )
        assert r_bad_zip.status_code == 400

    def test_t5_inspector_error_responses_and_no_raw_bytes_leak(
        self, api_client, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        client, _ = api_client
        assert client.post("/api/inspector/inspect", content=b"{bad", headers={"Content-Type": "application/json"}).status_code == 400
        assert client.post("/api/inspector/inspect", content=b"[]", headers={"Content-Type": "application/json"}).status_code == 400
        assert client.post("/api/inspector/inspect", json={}).status_code == 400
        assert client.post("/api/inspector/inspect", json={"content_b64": "!@#$", "filename": "x.bin"}).status_code == 400
        assert client.post("/api/inspector/inspect", json={"path": str(tmp_path / "nope.bytes")}).status_code == 404

        raw_bill = shared_provider.read("Databin/Client/Huanhua/ResBillboardSkinCfg.bytes")
        aes_a1 = se.BinaryInspector.encrypt_0x224a(b"<Project><Action>Test</Action></Project>", "A1")
        r_wrong_stem = client.post(
            "/api/inspector/crypto/0x224a",
            json={"content_b64": base64.b64encode(aes_a1).decode("ascii"), "action": "decrypt", "stem": "WrongStem"},
        )
        assert r_wrong_stem.status_code == 400

        r_bad_act = client.post(
            "/api/inspector/crypto/0x224a",
            json={"content_b64": base64.b64encode(raw_bill).decode("ascii"), "action": "hash", "stem": "ResBillboardSkinCfg"},
        )
        assert r_bad_act.status_code == 400

        r_dec = client.post(
            "/api/inspector/crypto/0x224a",
            json={"content_b64": base64.b64encode(raw_bill).decode("ascii"), "action": "decrypt", "stem": "ResBillboardSkinCfg"},
        )
        assert r_dec.status_code == 200
        assert "decrypted_bytes" not in r_dec.json()

        act_pkg = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/Actor_131_Actions.pkg.bytes")
        r_missing_entry = client.post(
            "/api/inspector/pkg/entry",
            json={"content_b64": base64.b64encode(act_pkg).decode("ascii"), "entry_name": "does/not/exist.xml"},
        )
        assert r_missing_entry.status_code == 404

        r_missing_dir = client.post("/api/inspector/pkg/pack", json={"src_dir": str(tmp_path / "missing_dir")})
        assert r_missing_dir.status_code == 404

        r_corrupt_zip = client.post(
            "/api/inspector/inspect",
            json={"content_b64": base64.b64encode(b"PK\x03\x04corrupt").decode("ascii"), "filename": "bad.pkg.bytes"},
        )
        assert r_corrupt_zip.status_code == 200
        assert r_corrupt_zip.json().get("zip_error")

        r_corrupt_224a = client.post(
            "/api/inspector/inspect",
            json={"content_b64": base64.b64encode(b"\x22\x4a\x67\x00\x10\x00\x00\x00bad").decode("ascii"), "filename": "bad.bytes"},
        )
        assert r_corrupt_224a.status_code == 200
        assert r_corrupt_224a.json().get("decrypt_error")

    def test_t5_mses_partial_string_edits_and_xml_track_delete(
        self, api_client, shared_provider: se.BaseResourceProvider, tmp_path: Path
    ):
        client, _ = api_client
        raw_btn = shared_provider.read("Databin/Client/Huanhua/ResPersonalButtonCfg.bytes")
        tbl = cp.parse_mses(cp.pg_decrypt(raw_btn, "ResPersonalButtonCfg"))
        rid0, rec0 = tbl["recs"][0]
        old_slen = struct.unpack_from("<I", rec0, 12)[0]
        old_str = rec0[16 : 16 + old_slen - 1].decode("utf-8")

        base_file = tmp_path / "ResPersonalButtonCfg.bytes"
        base_file.write_bytes(raw_btn)

        # Offset string_edit via base_path
        spec_offset = {"records": [{"rid": rid0, "string_edits": [{"offset": 12, "text": "Nút Bấm Totorox"}]}]}
        r_rep1 = client.post(
            "/api/inspector/repack",
            json={
                "kind": "mses_table",
                "content_text": json.dumps(spec_offset),
                "stem": "ResPersonalButtonCfg",
                "encrypt_224a": True,
                "base_path": str(base_file),
            },
        )
        assert r_rep1.status_code == 200, r_rep1.text
        out1 = base64.b64decode(r_rep1.json()["content_b64"])
        tbl1 = verify_mses_table(out1, "ResPersonalButtonCfg")
        rec1_out = dict(tbl1["recs"])[rid0]
        assert "Nút Bấm Totorox".encode("utf-8") in rec1_out

        # old/new string_edit via multipart base_file
        spec_old_new = {"records": [{"rid": rid0, "string_edits": [{"old": old_str, "new": "Nút Mới 3.0"}]}]}
        r_rep2 = client.post(
            "/api/inspector/repack",
            files={"base_file": ("ResPersonalButtonCfg.bytes", raw_btn, "application/octet-stream")},
            data={
                "kind": "mses_table",
                "content_text": json.dumps(spec_old_new),
                "stem": "ResPersonalButtonCfg",
                "encrypt_224a": "true",
            },
        )
        assert r_rep2.status_code == 200, r_rep2.text
        out2 = base64.b64decode(r_rep2.json()["content_b64"])
        tbl2 = verify_mses_table(out2, "ResPersonalButtonCfg")
        assert "Nút Mới 3.0".encode("utf-8") in dict(tbl2["recs"])[rid0]

        # XML track delete + dict-keyed updates + CommonActions plain XML preservation
        ca_pkg = shared_provider.read("Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes")
        back_info = se.BinaryInspector.read_pkg_entry(ca_pkg, "commonresource/Back.xml", full_text=True)
        orig_tracks = se.BinaryInspector.parse_xml_tracks(back_info["text_content"])
        r_del = client.post(
            "/api/inspector/xml/tracks",
            json={"action": "update", "xml_text": back_info["text_content"], "updates": {"0": {"delete": True}}},
        )
        assert r_del.status_code == 200, r_del.text
        assert r_del.json()["track_count"] == len(orig_tracks) - 1

        upd_ca = se.BinaryInspector.update_pkg_entry(
            ca_pkg,
            "commonresource/Back.xml",
            r_del.json()["xml_text"],
            encrypt_224a=False,
        )
        ca_entries = assert_pkg_stored_zero(upd_ca, "CommonActions.pkg.bytes")
        assert ca_entries["commonresource/Back.xml"][:2] != b"\x22\x4A"
        assert b"<Project" in ca_entries["commonresource/Back.xml"]

    def test_t5_dialog_tcl_filelist_and_system_error_paths(
        self, api_client, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ):
        client, app_mod = api_client
        parsed = app_mod._split_tcl_filelist(r'{C:\Thư Mục Có Dấu\a b.zip} C:\nospace.zip')
        assert parsed == [r"C:\Thư Mục Có Dấu\a b.zip", r"C:\nospace.zip"]

        assert 1 <= app_mod.pick_free_port(-1) <= 65535
        assert 1 <= app_mod.pick_free_port(70000) <= 65535

        import tkinter
        import tkinter.filedialog as fd

        class DummyTkNoTcl:
            def withdraw(self): pass
            def attributes(self, *a, **kw): pass
            def lift(self): pass
            def destroy(self): pass

        class DummyTkWithTcl(DummyTkNoTcl):
            class _Tk:
                @staticmethod
                def splitlist(raw):
                    return [r"C:\a b.zip", r"C:\c.zip"]
            tk = _Tk()

        monkeypatch.setattr(fd, "askopenfilenames", lambda **kw: r'{C:\a b.zip} C:\c.zip')
        monkeypatch.setattr(fd, "askdirectory", lambda **kw: str(tmp_path))
        monkeypatch.setattr(fd, "asksaveasfilename", lambda **kw: str(tmp_path / "out.zip"))

        monkeypatch.setattr(tkinter, "Tk", DummyTkNoTcl)
        r_files1 = client.post("/api/dialog/browse", json={"mode": "files"})
        assert r_files1.status_code == 200
        assert r_files1.json()["paths"] == [r"C:\a b.zip", r"C:\c.zip"]

        monkeypatch.setattr(tkinter, "Tk", DummyTkWithTcl)
        r_files2 = client.post("/api/dialog/browse", json={"mode": "files"})
        assert r_files2.status_code == 200
        assert r_files2.json()["paths"] == [r"C:\a b.zip", r"C:\c.zip"]

        assert client.post("/api/dialog/browse", json={"mode": "dir"}).json()["path"] == str(tmp_path)
        assert client.post("/api/dialog/browse", json={"mode": "save"}).json()["path"] == str(tmp_path / "out.zip")
        assert client.post("/api/dialog/browse", json={"mode": "bad"}).status_code == 400

        assert client.post("/api/config", json={"theme": "neon"}).status_code == 400
        assert client.post("/api/system/open-explorer", json={"path": ""}).status_code == 400

        existing_f = tmp_path / "exists.zip"
        existing_f.write_bytes(b"x")

        def fail_popen(*a, **kw):
            raise OSError("explorer blocked")

        monkeypatch.setattr(app_mod.subprocess, "Popen", fail_popen)
        assert client.post("/api/system/open-explorer", json={"path": str(existing_f)}).status_code == 500

        incomplete_zip = cp.build_in_memory_store_zip([("dummy.txt", 0x5800, 0x5B72, b"123")])
        r_seed = client.post(
            "/api/bypass-seed/import",
            files={"file": ("incomplete.zip", incomplete_zip, "application/zip")},
        )
        assert r_seed.status_code == 400

    def test_t5_jtcom_binary_hex_attr_and_camera_only_missing_assets(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ):
        node = {
            "name": "RootNode",
            "attrs": [("BinAttr", b"\xff\xfe\x00\x81"), ("StrAttr", b"ok")],
            "content": b"\xde\xad\xbe\xef",
            "children": [],
        }
        j = jtcom.jt_to_jsonable(node)
        assert any(a.get("hex") == "fffe0081" for a in j["attrs"])
        rt = jtcom.jsonable_to_jt(j)
        assert jtcom.serialize_jt(rt) == jtcom.serialize_jt(node)

        _, actorinfo_plain = _extract_actorinfo_plain(
            {
                "Prefab_Characters/Actor_131_Infos.pkg.bytes": shared_provider.read(
                    "Prefab_Characters/Actor_131_Infos.pkg.bytes"
                )
            },
            131,
        )
        promoted_single = jtcom.promote_skin_in_actorinfo(
            actorinfo_plain, hero_id=131, source_skin_id=13118, is_hd_skin=True, apply_to_all_skins=False
        )
        orig_root, _ = jtcom.parse_jt(actorinfo_plain, 0)
        new_root, _ = jtcom.parse_jt(promoted_single, 0)
        orig_sp = next(c for c in orig_root["children"] if c["name"] == "SkinPrefab")["children"]
        new_sp = next(c for c in new_root["children"] if c["name"] == "SkinPrefab")["children"]
        assert jtcom.serialize_jt(orig_sp[0]) == jtcom.serialize_jt(new_sp[0])

        assert (
            jtcom.rewrite_hero_effect_path("prefab_skill_effects/hero_skill_effects/131_libai/13112/LiBai_Cutin", 131, 13118, True)
            == "prefab_skill_effects/hero_skill_effects/131_libai/13118/LiBai_Cutin_HD"
        )
        assert (
            jtcom.rewrite_hero_effect_path("prefab_skill_effects/hero_skill_effects/13118_Foo.prefab", 131, 13118, True)
            == "prefab_skill_effects/hero_skill_effects/13118_Foo_HD"
        )

        # camera_only raises ValueError when CommonActions.pkg.bytes or junglemark.xml is missing
        no_ca_dir = tmp_path / "no_ca"
        (no_ca_dir / "Resources" / "1.64.1").mkdir(parents=True, exist_ok=True)
        (no_ca_dir / "Resources" / "1.64.1" / "version.txt").write_text("1.64.1.12|1793129", encoding="utf-8")
        with pytest.raises(ValueError):
            se.SkinModBuilder.build_mod(
                se.BaseResourceProvider(str(no_ca_dir)),
                {"mode": "camera_only", "camera_percent": 15, "output_dir": str(isolated_studio_env["out_dir"])},
            )

        no_jm_dir = tmp_path / "no_jm"
        ca_dest = no_jm_dir / "Resources" / "1.64.1" / "Ages" / "Prefab_Characters" / "Prefab_Hero"
        ca_dest.mkdir(parents=True, exist_ok=True)
        (no_jm_dir / "Resources" / "1.64.1" / "version.txt").write_text("1.64.1.12|1793129", encoding="utf-8")
        (ca_dest / "CommonActions.pkg.bytes").write_bytes(
            cp.build_in_memory_store_zip([("commonresource/Dummy.xml", 0x5800, 0x5B72, b"<Project/>")])
        )
        with pytest.raises(ValueError):
            se.SkinModBuilder.build_mod(
                se.BaseResourceProvider(str(no_jm_dir)),
                {"mode": "camera_only", "camera_percent": 15, "output_dir": str(isolated_studio_env["out_dir"])},
            )

        # merge_mods synthesizes languageMap.txt watermark even when auto-detected Resources Gốc.zip is absent
        monkeypatch.setattr(se, "_auto_detect_base_resources", lambda: "")
        z1 = cp.build_in_memory_store_zip([("Resources/1.64.1/version.txt", 0x5800, 0x5B72, b"1.64.1.12|1793129")])
        z2 = cp.build_in_memory_store_zip([("Resources/1.64.1/Dummy/test.bytes", 0x5800, 0x5B72, b"hello")])
        merged = se.OfflineMergerAndConverter.merge_mods(
            [("m1.zip", z1), ("m2.zip", z2)],
            output_dir=str(isolated_studio_env["out_dir"]),
            watermark_text="Synth Watermark 3.0",
        )
        _, _, rel_m = _read_zip_tree_from_build(merged)
        assert "Tip_WaterMark_Str = Synth Watermark 3.0" in rel_m["Languages/VN_Garena_VN/languageMap.txt"].decode("utf-8")

    def test_t5_local_mock_zip_validation_no_prefab_rpack_show_and_rescan(
        self, shared_provider: se.BaseResourceProvider, api_client, isolated_studio_env, tmp_path: Path
    ):
        # 1) JTCom: giữ nguyên ArtLobbyShowLOD không tự ép `.prefab` và raise RuntimeError nếu thiếu/NULL
        def _lod_node(name: str, values: list[str | None]) -> dict[str, Any]:
            ch = []
            for v in values:
                if v is None:
                    ch.append({"name": name, "attrs": [("JT", b"Pri"), ("Type", b"System.String"), ("NULL", b"Y")], "content": b"", "children": []})
                else:
                    ch.append({"name": name, "attrs": [("JT", b"Pri"), ("Type", b"System.String"), ("V", v.encode("utf-8"))], "content": b"", "children": []})
            return {"name": name, "attrs": [("JT", b"Com")], "content": b"", "children": ch}

        elem_ok = {
            "name": "SkinPrefab",
            "attrs": [("JT", b"Com")],
            "content": b"",
            "children": [
                _lod_node("ArtSkinPrefabLOD", ["Prefab_Characters/Prefab_Hero/130_GongBenWuZang/1302_Battle1", None, None]),
                _lod_node("ArtSkinLobbyShowLOD", ["Prefab_Characters/Prefab_Hero/130_GongBenWuZang/1302_Show1", None, None]),
            ],
        }
        actor_ok = jtcom.serialize_jt({
            "name": "CActorInfo",
            "attrs": [],
            "content": b"",
            "children": [{"name": "SkinPrefab", "attrs": [("JT", b"Com")], "content": b"", "children": [elem_ok]}],
        })
        promoted = jtcom.promote_skin_in_actorinfo(actor_ok, hero_id=130, source_skin_id=13001, is_hd_skin=False)
        proot, _ = jtcom.parse_jt(promoted, 0)
        lobby_node = next(c for c in proot["children"] if c["name"] == "ArtLobbyShowLOD")
        lobby_vals = [(jtcom.get_jt_attr(ch, "V") or b"").decode("utf-8") for ch in lobby_node["children"]]
        assert lobby_vals == ["Prefab_Characters/Prefab_Hero/130_GongBenWuZang/1302_Show1"] * 3
        assert not any(v.lower().endswith(".prefab") for v in lobby_vals)

        elem_null_lobby = {
            "name": "SkinPrefab",
            "attrs": [("JT", b"Com")],
            "content": b"",
            "children": [
                _lod_node("ArtSkinPrefabLOD", ["Prefab_Characters/Prefab_Hero/130_GongBenWuZang/1302_Battle1", None]),
                _lod_node("ArtSkinLobbyShowLOD", [None, None]),
            ],
        }
        actor_bad = jtcom.serialize_jt({
            "name": "CActorInfo",
            "attrs": [],
            "content": b"",
            "children": [{"name": "SkinPrefab", "attrs": [("JT", b"Com")], "content": b"", "children": [elem_null_lobby]}],
        })
        with pytest.raises(RuntimeError):
            jtcom.promote_skin_in_actorinfo(actor_bad, hero_id=130, source_skin_id=13001, is_hd_skin=False)

        # Kiểm tra thực tế Airi 13015 & Nakroth 15015 trong Resources gốc giữ Show model không `.prefab`
        for hid_chk, sid_chk in ((130, 13015), (150, 15015)):
            _, ai_plain = _extract_actorinfo_plain(
                {f"Prefab_Characters/Actor_{hid_chk}_Infos.pkg.bytes": shared_provider.read(f"Prefab_Characters/Actor_{hid_chk}_Infos.pkg.bytes")},
                hid_chk,
            )
            ai_out = jtcom.promote_skin_in_actorinfo(ai_plain, hero_id=hid_chk, source_skin_id=sid_chk, is_hd_skin=False)
            r_chk, _ = jtcom.parse_jt(ai_out, 0)
            l_node = next(c for c in r_chk["children"] if c["name"] == "ArtLobbyShowLOD")
            l_path = jtcom._first_valid_lod_path(l_node)
            assert l_path and not l_path.lower().endswith(".prefab")

        # 2) Thiếu RPack / version.txt / Thanos trong Resources -> raise RuntimeError trước khi xuất mod hỏng
        min_root = _build_lightweight_extracted_resources(shared_provider, tmp_path / "min_res")
        ver_dir = min_root / "Resources" / shared_provider.game_version
        rp_file = ver_dir / "assetbundle" / "resourcepackerinfosetall.assetbundle"
        rp_bak = rp_file.read_bytes()
        rp_file.unlink()
        with pytest.raises(RuntimeError):
            se.SkinModBuilder.build_mod(
                se.BaseResourceProvider(str(min_root)),
                {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(isolated_studio_env["out_dir"])},
            )
        rp_file.write_bytes(rp_bak)

        vt_file = ver_dir / "version.txt"
        vt_bak = vt_file.read_bytes()
        vt_file.unlink()
        with pytest.raises(RuntimeError):
            se.SkinModBuilder.build_mod(
                se.BaseResourceProvider(str(min_root)),
                {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(isolated_studio_env["out_dir"])},
            )
        vt_file.write_bytes(vt_bak)

        # 3) Bypass Seed Kiana lệch bản build (1.64.1.12 vs 1.64.1.13) -> chặn bằng RuntimeError
        se.import_bypass_seed_from_mod_zip(_build_mock_kiana_seed_zip("1.64.1.12|1793129"))
        with pytest.raises(RuntimeError):
            se.SkinModBuilder.build_mod(
                shared_provider,
                {"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "output_dir": str(isolated_studio_env["out_dir"])},
            )
        # Xóa custom seed lệch để test tiếp chế độ lua_only mặc định
        Path(se.CUSTOM_BYPASS_SEED_PATH).unlink(missing_ok=True)

        # 4) _patch_rpack_for_hero_battle_skins đánh dấu cả show/skin/ và merge_mods bảo toàn RPack < 5MB + nâng Thanos cũ
        rp_130 = se._patch_rpack_for_hero_battle_skins(rp_bak, 130)
        parsed_130 = verify_rpack_unityfs(rp_130, hero_id=130)
        show_marked = 0
        u_130 = cp.unpack_unityfs(rp_130)
        for rp_p, (_, hs, he) in parsed_130["recs"].items():
            if rp_p.lower().startswith("assetbundle/show/skin/130") and he > hs:
                if b"KianaMod" in u_130["payload"][hs:he]:
                    show_marked += 1
        assert show_marked > 0, "Expected show/skin/130* empty DLC entries to receive KianaMod mark"

        se.save_studio_config({"resources_path": str(RESOURCES_ZIP), "default_watermark": "Test", "theme": "dark"})
        vseg = shared_provider.game_version
        mock_mod_a = cp.build_in_memory_store_zip([
            (f"Resources/{vseg}/version.txt", 0x5800, 0x5B72, b"1.64.1.12|1793129"),
            (f"Resources/{vseg}/Thanos/HeroSkin_1.bytes", 0x5800, 0x5B72, b"OLD_44KB" * 5000),
            (f"Resources/{vseg}/assetbundle/resourcepackerinfosetall.assetbundle", 0x5800, 0x5B72, rp_130),
        ])
        mock_mod_b = cp.build_in_memory_store_zip([
            (f"Resources/{vseg}/version.txt", 0x5800, 0x5B72, vt_bak),
            (f"Resources/{vseg}/Dummy/extra_150.bytes", 0x5800, 0x5B72, b"ok"),
        ])
        merged_res = se.OfflineMergerAndConverter.merge_mods(
            [("modA.zip", mock_mod_a), ("modB.zip", mock_mod_b)],
            output_dir=str(isolated_studio_env["out_dir"]),
        )
        _, _, rel_merged = _read_zip_tree_from_build(merged_res)
        assert "assetbundle/resourcepackerinfosetall.assetbundle" in rel_merged
        assert len(rel_merged["assetbundle/resourcepackerinfosetall.assetbundle"]) < 5_000_000
        assert rel_merged["version.txt"] == vt_bak
        assert rel_merged["Thanos/HeroSkin_1.bytes"] == shared_provider.read("Thanos/HeroSkin_1.bytes")

        # 5) Local scan_local_resources chọn bản mới nhất & API /api/resources/rescan + studio.html
        mock_game_dir = tmp_path / "local_game"
        mock_game_dir.mkdir(parents=True, exist_ok=True)
        z_old = mock_game_dir / "Resources 01_11.zip"
        z_new = mock_game_dir / "Resources 25_11.zip"
        with zipfile.ZipFile(z_old, "w") as zf:
            zf.writestr("Resources/1.64.1/version.txt", b"1.64.1.12|1793129")
        with zipfile.ZipFile(z_new, "w") as zf:
            for root_f, _, files_f in os.walk(min_root):
                for fn in files_f:
                    if fn.lower() == "version.txt":
                        continue
                    fp = os.path.join(root_f, fn)
                    arc = os.path.relpath(fp, min_root).replace("\\", "/")
                    zf.write(fp, arc)
            zf.writestr(f"Resources/{vseg}/version.txt", b"1.64.1.14|1809999")

        scan_out = se.scan_local_resources(str(mock_game_dir), update_config=True)
        assert Path(scan_out["resources_path"]) == z_new
        assert scan_out["version_txt"] == "1.64.1.14|1809999"

        # Import Lua-only sample mod zip với URL quảng cáo giả -> phải chọn seed_mode='lua_only' và khử sạch URL
        dirty_lua_only_buf = io.BytesIO()
        base_seed_cur = se.load_bypass_seed()
        with zipfile.ZipFile(dirty_lua_only_buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr(f"Resources/{vseg}/version.txt", vt_bak)
            dirty_kl = cp.build_in_memory_store_zip([
                ("Lua_Signed/Init_lua.bytes", 0, 0x21, b"\x1bLuaR_0x432312_" + cp._KIANA_AD_GLOBAL_MARKER + b"https://raw.githubusercontent.com/ad.txt")
            ])
            zf.writestr(f"Resources/{vseg}/KernelLua.pkg.bytes", dirty_kl)
            zf.writestr(f"Resources/{vseg}/StableSystems_3.pkg.bytes", base_seed_cur["StableSystems_3.pkg.bytes"])
        lua_meta = se.import_bypass_seed_from_mod_zip(dirty_lua_only_buf.getvalue())
        assert lua_meta["seed_mode"] == "lua_only"
        loaded_lua_seed = se.load_bypass_seed()
        assert loaded_lua_seed["seed_mode"] == "lua_only"
        assert cp._KIANA_AD_GLOBAL_MARKER not in loaded_lua_seed["KernelLua.pkg.bytes"]
        assert b"raw.githubusercontent.com" not in loaded_lua_seed["KernelLua.pkg.bytes"]
        Path(se.CUSTOM_BYPASS_SEED_PATH).unlink(missing_ok=True)

        client, _ = api_client
        # RuntimeError từ thiếu tài nguyên -> API /api/mod/build trả HTTP 400 thông báo Tiếng Việt ngắn gọn
        rp_file.unlink()
        r_bad_build = client.post(
            "/api/mod/build",
            json={"mode": "skin", "hero_id": 131, "target_skin_id": 13118, "resources_path": str(min_root)},
        )
        assert r_bad_build.status_code == 400
        assert "resourcepackerinfosetall" in r_bad_build.json()["detail"].lower()
        rp_file.write_bytes(rp_bak)
        empty_game = tmp_path / "empty_game"
        empty_game.mkdir(parents=True, exist_ok=True)
        assert client.post("/api/resources/rescan", json={"game_dir": str(empty_game)}).status_code == 404

        r_rescan = client.post("/api/resources/rescan", json={"game_dir": str(mock_game_dir)})
        assert r_rescan.status_code == 200
        j_rescan = r_rescan.json()
        assert Path(j_rescan["resources_path"]) == z_new
        assert j_rescan["seed_status"]["seed_mode"] == "vanhoc"
        assert "catalog" in j_rescan and j_rescan["catalog"]["hero_count"] > 0

        r_health = client.get("/api/health")
        assert r_health.status_code == 200 and "seed_status" in r_health.json()
        r_cat = client.get("/api/catalog")
        assert r_cat.status_code == 200 and "seed_status" in r_cat.json()

        html_src = _require_studio_html()
        assert "Quét lại Resources" in html_src
        assert "/api/resources/rescan" in html_src
        assert "seedWarnBanner" in html_src

    def test_t5_selective_skin_replace_and_batch_build(
        self, shared_provider: se.BaseResourceProvider, shared_catalog: dict[str, Any], api_client, isolated_studio_env
    ):
        out_dir = isolated_studio_env["out_dir"]

        # 0) Kiểm tra phân loại tier_label / tier_rank trong CatalogIndexer
        h131 = next(h for h in shared_catalog["heroes"] if h["hero_id"] == 131)
        s13100 = next(s for s in h131["skins"] if s["skin_id"] == 13100)
        s13101 = next(s for s in h131["skins"] if s["skin_id"] == 13101)
        s13118 = next(s for s in h131["skins"] if s["skin_id"] == 13118)
        assert s13100["tier_label"] == "Mặc định" and s13100["tier_rank"] == 0
        assert s13101["tier_label"] == "Bậc A" and s13101["tier_rank"] == 1
        assert s13118["tier_rank"] >= 4

        # 1) Đè chọn lọc 13101 -> 13118 (giữ nguyên 13100 Mặc định, 13102, phụ kiện 13104)
        _, orig_ai_plain = _extract_actorinfo_plain(
            {"Prefab_Characters/Actor_131_Infos.pkg.bytes": shared_provider.read("Prefab_Characters/Actor_131_Infos.pkg.bytes")},
            131,
        )
        orig_ai_root, _ = jtcom.parse_jt(orig_ai_plain, 0)
        orig_root_lod = jtcom._first_valid_lod_path(next(c for c in orig_ai_root["children"] if c["name"] == "ArtPrefabLOD"))
        orig_sp = next(c for c in orig_ai_root["children"] if c["name"] == "SkinPrefab")["children"]
        orig_13102_lod = jtcom._first_valid_lod_path(
            next(f for f in orig_sp[1]["children"] if f["name"] == "ArtSkinPrefabLOD")
        )
        orig_13118_lod = jtcom._first_valid_lod_path(
            next(f for f in orig_sp[17]["children"] if f["name"] == "ArtSkinPrefabLOD")
        )

        orig_hs_recs = dict(
            cp.parse_mses(cp.pg_decrypt(shared_provider.read("Databin/Client/Actor/heroSkin.bytes"), "heroSkin"))["recs"]
        )

        res_sel = se.SkinModBuilder.build_mod(
            shared_provider,
            {
                "mode": "skin",
                "hero_id": 131,
                "source_skin_id": 13118,
                "replace_skin_ids": [13101],
                "output_dir": str(out_dir),
            },
        )
        assert res_sel["summary"]["is_selective_replace"] is True
        assert res_sel["summary"]["apply_to_all_skins"] is False
        assert res_sel["summary"]["replace_skin_ids"] == [13101]
        _, _, rel_sel = _read_zip_tree_from_build(res_sel)

        # ActorInfo: root (13100) & SkinPrefab[1] (13102) giữ nguyên; SkinPrefab[0] (13101) thành 13118
        _, new_ai_plain = _extract_actorinfo_plain(rel_sel, 131)
        new_ai_root, _ = jtcom.parse_jt(new_ai_plain, 0)
        assert jtcom._first_valid_lod_path(next(c for c in new_ai_root["children"] if c["name"] == "ArtPrefabLOD")) == orig_root_lod
        new_sp = next(c for c in new_ai_root["children"] if c["name"] == "SkinPrefab")["children"]
        assert jtcom._first_valid_lod_path(next(f for f in new_sp[0]["children"] if f["name"] == "ArtSkinPrefabLOD")) == orig_13118_lod
        assert jtcom._first_valid_lod_path(next(f for f in new_sp[1]["children"] if f["name"] == "ArtSkinPrefabLOD")) == orig_13102_lod
        lobby_13101 = jtcom._first_valid_lod_path(next(f for f in new_sp[0]["children"] if f["name"] == "ArtSkinLobbyShowLOD"))
        assert lobby_13101 and not lobby_13101.lower().endswith(".prefab")

        # heroSkin.bytes: 13101 đổi splash 3013118, 13100 & 13102 giữ nguyên bản gốc
        new_hs_recs = dict(verify_mses_table(rel_sel["Databin/Client/Actor/heroSkin.bytes"], "heroSkin")["recs"])
        assert b"3013118" in new_hs_recs[13101]
        assert new_hs_recs[13100] == orig_hs_recs[13100]
        assert new_hs_recs[13102] == orig_hs_recs[13102]

        # ResCharacterComponent: phụ kiện 13104 (không bị đè) KHÔNG bị xóa
        comp_tbl = verify_mses_table(rel_sel["Databin/Client/Character/ResCharacterComponent.bytes"], "ResCharacterComponent")
        assert any(int(r) // 100 == 13104 for r, _ in comp_tbl["recs"])

        # ResSkinSeniorLabelCfg: 13101 có nhãn HD
        sen_recs = dict(verify_mses_table(rel_sel["Databin/Client/Actor/ResSkinSeniorLabelCfg.bytes"], "ResSkinSeniorLabelCfg")["recs"])
        assert 13101 in sen_recs

        # Actor_131_Actions S1.xml: CheckSkinId cho 13118 chứa thêm 13101; PlayHeroSound tách nhánh flt=11 & flt=9(13101)
        act_entries = assert_pkg_stored_zero(rel_sel["Ages/Prefab_Characters/Prefab_Hero/Actor_131_Actions.pkg.bytes"], "Actor_131_Actions")
        s1_raw = next(d for k, d in act_entries.items() if k.lower().endswith("/s1.xml"))
        s1_xml = cp.pg_decrypt(s1_raw, "S1").decode("utf-8", errors="ignore")
        s1_tracks = cp.split_xml_tracks(s1_xml)[1]
        chk_13118 = [t for t in s1_tracks if "CheckSkinId" in (t.get("eventType") or "") and "13118" in t["raw"]]
        assert chk_13118 and any("13101" in (t.get("skinArrayIds") or []) for t in chk_13118)
        snd_clones = [t for t in s1_tracks if t.get("eventType") == "PlayHeroSoundTick" and t.get("filterType") == "9" and "13101" in (t.get("skins") or [])]
        assert snd_clones and all("_Skin18" in t["raw"] for t in snd_clones)

        # Back.xml: vòng xanh mặc định chỉ ẩn thêm 13101, và có track Totorox_BackLoop_13118 với SkinOrAvatarList 13101
        back_xml = _extract_common_xml(rel_sel, "commonresource/Back.xml")
        back_tracks = cp.split_xml_tracks(back_xml)[1]
        back_loops = [t for t in back_tracks if "Totorox_BackLoop_13118" in t["raw"]]
        assert back_loops and "13101" in (back_loops[0].get("skins") or [])

        # HeroSound.bytes: giữ 13100, 13102 gốc + thêm dòng nhân bản gắn skin_id=13101
        hsnd_tbl = verify_mses_table(rel_sel["Databin/Client/Sound/HeroSound.bytes"], "HeroSound")
        hsnd_vals_131 = []
        for _, rr in hsnd_tbl["recs"]:
            if len(rr) >= 17:
                sl = struct.unpack_from("<I", rr, 8)[0]
                if 1 <= sl <= len(rr) - 16 and rr[12 + sl - 1] == 0:
                    v = struct.unpack_from("<I", rr, 12 + sl)[0]
                    if 13100 <= v < 13200:
                        hsnd_vals_131.append(v)
        assert 13100 in hsnd_vals_131 and 13102 in hsnd_vals_131 and 13101 in hsnd_vals_131

        # 2) Nhiều cặp khác nguồn trong CÙNG 1 tướng + Mod Hàng Loạt đa tướng gộp 1 gói (merge_output=True)
        res_batch = se.SkinModBuilder.build_batch_mods(
            shared_provider,
            {
                "items": [
                    {"hero_id": 131, "source_skin_id": 13118, "replace_skin_ids": [13101]},
                    {"hero_id": 131, "source_skin_id": 13115, "replace_skin_ids": [13102]},
                    {"hero_id": 150, "source_skin_id": 15015, "replace_skin_ids": [15001]},
                ],
                "merge_output": True,
                "custom_filename": "Batch_Murad_Nakroth_MultiMap",
                "output_dir": str(out_dir),
            },
        )
        assert res_batch["ok"] is True and res_batch["hero_count"] == 2 and res_batch["item_count"] == 3
        _, _, rel_batch = _read_zip_tree_from_build(res_batch)
        _, b_ai_131 = _extract_actorinfo_plain(rel_batch, 131)
        b_sp_131 = next(c for c in jtcom.parse_jt(b_ai_131, 0)[0]["children"] if c["name"] == "SkinPrefab")["children"]
        assert jtcom._first_valid_lod_path(next(f for f in b_sp_131[0]["children"] if f["name"] == "ArtSkinPrefabLOD")) == orig_13118_lod
        orig_13115_lod = jtcom._first_valid_lod_path(next(f for f in orig_sp[14]["children"] if f["name"] == "ArtSkinPrefabLOD"))
        assert jtcom._first_valid_lod_path(next(f for f in b_sp_131[1]["children"] if f["name"] == "ArtSkinPrefabLOD")) == orig_13115_lod

        batch_hs = dict(verify_mses_table(rel_batch["Databin/Client/Actor/heroSkin.bytes"], "heroSkin")["recs"])
        assert b"3013118" in batch_hs[13101]
        assert b"3013115" in batch_hs[13102]
        assert b"3015015" in batch_hs[15001]
        assert batch_hs[13100] == orig_hs_recs[13100]
        assert batch_hs[15000] == orig_hs_recs[15000]
        verify_rpack_unityfs(rel_batch["assetbundle/resourcepackerinfosetall.assetbundle"], hero_id=131)
        verify_rpack_unityfs(rel_batch["assetbundle/resourcepackerinfosetall.assetbundle"], hero_id=150)

        # 3) Batch xuất từng file riêng lẻ (merge_output=False)
        split_dir = out_dir / "batch_split"
        res_split = se.SkinModBuilder.build_batch_mods(
            shared_provider,
            {
                "items": [
                    {"hero_id": 131, "source_skin_id": 13118, "replace_skin_ids": [13101]},
                    {"hero_id": 150, "source_skin_id": 15015, "replace_skin_ids": [15001]},
                ],
                "merge_output": False,
                "output_dir": str(split_dir),
            },
        )
        assert res_split["ok"] is True and len(res_split["results"]) == 2
        for sub_r in res_split["results"]:
            assert Path(sub_r["output_path"]).exists()

        # 4) API /api/mod/build (replace_skin_ids + reject sai dải tướng) & /api/mod/batch-build & UI studio.html
        client, _ = api_client
        r_api_sel = client.post(
            "/api/mod/build",
            json={"mode": "skin", "hero_id": 131, "source_skin_id": 13118, "replace_skin_ids": [13101]},
        )
        assert r_api_sel.status_code == 200
        assert r_api_sel.json()["summary"]["replace_skin_ids"] == [13101]

        r_api_bad = client.post(
            "/api/mod/build",
            json={"mode": "skin", "hero_id": 131, "source_skin_id": 13118, "replace_skin_ids": [15001]},
        )
        assert r_api_bad.status_code == 400

        r_api_batch = client.post(
            "/api/mod/batch-build",
            json={
                "items": [
                    {"hero_id": 131, "source_skin_id": 13118, "replace_skin_ids": [13101]},
                    {"hero_id": 150, "source_skin_id": 15015, "replace_skin_ids": [15001]},
                ],
                "merge_output": True,
            },
        )
        assert r_api_batch.status_code == 200
        assert r_api_batch.json()["download_url"]
        assert client.post("/api/mod/batch-build", json={"items": []}).status_code == 400

        html_src = _require_studio_html()
        for tok in ("data-replace-scope", "quickPickRankABtn", "addToBatchBtn", "runBatchBtn", "/api/mod/batch-build"):
            assert tok in html_src

    def test_t6_regression_bugs_a_and_b1_to_b6_full_contract(
        self, shared_provider: se.BaseResourceProvider, isolated_studio_env, api_client, tmp_path: Path
    ):
        # 1) Bug A: scan_local_resources(game_dir=None) giữ nguyên đường dẫn custom ngoài thư mục game/ mặc định
        custom_dir = tmp_path / "external_custom_dir"
        custom_dir.mkdir(parents=True, exist_ok=True)
        custom_zip = custom_dir / "My_Custom_AOV_Res.zip"
        shutil.copy2(RESOURCES_ZIP, custom_zip)
        se.save_studio_config({"resources_path": str(custom_zip), "default_watermark": "Test", "theme": "dark"})

        scan_keep = se.scan_local_resources(game_dir=None, update_config=True)
        assert Path(scan_keep["resources_path"]).resolve() == custom_zip.resolve()
        assert Path(se.load_studio_config()["resources_path"]).resolve() == custom_zip.resolve()

        client, _ = api_client
        r_rescan_keep = client.post("/api/resources/rescan", json={"resources_path": str(custom_zip)})
        assert r_rescan_keep.status_code == 200
        assert Path(r_rescan_keep.json()["resources_path"]).resolve() == custom_zip.resolve()

        # Phục hồi config về RESOURCES_ZIP sau khi test custom path
        se.save_studio_config({"resources_path": str(RESOURCES_ZIP), "default_watermark": "Test", "theme": "dark"})

        # 2) Bug B0-B5 trên Nakroth 15009 (toàn bộ skin) & đè chọn lọc 15000->15009, 15001->15012
        for is_sel in (False, True):
            opts = {
                "mode": "skin",
                "hero_id": 150,
                "source_skin_id": 15009,
                "enable_vfx": True,
                "enable_recall": True,
                "enable_born": True,
                "enable_sound": True,
                "enable_button": True,
                "enable_billboard": True,
                "camera_percent": 15,
                "output_dir": str(isolated_studio_env["out_dir"]),
            }
            if is_sel:
                opts["skin_mappings"] = {15000: 15009, 15001: 15012}
            res = se.SkinModBuilder.build_mod(shared_provider, opts)
            _, _, rel_map = _read_zip_tree_from_build(res)

            # B0/B1/B5: Kiana IFix HeroSkin_1/2 + ResPersonalButtonCfg sao chép record cho skin bị đè
            verify_kiana_ifix_thanos(rel_map, 150, 15009, 52, 45)
            pbtn_tbl = verify_mses_table(rel_map["Databin/Client/Huanhua/ResPersonalButtonCfg.bytes"], "ResPersonalButtonCfg")
            pbtn_sids = {struct.unpack_from("<I", rraw, 8)[0] for _, rraw in pbtn_tbl["recs"] if len(rraw) >= 12}
            assert 15000 in pbtn_sids and 15001 in pbtn_sids

            # B2: heroSkin.bytes đồng bộ avatar slot 15000 ('301500', giữ '301509head.jpg', hoán đổi idx@36 = 9 <-> 0)
            hs_tbl = verify_mses_table(rel_map["Databin/Client/Actor/heroSkin.bytes"], "heroSkin")
            hs_map = dict(hs_tbl["recs"])
            assert b"301500\x00" in hs_map[15000]
            assert b"301500.jpg" not in hs_map[15000]
            assert b"301509head.jpg" in hs_map[15000]
            assert struct.unpack_from("<I", hs_map[15000], 36)[0] == 9
            assert struct.unpack_from("<I", hs_map[15009], 36)[0] == 0
            assert struct.unpack_from("<I", hs_map[15001], 36)[0] == 1

            # B3: HasteE1.xml & HasteE1_leave.xml bơm track Totorox_Sprint (không bUseTargetSkinEffect) và dừng đúng track jiasu_tongyong_01
            h1 = _extract_common_xml(rel_map, "commonresource/HasteE1.xml")
            h1l = _extract_common_xml(rel_map, "commonresource/HasteE1_leave.xml")
            h1_trks = cp.split_xml_tracks(h1)[1]
            h1l_trks = cp.split_xml_tracks(h1l)[1]
            h1_sprints = [t for t in h1_trks if "Totorox_Sprint" in t["raw"] and "T2_Spint" in t["raw"]]
            h1l_sprints = [t for t in h1l_trks if "Totorox_Sprint" in t["raw"] and "T2_Spint" in t["raw"]]
            assert h1_sprints and all("bUseTargetSkinEffect" not in t["raw"] for t in h1_sprints)
            assert h1l_sprints and all("bUseTargetSkinEffect" not in t["raw"] for t in h1l_sprints)
            assert any(t.get("eventType") == "StopTracks" and 'id="8"' in t["raw"] and 'id="9"' in t["raw"] for t in h1_trks)
            assert any(t.get("eventType") == "StopTracks" and 'id="9"' in t["raw"] and 'id="12"' in t["raw"] for t in h1l_trks)

            # B4: bAllowEmptyEffect="false" trên track hiệu ứng + AssetRef & XML nén Zstd-dict + AES (0x224A67EF)
            aref_raw = rel_map["AssetRefs/Hero/150_AssetRef.bytes"]
            assert aref_raw[:4] == b"\x22\x4A\x67\xEF" and len(aref_raw) < 5000
            pkg_entries = assert_pkg_stored_zero(_extract_actor_actions_pkg(rel_map, 150), "Actor_150_Actions.pkg.bytes")
            u1_raw = next(v for k, v in pkg_entries.items() if os.path.basename(k).lower() == "u1.xml")
            assert u1_raw[:4] == b"\x22\x4A\x67\xEF"
            u1_xml = cp.pg_decrypt(u1_raw, "U1").decode("utf-8")
            assert 'bAllowEmptyEffect" value="false"' in u1_xml
            if not is_sel:
                assert 'bAllowEmptyEffect" value="true"' not in u1_xml

            # B6: Cam Xa 15% ghi heightRate=1.265 vào junglemark.xml
            assert 'heightRate" value="1.265"' in _extract_common_xml(rel_map, "PassiveResource/junglemark.xml")

        # B6 UI: không hardcode active trên data-cam-Mirror="15" & buildSkinItemPayload có camera_percent
        html_src = _require_studio_html()
        assert 'class="pill-choice active" data-cam-Mirror="15"' not in html_src
        fn_block = html_src.split("function buildSkinItemPayload()", 1)[1].split("function renderBatchQueue()", 1)[0]
        assert "camera_percent" in fn_block
