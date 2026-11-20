# Báo Cáo Phân Tích Cơ Chế Mod Skin & Lỗi Gộp Mod — Totorox

> **Ngày:** 20/11/2026  
> **Phạm vi:** Phân tích các gói mod `.zip` trong `Totorox-Mod-Studio/dist/TotoroxModStudio/output` (mod lẻ + pack gộp) và gói `[Mod VN] 100 Skin Ver 12 - iOS [KHAM PHA MOBILE].zip` trong `C:\Users\studi\Downloads\Mod skin`.  
> **Mục tiêu:** Hiểu cơ chế mod skin, xác định nguyên nhân thiếu hiệu ứng chiêu thức / lỗi âm thanh trên mod lẻ, và nguyên nhân chồng chéo khi gộp nhiều skin cùng tướng. Tài liệu này dùng để bàn giao cho các agent khác tiếp tục xử lý.

---

## 1. Tổng quan hai cơ chế mod skin

### 1.1. Cơ chế A — Mod targeted (Totorox, hero 150 / Nakroth)

Các gói trong `output/` đều là mod cho **tướng 150 (Nakroth)**, mỗi gói nhắm **một skin mục tiêu** khác nhau. Cơ chế:

- **`Thanos/HeroSkin_1.bytes`** — ILFix hook remap `hero_id → skin_id` (cặp `(150, skin_id)`). Đây là "chìa khóa" để game hiển thị skin mod khi chọn tướng 150.
- **`Thanos/HeroSkin_2.bytes`** — ILFix hook set hai trường cho tướng: `0x4B 3 = PersonalButtonID` (nút bấm cá nhân) và `0x4B 2 = broadcastID` (thông báo hạ gục). Cặp `(150, button_id, broadcast_id)`.
- **`Databin/Client/Huanhua/ResPersonalButtonCfg.bytes`** — định nghĩa nút bấm cá nhân theo skin.
- **`Databin/Client/Huanhua/ResBillboardSkinCfg.bytes`** — thông báo hạ gục (kill broadcast) theo skin.
- **`Databin/Client/Huanhua/ResSkinExclusiveBattleEffectCfg.bytes`** — hiệu ứng chiến đấu độc quyền (skill VFX) theo skin.
- **`Databin/Client/Sound/BattleBank.bytes`** — ánh xạ `skin_id → sound bank Wwise` (âm thanh chiêu thức/lồng tiếng).
- **`Ages/.../Actor_150_Actions.pkg.bytes`**, **`Prefab_Characters/Actor_150_Infos.pkg.bytes`** — animation/action và prefab của tướng (skill animation).
- **`assetbundle/...`** — tài nguyên 3D/texture.

Bảng ánh xạ skin mục tiêu của từng gói:

| Gói | Skin mục tiêu (hs1) | button_id (hs2) | broadcast_id (hs2) |
|---|---|---|---|
| `ve than.zip` (Vệ Thần) | 15009 | 52 | 45 |
| `bach dien chien thuong.zip` | 15015 | 17 | 20 |
| `killua.zip` | 15012 | 10 | 9 |
| `quy thuong liep de.zip` | 15013 | 15 | 16 |
| `sieu viet b5.zip` | 15033 | 0 | 0 |

### 1.2. Cơ chế B — Mod full resource (100 Skin)

Gói `[Mod VN] 100 Skin Ver 12 - iOS [KHAM PHA MOBILE].zip` (6986 file) là **thay thế toàn bộ tài nguyên game**: chứa đầy đủ `assetbundle/`, `Prefab_Characters/`, `Databin/`, `Sound/`, `Languages/`, Lua `.pkg.bytes`, v.v. và một thư mục `Mod_by_Youtube_KHAM-PHA-MOBILE/` với ~3633 file `KPM_MOD_*` (UnityFS assetbundle, mỗi file ~50–200 KB).

- **Không dùng Thanos remap**: `HeroSkin_1.bytes` / `HeroSkin_2.bytes` ở dạng gốc (parse_kiana trả `None`), tức không remap hero→skin.
- Cơ chế là **mở khóa toàn bộ skin trong game gốc** bằng cách cung cấp đủ asset cho mọi skin, nên không cần hoán đổi skin.
- Chi phí: ~120 MB (file cures) + hàng nghìn assetbundle; không phù hợp với mod targeted nhẹ.

---

## 2. Vấn đề mod lẻ (single skin)

### 2.1. Skill VFX (hiệu ứng chiêu thức) thiếu trên các skin ngoài Vệ Thần

Quan sát `ResSkinExclusiveBattleEffectCfg.bytes` (bảng hiệu ứng chiến đấu độc quyền):

- Mỗi gói đơn đều có entry cho **skin mục tiêu** của chính nó (target present = True), cùng một tập skin nền (15004, 15007, 15009, 15012, 15013, 15015, 15016, 15018, 15033, 1503305).
- Tuy nhiên, `Actor_150_Actions.pkg.bytes` và `Actor_150_Infos.pkg.bytes` (animation/prefab chiêu thức) **khác nhau về kích thước/hash** giữa các gói, và chỉ gói `ve than.zip` được tác giả build từ template đầy đủ (bao gồm hoán đổi animation skill).
- Các gói còn lại (`bach dien`, `killua`, `quy thuong`, `sieu viet`) chỉ hoán đổi: nút bấm (`ResPersonalButtonCfg`), thông báo hạ (`ResBillboardSkinCfg`), hiệu ứng độc quyền một phần (`ResSkinExclusiveBattleEffectCfg`), nhưng **không hoán đổi đầy đủ animation chiêu thức** trong `Actor_150_Actions.pkg.bytes`. Kết quả: in-game chỉ thấy nút + thông báo + hạ trụ, thiếu VFX chiêu thức.

**Kết luận:** Đây là vấn đề **nội dung tác giả** (incomplete mod authoring), không phải bug engine. Vệ Thần là gói duy nhất "hoàn thiện" vì được build từ template đầy đủ.

### 2.2. Lỗi âm thanh (sound) trên các skin ngoài Vệ Thần

Kiểm tra `BattleBank.bytes` (ánh xạ skin → sound bank Wwise):

| Gói | Skin mục tiêu | Có trong BattleBank? |
|---|---|---|
| `ve than.zip` | 15009 | ✅ |
| `bach dien chien thuong.zip` | 15015 | ✅ |
| `killua.zip` | 15012 | ✅ |
| `quy thuong liep de.zip` | 15013 | ✅ |
| `sieu viet b5.zip` | 15033 | ❌ **Thiếu** |

- `sieu viet b5.zip`: skin 15033 **không có entry** trong `BattleBank.bytes` → game không tìm thấy sound bank → lỗi âm thanh (im lặng/crash audio). Đây là nguyên nhân chính cho `sieu viet`.
- Các gói khác có entry trong BattleBank nhưng **HeroSound.bytes / BattleBank.bytes vẫn khác hash** so với Vệ Thần, và `hs2 params` button/broadcast IDs khác. Lỗi âm thanh còn lại có thể do:
  - `HeroSkin_2.bytes` set button/broadcast nhưng sound bank mapping trong `BattleBank.bytes` trỏ tới bank không tồn tại trong gói (thiếu file `.bnk`/`.wem` trong `Sound/`).
  - Kích thước `HeroSound.bytes` nhỏ hơn Vệ Thần (147752 vs 148936) → có thể thiếu bank.

**Kết luận:** `sieu viet` thiếu mapping BattleBank hoàn toàn (bug rõ ràng). Các gói khác cần kiểm tra chéo sound bank files trong `Sound/`.

---

## 3. Vấn đề chồng chéo khi gộp (merge) nhiều skin cùng tướng

### 3.1. Hiện tượng

Các pack gộp (`Pack gộp bằng app.zip`, `Pack gộp bằng tool.zip`) là kết quả gộp nhiều gói đơn cho hero 150. Kết quả:
- `Pack gộp bằng app`: skin mục tiêu 15015 (bach dien), hs2 (17,20).
- `Pack gộp bằng tool`: skin mục tiêu 15009 (Vệ Thần), hs2 (52,45).

Nhưng `ResSkinExclusiveBattleEffectCfg` của pack gộp chỉ chứa **một tập cố định** 14 skin (15000–15018, 15033, 1503305) — không đầy đủ tất cả skin đã gộp. Và `Actions.pkg.bytes` / `Infos.pkg.bytes` hash mới (khác tất cả input) → merge đã chạy `merge_actor_actions_pkg` / `merge_actor_infos_pkg`.

### 3.2. Nguyên nhân gốc (root cause)

Thuật toán `run_merge` trong `core_processor.py` được thiết kế cho **gộp các mod khác tướng** (khác hero_id), với các cơ chế:
- `family_winner`: mỗi family AssetBundle chỉ chọn **một mod thắng** (theo `bvk` build version, allshared flag). Các mod khác bị loại cho family đó.
- `HeroSkin_1` merge (`merge_hs1`): gộp các cặp `(hero, skin)` thành một danh sách `hero_skins` (extras), tạo skin selector multi-skin cho **cùng hero**.
- `HeroSkin_2` merge (`merge_hs2`): gộp params `(hero, button, broadcast)` cho từng hero.

**Vấn đề khi gộp nhiều skin CÙNG hero 150:**
1. `HeroSkin_1` tạo selector chứa nhiều skin (15009, 15012, 15013, 15015, 15033, …) → game nghĩ tất cả skin này đều có asset.
2. Nhưng `Actor_150_Actions.pkg.bytes`, `Actor_150_Infos.pkg.bytes`, assetbundle family cho hero 150 chỉ có **một winner** (family_winner) → chỉ asset của một skin survive; các skin khác trong selector dùng asset của winner → skill VFX sai/lệch ("chồng chéo").
3. `ResSkinExclusiveBattleEffectCfg` merge (`merge_databin_mses`) gộp record theo skin_id, nhưng nếu hai mod cùng sửa record cho cùng skin → conflict theo bvk, không phải union → mất hiệu ứng.
4. `BattleBank.bytes` merge: chỉ union skin→sound mapping, nhưng sound bank files (`.bnk`) chỉ của winner survive → skin không phải winner mất âm thanh.
5. `hs2` merge gộp button/broadcast cho hero 150 từ nhiều mod → nếu cùng hero, button/broadcast của mod này ghi đè mod kia (theo thứ tự params) → không nhất quán.

**Kết luận:** `run_merge` giả định mods target **khác hero** (khác hids). Khi target **cùng hero, khác skin**, các asset per-skin xung đột và family_winner chỉ giữ một → kết quả "chồng chéo cực nghiêm trọng" (multi-skin selector nhưng chỉ một bộ asset).

### 3.3. Hàm merge liên quan

- `core_processor.run_merge` (line ~4025)
- `merge_hs1` (line ~3729), `merge_hs2` (line ~3790)
- `merge_actor_actions_pkg`, `merge_actor_infos_pkg`
- `merge_databin_mses`, `merge_assetref_bytes`
- `family_winner` / `assetbundle_family_key`

---

## 4. Khuyến nghị & hướng xử lý

### 4.1. Mod lẻ (single skin)
- **Skill VFX thiếu:** Cần tác giả build mod từ template đầy đủ (hoán đổi `Actor_150_Actions.pkg.bytes` + assetbundle skill VFX), không chỉ button/notify. Vệ Thần là mẫu tham chiếu.
- **Âm thanh:** 
  - `sieu viet` (15033): thêm entry BattleBank cho 15033 + sound bank files.
  - Các gói khác: kiểm tra chéo `Sound/` chứa đủ `.bnk`/`.wem` cho skin mục tiêu; so sánh với Vệ Thần.

### 4.2. Gộp mod cùng tướng
- **Không nên gộp các mod cùng hero khác skin bằng `run_merge` hiện tại** vì family_winner chỉ giữ một bộ asset → chồng chéo.
- **Hướng đúng:**
  1. **Tách theo skin, không theo hero:** Mỗi skin cần bộ asset riêng. Gộp chỉ an toàn khi mods target **khác hero** (khác hids) — đúng thiết kế hiện tại.
  2. **Nếu muốn "mix skin cùng tướng":** Cần cơ chế chọn **một skin đại diện** (winner) cho asset, và chỉ thêm các skin khác vào selector HeroSkin_1 nếu chúng có asset riêng (không share). Hoặc tạo pack "all skins" theo cơ chế B (full resource).
  3. **Thêm guard trong `run_merge`:** Nếu `len(distinct_hero_sets) == 1` và `hero_mod_count >= 2` (tất cả mods cùng hero), cảnh báo hoặc từ chối gộp, hoặc chuyển sang chế độ "single winner + keep selector only for skins with own assets".
  4. **Hoặc:** Implement "per-skin asset isolation" — giữ assetbundle per-skin thay vì family_winner khi cùng hero.

### 4.3. Cơ chế B (100 Skin) làm tham chiếu
- Nếu mục tiêu là có nhiều skin cùng tướng hoạt động đầy đủ (VFX + sound), nên dùng cách tiếp cận full-resource (cơ chế B) thay vì targeted mod, vì nó cung cấp đủ asset cho mọi skin. Trade-off: kích thước lớn (~120MB+).

---

## 5. Dữ liệu đã thu thập (cho agent tiếp theo)

- Danh sách file & hash per mod: xem mục 2 & 3.
- Script phân tích: chạy trong `Totorox-Backend/` với `import core_processor as cp`, `pg_decrypt`, `parse_mses`, `parse_kiana_hs1/hs2`.
- Big mod zip: `C:\Users\studi\Downloads\Mod skin\[Mod VN] 100 Skin Ver 12 - iOS [KHAM PHA MOBILE].zip`.

### Checklist tiếp theo (gợi ý)
- [ ] Xác minh sound bank files trong `Sound/` cho từng gói đơn (so sánh với Vệ Thần).
- [ ] Kiểm tra `Actor_150_Actions.pkg.bytes` của Vệ Thần để xác định pattern hoán đổi skill VFX (template).
- [ ] Quyết định: giữ `run_merge` cho khác hero, thêm guard cho cùng hero; hoặc implement per-skin asset isolation.
- [ ] (Tùy chọn) Thêm UI cảnh báo trong Mod Studio khi user gộp nhiều mod cùng hero.

---

*Report generated by analysis agent. Cập nhật `TOTOROX_3.0_PROGRESS.md` khi có thay đổi code.*

---

## 6. Quyết định & Implement (20/11/2026)

**Quyết định:** Chuyển cả Studio Mod và Backend sang cơ chế **full-resource (B)** thay vì targeted (A), chấp nhận kích thước lớn, vì cơ chế B cung cấp đủ asset/VFX/sound cho mọi skin.

### Thay đổi đã thực hiện
1. **Backend `core_processor.run_merge`**: thêm guard `allow_same_hero_merge=False` (mặc định). Khi phát hiện nhiều mod targeted cùng 1 tướng (`distinct_hero_sets == 1` và `hero_mod_count >= 2`), raise `ValueError` rõ ràng thay vì âm thầm chồng chéo asset. Bật `allow_same_hero_merge=True` chỉ khi cố ý Mix Chiêu (targeted).
   - Test `test_hs2_..._same_hero_merge` cập nhật truyền `allow_same_hero_merge=True`.
2. **Studio `SkinModBuilder.build_mod`**: thêm option `full_resource` (mặc định `False`). Khi `True`, copy toàn bộ rel paths từ `BaseResourceProvider` vào gói trước khi áp dụng sửa đổi targeted, đảm bảo đủ asset. Giữ targeted cho gói nhẹ (cam xa, nút bấm).

### Bước tiếp theo
- Backend API/Studio UI: expose `full_resource` toggle và mặc định B cho build skin đầy đủ.
- Xác minh size/time build với full_resource=True.
- Cập nhật docs.
