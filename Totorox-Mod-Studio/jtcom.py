"""
jtcom.py — Parser, Serializer & Transformer cho định dạng nhị phân JTCom (VSerializer) của Liên Quân Mobile (AOV).

Sử dụng cho:
1. `Prefab_Characters/Actor_<H>_Infos.pkg.bytes` (`CActorInfo` — model 3D LOD, sảnh Lobby, camera, ánh sáng, hiệu ứng animator).
2. `AssetRefs/Hero/<H>_AssetRef.bytes` (`baseSubset` — danh sách đường dẫn hiệu ứng nạp trước trong trận).
3. Chế độ Chỉnh Sửa Chuyên Sâu (Inspector JSON ⇄ JTCom binary lossless 100%).
"""

from __future__ import annotations

import copy
import re
import struct
from typing import Any


def parse_jt(buf: bytes, pos: int = 0) -> tuple[dict[str, Any], int]:
    """Đọc đệ quy cây nhị phân JTCom lossless 100%."""
    if pos + 8 > len(buf):
        raise ValueError("Dữ liệu JTCom bị cụt ở header node.")
    tlen = struct.unpack_from("<I", buf, pos)[0]
    end = pos + tlen
    if tlen < 20 or end > len(buf):
        raise ValueError(f"Độ dài node JTCom không hợp lệ ({tlen} tại offset {pos}).")

    nlen = struct.unpack_from("<I", buf, pos + 4)[0]
    if nlen < 4 or pos + 4 + nlen > end:
        raise ValueError("Độ dài tên node JTCom không hợp lệ.")
    name = buf[pos + 8 : pos + 4 + nlen].decode("utf-8", errors="surrogateescape")
    p = pos + 4 + nlen

    alen = struct.unpack_from("<I", buf, p)[0]
    a_end = p + alen
    if alen < 4 or a_end > end:
        raise ValueError("Khối thuộc tính JTCom vượt quá phạm vi node.")
    attrs: list[tuple[str, bytes]] = []
    if alen > 4:
        acnt = struct.unpack_from("<I", buf, p + 4)[0]
        ap = p + 8
        for _ in range(acnt):
            elen, klen = struct.unpack_from("<II", buf, ap)
            if elen < 8 or klen < 4 or ap + elen > a_end or ap + 4 + klen > ap + elen:
                raise ValueError("Thuộc tính JTCom bị hỏng.")
            key = buf[ap + 8 : ap + 4 + klen].decode("utf-8", errors="surrogateescape")
            val = bytes(buf[ap + 4 + klen : ap + elen])
            attrs.append((key, val))
            ap += elen
        if ap != a_end:
            raise ValueError(f"Lệch kích thước thuộc tính JTCom ({ap} != {a_end}).")

    p = a_end
    clen = struct.unpack_from("<I", buf, p)[0]
    if clen < 4 or p + clen > end:
        raise ValueError("Khối content JTCom không hợp lệ.")
    content = bytes(buf[p + 4 : p + clen])
    p += clen

    chlen = struct.unpack_from("<I", buf, p)[0]
    ch_end = p + chlen
    if chlen < 4 or ch_end != end:
        raise ValueError(f"Lệch cuối node JTCom ({ch_end} != {end}).")
    children: list[dict[str, Any]] = []
    if chlen > 4:
        ccnt = struct.unpack_from("<I", buf, p + 4)[0]
        cp_pos = p + 8
        for _ in range(ccnt):
            ch, cp_pos = parse_jt(buf, cp_pos)
            children.append(ch)
        if cp_pos != ch_end:
            raise ValueError(f"Lệch kích thước node con JTCom ({cp_pos} != {ch_end}).")

    return {"name": name, "attrs": attrs, "content": content, "children": children}, end


def serialize_jt(node: dict[str, Any]) -> bytes:
    """Đóng gói cây JTCom về lại nhị phân chuẩn xác từng byte."""
    nb = str(node["name"]).encode("utf-8", errors="surrogateescape")
    nblock = struct.pack("<I", 4 + len(nb)) + nb

    attrs = node.get("attrs") or []
    if not attrs:
        ablock = struct.pack("<I", 4)
    else:
        a_entries: list[bytes] = []
        for k, v in attrs:
            kb = str(k).encode("utf-8", errors="surrogateescape")
            vb = v if isinstance(v, (bytes, bytearray)) else str(v).encode("utf-8")
            a_entries.append(struct.pack("<II", 8 + len(kb) + len(vb), 4 + len(kb)) + kb + bytes(vb))
        a_body = b"".join(a_entries)
        ablock = struct.pack("<II", 8 + len(a_body), len(a_entries)) + a_body

    cb = node.get("content") or b""
    if isinstance(cb, str):
        cb = cb.encode("utf-8")
    cblock = struct.pack("<I", 4 + len(cb)) + bytes(cb)

    children = node.get("children") or []
    if not children:
        chblock = struct.pack("<I", 4)
    else:
        ch_body = b"".join(serialize_jt(ch) for ch in children)
        chblock = struct.pack("<II", 8 + len(ch_body), len(children)) + ch_body

    total = 4 + len(nblock) + len(ablock) + len(cblock) + len(chblock)
    return struct.pack("<I", total) + nblock + ablock + cblock + chblock


def jt_to_jsonable(node: dict[str, Any]) -> dict[str, Any]:
    """Chuyển cây JTCom sang dict JSON thân thiện để hiển thị và sửa trực tiếp trên Studio UI."""
    attrs_out: list[dict[str, Any]] = []
    for k, v in node.get("attrs") or []:
        try:
            attrs_out.append({"key": k, "value": v.decode("utf-8")})
        except UnicodeDecodeError:
            attrs_out.append({"key": k, "hex": v.hex()})
    out: dict[str, Any] = {"name": node["name"], "attrs": attrs_out}
    if node.get("content"):
        out["content_hex"] = bytes(node["content"]).hex()
    if node.get("children"):
        out["children"] = [jt_to_jsonable(c) for c in node["children"]]
    return out


def jsonable_to_jt(obj: dict[str, Any]) -> dict[str, Any]:
    """Khôi phục cây JTCom từ JSON chỉnh sửa trên Studio UI."""
    attrs: list[tuple[str, bytes]] = []
    for item in obj.get("attrs") or []:
        k = str(item["key"])
        if "hex" in item:
            v = bytes.fromhex(item["hex"])
        else:
            v = str(item.get("value", "")).encode("utf-8")
        attrs.append((k, v))
    content = bytes.fromhex(obj["content_hex"]) if obj.get("content_hex") else b""
    children = [jsonable_to_jt(c) for c in (obj.get("children") or [])]
    return {"name": str(obj["name"]), "attrs": attrs, "content": content, "children": children}


def get_jt_attr(node: dict[str, Any], key: str) -> bytes | None:
    for k, v in node.get("attrs") or []:
        if k == key:
            return v
    return None


def set_jt_attr(node: dict[str, Any], key: str, val: bytes | str) -> None:
    vb = val if isinstance(val, bytes) else str(val).encode("utf-8")
    attrs = list(node.get("attrs") or [])
    for idx, (k, _) in enumerate(attrs):
        if k == key:
            attrs[idx] = (k, vb)
            node["attrs"] = attrs
            return
    attrs.append((key, vb))
    node["attrs"] = attrs


def rpack_hash31(s: str) -> int:
    """Băm chuỗi theo thuật toán nhân 31 (case-insensitive) của `CResourcePackerInfoSet`."""
    h = 0
    for ch in s.lower():
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    return h


def rpack_hash_pair(path_str: str) -> tuple[int, int]:
    """Tính cặp hash `(full_path_hash, basename_hash)` chuẩn RPack (tự bóc đuôi `.prefab`)."""
    norm = path_str.strip().replace("\\", "/").lower()
    if norm.endswith(".prefab"):
        norm = norm[:-7]
    base = norm.rsplit("/", 1)[-1]
    return (rpack_hash31(norm), rpack_hash31(base))


def rewrite_hero_effect_path(
    path: str,
    hero_id: int,
    skin_id: int,
    is_hd_skin: bool,
    rpack_hashes: set[tuple[int, int]] | None = None,
) -> str:
    """
    Chuyển đổi đường dẫn hiệu ứng kỹ năng gốc của tướng sang đường dẫn prefab của skin đích:
      - Nếu có `rpack_hashes` (trích từ `resourcepackerinfosetall.assetbundle`), đối chiếu trực tiếp
        bảng băm RPack để chọn chính xác hậu tố `_HD` hoặc `.prefab` thực sự tồn tại trong bundle của skin
        (khắc phục triệt để các skin nằm trong `ResSkinSeniorLabelCfg` nhưng prefab không có `_HD` như `15015`, `10620`, `54307`,
        hoặc các hạt hiệu ứng dùng chung không có thư mục `{skin_id}/`).
      - Khi không truyền `rpack_hashes`, giữ nguyên quy ước:
        * `is_hd_skin=True`: `.../<hero_dir>/<skin_id>/<eff>_HD`
        * `is_hd_skin=False`: `.../<hero_dir>/<skin_id>/<eff>.prefab`
    """
    p = path.strip()
    if not p:
        return p
    norm = p.replace("\\", "/")
    low = norm.lower()

    # R1.4: đường dẫn trực tiếp dưới hero_skill_effects/<skin_id>_* (không chèn lặp /{skin_id}/)
    skin_prefix = f"prefab_skill_effects/hero_skill_effects/{skin_id}_"
    if low.startswith(skin_prefix):
        base = norm[:-7] if low.endswith(".prefab") else norm
        base_no_hd = base[:-3] if base.lower().endswith("_hd") else base
        cand_hd = f"{base_no_hd}_HD"
        cand_std = f"{base_no_hd}.prefab"
        if rpack_hashes:
            order = (cand_hd, cand_std) if is_hd_skin else (cand_std, cand_hd)
            for cand in order:
                if rpack_hash_pair(cand) in rpack_hashes:
                    return cand
        if is_hd_skin:
            return base if base.lower().endswith("_hd") else f"{base}_HD"
        return f"{base}.prefab"

    hero_prefix = f"prefab_skill_effects/hero_skill_effects/{hero_id}_"
    if not low.startswith(hero_prefix):
        return p

    # Tách thư mục `<hero_id>_<HeroCode>` và phần còn lại
    slash_after_hero = norm.find("/", len("prefab_skill_effects/hero_skill_effects/"))
    if slash_after_hero < 0:
        return p
    hero_dir = norm[:slash_after_hero]
    rest = norm[slash_after_hero + 1 :]
    if not rest:
        return p

    # Nếu đã có thư mục con của skin khác (vd: `13112/LiBai_Cutin`) thì bóc tên file gốc
    parts = [seg for seg in rest.split("/") if seg]
    skin_str = str(skin_id)
    had_other_skin_dir = len(parts) >= 2 and parts[0].isdigit() and parts[0] != skin_str
    if len(parts) >= 2 and parts[0].isdigit():
        eff_name = "/".join(parts[1:])
    else:
        eff_name = "/".join(parts)

    # Bóc đuôi `.prefab` cũ nếu có trước khi chuẩn hóa
    if eff_name.lower().endswith(".prefab"):
        eff_name = eff_name[:-7]

    base_eff = eff_name[:-3] if eff_name.lower().endswith("_hd") else eff_name
    cand_hd = f"{hero_dir}/{skin_str}/{base_eff}_HD"
    cand_std = f"{hero_dir}/{skin_str}/{base_eff}.prefab"

    if rpack_hashes:
        order = (cand_hd, cand_std) if is_hd_skin else (cand_std, cand_hd)
        for cand in order:
            if rpack_hash_pair(cand) in rpack_hashes:
                return cand
        # Nếu RPack của tướng không có prefab riêng под `{skin_str}/`, kiểm tra xem đường dẫn gốc có tồn tại không
        if not had_other_skin_dir and rpack_hash_pair(norm) in rpack_hashes:
            return norm

    if is_hd_skin:
        if not eff_name.lower().endswith("_hd"):
            eff_name = f"{eff_name}_HD"
        return f"{hero_dir}/{skin_str}/{eff_name}"
    else:
        return f"{hero_dir}/{skin_str}/{eff_name}.prefab"


def _get_saved_skin_id(elem: dict[str, Any]) -> str | None:
    for f in elem.get("children") or []:
        if f.get("name") == "SavedSkinId":
            val = (get_jt_attr(f, "V") or b"").decode("utf-8", errors="ignore").strip()
            if val:
                return val
    return None


def _elem_has_valid_lod(elem: dict[str, Any]) -> bool:
    for lod_name in ("ArtSkinPrefabLOD", "ArtSkinLobbyShowLOD"):
        node = next((c for c in elem.get("children") or [] if c.get("name") == lod_name), None)
        if _first_valid_lod_path(node):
            return True
    return False


def _find_skin_element_index(
    skin_prefab_node: dict[str, Any],
    hero_id: int,
    source_skin_id: int,
    *,
    require_valid_lod: bool = True,
) -> int | None:
    children = skin_prefab_node.get("children") or []
    if not children:
        return None
    skin_idx = source_skin_id - hero_id * 100
    target_token = f"/{hero_id}{skin_idx + 1}_".lower()
    alt_token = f"/{source_skin_id}_".lower()

    # 1. Ưu tiên khớp chính xác mã prefab `/{hero_id}{skin_idx + 1}_` hoặc `/{source_skin_id}_` trong toàn bộ mảng SkinPrefab
    #    (Xử lý chuẩn các tướng có chèn bậc Siêu Việt / Tiến Hóa làm dịch chuyển chỉ số như Nakroth 150, Butterfly 116, Krixi 106, Valhein 133...)
    for tok in (target_token, alt_token):
        for idx, elem in enumerate(children):
            hit = False
            for f in elem.get("children") or []:
                if f["name"] in ("ArtSkinPrefabLOD", "ArtSkinLobbyShowLOD") and f.get("children"):
                    for ch in f["children"]:
                        v0 = (get_jt_attr(ch, "V") or b"").decode("utf-8", errors="ignore").lower()
                        if tok in v0:
                            hit = True
                            break
                if hit:
                    break
            if hit and (not require_valid_lod or _elem_has_valid_lod(elem)):
                return idx

    # 2. Khớp theo trường `SavedSkinId` (dùng cho các skin Siêu Việt / Tiến Hóa như 15033..15037, 11633..11638)
    for idx, elem in enumerate(children):
        sv = _get_saved_skin_id(elem)
        if sv in (str(skin_idx), str(source_skin_id)):
            if not require_valid_lod or _elem_has_valid_lod(elem):
                return idx

    # 3. Kiểm tra vị trí trực tiếp `skin_idx - 1` nếu không bị chiếm bởi `SavedSkinId` khác và có LOD hợp lệ
    if 1 <= skin_idx <= len(children):
        cand = skin_idx - 1
        sv = _get_saved_skin_id(children[cand])
        if sv in (None, str(skin_idx), str(source_skin_id)):
            if not require_valid_lod or _elem_has_valid_lod(children[cand]):
                return cand

    # 4. Fallback cuối cho slot đích (`require_valid_lod=False`) khi `cand` nằm trong mảng
    if not require_valid_lod and 1 <= skin_idx <= len(children):
        return skin_idx - 1
    return None


def _first_valid_lod_path(arr_node: dict[str, Any] | None) -> str:
    """Tìm đường dẫn prefab hợp lệ đầu tiên (không NULL='Y', không rỗng) trong mảng LOD."""
    if not arr_node:
        return ""
    for elem in arr_node.get("children") or []:
        if get_jt_attr(elem, "NULL") == b"Y":
            continue
        val = (get_jt_attr(elem, "V") or b"").decode("utf-8", errors="ignore").strip()
        if val:
            return val
    return ""


def _force_lod_array_to_highest(arr_node: dict[str, Any]) -> None:
    """Ép cả 3 mức LOD1/LOD2/LOD3 dùng chung model LOD1 chất lượng cao nhất, giữ nguyên đường dẫn gốc (không tự ép `.prefab`)."""
    ch = arr_node.get("children") or []
    if not ch:
        return
    best = _first_valid_lod_path(arr_node)
    if not best:
        return
    best_b = best.encode("utf-8")
    for elem in ch:
        # Nếu phần tử đang là NULL='Y' thì chuyển thành JTPri System.String
        elem["attrs"] = [("JT", b"Pri"), ("Type", b"System.String"), ("V", best_b)]


_SKIN_TO_ROOT_MAP = {
    "ArtSkinPrefabLOD": "ArtPrefabLOD",
    "ArtSkinPrefabLODEx": "ArtPrefabLODEx",
    "ArtSkinLobbyShowLOD": "ArtLobbyShowLOD",
    "ArtSkinLobbyIdleShowLOD": "ArtLobbyIdleShowLOD",
    "ArtSkinLobbyShowCamera": "ArtSkinLobbyShowCamera",
    "ArtSkinLobbyNode": "ArtSkinLobbyNode",
    "ArtSkinLobbyShowMovie": "ArtSkinLobbyShowMovie",
    "ArtSkinLobbyShowHighMovie": "ArtSkinLobbyShowHighMovie",
    "ArtSkinLobbyShowMediumMovie": "ArtSkinLobbyShowMediumMovie",
    "useStateDrivenMecanim": "useStateDrivenMecanim",
    "useNewMecanim": "useNewMecanim",
    "ignoreActorInfoAnimatorSetting": "ignoreActorInfoAnimatorSetting",
    "isHokSkin": "isHokSkin",
    "hasHokCameraAnim": "hasHokCameraAnim",
    "bUnityLight": "bUnityLight",
    "bDisableDirLight": "bDisableDirLight",
    "bShadowCameraFollowLobbyActor": "bShadowCameraFollowLobbyActor",
    "bDisableCameraOnLoaded": "bDisableCameraOnLoaded",
    "PreloadAnimatorEffects": "PreloadAnimatorEffects",
    "TransConfigs": "TransConfigs",
    "LookAt": "LookAt",
    "LightConfig": "LightConfig",
    "IdleShowConfigs": "IdleShowConfigs",
    "LobbyScale": "LobbyScale",
}


def _prepare_skin_element_for_promote(
    orig_root_children: list[dict[str, Any]],
    orig_skin_prefab: dict[str, Any],
    hero_id: int,
    src_sid: int,
    is_hd_skin: bool,
    rpack_hashes: set[tuple[int, int]] | None = None,
) -> dict[str, Any]:
    """Chuẩn bị và kiểm tra `SkinElement` chuẩn của `src_sid` từ ảnh chụp gốc của `CActorInfo`."""
    base_sid = int(hero_id) * 100
    skin_children = orig_skin_prefab.get("children") or []
    elem_idx = _find_skin_element_index(orig_skin_prefab, hero_id, src_sid, require_valid_lod=True)
    if elem_idx is None:
        if int(src_sid) == base_sid:
            root_by_name = {c["name"]: c for c in orig_root_children}
            children_list: list[dict[str, Any]] = []
            for s_key, r_key in _SKIN_TO_ROOT_MAP.items():
                if r_key in root_by_name:
                    cloned = copy.deepcopy(root_by_name[r_key])
                    cloned["name"] = s_key
                    children_list.append(cloned)
            src_elem: dict[str, Any] = {
                "name": "SkinPrefab",
                "attrs": [("JT", b"Com")],
                "content": b"",
                "children": children_list,
            }
        else:
            raise RuntimeError(f"Không tìm thấy SkinElement cho skin {src_sid} trong ActorInfo tướng {hero_id}.")
    else:
        src_elem = copy.deepcopy(skin_children[elem_idx])
        # Loại bỏ SavedSkinId của skin nguồn để khi gán sang slot đích không làm lệch chỉ số SavedSkinId
        src_elem["children"] = [
            c for c in (src_elem.get("children") or []) if c.get("name") != "SavedSkinId"
        ]

    elem_fields = {f["name"]: f for f in src_elem.get("children") or []}
    for lod_name in ("ArtSkinPrefabLOD", "ArtSkinLobbyShowLOD", "ArtSkinLobbyIdleShowLOD"):
        if lod_name in elem_fields:
            _force_lod_array_to_highest(elem_fields[lod_name])

    if "PreloadAnimatorEffects" in elem_fields:
        for sub in elem_fields["PreloadAnimatorEffects"].get("children") or []:
            v = (get_jt_attr(sub, "V") or b"").decode("utf-8", errors="ignore")
            if v:
                rewritten = rewrite_hero_effect_path(
                    v, hero_id, src_sid, is_hd_skin, rpack_hashes=rpack_hashes
                )
                # PreloadAnimatorEffects trong ActorInfo không dùng hậu tố `.prefab` nếu chuỗi gốc không có
                if not v.lower().endswith(".prefab") and rewritten.lower().endswith(".prefab"):
                    rewritten = rewritten[:-7]
                set_jt_attr(sub, "V", rewritten)

    b_lod = _first_valid_lod_path(elem_fields.get("ArtSkinPrefabLOD"))
    l_lod = _first_valid_lod_path(elem_fields.get("ArtSkinLobbyShowLOD"))
    missing = [n for n, v in (("ArtSkinPrefabLOD", b_lod), ("ArtSkinLobbyShowLOD", l_lod)) if not v]
    if missing:
        raise RuntimeError(
            f"Thiếu đường dẫn model {', '.join(missing)} hợp lệ cho skin nguồn {src_sid} của tướng {hero_id}."
        )
    return src_elem


def _apply_skin_element_to_root(
    root: dict[str, Any],
    src_elem: dict[str, Any],
) -> None:
    """Áp dụng toàn bộ trường model/lobby/camera từ `src_elem` lên cấp Root của `CActorInfo`."""
    root_children = root.get("children") or []
    elem_fields = {f["name"]: f for f in src_elem.get("children") or []}
    root_index_by_name = {c["name"]: idx for idx, c in enumerate(root_children)}
    skin_prefab_pos = root_index_by_name.get("SkinPrefab", len(root_children))
    extra_before_skin: list[dict[str, Any]] = []

    for s_key, r_key in _SKIN_TO_ROOT_MAP.items():
        if s_key not in elem_fields:
            continue
        cloned = copy.deepcopy(elem_fields[s_key])
        cloned["name"] = r_key
        if r_key in root_index_by_name:
            root_children[root_index_by_name[r_key]] = cloned
        else:
            extra_before_skin.append(cloned)

    if extra_before_skin:
        root_children = (
            root_children[:skin_prefab_pos]
            + extra_before_skin
            + root_children[skin_prefab_pos:]
        )
        root["children"] = root_children


def _preserve_dst_saved_skin_id(dst_elem: dict[str, Any], orig_dst_elem: dict[str, Any]) -> dict[str, Any]:
    """Bảo toàn node `SavedSkinId` gốc của slot đích (nếu có) để engine ánh xạ đúng các bậc tiến hóa (VD 15033..15037)."""
    orig_saved = next(
        (c for c in (orig_dst_elem.get("children") or []) if c.get("name") == "SavedSkinId"),
        None,
    )
    if orig_saved is not None:
        ch = [c for c in (dst_elem.get("children") or []) if c.get("name") != "SavedSkinId"]
        ch.append(copy.deepcopy(orig_saved))
        dst_elem["children"] = ch
    return dst_elem


def promote_skin_in_actorinfo(
    actorinfo_plain: bytes,
    hero_id: int,
    source_skin_id: int,
    is_hd_skin: bool,
    author_label: str | None = None,
    apply_to_all_skins: bool = True,
    skin_mappings: dict[int, int] | None = None,
    hd_skin_ids: set[int] | None = None,
    rpack_hashes: set[tuple[int, int]] | None = None,
) -> bytes:
    """
    Biến đổi `CActorInfo` (`<H>_<Hero>_actorinfo.bytes`):
      - Mặc định (`skin_mappings=None`): đè `source_skin_id` lên Root (và mọi skin nếu `apply_to_all_skins=True`).
      - Chế độ chọn lọc (`skin_mappings={dst_sid: src_sid}`): chỉ đè đúng từng cặp skin bị đè, giữ nguyên các skin còn lại của tướng.
    """
    root, _ = parse_jt(actorinfo_plain, 0)
    root_children = root.get("children") or []
    skin_prefab = next((c for c in root_children if c["name"] == "SkinPrefab"), None)
    if skin_prefab is None:
        raise RuntimeError(f"ActorInfo tướng {hero_id} thiếu node SkinPrefab.")

    orig_skin_prefab_snapshot = copy.deepcopy(skin_prefab)
    orig_root_snapshot = copy.deepcopy(root_children)
    base_sid = int(hero_id) * 100
    hd_set = set(hd_skin_ids or ())
    if is_hd_skin:
        hd_set.add(int(source_skin_id))

    if author_label:
        actor_name_node = next((c for c in root_children if c["name"] == "ActorName"), None)
        if actor_name_node is not None:
            set_jt_attr(actor_name_node, "V", author_label)

    if skin_mappings is not None and not apply_to_all_skins:
        norm_map = {int(k): int(v) for k, v in skin_mappings.items()}
        prepared_by_src: dict[int, dict[str, Any]] = {}
        for src_sid in sorted(set(norm_map.values())):
            prepared_by_src[src_sid] = _prepare_skin_element_for_promote(
                orig_root_snapshot,
                orig_skin_prefab_snapshot,
                hero_id,
                src_sid,
                src_sid in hd_set,
                rpack_hashes=rpack_hashes,
            )

        if base_sid in norm_map:
            _apply_skin_element_to_root(root, prepared_by_src[norm_map[base_sid]])
            root_children = root.get("children") or []
        else:
            # Nếu không đè skin mặc định, vẫn đảm bảo LOD root hợp lệ (không tự ép `.prefab`)
            root_fields_chk = {c["name"]: c for c in root_children}
            for lod_name in ("ArtPrefabLOD", "ArtLobbyShowLOD", "ArtLobbyIdleShowLOD"):
                if lod_name in root_fields_chk:
                    _force_lod_array_to_highest(root_fields_chk[lod_name])

        sp_children = skin_prefab.get("children") or []
        orig_sp_children = orig_skin_prefab_snapshot.get("children") or []
        for dst_sid, src_sid in sorted(norm_map.items()):
            if dst_sid == base_sid:
                continue
            dst_idx = _find_skin_element_index(
                orig_skin_prefab_snapshot, hero_id, dst_sid, require_valid_lod=False
            )
            if dst_idx is None or not (0 <= dst_idx < len(sp_children)):
                raise RuntimeError(
                    f"Không tìm thấy vị trí SkinElement cho skin bị đè {dst_sid} trong ActorInfo tướng {hero_id}."
                )
            new_dst_elem = copy.deepcopy(prepared_by_src[src_sid])
            if 0 <= dst_idx < len(orig_sp_children):
                _preserve_dst_saved_skin_id(new_dst_elem, orig_sp_children[dst_idx])
            sp_children[dst_idx] = new_dst_elem
    else:
        src_elem = _prepare_skin_element_for_promote(
            orig_root_snapshot,
            orig_skin_prefab_snapshot,
            hero_id,
            int(source_skin_id),
            is_hd_skin,
            rpack_hashes=rpack_hashes,
        )
        _apply_skin_element_to_root(root, src_elem)
        root_children = root.get("children") or []
        if apply_to_all_skins:
            orig_sp_children = orig_skin_prefab_snapshot.get("children") or []
            skin_prefab["children"] = [
                _preserve_dst_saved_skin_id(copy.deepcopy(src_elem), orig_el)
                for orig_el in orig_sp_children
            ]

    root_fields = {c["name"]: c for c in root_children}
    battle_lod = _first_valid_lod_path(root_fields.get("ArtPrefabLOD"))
    lobby_lod = _first_valid_lod_path(root_fields.get("ArtLobbyShowLOD"))
    missing_lods = [
        name
        for name, val in (("ArtPrefabLOD", battle_lod), ("ArtLobbyShowLOD", lobby_lod))
        if not val
    ]
    if missing_lods:
        raise RuntimeError(
            f"Thiếu đường dẫn model {', '.join(missing_lods)} hợp lệ sau khi promote skin {source_skin_id} cho tướng {hero_id}."
        )

    return serialize_jt(root)


def transform_assetref_paths(
    assetref_plain: bytes,
    hero_id: int,
    source_skin_id: int,
    is_hd_skin: bool,
    rpack_hashes: set[tuple[int, int]] | None = None,
    skin_mappings: dict[int, int] | None = None,
    hd_skin_ids: set[int] | None = None,
) -> bytes:
    """
    Cập nhật đường dẫn hiệu ứng trong `<H>_AssetRef.bytes`:
      - Hỗ trợ cả chế độ đè toàn bộ / mặc định lẫn chế độ đè chọn lọc `skin_mappings={dst_sid: src_sid}`.
      - Bổ sung `skinSubset[dst_sid]` được sao chép từ `skinSubset[src_sid]` (nếu có) để nạp đủ animations/actions/particles riêng của skin nguồn.
    """
    root, _ = parse_jt(assetref_plain, 0)
    base_sid = int(hero_id) * 100
    hd_set = set(hd_skin_ids or ())
    if is_hd_skin:
        hd_set.add(int(source_skin_id))

    def _rewrite_tree_for_skin(node: dict[str, Any], target_sid: int) -> None:
        if target_sid == base_sid:
            return
        v = get_jt_attr(node, "V")
        if v and get_jt_attr(node, "Type") == b"System.String":
            s = v.decode("utf-8", errors="ignore")
            if "hero_skill_effects/" in s.lower():
                new_s = rewrite_hero_effect_path(
                    s, hero_id, target_sid, target_sid in hd_set, rpack_hashes=rpack_hashes
                )
                if new_s != s:
                    set_jt_attr(node, "V", new_s)
        for ch in node.get("children") or []:
            _rewrite_tree_for_skin(ch, target_sid)

    # Snapshot skinSubset gốc trước khi biến đổi
    skin_subset_node = next((c for c in (root.get("children") or []) if c.get("name") == "skinSubset"), None)
    orig_skin_subset_by_id: dict[int, dict[str, Any]] = {}
    if skin_subset_node is not None:
        for el in skin_subset_node.get("children") or []:
            v1_node = next((c for c in (el.get("children") or []) if c.get("name") == "v1"), None)
            if v1_node is not None:
                v1_str = (get_jt_attr(v1_node, "V") or b"").decode("utf-8", errors="ignore").strip()
                if v1_str.isdigit():
                    orig_skin_subset_by_id[int(v1_str)] = copy.deepcopy(el)

    if skin_mappings is not None:
        norm_map = {int(k): int(v) for k, v in skin_mappings.items()}
        base_subset_node = next((c for c in (root.get("children") or []) if c.get("name") == "baseSubset"), None)
        orig_base_snapshot = copy.deepcopy(base_subset_node) if base_subset_node is not None else None

        # Nếu đè cả skin mặc định `base_sid`, đổi trực tiếp baseSubset theo skin nguồn của `base_sid`
        if base_sid in norm_map and base_subset_node is not None:
            _rewrite_tree_for_skin(base_subset_node, norm_map[base_sid])

        # Bổ sung hạt hiệu ứng của các skin nguồn khác trong `norm_map` vào `baseSubset` để luôn được preload
        if base_subset_node is not None and orig_base_snapshot is not None:
            active_srcs = sorted({s for s in norm_map.values() if s != base_sid})
            for layer_name in ("particlesInFirstLayer", "hurtParticlesInFirstLayer"):
                dst_layer = next((c for c in (base_subset_node.get("children") or []) if c.get("name") == layer_name), None)
                src_layer_snap = next((c for c in (orig_base_snapshot.get("children") or []) if c.get("name") == layer_name), None)
                if dst_layer is None or src_layer_snap is None:
                    continue
                existing_paths: set[str] = set()
                for el in dst_layer.get("children") or []:
                    v1_n = next((c for c in (el.get("children") or []) if c.get("name") == "v1"), None)
                    if v1_n is not None:
                        existing_paths.add((get_jt_attr(v1_n, "V") or b"").decode("utf-8", errors="ignore"))
                for src_sid in active_srcs:
                    cloned_layer = copy.deepcopy(src_layer_snap)
                    _rewrite_tree_for_skin(cloned_layer, src_sid)
                    for el in cloned_layer.get("children") or []:
                        v1_n = next((c for c in (el.get("children") or []) if c.get("name") == "v1"), None)
                        if v1_n is not None:
                            p_str = (get_jt_attr(v1_n, "V") or b"").decode("utf-8", errors="ignore")
                            if p_str and p_str not in existing_paths:
                                existing_paths.add(p_str)
                                dst_layer["children"].append(el)

        # Cập nhật `skinSubset` cho các `dst_sid` được chọn
        if skin_subset_node is not None:
            kept_ss: list[dict[str, Any]] = []
            for el in skin_subset_node.get("children") or []:
                v1_n = next((c for c in (el.get("children") or []) if c.get("name") == "v1"), None)
                v1_s = (get_jt_attr(v1_n, "V") or b"").decode("utf-8", errors="ignore").strip() if v1_n else ""
                if v1_s.isdigit() and int(v1_s) in norm_map:
                    continue
                kept_ss.append(el)
            for dst_sid, src_sid in sorted(norm_map.items()):
                if src_sid in orig_skin_subset_by_id:
                    cloned_ss = copy.deepcopy(orig_skin_subset_by_id[src_sid])
                    v1_n = next((c for c in (cloned_ss.get("children") or []) if c.get("name") == "v1"), None)
                    if v1_n is not None:
                        set_jt_attr(v1_n, "V", str(dst_sid))
                    _rewrite_tree_for_skin(cloned_ss, src_sid)
                    kept_ss.append(cloned_ss)
            skin_subset_node["children"] = kept_ss
    else:
        _rewrite_tree_for_skin(root, int(source_skin_id))
        if skin_subset_node is not None and int(source_skin_id) in orig_skin_subset_by_id:
            has_base_ss = any(
                (get_jt_attr(next((c for c in (el.get("children") or []) if c.get("name") == "v1"), {}), "V") or b"")
                == str(base_sid).encode("ascii")
                for el in (skin_subset_node.get("children") or [])
            )
            if not has_base_ss:
                cloned_base_ss = copy.deepcopy(orig_skin_subset_by_id[int(source_skin_id)])
                v1_n = next((c for c in (cloned_base_ss.get("children") or []) if c.get("name") == "v1"), None)
                if v1_n is not None:
                    set_jt_attr(v1_n, "V", str(base_sid))
                _rewrite_tree_for_skin(cloned_base_ss, int(source_skin_id))
                skin_subset_node["children"].append(cloned_base_ss)

    return serialize_jt(root)
