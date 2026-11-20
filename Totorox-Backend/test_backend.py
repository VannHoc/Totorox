import contextlib
import io
import json
import os
import plistlib
import sqlite3
import sys
import tempfile
import time
import unittest
import uuid
import zipfile
from urllib.parse import parse_qs, urlparse

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

# Point DB to a temporary path BEFORE importing main/database
_TEMP_DB_FILE = tempfile.NamedTemporaryFile(prefix="totorox_test_", suffix=".db", delete=False)
_TEMP_DB_PATH = _TEMP_DB_FILE.name
_TEMP_DB_FILE.close()
os.environ["TOTOROX_DB_PATH"] = _TEMP_DB_PATH

from fastapi.testclient import TestClient  # noqa: E402
import database  # noqa: E402
import admin  # noqa: E402
import admin_keys  # noqa: E402
import core_processor  # noqa: E402
import main as backend_main  # noqa: E402


class SignedTestClient(TestClient):
    """TestClient tự động gắn chữ ký HMAC-SHA256 cho các API app iOS."""

    def request(self, method, url, **kwargs):
        parsed_path = urlparse(str(url)).path.rstrip("/")
        if parsed_path in backend_main._HMAC_PROTECTED_PATHS:
            headers = dict(kwargs.pop("headers", None) or {})
            if "X-Signature" not in headers and "x-signature" not in headers:
                ts = str(int(time.time()))
                nonce = uuid.uuid4().hex
                hwid = headers.get("X-HWID") or headers.get("x-hwid") or ""
                auth = headers.get("Authorization") or headers.get("authorization") or ""
                headers["X-Timestamp"] = ts
                headers["X-Nonce"] = nonce
                headers["X-Signature"] = backend_main.compute_api_hmac_signature(
                    method,
                    urlparse(str(url)).path,
                    ts,
                    nonce,
                    hwid,
                    auth,
                )
            kwargs["headers"] = headers
        return super().request(method, url, **kwargs)


class BackendTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        backend_main.app.state.limiter.enabled = False
        cls.raw_client = TestClient(backend_main.app)
        cls.client = SignedTestClient(backend_main.app)

    @classmethod
    def tearDownClass(cls):
        if os.path.exists(_TEMP_DB_PATH):
            try:
                os.remove(_TEMP_DB_PATH)
            except OSError:
                pass

    def setUp(self):
        with contextlib.closing(sqlite3.connect(_TEMP_DB_PATH)) as conn:
            conn.execute("DELETE FROM users")
            conn.execute("DELETE FROM licenses")
            if conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='merge_jobs'"
            ).fetchone():
                conn.execute("DELETE FROM merge_jobs")
            conn.commit()
        backend_main._REPLAY_NONCES.clear()
        database.init_db()

    def _create_code(self, days: int, uses: int | None = None, key: str | None = None) -> str:
        argv = ["create", "--days", str(days)]
        if uses is not None:
            argv += ["--uses", str(uses)]
        if key is not None:
            argv += ["--key", key]
        out = io.StringIO()
        old_stdout = sys.stdout
        sys.stdout = out
        try:
            admin_keys.main(argv)
        finally:
            sys.stdout = old_stdout
        for line in out.getvalue().splitlines():
            if line.startswith("Redeem Code :"):
                return line.split(":", 1)[1].strip()
        raise AssertionError(f"Failed to parse generated code from CLI output:\n{out.getvalue()}")

    def _auth_headers(self, token: str, udid: str | None = None) -> dict[str, str]:
        h = {"Authorization": f"Bearer {token}"}
        if udid:
            h["X-HWID"] = udid
        return h

    def _signed_ota_blob(self, udid: str, product: str = "iPhone16,2", version: str = "21E219") -> bytes:
        xml_bytes = plistlib.dumps(
            {
                "UDID": udid,
                "PRODUCT": product,
                "VERSION": version,
            },
            fmt=plistlib.FMT_XML,
        )
        # Simulate Apple DER/CMS signature envelope around XML plist
        return b"\x30\x82\x09\x11\x06\x09\x2a\x86\x48\x86" + xml_bytes + b"\x04\x81\x99\xaa\xbb\xcc"

    def _verify_device(self, username: str, udid: str):
        return self.client.post(
            f"/api/v1/device/callback?username={username}",
            content=self._signed_ota_blob(udid),
            follow_redirects=False,
        )

    def test_v1_schema_auto_migration(self):
        fd, legacy_path = tempfile.mkstemp(prefix="legacy_v1_", suffix=".db")
        os.close(fd)
        old_path = database.DB_PATH
        try:
            with contextlib.closing(sqlite3.connect(legacy_path)) as conn:
                conn.execute(
                    """
                    CREATE TABLE licenses (
                        license_key TEXT PRIMARY KEY,
                        hwid TEXT,
                        expires_at INTEGER,
                        is_banned INTEGER DEFAULT 0,
                        max_uses INTEGER DEFAULT 9999,
                        used_count INTEGER DEFAULT 0
                    )
                    """
                )
                future_exp = int(time.time()) + 7 * 86400
                conn.execute(
                    "INSERT INTO licenses VALUES ('TOTOROX-OLD1-0001-0001', NULL, ?, 0, 9999, 0)",
                    (future_exp,),
                )
                conn.commit()
            database.DB_PATH = legacy_path
            database.init_db()
            with database.get_connection() as conn:
                user_cols = {r["name"] for r in conn.execute("PRAGMA table_info(users)")}
                self.assertTrue({"id", "username", "password_hash", "expires_at", "max_uses", "used_count", "daily_used", "daily_reset_date", "active_token", "hwid", "udid", "created_at"}.issubset(user_cols))
                lic_row = conn.execute("SELECT * FROM licenses WHERE license_key='TOTOROX-OLD1-0001-0001'").fetchone()
                self.assertEqual(lic_row["max_uses"], -1)
                self.assertIsNotNone(lic_row["duration_days"])
        finally:
            database.DB_PATH = old_path
            for suffix in ("", "-wal", "-shm"):
                p = legacy_path + suffix
                if os.path.exists(p):
                    try:
                        os.remove(p)
                    except OSError:
                        pass

    def test_admin_cli_and_daily_anti_spam_cap(self):
        # Mặc định 30 ngày = 300 lượt; dùng --uses -1 để test gói Vô hạn chạm anti-spam 300/ngày
        code_default_30d = self._create_code(days=30)
        with database.get_connection() as conn:
            row_30d = conn.execute(
                "SELECT max_uses FROM licenses WHERE license_key = ?",
                (code_default_30d,),
            ).fetchone()
            self.assertEqual(row_30d["max_uses"], 300)

        code = self._create_code(days=30, uses=-1, key="TOTOROX-CLI1-2222-3333")
        self.assertEqual(code, "TOTOROX-CLI1-2222-3333")
        udid = "00008110-0011223344556677"
        reg = self.client.post(
            "/api/v1/auth/register",
            json={"username": "spamcheck", "password": "password123"},
        ).json()
        token = reg["token"]
        uid = reg["user"]["id"]
        cb = self._verify_device("spamcheck", udid)
        self.assertEqual(cb.status_code, 301)
        red = self.client.post("/api/v1/auth/redeem", json={"code": code}, headers=self._auth_headers(token, udid))
        self.assertEqual(red.status_code, 200, red.text)
        today = database._today_utc()
        with database.get_connection() as conn:
            conn.execute(
                "UPDATE users SET daily_used = ?, daily_reset_date = ? WHERE id = ?",
                (database.DAILY_ANTI_SPAM_CAP, today, uid),
            )
        ok, status, _msg, _u = database.consume_user_usage(uid, 1)
        self.assertFalse(ok)
        self.assertEqual(status, 429)

        # Tài khoản gói giới hạn lượt (ví dụ 300 lượt) cũng bị chặn khi đạt 50 lượt/ngày
        reg2 = self.client.post(
            "/api/v1/auth/register",
            json={"username": "spamcheck_finite", "password": "password123"},
        ).json()
        uid2 = reg2["user"]["id"]
        self._verify_device("spamcheck_finite", "00008110-0011223344556688")
        red2 = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_default_30d},
            headers=self._auth_headers(reg2["token"], "00008110-0011223344556688"),
        )
        self.assertEqual(red2.status_code, 200, red2.text)
        self.assertEqual(red2.json()["user"]["daily_cap"], database.DAILY_ANTI_SPAM_CAP)
        with database.get_connection() as conn:
            conn.execute(
                "UPDATE users SET daily_used = ?, daily_reset_date = ? WHERE id = ?",
                (database.DAILY_ANTI_SPAM_CAP, today, uid2),
            )
        ok2, status2, _msg2, _u2 = database.consume_user_usage(uid2, 1)
        self.assertFalse(ok2)
        self.assertEqual(status2, 429)
        auth_ok, auth_status, _auth_msg, _auth_u = database.authenticate_token(
            reg2["token"],
            hwid="00008110-0011223344556688",
            require_active_plan=True,
            require_quota=True,
        )
        self.assertFalse(auth_ok)
        self.assertEqual(auth_status, 429)

        # CLI list / users smoke check
        buf = io.StringIO()
        old_out = sys.stdout
        sys.stdout = buf
        try:
            admin_keys.main(["list"])
            admin_keys.main(["users"])
        finally:
            sys.stdout = old_out
        cli_text = buf.getvalue()
        self.assertIn("REDEEMED", cli_text)
        self.assertIn("spamcheck", cli_text)

    def test_register_login_single_session_and_me(self):
        # Register user without hardware UDID yet
        r = self.client.post(
            "/api/v1/auth/register",
            json={"username": "player01", "password": "secret123"},
        )
        self.assertEqual(r.status_code, 200, r.text)
        data = r.json()
        self.assertTrue(data["ok"])
        token_a = data["token"]
        self.assertEqual(data["user"]["username"], "player01")
        self.assertFalse(data["user"]["has_active_plan"])
        self.assertFalse(data["user"]["is_udid_verified"])
        self.assertIsNone(data["user"]["udid"])
        self.assertIsNone(data["user"]["expires_at"])
        self.assertEqual(data["user"]["remaining_uses"], 0)

        # Duplicate username rejected (case-insensitive)
        dup = self.client.post(
            "/api/v1/auth/register",
            json={"username": "Player01", "password": "secret123"},
        )
        self.assertEqual(dup.status_code, 409)

        # Device A can call /auth/me before UDID binding
        me_a = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token_a))
        self.assertEqual(me_a.status_code, 200)
        self.assertEqual(me_a.json()["user"]["username"], "player01")

        # Device B logs in -> overwrites active_token and kicks Device A!
        login_b = self.client.post(
            "/api/v1/auth/login",
            json={"username": "player01", "password": "secret123"},
        )
        self.assertEqual(login_b.status_code, 200)
        token_b = login_b.json()["token"]
        self.assertNotEqual(token_a, token_b)

        kicked = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token_a))
        self.assertEqual(kicked.status_code, 401)

        me_b = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token_b))
        self.assertEqual(me_b.status_code, 200)

        # Bind hardware UDID via Apple OTA callback
        udid_real = "00008110-001234567890ABCD"
        cb = self._verify_device("player01", udid_real)
        self.assertEqual(cb.status_code, 301)

        # Calling /auth/me WITHOUT X-HWID masks UDID while reporting is_udid_verified=True
        me_masked = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token_b))
        self.assertEqual(me_masked.status_code, 200)
        self.assertTrue(me_masked.json()["user"]["is_udid_verified"])
        self.assertIsNone(me_masked.json()["user"]["udid"])

        # Calling /auth/me WITH matching X-HWID reveals verified UDID
        me_matched = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token_b, udid_real))
        self.assertEqual(me_matched.status_code, 200)
        self.assertEqual(me_matched.json()["user"]["udid"], udid_real)

        # Another device passing wrong UDID cannot log in or use /auth/me
        other_login = self.client.post(
            "/api/v1/auth/login",
            json={"username": "player01", "password": "secret123", "udid": "00008110-9999999999999999"},
        )
        self.assertEqual(other_login.status_code, 403)
        wrong_me = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token_b, "00008110-9999999999999999"))
        self.assertEqual(wrong_me.status_code, 403)

        # Wrong password -> 401
        bad_pw = self.client.post(
            "/api/v1/auth/login",
            json={"username": "player01", "password": "wrong"},
        )
        self.assertEqual(bad_pw.status_code, 401)

    def test_redeem_codes_and_accumulation(self):
        # Create 1d (default 5 uses), 7d (default 30 uses), 30d (default 300 uses), and explicit unlimited (-1)
        code_1d = self._create_code(days=1)
        code_1d_b = self._create_code(days=1)
        code_7d = self._create_code(days=7)
        code_30d = self._create_code(days=30)
        code_unlimited = self._create_code(days=30, uses=-1)

        with database.get_connection() as conn:
            r1 = conn.execute("SELECT max_uses, duration_days FROM licenses WHERE license_key=?", (code_1d,)).fetchone()
            r7 = conn.execute("SELECT max_uses, duration_days FROM licenses WHERE license_key=?", (code_7d,)).fetchone()
            r30 = conn.execute("SELECT max_uses, duration_days FROM licenses WHERE license_key=?", (code_30d,)).fetchone()
            r_unlim = conn.execute("SELECT max_uses, duration_days FROM licenses WHERE license_key=?", (code_unlimited,)).fetchone()
            self.assertEqual((r1["duration_days"], r1["max_uses"]), (1, 5))
            self.assertEqual((r7["duration_days"], r7["max_uses"]), (7, 30))
            self.assertEqual((r30["duration_days"], r30["max_uses"]), (30, 300))
            self.assertEqual((r_unlim["duration_days"], r_unlim["max_uses"]), (30, -1))

        udid = "00008110-000A111122223333"
        reg = self.client.post(
            "/api/v1/auth/register",
            json={"username": "alice", "password": "password123"},
        ).json()
        token = reg["token"]
        uid = reg["user"]["id"]

        # Redeem before UDID verification -> 403
        unverified_red = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_1d},
            headers=self._auth_headers(token, udid),
        )
        self.assertEqual(unverified_red.status_code, 403)

        # Verify device via Apple OTA callback
        self.assertEqual(self._verify_device("alice", udid).status_code, 301)

        # Redeem 1-day code (5 uses)
        red1 = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_1d},
            headers=self._auth_headers(token, udid),
        )
        self.assertEqual(red1.status_code, 200, red1.text)
        u1 = red1.json()["user"]
        self.assertTrue(u1["has_active_plan"])
        self.assertTrue(u1["is_udid_verified"])
        self.assertEqual(u1["udid"], udid)
        self.assertEqual(u1["remaining_uses"], 5)
        exp1 = u1["expires_at"]

        # Re-redeem same code -> 409
        again = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_1d},
            headers=self._auth_headers(token, udid),
        )
        self.assertEqual(again.status_code, 409)

        # Consume 2 uses -> 3 remaining
        database.consume_user_usage(uid, 2)

        # Second 1-day code on same user/UDID must be rejected with 409
        red2_blocked = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_1d_b},
            headers=self._auth_headers(token, udid),
        )
        self.assertEqual(red2_blocked.status_code, 409)

        # Redeem a 7-day code (5 uses) -> finite accumulation: 3 + 5 = 8 remaining, +7 days expiry!
        code_7d = self._create_code(days=7, uses=5)
        red2 = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_7d},
            headers=self._auth_headers(token, udid),
        )
        self.assertEqual(red2.status_code, 200)
        u2 = red2.json()["user"]
        self.assertEqual(u2["remaining_uses"], 8)
        self.assertGreaterEqual(u2["expires_at"], exp1 + 7 * 86400)
        exp2 = u2["expires_at"]

        # Redeem 30-day (default 300 uses) code -> accumulates 8 + 300 = 308 remaining uses and adds 30 days
        red3 = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_30d},
            headers=self._auth_headers(token, udid),
        )
        self.assertEqual(red3.status_code, 200)
        u3 = red3.json()["user"]
        self.assertEqual(u3["max_uses"], 308)
        self.assertEqual(u3["remaining_uses"], 308)
        self.assertGreaterEqual(u3["expires_at"], exp2 + 30 * 86400)
        exp3 = u3["expires_at"]

        # Redeem explicit unlimited (-1) code -> becomes unlimited (-1) and adds 30 days
        red_unlim = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_unlimited},
            headers=self._auth_headers(token, udid),
        )
        self.assertEqual(red_unlim.status_code, 200)
        u_unlim = red_unlim.json()["user"]
        self.assertEqual(u_unlim["max_uses"], -1)
        self.assertEqual(u_unlim["remaining_uses"], -1)
        self.assertGreaterEqual(u_unlim["expires_at"], exp3 + 30 * 86400)

        # Finite code added onto active unlimited plan keeps unlimited (-1)!
        code_7d_extra = self._create_code(days=7, uses=5)
        red4 = self.client.post(
            "/api/v1/auth/redeem",
            json={"code": code_7d_extra},
            headers=self._auth_headers(token, udid),
        )
        self.assertEqual(red4.status_code, 200)
        u4 = red4.json()["user"]
        self.assertEqual(u4["max_uses"], -1)
        self.assertEqual(u4["remaining_uses"], -1)

    def test_convert_header_and_merge_plan_usage_deduction(self):
        code = self._create_code(days=1, uses=1)
        udid = "00008110-000B111122224444"
        reg = self.client.post(
            "/api/v1/auth/register",
            json={"username": "bob", "password": "password123"},
        ).json()
        token = reg["token"]
        self.assertEqual(self._verify_device("bob", udid).status_code, 301)

        # Minimal manifest for to_zip
        manifest = {
            "schemaVersion": 3,
            "name": "TestPatch",
            "bundleIdentifiers": ["com.garena.game.kgvn"],
            "directories": [],
            "rules": [
                {
                    "bundleID": "com.garena.game.kgvn",
                    "relativePath": "Documents/Resources/1.64.1/Version.txt",
                    "replacementFilename": "Version.txt",
                    "payloadPath": "com.garena.game.kgvn/Documents/Resources/1.64.1/Version.txt",
                }
            ],
        }
        manifest_bytes = json.dumps(manifest).encode("utf-8")

        # Without active plan -> 403
        no_plan = self.client.post(
            "/api/v1/convert-header",
            headers=self._auth_headers(token, udid),
            data={"mode": "to_zip"},
            files={"file": ("manifest.json", manifest_bytes, "application/json")},
        )
        self.assertEqual(no_plan.status_code, 403)

        # Redeem 1-use code
        self.client.post("/api/v1/auth/redeem", json={"code": code}, headers=self._auth_headers(token, udid))

        # to_zip consumes 1 use and drops remaining_uses to 0 -> has_active_plan becomes False
        conv_ok = self.client.post(
            "/api/v1/convert-header",
            headers=self._auth_headers(token, udid),
            data={"mode": "to_zip"},
            files={"file": ("manifest.json", manifest_bytes, "application/json")},
        )
        self.assertEqual(conv_ok.status_code, 200, conv_ok.text)
        body = conv_ok.json()
        self.assertEqual(body["used_count"], 1)
        self.assertEqual(body["remaining_uses"], 0)
        self.assertFalse(body["has_active_plan"])

        # Second chargeable call hits 403 because quota exhausted
        exhausted = self.client.post(
            "/api/v1/convert-header",
            headers=self._auth_headers(token, udid),
            data={"mode": "to_zip"},
            files={"file": ("manifest.json", manifest_bytes, "application/json")},
        )
        self.assertEqual(exhausted.status_code, 403)

        # Missing/wrong X-HWID on merge-plan -> 403 even with active plan
        code_merge = self._create_code(days=7, uses=2)
        self.client.post("/api/v1/auth/redeem", json={"code": code_merge}, headers=self._auth_headers(token, udid))
        zbuf = io.BytesIO()
        with zipfile.ZipFile(zbuf, "w") as zf:
            zf.writestr("mod1/Documents/Resources/1.64.1/Ages/test.txt", b"hello")
        cfg = json.dumps({"mods": [{"name": "mod1", "paths": ["Documents/Resources/1.64.1/Ages/test.txt"]}], "target_version": "1.64.1"})

        no_hwid = self.client.post(
            "/api/v1/merge-plan",
            headers=self._auth_headers(token),
            data={"config_json": cfg},
            files={"file": ("config_bundle.zip", zbuf.getvalue(), "application/zip")},
        )
        self.assertEqual(no_hwid.status_code, 403)

        mp = self.client.post(
            "/api/v1/merge-plan",
            headers=self._auth_headers(token, udid),
            data={"config_json": cfg},
            files={"file": ("config_bundle.zip", zbuf.getvalue(), "application/zip")},
        )
        self.assertEqual(mp.status_code, 200, mp.text)
        mp_body = mp.json()
        self.assertTrue(mp_body["ok"])
        self.assertEqual(mp_body["used_count"], 1)
        self.assertEqual(mp_body["remaining_uses"], 1)

    def test_overwrite_plan_auth_expiry_free_quota_and_smart_mapping(self):
        udid = "00008110-000C111122225555"
        reg = self.client.post(
            "/api/v1/auth/register",
            json={"username": "modder", "password": "password123"},
        ).json()
        token = reg["token"]
        self.assertEqual(self._verify_device("modder", udid).status_code, 301)

        req_payload = {
            "source_paths": [
                "SkinNak/__MACOSX/._foo",
                "SkinNak/Documents/Resources/1.63.1/.DS_Store",
                "SkinNak/payload/com.garena.game.kgvn/Documents/Resources/1.63.1/Ages/Hero.bytes",
                "SkinNak/payload/com.garena.game.kgvn/Documents/Resources/1.63.1/Databin/Client/tiny.bytes",
                "SkinNak/payload/com.garena.game.kgvn/Documents/Resources/1.63.1/Databin/Client/valid.bytes",
                "SkinNak/payload/com.garena.game.kgvn/patch.json",
                "../escape.txt",
            ],
            "target_paths": [
                "Documents",
                "Documents/Resources",
                "Documents/Resources/1.64.1",
                "Documents/Resources/1.64.1/Ages",
                "Library",
            ],
            "target_bundle_id": "com.garena.game.kgvn",
            "target_subfolder": "",
            "source_sizes": {
                "SkinNak/payload/com.garena.game.kgvn/Documents/Resources/1.63.1/Databin/Client/tiny.bytes": 12,
                "SkinNak/payload/com.garena.game.kgvn/Documents/Resources/1.63.1/Databin/Client/valid.bytes": 128,
            },
        }

        # No plan -> 403
        r_no_plan = self.client.post("/api/v1/overwrite-plan", json=req_payload, headers=self._auth_headers(token, udid))
        self.assertEqual(r_no_plan.status_code, 403)

        # Redeem 1-day code (5 uses)
        code = self._create_code(days=1)
        self.client.post("/api/v1/auth/redeem", json={"code": code}, headers=self._auth_headers(token, udid))

        # Active plan -> 200, smart version matching (1.63.1 -> 1.64.1), junk + <32B Databin filtered!
        r_ok = self.client.post("/api/v1/overwrite-plan", json=req_payload, headers=self._auth_headers(token, udid))
        self.assertEqual(r_ok.status_code, 200, r_ok.text)
        res = r_ok.json()
        self.assertEqual(res["resolved_target_version"], "1.64.1")
        dest_map = {m["source"]: m["destination"] for m in res["mappings"]}
        self.assertEqual(
            dest_map,
            {
                "SkinNak/payload/com.garena.game.kgvn/Documents/Resources/1.63.1/Ages/Hero.bytes": "Documents/Resources/1.64.1/Ages/Hero.bytes",
                "SkinNak/payload/com.garena.game.kgvn/Documents/Resources/1.63.1/Databin/Client/valid.bytes": "Documents/Resources/1.64.1/Databin/Client/valid.bytes",
            },
        )
        self.assertIn("../escape.txt", res["skipped"])
        self.assertIn("SkinNak/payload/com.garena.game.kgvn/Documents/Resources/1.63.1/Databin/Client/tiny.bytes", res["skipped"])

        # Does NOT deduct used_count even after repeated calls!
        self.client.post("/api/v1/overwrite-plan", json=req_payload, headers=self._auth_headers(token, udid))
        me = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token, udid)).json()["user"]
        self.assertEqual(me["used_count"], 0)
        self.assertEqual(me["remaining_uses"], 5)

        # Exhaust finite quota (5/5 used) -> overwrite-plan also blocked with 403!
        database.consume_user_usage(me["id"], 5)
        r_exhausted = self.client.post("/api/v1/overwrite-plan", json=req_payload, headers=self._auth_headers(token, udid))
        self.assertEqual(r_exhausted.status_code, 403)
        me_exhausted = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token, udid)).json()["user"]
        self.assertFalse(me_exhausted["has_active_plan"])

        # Restore 1 use for subfolder check
        with database.get_connection() as conn:
            conn.execute("UPDATE users SET used_count = 4 WHERE id = ?", (me["id"],))

        # Subfolder Documents/Resources -> omits duplicate Documents/Resources prefix
        sub_res = self.client.post(
            "/api/v1/overwrite-plan",
            json={
                "source_paths": ["Documents/Resources/1.63.1/Ages/Hero.bytes", "AssetRefs/101.bytes"],
                "target_paths": ["1.64.1", "1.64.1/Ages"],
                "target_bundle_id": "com.garena.game.kgvn",
                "target_subfolder": "Documents/Resources",
            },
            headers=self._auth_headers(token, udid),
        ).json()
        self.assertEqual(
            {m["destination"] for m in sub_res["mappings"]},
            {"1.64.1/Ages/Hero.bytes", "1.64.1/AssetRefs/101.bytes"},
        )

        # Force plan expiration -> 403
        with database.get_connection() as conn:
            conn.execute("UPDATE users SET expires_at = ? WHERE username = 'modder'", (int(time.time()) - 10,))
        r_expired = self.client.post("/api/v1/overwrite-plan", json=req_payload, headers=self._auth_headers(token, udid))
        self.assertEqual(r_expired.status_code, 403)

    def test_device_ota_profile_callback_and_complete_html(self):
        self.client.post("/api/v1/auth/register", json={"username": "user1", "password": "password123"})
        self.client.post("/api/v1/auth/register", json={"username": "user2", "password": "password123"})

        # 1. Mobileconfig generation
        prof = self.client.get("/api/v1/device/profile?username=user1")
        self.assertEqual(prof.status_code, 200, prof.text)
        self.assertTrue(prof.headers["content-type"].startswith("application/x-apple-aspen-config"))
        self.assertIn("totorox_udid.mobileconfig", prof.headers.get("content-disposition", ""))
        parsed = plistlib.loads(prof.content)
        self.assertEqual(parsed["PayloadType"], "Profile Service")
        self.assertEqual(parsed["PayloadContent"]["DeviceAttributes"], ["UDID", "PRODUCT", "VERSION"])
        self.assertIn("/api/v1/device/callback?username=user1", parsed["PayloadContent"]["URL"])

        # 2. Apple OTA callback MUST return 301 redirect (never direct 200)
        udid1 = "00008110-001A2B3C4D5E6F70"
        cb_ok = self._verify_device("user1", udid1)
        self.assertEqual(cb_ok.status_code, 301)
        loc = cb_ok.headers["location"]
        q = parse_qs(urlparse(loc).query)
        self.assertEqual(q.get("status"), ["ok"])
        self.assertEqual(q.get("udid"), [udid1])

        # 3. Same UDID CAN bind to multiple accounts (1 device, multiple accounts)
        cb_shared = self._verify_device("user2", udid1)
        self.assertEqual(cb_shared.status_code, 301)
        q_shared = parse_qs(urlparse(cb_shared.headers["location"]).query)
        self.assertEqual(q_shared.get("status"), ["ok"])
        self.assertEqual(q_shared.get("udid"), [udid1])

        # 4. Mismatch: user1 cannot bind a different UDID without admin reset
        udid2 = "00008110-0099887766554433"
        cb_mismatch = self._verify_device("user1", udid2)
        self.assertEqual(cb_mismatch.status_code, 301)
        q_mismatch = parse_qs(urlparse(cb_mismatch.headers["location"]).query)
        self.assertEqual(q_mismatch.get("status"), ["mismatch"])

        # 5. Complete HTML page contains deep link + dark mode button
        done_page = self.client.get(f"/api/v1/device/complete?status=ok&udid={udid1}")
        self.assertEqual(done_page.status_code, 200)
        self.assertIn(f"totorox://udid-verified?status=ok&amp;udid={udid1}", done_page.text)
        self.assertIn("Mở lại ứng dụng Totorox", done_page.text)

        # 6. One-time claim token syncs UDID without requiring totorox:// URL scheme
        login1 = self.client.post("/api/v1/auth/login", json={"username": "user1", "password": "password123"}).json()
        claim_tok = "claim-test-12345678"
        prof_claim = self.client.get(f"/api/v1/device/profile?username=user1&claim={claim_tok}")
        self.assertEqual(prof_claim.status_code, 200)
        self.assertIn(f"claim={claim_tok}", plistlib.loads(prof_claim.content)["PayloadContent"]["URL"])
        cb_claim = self.client.post(
            f"/api/v1/device/callback?username=user1&claim={claim_tok}",
            content=self._signed_ota_blob(udid1),
            follow_redirects=False,
        )
        self.assertEqual(cb_claim.status_code, 301)
        claimed = self.client.get(
            f"/api/v1/device/claim?claim={claim_tok}",
            headers=self._auth_headers(login1["token"]),
        )
        self.assertEqual(claimed.status_code, 200)
        self.assertEqual(claimed.json(), {"ok": True, "udid": udid1})
        # One-time use: second claim returns ok=False
        claimed_again = self.client.get(
            f"/api/v1/device/claim?claim={claim_tok}",
            headers=self._auth_headers(login1["token"]),
        )
        self.assertEqual(claimed_again.json(), {"ok": False, "udid": None})

    def test_admin_reset_udid_and_subdomain_isolation(self):
        # Register & verify device
        reg = self.client.post("/api/v1/auth/register", json={"username": "resetme", "password": "password123"}).json()
        uid = reg["user"]["id"]
        token = reg["token"]
        old_udid = "00008110-0000111122223333"
        new_udid = "00008110-4444555566667777"
        self.assertEqual(self._verify_device("resetme", old_udid).status_code, 301)

        # Subdomain guard: api.totorox.io.vn MUST receive 404 on / and /admin/*
        api_root = self.client.get("/", headers={"Host": "api.totorox.io.vn"})
        api_admin = self.client.get("/admin/api/overview", headers={"Host": "api.totorox.io.vn"})
        self.assertEqual(api_root.status_code, 404)
        self.assertEqual(api_admin.status_code, 404)

        # Admin login on admin.totorox.io.vn & reset UDID
        admin_login = self.client.post(
            "/admin/api/login",
            json={"password": admin.ADMIN_PASSWORD},
            headers={"Host": "admin.totorox.io.vn"},
        )
        self.assertEqual(admin_login.status_code, 200, admin_login.text)
        admin_token = admin_login.json()["token"]

        reset_res = self.client.post(
            f"/admin/api/users/{uid}/reset-udid",
            headers={
                "Host": "admin.totorox.io.vn",
                "Authorization": f"Bearer {admin_token}",
            },
        )
        self.assertEqual(reset_res.status_code, 200, reset_res.text)

        # Old token invalidated and both udid + hwid cleared
        self.assertEqual(self.client.get("/api/v1/auth/me", headers=self._auth_headers(token, old_udid)).status_code, 401)
        user_row = database.get_user_by_username("resetme")
        self.assertIsNotNone(user_row)
        self.assertFalse(user_row["is_udid_verified"])
        self.assertIsNone(user_row["udid"])

        # Re-login and bind new hardware UDID succeeds
        relogin = self.client.post("/api/v1/auth/login", json={"username": "resetme", "password": "password123"}).json()
        cb_new = self._verify_device("resetme", new_udid)
        self.assertEqual(cb_new.status_code, 301)
        self.assertEqual(parse_qs(urlparse(cb_new.headers["location"]).query).get("status"), ["ok"])
        me_new = self.client.get("/api/v1/auth/me", headers=self._auth_headers(relogin["token"], new_udid)).json()["user"]
        self.assertTrue(me_new["is_udid_verified"])
        self.assertEqual(me_new["udid"], new_udid)

    def test_merge_plan_mses_md5_refresh_pkg_store_blob_aliases_and_partial_bundles(self):
        import base64
        import hashlib
        import struct
        import core_processor

        code = self._create_code(days=2, uses=10)
        udid = "00008110-000E111122229999"
        reg = self.client.post("/api/v1/auth/register", json={"username": "merger", "password": "password123"}).json()
        token = reg["token"]
        self.assertEqual(self._verify_device("merger", udid).status_code, 301)
        self.client.post("/api/v1/auth/redeem", json={"code": code}, headers=self._auth_headers(token, udid))

        def build_mses_bytes(records: list[tuple[int, bytes]], stale_md5: str) -> bytes:
            # 140-byte MSES header: b"MSES", v=1, max_rec, count, ..., md5 at 96:128
            hdr = bytearray(140)
            hdr[0:4] = b"MSES"
            struct.pack_into("<I", hdr, 4, 1)
            encoded_recs = []
            max_rec = 0
            for rid, body in records:
                rec = struct.pack("<II", 4 + len(body), rid) + body
                encoded_recs.append(rec)
                max_rec = max(max_rec, len(rec) - 4)
            struct.pack_into("<II", hdr, 8, max_rec, len(encoded_recs))
            hdr[96:128] = stale_md5.encode("ascii")
            return bytes(hdr) + b"".join(encoded_recs)

        def build_pkg_zip(entries: list[tuple[str, bytes]], compress_type: int, date_time=(2026, 1, 1, 0, 0, 0)) -> bytes:
            out = io.BytesIO()
            with zipfile.ZipFile(out, "w", compression=compress_type) as zf:
                for path, payload in entries:
                    zi = zipfile.ZipInfo(path, date_time)
                    zi.compress_type = compress_type
                    zf.writestr(zi, payload)
            return out.getvalue()

        hs_mod0 = core_processor.pg_encrypt(build_mses_bytes([(13101, b"AAAA_MURAD_131")], "0" * 32), "HeroSkin")
        hs_mod1 = core_processor.pg_encrypt(build_mses_bytes([(15001, b"BBBB_NAKROTH_150")], "f" * 32), "HeroSkin")

        # KernelLua & StableSystems: rank strictly by (is_mod, buildVersion, timestamp), NOT by 22 4A 67 EF magic
        kernel_old_jgef = build_pkg_zip(
            [("a.lua", b"\x22\x4a\x67\xef" + b"OLD_STOCK_JGEF")],
            zipfile.ZIP_DEFLATED,
            (2026, 10, 6, 11, 48, 26),
        )
        kernel_mod_raw = build_pkg_zip(
            [("a.lua", b"\x00\x00\x00\x00" + b"MODDED_LUA_WIN")],
            zipfile.ZIP_DEFLATED,
            (2026, 9, 29, 11, 27, 10),
        )
        stable_epoch_jgef = build_pkg_zip(
            [("s.lua", b"\x22\x4a\x67\xef" + b"UNMODDED_1980_JGEF")],
            zipfile.ZIP_DEFLATED,
            (1980, 1, 1, 0, 0, 0),
        )
        stable_mod_raw = build_pkg_zip(
            [("s.lua", b"\x4f\xe3\xa0\x0b" + b"MODDED_STABLE_WIN")],
            zipfile.ZIP_DEFLATED,
            (2026, 9, 29, 11, 26, 40),
        )
        heroinfo_pkg = build_pkg_zip([("b.lua", b"\x22\x4a\x67\xef" + b"HEROINFO")], zipfile.ZIP_DEFLATED)

        zbuf = io.BytesIO()
        with zipfile.ZipFile(zbuf, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.writestr("mod_0/Resources/1.64.1/version.txt", b"1.64.1.11|1789525\n")
            zf.writestr("mod_0/Resources/1.64.1/Databin/Client/HeroSkin.bytes", hs_mod0)
            zf.writestr("mod_0/Resources/1.64.1/KernelLua.pkg.bytes", kernel_old_jgef)
            zf.writestr("mod_0/Resources/1.64.1/StableSystems_3.pkg.bytes", stable_mod_raw)
            zf.writestr("mod_0/Resources/1.64.1/HeroInfoLua.pkg.bytes", heroinfo_pkg)
            zf.writestr("mod_1/Resources/1.64.1/version.txt", b"1.64.1.12|1793129\n")
            zf.writestr("mod_1/Resources/1.64.1/Databin/Client/HeroSkin.bytes", hs_mod1)
            zf.writestr("mod_1/Resources/1.64.1/KernelLua.pkg.bytes", kernel_mod_raw)
            zf.writestr("mod_1/Resources/1.64.1/StableSystems_3.pkg.bytes", stable_epoch_jgef)

        cfg = json.dumps({
            "mods": [
                {"name": "Murad.zip", "heroIDs": [131], "skinIDs": [], "explicitVersion": "1.64.1"},
                {"name": "Nakroth.zip", "heroIDs": [150], "skinIDs": [], "explicitVersion": "1.64.1"},
            ],
            "output": {"resourcesVersion": "1.64.1"},
            "blob_aliases": [
                {
                    "source_mod_index": 0,
                    "source_path": "Resources/1.64.1/HeroInfoLua.pkg.bytes",
                    "target_mod_index": 1,
                    "target_path": "Resources/1.64.1/HeroInfoLua.pkg.bytes",
                }
            ],
        })

        resp = self.client.post(
            "/api/v1/merge-plan",
            headers=self._auth_headers(token, udid),
            data={"config_json": cfg},
            files={"file": ("config_bundle.zip", zbuf.getvalue(), "application/zip")},
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        body = resp.json()
        self.assertTrue(body["ok"])
        bvs = body["merge_plan"]["bundle_versions"]
        self.assertEqual([b["build_number"] for b in bvs], [1789525, 1793129])

        outer = zipfile.ZipFile(io.BytesIO(base64.b64decode(body["zip_bytes_b64"])), "r")
        inner = zipfile.ZipFile(io.BytesIO(outer.read("result.zip")), "r")
        inner_names = {n.lower(): n for n in inner.namelist()}

        # version.txt prefers higher build version
        self.assertEqual(inner.read(inner_names["resources/1.64.1/version.txt"]).strip(), b"1.64.1.12|1793129")

        # Stale MSES MD5 must be refreshed to match merged payload
        merged_hs_dec = core_processor.pg_decrypt(
            inner.read(inner_names["resources/1.64.1/databin/client/heroskin.bytes"]),
            "HeroSkin",
        )
        parsed = core_processor.parse_mses(merged_hs_dec)
        self.assertIsNotNone(parsed)
        self.assertTrue(parsed["has_md5"])
        self.assertEqual({r[0] for r in parsed["recs"]}, {13101, 15001})
        actual_md5 = hashlib.md5(merged_hs_dec[140:]).hexdigest().lower().encode("ascii")
        self.assertEqual(merged_hs_dec[96:128].lower(), actual_md5)

        # KernelLua, StableSystems_3 & HeroInfoLua must use (is_mod, build_vk, ts) & keep inner ZIP_STORED (0)
        for pkg_key in (
            "resources/1.64.1/kernellua.pkg.bytes",
            "resources/1.64.1/stablesystems_3.pkg.bytes",
            "resources/1.64.1/heroinfolua.pkg.bytes",
        ):
            pkg_zf = zipfile.ZipFile(io.BytesIO(inner.read(inner_names[pkg_key])), "r")
            self.assertTrue(all(i.compress_type == zipfile.ZIP_STORED for i in pkg_zf.infolist()))
        k_zf = zipfile.ZipFile(io.BytesIO(inner.read(inner_names["resources/1.64.1/kernellua.pkg.bytes"])), "r")
        self.assertEqual(k_zf.read("a.lua"), b"\x00\x00\x00\x00" + b"MODDED_LUA_WIN")
        s_zf = zipfile.ZipFile(io.BytesIO(inner.read(inner_names["resources/1.64.1/stablesystems_3.pkg.bytes"])), "r")
        self.assertEqual(s_zf.read("s.lua"), b"\x4f\xe3\xa0\x0b" + b"MODDED_STABLE_WIN")

        # Server pg_encrypt output must follow standard PKCS#7 padding (every pad byte == pad_len, incl. 16B aligned)
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.backends import default_backend
        hs_raw = inner.read(inner_names["resources/1.64.1/databin/client/heroskin.bytes"])
        self.assertEqual(hs_raw[:4], b"\x22\x4a\x67\x00")
        dec_tf = Cipher(
            algorithms.AES(core_processor.derive_pkg_key("HeroSkin")),
            modes.CBC(core_processor._AES128_CBC_IV),
            backend=default_backend(),
        ).decryptor()
        padded_pt = dec_tf.update(hs_raw[8:]) + dec_tf.finalize()
        pad_val = padded_pt[-1]
        self.assertIn(pad_val, range(1, 17))
        self.assertEqual(padded_pt[-pad_val:], bytes([pad_val]) * pad_val)

        # Empty config_bundle with 2 asset-only mods still preserves both mods & valid result.zip
        empty_zip = io.BytesIO()
        with zipfile.ZipFile(empty_zip, "w", compression=zipfile.ZIP_STORED):
            pass
        cfg_empty = json.dumps({
            "mods": [
                {"name": "Edras_AssetOnly.zip", "heroIDs": [595], "explicitVersion": "1.64.1"},
                {"name": "Tulen_AssetOnly.zip", "heroIDs": [190], "explicitVersion": "1.64.1"},
            ],
            "output": {"resourcesVersion": "1.64.1"},
        })
        resp_empty = self.client.post(
            "/api/v1/merge-plan",
            headers=self._auth_headers(token, udid),
            data={"config_json": cfg_empty},
            files={"file": ("config_bundle.zip", empty_zip.getvalue(), "application/zip")},
        )
        self.assertEqual(resp_empty.status_code, 200, resp_empty.text)
        empty_body = resp_empty.json()
        self.assertTrue(empty_body["merge_plan"]["output_filename"].startswith("AOV_Mod_2Heroes_"))
        self.assertEqual(len(empty_body["merge_plan"]["loaded_mods"]), 2)
        outer_empty = zipfile.ZipFile(io.BytesIO(base64.b64decode(empty_body["zip_bytes_b64"])), "r")
        self.assertIn("result.zip", outer_empty.namelist())

        # Partial config_bundle: mod_0 asset-only (omitted from zip) + mod_1 has config
        part_zip = io.BytesIO()
        with zipfile.ZipFile(part_zip, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.writestr("mod_1/Resources/1.64.1/version.txt", b"1.64.1.12|1793129\n")
        resp_part = self.client.post(
            "/api/v1/merge-plan",
            headers=self._auth_headers(token, udid),
            data={"config_json": cfg_empty},
            files={"file": ("config_bundle.zip", part_zip.getvalue(), "application/zip")},
        )
        self.assertEqual(resp_part.status_code, 200, resp_part.text)
        part_body = resp_part.json()
        self.assertTrue(part_body["merge_plan"]["output_filename"].startswith("AOV_Mod_2Heroes_"))
        self.assertEqual(len(part_body["merge_plan"]["loaded_mods"]), 2)
        self.assertEqual(len(part_body["merge_plan"]["bundle_versions"]), 2)

    def test_aes128_pkcs7_padding_and_generic_pkg_ranking_edge_cases(self):
        import struct
        import core_processor
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.backends import default_backend

        # 1. Exact 16-byte multiple AND every remainder 1..15 must emit standard PKCS#7 padding (bytes([pad]) * pad)
        for plain_len in list(range(1, 18)) + [32, 48]:
            plain = bytes((i % 251) for i in range(plain_len))
            enc = core_processor.pg_encrypt(plain, "heroSkin")
            self.assertEqual(enc[:4], b"\x22\x4a\x67\x00")
            self.assertEqual(struct.unpack_from("<I", enc, 4)[0], plain_len)
            key = core_processor.derive_pkg_key("heroSkin")
            tf = Cipher(algorithms.AES(key), modes.CBC(core_processor._AES128_CBC_IV), backend=default_backend()).decryptor()
            raw_pt = tf.update(enc[8:]) + tf.finalize()
            expected_pad = 16 - (plain_len % 16)
            self.assertEqual(raw_pt, plain + (bytes([expected_pad]) * expected_pad))
            self.assertEqual(core_processor.pg_decrypt(enc, "heroSkin"), plain)

        # 2. Equal vk & both modified -> newer DOS timestamp wins even when older entry starts with 22 4A 67 EF
        def mk_pkg(name: str, data: bytes, dt: tuple[int, ...]) -> bytes:
            b = io.BytesIO()
            with zipfile.ZipFile(b, "w", compression=zipfile.ZIP_STORED) as zf:
                zf.writestr(zipfile.ZipInfo(name, dt), data)
            return b.getvalue()

        vk = ((1, 64, 1, 12), 1793129, "1.64.1.12")
        older_jgef = mk_pkg("Lua_Signed/test.bytes", b"\x22\x4a\x67\xefOLDER", (2026, 9, 28, 10, 0, 0))
        newer_raw = mk_pkg("Lua_Signed/test.bytes", b"\x00\x00\x00\x00NEWER_MOD", (2026, 9, 29, 10, 0, 0))
        merged = core_processor.merge_generic_pkg([(vk, older_jgef), (vk, newer_raw)])
        with zipfile.ZipFile(io.BytesIO(merged), "r") as zout:
            self.assertEqual(zout.read("Lua_Signed/test.bytes"), b"\x00\x00\x00\x00NEWER_MOD")

    def test_web_admin_30d_300_quota_key_actions_and_extend(self):
        admin_login = self.client.post(
            "/admin/api/login",
            json={"password": admin.ADMIN_PASSWORD},
            headers={"Host": "admin.totorox.io.vn"},
        )
        self.assertEqual(admin_login.status_code, 200, admin_login.text)
        admin_headers = {
            "Host": "admin.totorox.io.vn",
            "Authorization": f"Bearer {admin_login.json()['token']}",
        }

        # 30-day auto mode generates max_uses = 300
        gen30 = self.client.post(
            "/admin/api/keys/generate",
            headers=admin_headers,
            json={"count": 2, "prefix": "VIP", "days": 30, "uses_mode": "auto", "note": "Goi 30d"},
        )
        self.assertEqual(gen30.status_code, 200, gen30.text)
        gen30_body = gen30.json()
        self.assertEqual(gen30_body["max_uses"], 300)
        self.assertEqual(len(gen30_body["keys"]), 2)
        self.assertTrue(all(k.startswith("VIP-") for k in gen30_body["keys"]))

        # Explicit unlimited still returns -1
        gen_unlim = self.client.post(
            "/admin/api/keys/generate",
            headers=admin_headers,
            json={"count": 1, "prefix": "TOTOROX-", "days": 30, "uses_mode": "unlimited", "note": "Test unlim"},
        )
        self.assertEqual(gen_unlim.status_code, 200, gen_unlim.text)
        self.assertEqual(gen_unlim.json()["max_uses"], -1)

        # List, revoke, unrevoke, and permanent delete via Web Admin API
        listed = self.client.get("/admin/api/keys?status=unused&search=Goi", headers=admin_headers)
        self.assertEqual(listed.status_code, 200)
        self.assertEqual(len(listed.json()["keys"]), 2)
        self.assertTrue(all(k["max_uses"] == 300 for k in listed.json()["keys"]))

        k1 = gen30_body["keys"][0]
        self.assertEqual(
            self.client.post(f"/admin/api/keys/{k1}/action", headers=admin_headers, json={"action": "revoke"}).status_code,
            200,
        )
        self.assertEqual(
            self.client.post(f"/admin/api/keys/{k1}/action", headers=admin_headers, json={"action": "unrevoke"}).status_code,
            200,
        )
        self.assertEqual(
            self.client.post(f"/admin/api/keys/{k1}/action", headers=admin_headers, json={"action": "delete"}).status_code,
            200,
        )
        with database.get_connection() as conn:
            self.assertIsNone(conn.execute("SELECT 1 FROM licenses WHERE license_key = ?", (k1,)).fetchone())

        # Extend new user +30 days -> receives 300 uses automatically
        reg = self.client.post("/api/v1/auth/register", json={"username": "ext30", "password": "password123"}).json()
        uid = reg["user"]["id"]
        ext = self.client.post(
            f"/admin/api/users/{uid}/extend",
            headers=admin_headers,
            json={"add_days": 30, "uses_action": "keep", "add_uses": 0},
        )
        self.assertEqual(ext.status_code, 200, ext.text)
        self.assertEqual(ext.json()["user"]["max_uses"], 300)
        self.assertEqual(ext.json()["user"]["remaining_uses"], 300)

        ext_add = self.client.post(
            f"/admin/api/users/{uid}/extend",
            headers=admin_headers,
            json={"add_days": 0, "uses_action": "add", "add_uses": 50},
        )
        self.assertEqual(ext_add.status_code, 200, ext_add.text)
        self.assertEqual(ext_add.json()["user"]["max_uses"], 350)

        ext_unlim = self.client.post(
            f"/admin/api/users/{uid}/extend",
            headers=admin_headers,
            json={"add_days": 0, "uses_action": "set_unlimited", "add_uses": 0},
        )
        self.assertEqual(ext_unlim.status_code, 200, ext_unlim.text)
        self.assertEqual(ext_unlim.json()["user"]["max_uses"], -1)

    def test_admin_cli_synced_commands_and_html_ui(self):
        def run_cli(*argv: str) -> str:
            buf = io.StringIO()
            old_out = sys.stdout
            sys.stdout = buf
            try:
                admin_keys.main(list(argv))
            finally:
                sys.stdout = old_out
            return buf.getvalue()

        # Batch create with prefix + note + default 30d (300 uses)
        out_batch = run_cli("create", "--count", "2", "--prefix", "PRO", "--days", "30", "--note", "Khach B")
        self.assertIn("300 lượt", out_batch)
        keys_created = [
            line.split("Redeem Code :", 1)[1].strip()
            for line in out_batch.splitlines()
            if "Redeem Code :" in line
        ]
        self.assertEqual(len(keys_created), 2)
        self.assertTrue(all(k.startswith("PRO-") for k in keys_created))

        # Explicit --unlimited flag
        out_unlim = run_cli("create", "--days", "30", "--unlimited", "--key", "TOTOROX-UNL0-0001-0002")
        self.assertIn("Vô hạn", out_unlim)

        # Ban -> list --status revoked -> unban -> delete
        run_cli("ban", "--key", keys_created[0])
        revoked_list = run_cli("list", "--status", "revoked", "--search", "Khach B")
        self.assertIn(keys_created[0], revoked_list)
        self.assertIn("REVOKED", revoked_list)

        run_cli("unban", "--key", keys_created[0])
        unused_list = run_cli("list", "--status", "unused", "--search", keys_created[0])
        self.assertIn("UNUSED", unused_list)

        del_out = run_cli("delete", "--key", keys_created[0])
        self.assertIn("Đã xóa vĩnh viễn", del_out)
        with database.get_connection() as conn:
            self.assertIsNone(
                conn.execute("SELECT 1 FROM licenses WHERE license_key = ?", (keys_created[0],)).fetchone()
            )

        # Register + verify user, then test overview, ban-user, reset-udid, extend
        reg = self.client.post("/api/v1/auth/register", json={"username": "clitest", "password": "password123"}).json()
        token = reg["token"]
        udid = "00008110-00AA112233445566"
        self.assertEqual(self._verify_device("clitest", udid).status_code, 301)

        over_out = run_cli("overview")
        self.assertIn("TỔNG QUAN HỆ THỐNG TOTOROX", over_out)

        run_cli("extend", "--user", "clitest", "--days", "30")
        u_after_30 = database.get_user_by_username("clitest")
        self.assertEqual(u_after_30["max_uses"], 300)
        self.assertEqual(u_after_30["remaining_uses"], 300)

        run_cli("extend", "--user", "clitest", "--add-uses", "50")
        self.assertEqual(database.get_user_by_username("clitest")["max_uses"], 350)

        database.consume_user_usage(u_after_30["id"], 3)
        run_cli("extend", "--user", "clitest", "--reset-used")
        self.assertEqual(database.get_user_by_username("clitest")["used_count"], 0)

        run_cli("extend", "--user", "clitest", "--set-unlimited")
        self.assertEqual(database.get_user_by_username("clitest")["max_uses"], -1)

        # Ban user clears session token, unban unlocks
        run_cli("ban-user", "--user", "clitest")
        self.assertTrue(database.get_user_by_username("clitest")["is_banned"])
        self.assertEqual(self.client.get("/api/v1/auth/me", headers=self._auth_headers(token, udid)).status_code, 401)
        self.assertIn("BANNED", run_cli("users", "--status", "banned", "--search", "clitest"))
        run_cli("ban-user", "--user", "clitest", "--unban")
        self.assertFalse(database.get_user_by_username("clitest")["is_banned"])

        # reset-udid clears verified udid
        run_cli("reset-udid", "--user", "clitest")
        self.assertIsNone(database.get_user_by_username("clitest")["udid"])

        # admin.html displays 300 uses for 30-day plan
        html_path = os.path.join(BACKEND_DIR, "admin.html")
        with open(html_path, "r", encoding="utf-8") as fh:
            html_src = fh.read()
        self.assertIn("30 ngày (300 lượt)", html_src)
        self.assertIn("300 lượt (Tự động)", html_src)
        self.assertNotIn("30 ngày (Không giới hạn)", html_src)
        self.assertNotIn("Vô hạn lượt (Tự động)", html_src)

    def test_api_hmac_signing_replay_and_tamper_protection(self):
        udid = "00008110-00CC112233445566"
        reg = self.client.post(
            "/api/v1/auth/register",
            json={"username": "hmacuser", "password": "password123"},
        )
        self.assertEqual(reg.status_code, 200, reg.text)
        token = reg.json()["token"]
        self.assertEqual(self._verify_device("hmacuser", udid).status_code, 301)

        # 1. Missing HMAC headers -> 403
        missing = self.raw_client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {token}", "X-HWID": udid},
        )
        self.assertEqual(missing.status_code, 403)

        # 2. Invalid signature -> 403
        now_ts = str(int(time.time()))
        bad_sig = self.raw_client.get(
            "/api/v1/auth/me",
            headers={
                "Authorization": f"Bearer {token}",
                "X-HWID": udid,
                "X-Timestamp": now_ts,
                "X-Nonce": "nonce_bad_sig_01",
                "X-Signature": "0" * 64,
            },
        )
        self.assertEqual(bad_sig.status_code, 403)

        # 3. Expired timestamp (> 60s skew) -> 403
        stale_ts = str(int(time.time()) - 120)
        stale_nonce = "nonce_stale_0001"
        stale_sig = backend_main.compute_api_hmac_signature(
            "GET", "/api/v1/auth/me", stale_ts, stale_nonce, udid, f"Bearer {token}"
        )
        stale_resp = self.raw_client.get(
            "/api/v1/auth/me",
            headers={
                "Authorization": f"Bearer {token}",
                "X-HWID": udid,
                "X-Timestamp": stale_ts,
                "X-Nonce": stale_nonce,
                "X-Signature": stale_sig,
            },
        )
        self.assertEqual(stale_resp.status_code, 403)

        # 4. Tampering X-HWID after signing -> 403
        tamper_nonce = "nonce_tamper_001"
        tamper_sig = backend_main.compute_api_hmac_signature(
            "GET", "/api/v1/auth/me", now_ts, tamper_nonce, udid, f"Bearer {token}"
        )
        tamper_resp = self.raw_client.get(
            "/api/v1/auth/me",
            headers={
                "Authorization": f"Bearer {token}",
                "X-HWID": "00008110-9999999999999999",
                "X-Timestamp": now_ts,
                "X-Nonce": tamper_nonce,
                "X-Signature": tamper_sig,
            },
        )
        self.assertEqual(tamper_resp.status_code, 403)

        # 5. Valid signed request succeeds (200), then exact replay is blocked (403)
        ok_nonce = "nonce_valid_0001"
        ok_sig = backend_main.compute_api_hmac_signature(
            "GET", "/api/v1/auth/me", now_ts, ok_nonce, udid, f"Bearer {token}"
        )
        valid_headers = {
            "Authorization": f"Bearer {token}",
            "X-HWID": udid,
            "X-Timestamp": now_ts,
            "X-Nonce": ok_nonce,
            "X-Signature": ok_sig,
        }
        first_call = self.raw_client.get("/api/v1/auth/me", headers=valid_headers)
        self.assertEqual(first_call.status_code, 200, first_call.text)
        replay_call = self.raw_client.get("/api/v1/auth/me", headers=valid_headers)
        self.assertEqual(replay_call.status_code, 403)

        # 6. Heavy upload paths (/api/v1/merge-plan) allow up to 300s skew (e.g. 120s),
        # while timestamps beyond 300s (e.g. 360s) remain rejected with 403.
        license_key = self._create_code(days=30, uses=-1)
        redeem = self.client.post(
            "/api/v1/auth/redeem",
            headers=self._auth_headers(token, udid),
            json={"code": license_key, "udid": udid},
        )
        self.assertEqual(redeem.status_code, 200, redeem.text)

        slow_ts = str(int(time.time()) - 120)
        slow_nonce = "nonce_upload_120s"
        slow_sig = backend_main.compute_api_hmac_signature(
            "POST", "/api/v1/merge-plan", slow_ts, slow_nonce, udid, f"Bearer {token}"
        )
        empty_zip = io.BytesIO()
        with zipfile.ZipFile(empty_zip, "w", compression=zipfile.ZIP_DEFLATED):
            pass
        slow_resp = self.raw_client.post(
            "/api/v1/merge-plan",
            headers={
                "Authorization": f"Bearer {token}",
                "X-HWID": udid,
                "X-Timestamp": slow_ts,
                "X-Nonce": slow_nonce,
                "X-Signature": slow_sig,
            },
            data={"config_json": json.dumps({"mods": []})},
            files={"file": ("config_bundle.zip", empty_zip.getvalue(), "application/zip")},
        )
        self.assertEqual(slow_resp.status_code, 200, slow_resp.text)

        expired_upload_ts = str(int(time.time()) - 360)
        expired_upload_nonce = "nonce_upload_360s"
        expired_upload_sig = backend_main.compute_api_hmac_signature(
            "POST", "/api/v1/merge-plan", expired_upload_ts, expired_upload_nonce, udid, f"Bearer {token}"
        )
        expired_upload_resp = self.raw_client.post(
            "/api/v1/merge-plan",
            headers={
                "Authorization": f"Bearer {token}",
                "X-HWID": udid,
                "X-Timestamp": expired_upload_ts,
                "X-Nonce": expired_upload_nonce,
                "X-Signature": expired_upload_sig,
            },
            data={"config_json": json.dumps({"mods": []})},
            files={"file": ("config_bundle.zip", empty_zip.getvalue(), "application/zip")},
        )
        self.assertEqual(expired_upload_resp.status_code, 403)

    def test_mod_store_admin_upload_and_quota_download(self):
        from pathlib import Path
        orig_dir = database.MOD_STORAGE_DIR
        tmp_mods = tempfile.TemporaryDirectory()
        database.MOD_STORAGE_DIR = Path(tmp_mods.name)
        backend_main.MOD_STORAGE_DIR = Path(tmp_mods.name)
        admin.MOD_STORAGE_DIR = Path(tmp_mods.name)
        try:
            admin_login = self.client.post(
                "/admin/api/login",
                headers={"Host": "admin.totorox.io.vn"},
                json={"password": admin.ADMIN_PASSWORD},
            )
            self.assertEqual(admin_login.status_code, 200)
            admin_headers = {
                "Host": "admin.totorox.io.vn",
                "Authorization": f"Bearer {admin_login.json()['token']}",
            }

            zbuf = io.BytesIO()
            with zipfile.ZipFile(zbuf, "w") as zf:
                zf.writestr("Resources/1.64.1/version.txt", b"1.64.1.12|1")
            zip_bytes = zbuf.getvalue()

            up = self.client.post(
                "/admin/api/mods/upload",
                headers=admin_headers,
                data={
                    "name": "Murad Thien Luan",
                    "hero_name": "Murad",
                    "skin_name": "Thien Luan",
                    "hero_id": "131",
                    "resource_version": "1.64.1",
                    "category": "skin",
                },
                files={"file": ("murad_131.zip", zip_bytes, "application/zip")},
            )
            self.assertEqual(up.status_code, 200, up.text)
            mod_id = up.json()["mod"]["id"]

            udid = "00008110-00AA112233445566"
            reg = self.client.post("/api/v1/auth/register", json={"username": "modbuyer", "password": "password123"}).json()
            token = reg["token"]
            self.assertEqual(self._verify_device("modbuyer", udid).status_code, 301)
            code = self._create_code(days=7, uses=2)
            self.client.post("/api/v1/auth/redeem", json={"code": code}, headers=self._auth_headers(token, udid))

            cat = self.client.get("/api/v1/mods", headers=self._auth_headers(token, udid))
            self.assertEqual(cat.status_code, 200)
            self.assertEqual(len(cat.json()["mods"]), 1)

            dl = self.client.post(
                "/api/v1/mods/download",
                json={"mod_id": mod_id, "udid": udid},
                headers=self._auth_headers(token, udid),
            )
            self.assertEqual(dl.status_code, 200)
            self.assertEqual(dl.content, zip_bytes)
            self.assertEqual(dl.headers.get("X-Totorox-Remaining-Uses"), "1")

            me = self.client.get("/api/v1/auth/me", headers=self._auth_headers(token, udid)).json()["user"]
            self.assertEqual(me["remaining_uses"], 1)

            # Toggle hide -> 404 for user download, then delete
            tog = self.client.post(f"/admin/api/mods/{mod_id}/toggle", headers=admin_headers, json={"is_active": False})
            self.assertEqual(tog.status_code, 200)
            dl_hidden = self.client.post(
                "/api/v1/mods/download",
                json={"mod_id": mod_id, "udid": udid},
                headers=self._auth_headers(token, udid),
            )
            self.assertEqual(dl_hidden.status_code, 404)

            rem = self.client.delete(f"/admin/api/mods/{mod_id}", headers=admin_headers)
            self.assertEqual(rem.status_code, 200)
        finally:
            database.MOD_STORAGE_DIR = orig_dir
            backend_main.MOD_STORAGE_DIR = orig_dir
            admin.MOD_STORAGE_DIR = orig_dir
            tmp_mods.cleanup()

    def test_async_merge_queue_submit_poll_result_and_isolation(self):
        udid_a = "00008110-0011223344556677"
        udid_b = "00008110-008899AABBCCDDEE"
        reg_a = self.client.post("/api/v1/auth/register", json={"username": "queuea", "password": "password123"}).json()
        tok_a = reg_a["token"]
        self.assertEqual(self._verify_device("queuea", udid_a).status_code, 301)
        code_a = self._create_code(days=7, uses=1)
        self.assertEqual(
            self.client.post("/api/v1/auth/redeem", json={"code": code_a}, headers=self._auth_headers(tok_a, udid_a)).status_code,
            200,
        )

        reg_b = self.client.post("/api/v1/auth/register", json={"username": "queueb", "password": "password123"}).json()
        tok_b = reg_b["token"]
        self.assertEqual(self._verify_device("queueb", udid_b).status_code, 301)
        code_b = self._create_code(days=7, uses=5)
        self.assertEqual(
            self.client.post("/api/v1/auth/redeem", json={"code": code_b}, headers=self._auth_headers(tok_b, udid_b)).status_code,
            200,
        )

        zbuf = io.BytesIO()
        with zipfile.ZipFile(zbuf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("mod_0/Resources/1.64.1/version.txt", b"1.64.1.12|1793129\n")
            zf.writestr("mod_1/Resources/1.64.1/version.txt", b"1.64.1.12|1793129\n")

        cfg = json.dumps({
            "mods": [
                {"name": "ModA.zip", "heroIDs": [131], "explicitVersion": "1.64.1"},
                {"name": "ModB.zip", "heroIDs": [150], "explicitVersion": "1.64.1"},
            ],
            "output": {"resourcesVersion": "1.64.1"},
        })
        sub = self.client.post(
            "/api/v1/merge-plan/jobs",
            headers=self._auth_headers(tok_a, udid_a),
            data={"config_json": cfg, "udid": udid_a},
            files={"file": ("config_bundle.zip", zbuf.getvalue(), "application/zip")},
        )
        self.assertEqual(sub.status_code, 200, sub.text)
        job_id = sub.json()["job_id"]

        # IDOR protection: user B cannot poll or download user A's job
        idor_poll = self.client.get(
            f"/api/v1/merge-plan/jobs?job_id={job_id}",
            headers=self._auth_headers(tok_b, udid_b),
        )
        self.assertEqual(idor_poll.status_code, 404)

        status_payload = None
        for _ in range(40):
            poll = self.client.get(
                f"/api/v1/merge-plan/jobs?job_id={job_id}",
                headers=self._auth_headers(tok_a, udid_a),
            )
            self.assertEqual(poll.status_code, 200, poll.text)
            body = poll.json()
            if body["status"] in ("done", "failed"):
                status_payload = body
                break
            time.sleep(0.05)

        self.assertIsNotNone(status_payload)
        self.assertEqual(status_payload["status"], "done", status_payload)
        self.assertTrue(status_payload["has_result_zip"])
        self.assertEqual(status_payload["remaining_uses"], 0)
        self.assertEqual(status_payload["used_count"], 1)

        # Even with remaining_uses == 0 after job completion, user A can still download their paid result!
        dl = self.client.get(
            f"/api/v1/merge-plan/jobs/result?job_id={job_id}",
            headers=self._auth_headers(tok_a, udid_a),
        )
        self.assertEqual(dl.status_code, 200, dl.text)
        outer = zipfile.ZipFile(io.BytesIO(dl.content), "r")
        self.assertIn("merge_plan.json", outer.namelist())
        self.assertIn("result.zip", outer.namelist())

        # User B submits corrupted ZIP with PK magic -> job fails (400) and user B loses 0 quota
        bad_sub = self.client.post(
            "/api/v1/merge-plan/jobs",
            headers=self._auth_headers(tok_b, udid_b),
            data={"config_json": cfg, "udid": udid_b},
            files={"file": ("config_bundle.zip", b"PK\x03\x04CORRUPT_ZIP", "application/zip")},
        )
        self.assertEqual(bad_sub.status_code, 200, bad_sub.text)
        bad_id = bad_sub.json()["job_id"]
        bad_payload = None
        for _ in range(40):
            poll = self.client.get(
                f"/api/v1/merge-plan/jobs?job_id={bad_id}",
                headers=self._auth_headers(tok_b, udid_b),
            )
            self.assertEqual(poll.status_code, 200, poll.text)
            if poll.json()["status"] in ("done", "failed"):
                bad_payload = poll.json()
                break
            time.sleep(0.05)

        self.assertIsNotNone(bad_payload)
        self.assertEqual(bad_payload["status"], "failed")
        self.assertEqual(bad_payload["error_code"], 400)
        me_b = self.client.get("/api/v1/auth/me", headers=self._auth_headers(tok_b, udid_b)).json()["user"]
        self.assertEqual(me_b["remaining_uses"], 5)
        self.assertEqual(me_b["used_count"], 0)

        # Chunked upload: split valid zip into 2 chunks, block user A from hijacking user B's upload_id,
        # assemble in /api/v1/merge-plan/jobs, verify done + 1 quota deducted.
        uid = "abcdef1234567890abcdef1234567890"
        zip_raw = zbuf.getvalue()
        mid = len(zip_raw) // 2
        c0 = self.client.post(
            "/api/v1/merge-plan/chunks",
            headers=self._auth_headers(tok_b, udid_b),
            data={"upload_id": uid, "chunk_index": "0", "total_chunks": "2", "udid": udid_b},
            files={"chunk": ("part0.bin", zip_raw[:mid], "application/octet-stream")},
        )
        self.assertEqual(c0.status_code, 200, c0.text)

        # IDOR protection: user A cannot overwrite user B's upload_id (user A has 0 quota left anyway, use another user or check 403/429)
        c_hijack = self.client.post(
            "/api/v1/merge-plan/chunks",
            headers=self._auth_headers(tok_a, udid_a),
            data={"upload_id": uid, "chunk_index": "1", "total_chunks": "2", "udid": udid_a},
            files={"chunk": ("part1.bin", zip_raw[mid:], "application/octet-stream")},
        )
        self.assertIn(c_hijack.status_code, (403, 429))

        c1 = self.client.post(
            "/api/v1/merge-plan/chunks",
            headers=self._auth_headers(tok_b, udid_b),
            data={"upload_id": uid, "chunk_index": "1", "total_chunks": "2", "udid": udid_b},
            files={"chunk": ("part1.bin", zip_raw[mid:], "application/octet-stream")},
        )
        self.assertEqual(c1.status_code, 200, c1.text)

        sub_chunked = self.client.post(
            "/api/v1/merge-plan/jobs",
            headers=self._auth_headers(tok_b, udid_b),
            data={"upload_id": uid, "total_chunks": "2", "config_json": cfg, "udid": udid_b},
        )
        self.assertEqual(sub_chunked.status_code, 200, sub_chunked.text)
        chunked_job_id = sub_chunked.json()["job_id"]
        chunked_done = None
        for _ in range(40):
            p = self.client.get(
                f"/api/v1/merge-plan/jobs?job_id={chunked_job_id}",
                headers=self._auth_headers(tok_b, udid_b),
            )
            self.assertEqual(p.status_code, 200, p.text)
            if p.json()["status"] in ("done", "failed"):
                chunked_done = p.json()
                break
            time.sleep(0.05)

        self.assertIsNotNone(chunked_done)
        self.assertEqual(chunked_done["status"], "done", chunked_done)
        self.assertEqual(chunked_done["accepted_bytes"], len(zip_raw))
        self.assertEqual(chunked_done["remaining_uses"], 4)

    def test_merge_camera_height_with_skin_mod_preserves_both_and_orders(self):
        import re
        import core_processor

        def build_pkg_with_dates(items: list[tuple[str, bytes, tuple[int, ...]]]) -> bytes:
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_STORED) as zf:
                for path, payload, dt in items:
                    zf.writestr(zipfile.ZipInfo(path, dt), payload)
            return buf.getvalue()

        stock_blue = (
            b'\xef\xbb\xbf<?xml version="1.0" encoding="utf-8"?>\r\n'
            b'<Project>\r\n  <Action tag="" length="1.000">\r\n'
            b'    <Track trackName="CheckSkinIdVirtualTick0" eventType="CheckSkinIdVirtualTick" guid="8828ae1e-da5b-47ea-a2a9-057e6582a306">\r\n'
            b'      <Event eventName="CheckSkinIdVirtualTick"><int name="skinId" value="15009" /></Event>\r\n'
            b'    </Track>\r\n  </Action>\r\n</Project>'
        )
        mod_blue = (
            b'<Project><Action tag="" length="1.000">'
            b'<Track trackName="CheckHeroIdTick0" eventType="CheckHeroIdTick" guid="8828ae1e-da5b-47ea-a2a9-057e6582a306">'
            b'<Event eventName="CheckHeroIdTick"><int name="heroId" value="150" /></Event>'
            b'</Track></Action></Project>'
        )
        stock_sprint = (
            b'<?xml version="1.0" encoding="utf-8"?>\r\n<Project>\r\n  <Action>\r\n'
            b'    <Track trackName="PlayAnim0" eventType="PlayAnimationTick" guid="11111111-1111-1111-1111-111111111111">\r\n'
            b'      <Event><String name="clipName" value="Sprint_end" /></Event>\r\n'
            b'    </Track>\r\n  </Action>\r\n</Project>'
        )
        mod_sprint = (
            b'<Project><Action>'
            b'<Track trackName="PlayAnim0" eventType="PlayAnimationTick" guid="11111111-1111-1111-1111-111111111111">'
            b'<Event><String name="clipName" value="11620/Awaken/Dance16_Sprint_end" /></Event>'
            b'</Track></Action></Project>'
        )
        stock_born_pretty = b'<?xml version="1.0" encoding="utf-8"?>\r\n<Project>\r\n  <Action>\r\n    <Track trackName="B0" eventType="HitTriggerTick" guid="22222222-2222-2222-2222-222222222222"></Track>\r\n  </Action>\r\n</Project>'
        mod_born_min = b'<Project><Action><Track trackName="B0" eventType="HitTriggerTick" guid="22222222-2222-2222-2222-222222222222"></Track></Action></Project>'

        jm_base = (
            '<Project><Action tag="" length="1.000" loop="false">'
            '<Track trackName="HitTriggerTick0" eventType="HitTriggerTick" guid="8e943844-af73-4d04-8860-1f87daa8a258"></Track>'
            '{extra}</Action></Project>'
        )
        cam_track = (
            '<Track trackName="SetCameraHeightDuration0" eventType="SetCameraHeightDuration" guid="9489c796-894b-4c2e-9a95-acf27873964a">'
            '<Event eventName="SetCameraHeightDuration" time="0.000" length="1.000">'
            '<float name="heightRate" value="{rate}" /></Event></Track>'
        )

        jm_skin = jm_base.format(extra="").encode("utf-8")
        jm_cam5 = jm_base.format(extra=cam_track.format(rate="1.155")).encode("utf-8")
        jm_cam20 = jm_base.format(extra=cam_track.format(rate="1.320")).encode("utf-8")
        jm_cam10 = jm_base.format(extra=cam_track.format(rate="1.210")).encode("utf-8")

        dt_mod = (2026, 11, 17, 7, 15, 0)
        dt_stock = (1980, 1, 1, 0, 0, 0)
        vk = core_processor.ver_key((1, 64, 1, 13), 1802180)

        ca_skin = build_pkg_with_dates([
            ("PassiveResource/BlueBuff.xml", mod_blue, dt_mod),
            ("commonresource/DaofengSprint.xml", mod_sprint, dt_mod),
            ("commonresource/Born.xml", mod_born_min, dt_mod),
            ("PassiveResource/junglemark.xml", jm_skin, dt_mod),
        ])
        ca_cam20 = build_pkg_with_dates([
            ("PassiveResource/BlueBuff.xml", stock_blue, dt_stock),
            ("commonresource/DaofengSprint.xml", stock_sprint, dt_stock),
            ("commonresource/Born.xml", stock_born_pretty, dt_stock),
            ("PassiveResource/junglemark.xml", jm_cam20, dt_mod),
        ])
        ca_cam5 = build_pkg_with_dates([
            ("PassiveResource/BlueBuff.xml", stock_blue, dt_mod),
            ("commonresource/DaofengSprint.xml", stock_sprint, dt_mod),
            ("PassiveResource/junglemark.xml", jm_cam5, dt_mod),
        ])
        ca_cam10 = build_pkg_with_dates([
            ("PassiveResource/junglemark.xml", jm_cam10, dt_mod),
        ])
        ca_skin_bundled_cam20 = build_pkg_with_dates([
            ("PassiveResource/BlueBuff.xml", mod_blue, dt_mod),
            ("PassiveResource/junglemark.xml", jm_cam20, dt_mod),
        ])

        # 1. Merging skin mod + cam20 preserves skin XMLs verbatim AND injects heightRate 1.320 in both orders
        for inputs in [
            [({116, 150}, vk, ca_skin), (set(), vk, ca_cam20)],
            [(set(), vk, ca_cam20), ({116, 150}, vk, ca_skin)],
        ]:
            merged_raw = core_processor.merge_common_actions(inputs)
            with zipfile.ZipFile(io.BytesIO(merged_raw), "r") as zf:
                self.assertIn(b"CheckHeroIdTick", zf.read("PassiveResource/BlueBuff.xml"))
                self.assertIn(b"11620/Awaken/Dance16_Sprint_end", zf.read("commonresource/DaofengSprint.xml"))
                self.assertEqual(zf.read("commonresource/Born.xml"), mod_born_min)
                jm_txt = zf.read("PassiveResource/junglemark.xml").decode("utf-8")
                self.assertIn('value="1.320"', jm_txt)

        # 2. Even if repacked with mod timestamps on stock files, whitespace normalization + hero affinity preserves skin mod
        for inputs in [
            [({116, 150}, vk, ca_skin), (set(), vk, ca_cam5)],
            [(set(), vk, ca_cam5), ({116, 150}, vk, ca_skin)],
        ]:
            merged_raw = core_processor.merge_common_actions(inputs)
            with zipfile.ZipFile(io.BytesIO(merged_raw), "r") as zf:
                self.assertIn(b"CheckHeroIdTick", zf.read("PassiveResource/BlueBuff.xml"))
                self.assertIn(b"11620/Awaken/Dance16_Sprint_end", zf.read("commonresource/DaofengSprint.xml"))
                self.assertIn('value="1.155"', zf.read("PassiveResource/junglemark.xml").decode("utf-8"))

        # 3. Multiple cam mods pick higher heightRate deterministically regardless of order
        for inputs in [[(set(), vk, ca_cam5), (set(), vk, ca_cam20)], [(set(), vk, ca_cam20), (set(), vk, ca_cam5)]]:
            merged_raw = core_processor.merge_common_actions(inputs)
            with zipfile.ZipFile(io.BytesIO(merged_raw), "r") as zf:
                hrs = re.findall(r'heightRate" value="([^"]+)"', zf.read("PassiveResource/junglemark.xml").decode("utf-8"))
                self.assertEqual(hrs, ["1.320"])

        # 4. Standalone global cam10 overrides cam20 bundled inside a skin mod in both orders
        for inputs in [
            [({150}, vk, ca_skin_bundled_cam20), (set(), vk, ca_cam10)],
            [(set(), vk, ca_cam10), ({150}, vk, ca_skin_bundled_cam20)],
        ]:
            merged_raw = core_processor.merge_common_actions(inputs)
            with zipfile.ZipFile(io.BytesIO(merged_raw), "r") as zf:
                hrs = re.findall(r'heightRate" value="([^"]+)"', zf.read("PassiveResource/junglemark.xml").decode("utf-8"))
                self.assertEqual(hrs, ["1.210"])
                self.assertIn(b"CheckHeroIdTick", zf.read("PassiveResource/BlueBuff.xml"))

        # 5. Dynamic cam xa works on any XML filename (e.g., commonresource/Born.xml), arbitrary rate (1.450), even with 1980 timestamp
        born_cam = (
            '<Project><Action><Track trackName="B0" eventType="HitTriggerTick" guid="22222222-2222-2222-2222-222222222222"></Track>'
            + cam_track.format(rate="1.450")
            + "</Action></Project>"
        ).encode("utf-8")
        ca_born_cam_1980 = build_pkg_with_dates([
            ("commonresource/Born.xml", born_cam, dt_stock),
        ])
        for inputs in [
            [({116, 150}, vk, ca_skin), (set(), vk, ca_born_cam_1980)],
            [(set(), vk, ca_born_cam_1980), ({116, 150}, vk, ca_skin)],
        ]:
            merged_raw = core_processor.merge_common_actions(inputs)
            with zipfile.ZipFile(io.BytesIO(merged_raw), "r") as zf:
                born_txt = zf.read("commonresource/Born.xml").decode("utf-8")
                self.assertIn('value="1.450"', born_txt)
                self.assertIn("HitTriggerTick", born_txt)

        # 6. languageMap.txt replaces Kiana Tip_WaterMark_Str with Totorox branding while preserving CR delimiter
        lm_kiana = b"other_key = A\\nB\rTip_WaterMark_Str = MOD BY KIANA MOD AOV\rtail_key = OK"
        out_name, out_files, _, _ = core_processor.run_merge([
            {
                "name": "mod33.zip",
                "explicit_ver": "1.64.1",
                "raw_files": {
                    "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                    "Resources/1.64.1/Languages/VN_Garena_VN/languageMap.txt": lm_kiana,
                },
            },
            {
                "name": "cam.zip",
                "explicit_ver": "1.64.1",
                "raw_files": {
                    "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                },
            },
        ])
        self.assertTrue(out_name.endswith(".zip"))
        lm_out = out_files["Resources/1.64.1/Languages/VN_Garena_VN/languageMap.txt"]
        self.assertEqual(
            lm_out,
            (
                "other_key = A\\nB\r"
                "Tip_WaterMark_Str = Mod pack được tạo bởi Totorox • Phát triển bởi VannHoc\r"
                "tail_key = OK"
            ).encode("utf-8"),
        )

    def test_zmod_zero_timestamp_xml_and_battleeffect_and_rp_append(self):
        import struct
        import core_processor

        # 1. BattleEffect 5-digit suffix IDs like 29599 match hero 599
        self.assertTrue(core_processor.rid_matches_any_hero(29599, {599}, "BattleEffect"))
        self.assertFalse(core_processor.rid_matches_any_hero(29599, {599}, "heroSkin"))

        # 2. ZMOD-style mod with 1980-01-01 timestamps still preserves its hero 599 tracks when merged with Kiana mod
        def mk_pkg(items):
            b = io.BytesIO()
            with zipfile.ZipFile(b, "w", compression=zipfile.ZIP_STORED) as zf:
                for path, payload, dt in items:
                    zf.writestr(zipfile.ZipInfo(path, dt), payload)
            return b.getvalue()

        back_kiana = (
            b'<Project><Action>'
            b'<Track trackName="T150" eventType="CheckSkinIdVirtualTick" guid="aaaa0000-0000-0000-0000-000000000001"><SkinOrAvatarList id="15009" /></Track>'
            b'</Action></Project>'
        )
        back_zmod = (
            b'<Project><Action>'
            b'<Track trackName="T150" eventType="CheckSkinIdVirtualTick" guid="aaaa0000-0000-0000-0000-000000000001"></Track>'
            b'<Track trackName="Billow_Hero599" eventType="CheckHeroIdTick" guid="bbbb0000-0000-0000-0000-000000000599"><Event><int name="heroId" value="599" /></Event></Track>'
            b'</Action></Project>'
        )
        vk = core_processor.ver_key((1, 64, 1, 13), 1802180)
        ca_kiana = mk_pkg([("commonresource/Back.xml", back_kiana, (2026, 11, 17, 7, 15, 0))])
        ca_zmod = mk_pkg([("commonresource/Back.xml", back_zmod, (1980, 1, 1, 0, 0, 0))])

        merged_ca = core_processor.merge_common_actions([({150}, vk, ca_kiana), ({599}, vk, ca_zmod)])
        with zipfile.ZipFile(io.BytesIO(merged_ca), "r") as zf:
            merged_back = zf.read("commonresource/Back.xml").decode("utf-8")
            self.assertIn("15009", merged_back)
            self.assertIn("Billow_Hero599", merged_back)

        # 3. ResourcePacker appends new records + dependency pairs and shifts Unity SerializedFile v22 ObjectInfo offsets
        def build_unityfs_rp(records: list[tuple[str, bytes]], pairs: list[tuple[int, int]]) -> bytes:
            marker = b"\x18\x00\x00\x00ResourcePackerInfoSetXML"
            ver_blk = struct.pack("<I", 9) + b"1.64.1.12\x00\x00\x00" + struct.pack("<I", 7) + b"1793129\x00"
            # Minimal SF v22 metadata: 0 types, 2 objects (Obj[0]=RP, Obj[1]=Tail)
            sf_pre = bytearray(48)
            struct.pack_into(">I", sf_pre, 8, 22)
            sf_meta = sf_pre + b"2022.3.5f1\x00" + struct.pack("<IBI", 9, 0, 0)
            obj_cnt_off = len(sf_meta)
            sf_meta += struct.pack("<I", 2)
            obj0_off = (len(sf_meta) + 3) & ~3
            sf_meta.extend(b"\x00" * (obj0_off - len(sf_meta) + 48))
            data_off = (len(sf_meta) + 15) & ~15
            sf_meta.extend(b"\x00" * (data_off - len(sf_meta)))
            struct.pack_into(">Q", sf_meta, 32, data_off)

            rp_body = bytearray(marker + ver_blk + marker + struct.pack("<I", len(records)))
            for path, hash_bytes in records:
                pb = path.encode("utf-8")
                rp_body += struct.pack("<I", len(pb)) + pb + b"\x00" * ((4 - len(pb) % 4) % 4)
                rp_body += b"\x00" * 12 + struct.pack("<II", 0, 0) + struct.pack("<I", 1) + hash_bytes
            rp_body += struct.pack("<I", len(pairs))
            for a, b in pairs:
                rp_body += struct.pack("<II", a, b)

            rp_bstart = 0
            rp_bsize = len(rp_body)
            pad = (8 - (rp_bsize % 8)) % 8
            tail_bstart = rp_bsize + pad
            tail_body = b"TAILOBJ012345678"
            payload = bytearray(sf_meta) + rp_body + (b"\x00" * pad) + tail_body
            struct.pack_into("<qQII", payload, obj0_off, 100, rp_bstart, rp_bsize, 1)
            struct.pack_into("<qQII", payload, obj0_off + 24, 200, tail_bstart, len(tail_body), 2)
            struct.pack_into(">Q", payload, 24, len(payload))

            comp_payload = core_processor.lz4_compress_raw_fast(bytes(payload))
            info_raw = b"\x00" * 16 + struct.pack(">IHHII", 1, 2, 0, len(comp_payload), len(payload)) + b"\x00" * 61
            tail_info = core_processor.lz4_compress_raw_fast(info_raw)
            hdr = bytearray(b"UnityFS\x00\x00\x00\x00\x075.x.x\x002022.3.5f1\x00")
            spos = len(hdr)
            hdr += struct.pack(">QIII", 0, len(tail_info), len(info_raw), 0x00C2)
            while len(hdr) % 16:
                hdr.append(0)
            total_sz = len(hdr) + len(comp_payload) + len(tail_info)
            struct.pack_into(">Q", hdr, spos, total_sz)
            return bytes(hdr) + comp_payload + tail_info

        h_entry = b"\x00" * 8 + struct.pack("<I", 4) + b"abcd"
        rp_a = build_unityfs_rp([("a.ab", h_entry), ("b.ab", h_entry)], [(0, 1)])
        rp_b = build_unityfs_rp([("a.ab", h_entry), ("z_new.ab", h_entry)], [(0, 1)])
        merged_rp = core_processor.merge_resource_packer([rp_a, rp_b])
        u_out = core_processor.unpack_unityfs(merged_rp)
        p_out = core_processor.parse_rpack(u_out)
        self.assertEqual(p_out["rec_cnt"], 3)
        self.assertIn("z_new.ab", p_out["recs"])
        self.assertEqual(set(p_out["pairs_by_path"]), {("a.ab", "b.ab"), ("a.ab", "z_new.ab")})
        doff, sf_objs = core_processor._parse_unity_sf_objects(bytes(u_out["payload"]))
        self.assertEqual(doff + sf_objs[1]["byteStart"] + sf_objs[1]["byteSize"], len(u_out["payload"]))

    def test_mses_mismatched_record_count_and_truncated_tail(self):
        import hashlib
        import struct
        import core_processor

        def make_mses(records: list[tuple[int, bytes]], header_cnt: int | None = None, trailing: bytes = b"") -> bytes:
            recs_bytes = b"".join(struct.pack("<II", 4 + len(body), rid) + body for rid, body in records)
            payload = recs_bytes + trailing
            hdr = bytearray(140)
            hdr[:4] = b"MSES"
            mx = max([4 + len(body) for _, body in records] + [40])
            struct.pack_into("<II", hdr, 8, mx, header_cnt if header_cnt is not None else len(records))
            hdr[96:128] = hashlib.md5(payload).hexdigest().encode("ascii")
            return bytes(hdr) + payload

        # 1. Header declares cnt=5 (higher than actual 3 records at clean EOF), like Nak.zip organSkin.bytes
        bad_cnt_plain = make_mses([(1, b"AAAA" * 8), (2, b"BBBB" * 8), (5, b"CCCC" * 8)], header_cnt=5)
        parsed = core_processor.parse_mses(bad_cnt_plain)
        self.assertIsNotNone(parsed)
        self.assertEqual([r[0] for r in parsed["recs"]], [1, 2, 5])
        self.assertEqual(parsed["ftr"], b"")

        # Merging with a valid base repairs count & MD5 and preserves all records
        valid_base_plain = make_mses([(1, b"AAAA" * 8), (2, b"BBBB" * 8), (10, b"DDDD" * 8)])
        vk = core_processor.ver_key((1, 64, 1, 13), 1802180)
        merged_enc = core_processor.merge_databin_mses(
            "organSkin",
            [
                ({150}, vk, core_processor.pg_encrypt(bad_cnt_plain, "organSkin")),
                ({151}, vk, core_processor.pg_encrypt(valid_base_plain, "organSkin")),
            ],
        )
        merged_dec = core_processor.pg_decrypt(merged_enc, "organSkin")
        _, repaired_cnt = struct.unpack_from("<II", merged_dec, 8)
        self.assertEqual(repaired_cnt, 4)
        self.assertEqual(
            merged_dec[96:128].decode("ascii"),
            hashlib.md5(merged_dec[140:]).hexdigest(),
        )
        re_parsed = core_processor.parse_mses(merged_dec)
        self.assertEqual({r[0] for r in re_parsed["recs"]}, {1, 2, 5, 10})

        # 2. Truncated partial trailing record stops cleanly without corrupting ftr
        trunc_plain = make_mses([(1, b"AAAA"), (2, b"BBBB")], header_cnt=3, trailing=b"\x20\x00\x00\x00\x03\x00")
        parsed_trunc = core_processor.parse_mses(trunc_plain)
        self.assertIsNotNone(parsed_trunc)
        self.assertEqual([r[0] for r in parsed_trunc["recs"]], [1, 2])
        self.assertEqual(parsed_trunc["ftr"], b"")

        # 3. Unparseable first record with cnt > 0 returns None
        corrupt_first = make_mses([], header_cnt=2, trailing=b"\x02\x00\x00\x00\x01\x00\x00\x00")
        self.assertIsNone(core_processor.parse_mses(corrupt_first))

    def test_kiana_lua_popup_sanitization_born_skinidarray_rp_resize_and_bundle_families(self):
        import hashlib
        import struct
        import core_processor

        def mk_pkg(items: list[tuple[str, bytes]]) -> bytes:
            b = io.BytesIO()
            with zipfile.ZipFile(b, "w", compression=zipfile.ZIP_STORED) as zf:
                for path, payload in items:
                    zf.writestr(zipfile.ZipInfo(path, (2026, 11, 17, 8, 0, 0)), payload)
            return b.getvalue()

        def build_unityfs_rp(ver_str: str, build_str: str, records: list[tuple[str, list[bytes]]], pairs: list[tuple[int, int]]) -> bytes:
            marker = b"\x18\x00\x00\x00ResourcePackerInfoSetXML"
            vb = ver_str.encode("utf-8")
            bb = build_str.encode("utf-8")
            ver_blk = (
                struct.pack("<I", len(vb)) + vb + (b"\x00" * ((4 - len(vb) % 4) % 4))
                + struct.pack("<I", len(bb)) + bb + (b"\x00" * ((4 - len(bb) % 4) % 4))
            )
            sf_pre = bytearray(48)
            struct.pack_into(">I", sf_pre, 8, 22)
            sf_meta = sf_pre + b"2022.3.5f1\x00" + struct.pack("<IBI", 9, 0, 0)
            sf_meta += struct.pack("<I", 2)
            obj0_off = (len(sf_meta) + 3) & ~3
            sf_meta.extend(b"\x00" * (obj0_off - len(sf_meta) + 48))
            data_off = (len(sf_meta) + 15) & ~15
            sf_meta.extend(b"\x00" * (data_off - len(sf_meta)))
            struct.pack_into(">Q", sf_meta, 32, data_off)

            rp_body = bytearray(marker + ver_blk + marker + struct.pack("<I", len(records)))
            for path, hash_entries in records:
                pb = path.encode("utf-8")
                rp_body += struct.pack("<I", len(pb)) + pb + (b"\x00" * ((4 - len(pb) % 4) % 4))
                rp_body += b"\x00" * 12 + struct.pack("<II", 0, 0) + struct.pack("<I", len(hash_entries))
                for he in hash_entries:
                    rp_body += he
            rp_body += struct.pack("<I", len(pairs))
            for a, b in pairs:
                rp_body += struct.pack("<II", a, b)

            rp_bsize = len(rp_body)
            pad = (8 - (rp_bsize % 8)) % 8
            tail_bstart = rp_bsize + pad
            tail_body = b"TAILOBJ_VERIFY16"
            payload = bytearray(sf_meta) + rp_body + (b"\x00" * pad) + tail_body
            struct.pack_into("<qQII", payload, obj0_off, 100, 0, rp_bsize, 1)
            struct.pack_into("<qQII", payload, obj0_off + 24, 200, tail_bstart, len(tail_body), 2)
            struct.pack_into(">Q", payload, 24, len(payload))

            comp_payload = core_processor.lz4_compress_raw_fast(bytes(payload))
            info_raw = b"\x00" * 16 + struct.pack(">IHHII", 1, 2, 0, len(comp_payload), len(payload)) + b"\x00" * 61
            tail_info = core_processor.lz4_compress_raw_fast(info_raw)
            hdr = bytearray(b"UnityFS\x00\x00\x00\x00\x075.x.x\x002022.3.5f1\x00")
            spos = len(hdr)
            hdr += struct.pack(">QIII", 0, len(tail_info), len(info_raw), 0x00C2)
            while len(hdr) % 16:
                hdr.append(0)
            total_sz = len(hdr) + len(comp_payload) + len(tail_info)
            struct.pack_into(">Q", hdr, spos, total_sz)
            return bytes(hdr) + comp_payload + tail_info

        # Fake Lua 5.3 bytecode containing FixReset (_0x242424) + Kiana popup (_0x237912319231723827 + raw github URL)
        fake_util_lua = (
            b"\x00" * 128
            + b"\x1bLuaS\x00\x19\x93\r\n\x1a\n"
            + b"\x04\x0a_0x242424"
            + b"\x04\x16_0x237912319231723827"
            + b"\x14Shttps://raw.githubusercontent.com/Nedier000/huhuhuhuhuhuhuh/refs/heads/main/la.txt"
        )
        kl_pkg = mk_pkg([("Lua_Signed/Kernel/Util/xlua/util_lua.bytes", fake_util_lua)])

        born_base = (
            b'<Project><Action>'
            b'<Track trackName="Anim3" eventType="CheckSkinIdVirtualTick" guid="809a9bd8-3c15-4e38-b057-d411f965e4e9">'
            b'<Event eventName="CheckSkinIdVirtualTick"><Array name="skinIdArray" type="int">'
            b'<int value="12912" /><int value="59901" />'
            b'</Array></Event></Track></Action></Project>'
        )
        born_bilow = (
            b'<Project><Action>'
            b'<Track trackName="Anim3" eventType="CheckSkinIdVirtualTick" guid="809a9bd8-3c15-4e38-b057-d411f965e4e9">\n'
            b'  <Event eventName="CheckSkinIdVirtualTick">\n'
            b'    <Array name="skinIdArray" type="int">\n'
            b'      <int value="12912"/>\n'
            b'      <int value="59901"/>\n'
            b'      <int value="59900"/>\n'
            b'    </Array>\n'
            b'  </Event>\n'
            b'</Track></Action></Project>'
        )

        he1 = b"\x11" * 8 + struct.pack("<I", 4) + b"a1.x"
        he2 = b"\x22" * 8 + struct.pack("<I", 4) + b"a2.x"
        rp_bilow = build_unityfs_rp(
            "1.64.1.12",
            "1793129",
            [
                ("Ages/Prefab_Characters/Prefab_Hero/Actor_599_Actions.pkg.bytes", [he1, he2]),
                ("assetbundle/inner_game_effect/inner_game_effect_r_48.assetbundle", [he1]),
            ],
            [(0, 1)],
        )
        rp_nak = build_unityfs_rp(
            "1.64.1.13",
            "1802180",
            [
                ("Ages/Prefab_Characters/Prefab_Hero/Actor_599_Actions.pkg.bytes", [he1]),
                ("assetbundle/inner_game_effect/inner_game_effect_r_48.assetbundle", [he1, he2]),
                ("assetbundle/extra_164113.assetbundle", [he1]),
            ],
            [(0, 1)],
        )

        fake_hs1_plain = b"Project.Plugins_d\x00kernellua.pkg.bytes " + (b"0" * 32) + b"\x00"
        fake_hs1_enc = core_processor.pg_encrypt(fake_hs1_plain, "HeroSkin_1")

        _, out_files, _, _ = core_processor.run_merge([
            {
                "name": "Bilow.zip",
                "explicit_ver": "1.64.1",
                "seed_hids": [599],
                "raw_files": {
                    "Resources/1.64.1/version.txt": b"1.64.1.12|1793129",
                    "Resources/1.64.1/KernelLua.pkg.bytes": kl_pkg,
                    "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes": mk_pkg([("commonresource/Born.xml", born_bilow)]),
                    "Resources/1.64.1/AssetBundle/ResourcePackerInfoSetAll.assetbundle": rp_bilow,
                    "Resources/1.64.1/assetbundle/uisystem/battle/battlecommon.assetbundle": b"BILOW_COMMON",
                    "Resources/1.64.1/assetbundle/uisystem/battle/battlecommon_raw.assetbundle": b"BILOW_COMMON_RAW",
                    "Resources/1.64.1/assetbundle/uisystem/battle/battleotherui.assetbundle": b"BILOW_OTHER",
                    "Resources/1.64.1/assetbundle/uisystem/battle/battleotherui_raw.assetbundle": b"BILOW_OTHER_RAW",
                    "Resources/1.64.1/Sound/iOS/UI.bnk": b"BILOW_UI_BNK",
                },
            },
            {
                "name": "Edras.zip",
                "explicit_ver": "1.64.1",
                "seed_hids": [595],
                "raw_files": {
                    "Resources/1.64.1/version.txt": b"1.64.1.12|1793129",
                    "Resources/1.64.1/KernelLua.pkg.bytes": kl_pkg,
                    "Resources/1.64.1/assetbundle/uisystem/atlas/primary/allshared.assetbundle": b"EDRAS_ALLSHARED",
                    "Resources/1.64.1/assetbundle/uisystem/battle/battlecommon_raw.assetbundle": b"EDRAS_COMMON_RAW",
                    "Resources/1.64.1/assetbundle/uisystem/battle/battleotherui.assetbundle": b"EDRAS_OTHER",
                },
            },
            {
                "name": "Nak.zip",
                "explicit_ver": "1.64.1",
                "seed_hids": [150],
                "raw_files": {
                    "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                    "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes": mk_pkg([("commonresource/Born.xml", born_base)]),
                    "Resources/1.64.1/AssetBundle/ResourcePackerInfoSetAll.assetbundle": rp_nak,
                    "Resources/1.64.1/Thanos/HeroSkin_1.bytes": fake_hs1_enc,
                },
            },
        ])

        low_out = {k.lower(): v for k, v in out_files.items()}

        # 1. KernelLua popup sanitized without changing byte length, MD5 refreshed inside HeroSkin_1
        kl_out = low_out["resources/1.64.1/kernellua.pkg.bytes"]
        with zipfile.ZipFile(io.BytesIO(kl_out), "r") as zkl:
            u_clean = zkl.read("Lua_Signed/Kernel/Util/xlua/util_lua.bytes")
            self.assertEqual(len(u_clean), len(fake_util_lua))
            self.assertIn(b"_0x242424", u_clean)
            self.assertNotIn(b"_0x237912319231723827", u_clean)
            self.assertNotIn(b"raw.githubusercontent.com", u_clean)
        kl_md5 = hashlib.md5(kl_out).hexdigest().lower().encode("ascii")
        hs1_out_dec = core_processor.pg_decrypt(low_out["resources/1.64.1/thanos/heroskin_1.bytes"], "HeroSkin_1")
        self.assertIn(b"kernellua.pkg.bytes " + kl_md5, hs1_out_dec.lower())

        # 2. Born.xml preserves 59900 in <Array name="skinIdArray">
        with zipfile.ZipFile(io.BytesIO(low_out["resources/1.64.1/ages/prefab_characters/prefab_hero/commonactions.pkg.bytes"]), "r") as zca:
            born_out = zca.read("commonresource/Born.xml").decode("utf-8")
            self.assertIn("59900", born_out)
            self.assertIn("59901", born_out)

        # 3. ResourcePacker updates Actor_599_Actions (hcnt=2) while keeping 1.64.1.13 inner_game_effect_r_48 (hcnt=2) and valid SF tail
        u_rp = core_processor.unpack_unityfs(low_out["resources/1.64.1/assetbundle/resourcepackerinfosetall.assetbundle"])
        p_rp = core_processor.parse_rpack(u_rp)
        _, hs599, he599 = p_rp["recs"]["Ages/Prefab_Characters/Prefab_Hero/Actor_599_Actions.pkg.bytes"]
        _, hs48, he48 = p_rp["recs"]["assetbundle/inner_game_effect/inner_game_effect_r_48.assetbundle"]
        self.assertEqual(he599 - hs599, len(he1) + len(he2))
        self.assertEqual(he48 - hs48, len(he1) + len(he2))
        doff, sf_objs = core_processor._parse_unity_sf_objects(bytes(u_rp["payload"]))
        tail_off = doff + sf_objs[1]["byteStart"]
        self.assertEqual(bytes(u_rp["payload"][tail_off:tail_off + sf_objs[1]["byteSize"]]), b"TAILOBJ_VERIFY16")

        # 4. Battle HUD family keeps Edras cohesive with allshared and blocks Bilow orphan battlecommon/battleotherui_raw/UI.bnk
        self.assertEqual(low_out["resources/1.64.1/assetbundle/uisystem/atlas/primary/allshared.assetbundle"], b"EDRAS_ALLSHARED")
        self.assertEqual(low_out["resources/1.64.1/assetbundle/uisystem/battle/battlecommon_raw.assetbundle"], b"EDRAS_COMMON_RAW")
        self.assertEqual(low_out["resources/1.64.1/assetbundle/uisystem/battle/battleotherui.assetbundle"], b"EDRAS_OTHER")
        self.assertNotIn("resources/1.64.1/assetbundle/uisystem/battle/battlecommon.assetbundle", low_out)
        self.assertNotIn("resources/1.64.1/assetbundle/uisystem/battle/battleotherui_raw.assetbundle", low_out)
        self.assertNotIn("resources/1.64.1/sound/ios/ui.bnk", low_out)

    def test_isolate_global_hud_conflict_preserves_personal_buttons_and_mses_huanhua(self):
        """Gộp mod xung đột HUD toàn cục khi isolate_hud_on_conflict=True: bỏ battlecommon/battleotherui/allshared/UI.bnk, giữ PersonalButton & hợp nhất ResPersonalButtonCfg + ResBillboardSkinCfg theo tướng."""
        import struct

        def _mses_tbl(recs: list[tuple[int, bytes]], has_md5: bool = True) -> bytes:
            hdr = bytearray(140)
            hdr[:4] = b"MSES"
            if has_md5:
                hdr[96:128] = b"0" * 32
            return core_processor.serialize_mses({"hdr": hdr, "has_md5": has_md5, "max_rec": 128, "recs": recs, "ftr": b""})

        def _pb_rec(rid: int, skin_id: int, label: bytes) -> tuple[int, bytes]:
            body = struct.pack("<III", rid, skin_id, len(label) + 1) + label + b"\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00"
            return rid, struct.pack("<I", len(body)) + body

        def _bb_rec(rid: int, sids: list[int]) -> tuple[int, bytes]:
            body = struct.pack("<II", rid, len(sids)) + struct.pack(f"<{len(sids)}I", *sids)
            return rid, struct.pack("<I", len(body)) + body

        pb_bilow = core_processor.pg_encrypt(_mses_tbl([_pb_rec(80, 59903, b"BILLOW_NEW"), _pb_rec(93, 59501, b"EDRAS_OLD")]), "ResPersonalButtonCfg")
        pb_edras = core_processor.pg_encrypt(_mses_tbl([_pb_rec(80, 59903, b"BILLOW_OLD"), _pb_rec(93, 59501, b"EDRAS_NEW")]), "ResPersonalButtonCfg")

        bb_bilow = core_processor.pg_encrypt(_mses_tbl([_bb_rec(61, [15016, 15001]), _bb_rec(95, [59903])]), "ResBillboardSkinCfg")
        bb_edras = core_processor.pg_encrypt(_mses_tbl([_bb_rec(61, [15016, 15002]), _bb_rec(595, [59501])]), "ResBillboardSkinCfg")

        _, out_files, _, _ = core_processor.run_merge(
            [
                {
                    "name": "Bilow_599.zip",
                    "explicit_ver": "1.64.1",
                    "seed_hids": [599],
                    "raw_files": {
                        "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                        "Resources/1.64.1/assetbundle/uisystem/battle/battlecommon.assetbundle": b"BILOW_COMMON",
                        "Resources/1.64.1/assetbundle/uisystem/battle/battleotherui.assetbundle": b"BILOW_OTHER",
                        "Resources/1.64.1/Sound/iOS/UI.bnk": b"BILOW_UI",
                        "Resources/1.64.1/assetbundle/personalbutton/personalbuttonsprite_59903.assetbundle": b"PB_59903",
                        "Resources/1.64.1/Databin/Client/Huanhua/ResPersonalButtonCfg.bytes": pb_bilow,
                        "Resources/1.64.1/Databin/Client/Huanhua/ResBillboardSkinCfg.bytes": bb_bilow,
                    },
                },
                {
                    "name": "Edras_595.zip",
                    "explicit_ver": "1.64.1",
                    "seed_hids": [595],
                    "raw_files": {
                        "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                        "Resources/1.64.1/assetbundle/uisystem/atlas/primary/allshared.assetbundle": b"EDRAS_ALLSHARED",
                        "Resources/1.64.1/assetbundle/uisystem/battle/battleotherui.assetbundle": b"EDRAS_OTHER",
                        "Resources/1.64.1/assetbundle/personalbutton/personalbuttonsprite_59501.assetbundle": b"PB_59501",
                        "Resources/1.64.1/Databin/Client/Huanhua/ResPersonalButtonCfg.bytes": pb_edras,
                        "Resources/1.64.1/Databin/Client/Huanhua/ResBillboardSkinCfg.bytes": bb_edras,
                    },
                },
            ],
            isolate_hud_on_conflict=True,
        )

        low = {k.lower(): v for k, v in out_files.items()}
        for global_p in (
            "resources/1.64.1/assetbundle/uisystem/battle/battlecommon.assetbundle",
            "resources/1.64.1/assetbundle/uisystem/battle/battleotherui.assetbundle",
            "resources/1.64.1/assetbundle/uisystem/atlas/primary/allshared.assetbundle",
            "resources/1.64.1/sound/ios/ui.bnk",
        ):
            self.assertNotIn(global_p, low)

        self.assertEqual(low["resources/1.64.1/assetbundle/personalbutton/personalbuttonsprite_59903.assetbundle"], b"PB_59903")
        self.assertEqual(low["resources/1.64.1/assetbundle/personalbutton/personalbuttonsprite_59501.assetbundle"], b"PB_59501")

        pb_merged = dict(
            core_processor.parse_mses(
                core_processor.pg_decrypt(low["resources/1.64.1/databin/client/huanhua/respersonalbuttoncfg.bytes"], "ResPersonalButtonCfg")
            )["recs"]
        )
        self.assertIn(b"BILLOW_NEW", pb_merged[80])
        self.assertIn(b"EDRAS_NEW", pb_merged[93])

        bb_merged = dict(
            core_processor.parse_mses(
                core_processor.pg_decrypt(low["resources/1.64.1/databin/client/huanhua/resbillboardskincfg.bytes"], "ResBillboardSkinCfg")
            )["recs"]
        )
        cnt61 = struct.unpack_from("<I", bb_merged[61], 8)[0]
        sids61 = set(struct.unpack_from(f"<{cnt61}I", bb_merged[61], 12))
        self.assertEqual(sids61, {15016, 15001, 15002})
        self.assertIn(95, bb_merged)
        self.assertIn(595, bb_merged)

    def test_isolate_global_hud_when_single_hud_mod_merges_with_non_hud_hero_mod(self):
        """Gộp 1 mod có Battle HUD toàn cục (Bilow 599) + 1 mod tướng không HUD (Nakroth 150) vẫn phải tách bỏ HUD chung."""
        import struct

        def _mses_tbl(recs: list[tuple[int, bytes]]) -> bytes:
            hdr = bytearray(140)
            hdr[:4] = b"MSES"
            hdr[96:128] = b"0" * 32
            return core_processor.serialize_mses({"hdr": hdr, "has_md5": True, "max_rec": 128, "recs": recs, "ftr": b""})

        pb_bilow = core_processor.pg_encrypt(
            _mses_tbl([(80, struct.pack("<IIII", 24, 80, 59903, 2) + b"B\x00" + b"\x00" * 10)]),
            "ResPersonalButtonCfg",
        )
        pb_nak = core_processor.pg_encrypt(
            _mses_tbl([(52, struct.pack("<IIII", 24, 52, 15009, 2) + b"N\x00" + b"\x00" * 10)]),
            "ResPersonalButtonCfg",
        )
        _, out_files, _, _ = core_processor.run_merge(
            [
                {
                    "name": "Bilow_599.zip",
                    "explicit_ver": "1.64.1",
                    "seed_hids": [599],
                    "raw_files": {
                        "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                        "Resources/1.64.1/assetbundle/uisystem/battle/battlecommon.assetbundle": b"BILOW_COMMON",
                        "Resources/1.64.1/assetbundle/uisystem/battle/battleotherui.assetbundle": b"BILOW_OTHER",
                        "Resources/1.64.1/assetbundle/uisystem/atlas/primary/allshared.assetbundle": b"BILOW_ALLSHARED",
                        "Resources/1.64.1/Sound/iOS/UI.bnk": b"BILOW_UI",
                        "Resources/1.64.1/assetbundle/personalbutton/personalbuttonsprite_59903.assetbundle": b"PB_59903",
                        "Resources/1.64.1/Databin/Client/Huanhua/ResPersonalButtonCfg.bytes": pb_bilow,
                    },
                },
                {
                    "name": "Nakroth_150.zip",
                    "explicit_ver": "1.64.1",
                    "seed_hids": [150],
                    "raw_files": {
                        "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                        "Resources/1.64.1/assetbundle/personalbutton/personalbuttonsprite_15009.assetbundle": b"PB_15009",
                        "Resources/1.64.1/Databin/Client/Huanhua/ResPersonalButtonCfg.bytes": pb_nak,
                    },
                },
            ],
            isolate_hud_on_conflict=True,
        )
        low = {k.lower(): v for k, v in out_files.items()}
        for global_p in (
            "resources/1.64.1/assetbundle/uisystem/battle/battlecommon.assetbundle",
            "resources/1.64.1/assetbundle/uisystem/battle/battleotherui.assetbundle",
            "resources/1.64.1/assetbundle/uisystem/atlas/primary/allshared.assetbundle",
            "resources/1.64.1/sound/ios/ui.bnk",
        ):
            self.assertNotIn(global_p, low)
        self.assertEqual(low["resources/1.64.1/assetbundle/personalbutton/personalbuttonsprite_59903.assetbundle"], b"PB_59903")
        self.assertEqual(low["resources/1.64.1/assetbundle/personalbutton/personalbuttonsprite_15009.assetbundle"], b"PB_15009")

        # Kiểm thử khứ hồi pg_encrypt(..., compress_zstd=True) -> header 0x224A67EF
        sample = b"<Project><Action>Test Zstd Dict Roundtrip</Action></Project>" * 4
        enc_ef = core_processor.pg_encrypt(sample, "150_AssetRef", compress_zstd=True)
        self.assertEqual(enc_ef[:4], b"\x22\x4A\x67\xEF")
        self.assertEqual(core_processor.pg_decrypt(enc_ef, "150_AssetRef"), sample)

    def test_hs2_8inst_anti_88_freeze_single_mses_md5_repair_and_same_hero_merge(self):
        """Chống kẹt 88% (HeroSkin_2 khối 8 lệnh + sửa MD5 MSES đơn lẻ), tách HUD allshared_raw/cùng tướng, và gộp chọn lọc cùng 1 tướng."""
        import hashlib
        import struct

        # 1) HeroSkin_2 có khối 8 lệnh (chỉ set 0x4B 3) đứng đầu + khối 11 lệnh đứng sau: không được false-match làm hỏng bảng extern & KernelLua!
        prefix = b"Project.Plugins_d\x00" + b"\x00" * 10 + struct.pack("<I", 1)
        pre58 = bytearray(58 * 8)
        struct.pack_into("<Ii", pre58, 0, 0x92, 5)
        blk_104 = (
            core_processor.ifix_inst(0xA4, 1) + core_processor.ifix_inst(0x8F, 104)
            + core_processor.ifix_inst(0xA6, 0) + core_processor.ifix_inst(0x86, 5)
            + core_processor.ifix_inst(0xA4, 0) + core_processor.ifix_inst(0x8F, 12)
            + core_processor.ifix_inst(0x4B, 3) + core_processor.ifix_inst(0xAD, 0)
        )
        blk_543 = (
            core_processor.ifix_inst(0xA4, 1) + core_processor.ifix_inst(0x8F, 543)
            + core_processor.ifix_inst(0xA6, 0) + core_processor.ifix_inst(0x86, 8)
            + core_processor.ifix_inst(0xA4, 0) + core_processor.ifix_inst(0x8F, 60)
            + core_processor.ifix_inst(0x4B, 3) + core_processor.ifix_inst(0xA4, 0)
            + core_processor.ifix_inst(0x8F, 52) + core_processor.ifix_inst(0x4B, 2)
            + core_processor.ifix_inst(0xAD, 0)
        )
        tail = (
            b"\x00\x00\x00\x00\x08Contains\x00\x0bOnAddedHero\x00"
            b"/Resources/1.64.1/KernelLua.pkg.bytes " + b"0" * 32
            + b" /Resources/1.64.1/StableSystems_3.pkg.bytes " + b"0" * 32
        )
        hs2_a = prefix + struct.pack("<I", 58 + 8 + 11 + 1) + bytes(pre58) + blk_104 + blk_543 + core_processor.ifix_inst(0xAD, 0) + tail
        lay_a = core_processor.parse_kiana_hs2(hs2_a)
        self.assertIsNotNone(lay_a)
        self.assertEqual(lay_a["params"], [(104, 12, 0), (543, 60, 52)])

        blk_150 = (
            core_processor.ifix_inst(0xA4, 1) + core_processor.ifix_inst(0x8F, 150)
            + core_processor.ifix_inst(0xA6, 0) + core_processor.ifix_inst(0x86, 8)
            + core_processor.ifix_inst(0xA4, 0) + core_processor.ifix_inst(0x8F, 52)
            + core_processor.ifix_inst(0x4B, 3) + core_processor.ifix_inst(0xA4, 0)
            + core_processor.ifix_inst(0x8F, 45) + core_processor.ifix_inst(0x4B, 2)
            + core_processor.ifix_inst(0xAD, 0)
        )
        hs2_b = prefix + struct.pack("<I", 58 + 11 + 1) + bytes(pre58) + blk_150 + core_processor.ifix_inst(0xAD, 0) + tail
        vk = core_processor.ver_key((1, 64, 1, 13), 1802180)
        merged_hs2 = core_processor.merge_hs2(
            [
                (104, 12, 0, vk, core_processor.pg_encrypt(hs2_a, "HeroSkin_2")),
                (150, 52, 45, vk, core_processor.pg_encrypt(hs2_b, "HeroSkin_2")),
            ],
            {"KernelLua.pkg.bytes": "a" * 32, "StableSystems_3.pkg.bytes": "b" * 32},
        )
        merged_hs2_dec = core_processor.pg_decrypt(merged_hs2, "HeroSkin_2")
        re_lay = core_processor.parse_kiana_hs2(merged_hs2_dec)
        self.assertIsNotNone(re_lay)
        self.assertEqual(re_lay["params"], [(104, 12, 0), (543, 60, 52), (150, 52, 45)])
        self.assertIn(b"Contains", merged_hs2_dec)
        self.assertIn(b"/Resources/1.64.1/KernelLua.pkg.bytes " + b"a" * 32, merged_hs2_dec)
        self.assertIn(b"/Resources/1.64.1/StableSystems_3.pkg.bytes " + b"b" * 32, merged_hs2_dec)

        # 2) Gộp 2 mod chọn lọc CÙNG tướng 150 (`15000->15009` + `15002->15015`) + BattleEffect sai MD5 + PersonalButton trùng rid=96 + allshared_raw HUD
        def _mses_bytes(recs: list[tuple[int, bytes]], bad_md5: str | None = None) -> bytes:
            hdr = bytearray(140)
            hdr[:4] = b"MSES"
            hdr[96:128] = b"0" * 32
            raw = bytearray(core_processor.serialize_mses({"hdr": hdr, "has_md5": True, "max_rec": 128, "recs": recs, "ftr": b""}))
            if bad_md5 is not None:
                raw[96:128] = bad_md5.encode("ascii")
            return bytes(raw)

        def _jt_str_el(name: str, val: str) -> dict:
            return {"name": name, "attrs": [("Type", b"System.String"), ("V", val.encode("utf-8"))], "content": b"", "children": []}

        def _actorinfo_bytes(root_path: str, slot0_path: str, slot1_path: str) -> bytes:
            tree = {
                "name": "CActorInfo",
                "attrs": [],
                "content": b"",
                "children": [
                    {"name": "ArtPrefabLOD", "attrs": [], "content": b"", "children": [_jt_str_el("Element", root_path)]},
                    {
                        "name": "SkinPrefab",
                        "attrs": [],
                        "content": b"",
                        "children": [
                            {"name": "Element", "attrs": [], "content": b"", "children": [{"name": "ArtSkinPrefabLOD", "attrs": [], "content": b"", "children": [_jt_str_el("Element", slot0_path)]}]},
                            {"name": "Element", "attrs": [], "content": b"", "children": [{"name": "ArtSkinPrefabLOD", "attrs": [], "content": b"", "children": [_jt_str_el("Element", slot1_path)]}]},
                        ],
                    },
                ],
            }
            return core_processor.pg_encrypt(core_processor._jt_serialize(tree), "150_HanXin_actorinfo")

        def _assetref_bytes(paths: list[str]) -> bytes:
            els = [{"name": "Element", "attrs": [], "content": b"", "children": [_jt_str_el("v1", p)]} for p in paths]
            tree = {
                "name": "AssetRef",
                "attrs": [],
                "content": b"",
                "children": [
                    {"name": "baseSubset", "attrs": [], "content": b"", "children": [{"name": "particlesInFirstLayer", "attrs": [], "content": b"", "children": els}]}
                ],
            }
            return core_processor.pg_encrypt(core_processor._jt_serialize(tree), "150_AssetRef", compress_zstd=True)

        def _mk_pkg(items: list[tuple[str, bytes]]) -> bytes:
            b = io.BytesIO()
            with zipfile.ZipFile(b, "w", compression=zipfile.ZIP_STORED) as zf:
                for p, d in items:
                    zf.writestr(zipfile.ZipInfo(p, (2026, 11, 18, 10, 0, 0)), d)
            return b.getvalue()

        def _pb_rec(rid: int, sid: int, tag: bytes) -> tuple[int, bytes]:
            body = struct.pack("<III", rid, sid, len(tag) + 1) + tag + b"\x00\x01\x00\x00\x00"
            return rid, struct.pack("<I", len(body)) + body

        def _snd_rec(rid: int, skin_id: int) -> tuple[int, bytes]:
            ev = b"Play_150\x00"
            body = struct.pack("<II", rid, len(ev)) + ev + struct.pack("<I", skin_id) + b"\x00\x00\x00\x00"
            return rid, struct.pack("<I", len(body)) + body

        # Trùng GUID giữa 2 track chọn lọc flt=9 (mô phỏng lỗi từ Mod Studio bản cũ!)
        same_guid = "11111111-2222-3333-4444-555555555555"
        a1_m1 = (
            '<Project><Action>'
            '<Track trackName="Base" eventType="TriggerParticleTick" guid="00000000-0000-0000-0000-000000000001" SkinAvatarFilterType="11">'
            '<Event eventName="TriggerParticleTick"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_hanxin/hanxin_attack_01" /></Event>'
            '<SkinOrAvatarList id="15000" /></Track>'
            f'<Track trackName="Clone" eventType="TriggerParticleTick" guid="{same_guid}" SkinAvatarFilterType="9">'
            '<Event eventName="TriggerParticleTick"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_hanxin/15009/hanxin_attack_01.prefab" /></Event>'
            '<SkinOrAvatarList id="15000" /></Track>'
            '</Action></Project>'
        ).encode("utf-8")
        a1_m2 = (
            '<Project><Action>'
            '<Track trackName="Base" eventType="TriggerParticleTick" guid="00000000-0000-0000-0000-000000000001" SkinAvatarFilterType="11">'
            '<Event eventName="TriggerParticleTick"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_hanxin/hanxin_attack_01" /></Event>'
            '<SkinOrAvatarList id="15002" /></Track>'
            f'<Track trackName="Clone" eventType="TriggerParticleTick" guid="{same_guid}" SkinAvatarFilterType="9">'
            '<Event eventName="TriggerParticleTick"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_hanxin/15015/hanxin_attack_01.prefab" /></Event>'
            '<SkinOrAvatarList id="15002" /></Track>'
            '</Action></Project>'
        ).encode("utf-8")

        haste_m1 = (
            '<Project><Action>'
            '<Track trackName="15015逻辑层" eventType="CheckSkinIdTick" guid="c415bae9-6ce0-43a7-83c2-132eaa5c98bb">'
            '<Event eventName="CheckSkinIdTick"><int name="skinId" value="15015" /></Event></Track>'
            '<Track trackName="Totorox_Sprint_15009_0" eventType="TriggerParticle" guid="aaaa0000-0000-0000-0000-000000015009" SkinAvatarFilterType="9">'
            '<Event eventName="TriggerParticle"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_HanXin/15009/T2_Spint.prefab" /></Event>'
            '<SkinOrAvatarList id="15000" /></Track>'
            '</Action></Project>'
        ).encode("utf-8")
        haste_m2 = (
            '<Project><Action>'
            '<Track trackName="15015逻辑层" eventType="CheckSkinIdVirtualTick" guid="c415bae9-6ce0-43a7-83c2-132eaa5c98bb">'
            '<Event eventName="CheckSkinIdVirtualTick"><int name="skinId" value="15015" /><Array name="skinIdArray" type="int"><int value="15015" /><int value="15002" /></Array></Event></Track>'
            '</Action></Project>'
        ).encode("utf-8")

        bad_be = core_processor.pg_encrypt(_mses_bytes([(15001, struct.pack("<II", 12, 15001) + b"ABCDEFGH")], bad_md5="f" * 32), "BattleEffect")

        _, out_files, _, _ = core_processor.run_merge(
            [
                {
                    "name": "Ve_than.zip",
                    "explicit_ver": "1.64.1",
                    "seed_hids": [150],
                    "raw_files": {
                        "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                        "Resources/1.64.1/Prefab_Characters/Actor_150_Infos.pkg.bytes": _mk_pkg([("150_HanXin_actorinfo.bytes", _actorinfo_bytes("150_HanXin/15010_HanXin_LOD1", "150_HanXin/1502_HanXin_LOD1", "150_HanXin/1503_HanXin_LOD1"))]),
                        "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/Actor_150_Actions.pkg.bytes": _mk_pkg([("150_HanXin/skill/A1.xml", core_processor.pg_encrypt(a1_m1, "A1", compress_zstd=True))]),
                        "Resources/1.64.1/AssetRefs/Hero/150_AssetRef.bytes": _assetref_bytes(["150_hanxin/15009/hanxin_attack_01.prefab"]),
                        "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes": _mk_pkg([("commonresource/HasteE1.xml", haste_m1)]),
                        "Resources/1.64.1/Databin/Client/Huanhua/ResPersonalButtonCfg.bytes": core_processor.pg_encrypt(_mses_bytes([_pb_rec(52, 15009, b"VETHAN"), _pb_rec(96, 15000, b"BTN_15000")]), "ResPersonalButtonCfg"),
                        "Resources/1.64.1/Databin/Client/Sound/HeroSound.bytes": core_processor.pg_encrypt(_mses_bytes([_snd_rec(150001, 23500), _snd_rec(150002, 15002), _snd_rec(15000900, 15000)]), "HeroSound"),
                        "Resources/1.64.1/Databin/Client/Skill/BattleEffect.bytes": bad_be,
                        "Resources/1.64.1/assetbundle/uisystem/allshared_raw.assetbundle": b"HUD_RAW",
                    },
                },
                {
                    "name": "Bach_dien.zip",
                    "explicit_ver": "1.64.1",
                    "seed_hids": [150],
                    "raw_files": {
                        "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                        "Resources/1.64.1/Prefab_Characters/Actor_150_Infos.pkg.bytes": _mk_pkg([("150_HanXin_actorinfo.bytes", _actorinfo_bytes("150_HanXin/1501_HanXin_LOD1", "150_HanXin/1502_HanXin_LOD1", "150_HanXin/15016_HanXin_LOD1"))]),
                        "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/Actor_150_Actions.pkg.bytes": _mk_pkg([("150_HanXin/skill/A1.xml", core_processor.pg_encrypt(a1_m2, "A1", compress_zstd=True))]),
                        "Resources/1.64.1/AssetRefs/Hero/150_AssetRef.bytes": _assetref_bytes(["150_hanxin/15015/hanxin_attack_01.prefab"]),
                        "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes": _mk_pkg([("commonresource/HasteE1.xml", haste_m2)]),
                        "Resources/1.64.1/Databin/Client/Huanhua/ResPersonalButtonCfg.bytes": core_processor.pg_encrypt(_mses_bytes([_pb_rec(17, 15015, b"BACHDIEN"), _pb_rec(96, 15002, b"BTN_15002")]), "ResPersonalButtonCfg"),
                        "Resources/1.64.1/Databin/Client/Sound/HeroSound.bytes": core_processor.pg_encrypt(_mses_bytes([_snd_rec(150001, 15000), _snd_rec(150002, 23502), _snd_rec(15002900, 15002)]), "HeroSound"),
                    },
                },
            ],
            isolate_hud_on_conflict=True,
            allow_same_hero_merge=True,
        )
        low = {k.lower(): v for k, v in out_files.items()}
        # allshared_raw bị tách bỏ khi gộp 2 mod cùng tướng
        self.assertNotIn("resources/1.64.1/assetbundle/uisystem/allshared_raw.assetbundle", low)
        # BattleEffect đơn lẻ được tự sửa MD5
        be_out_dec = core_processor.pg_decrypt(low["resources/1.64.1/databin/client/skill/battleeffect.bytes"], "BattleEffect")
        self.assertEqual(be_out_dec[96:128].decode("ascii"), hashlib.md5(be_out_dec[140:]).hexdigest())
        # Actor_150_Infos giữ cả Root=15010 lẫn slot1=15016
        ai_ents = dict((n, d) for n, _, _, d in core_processor.parse_in_memory_zip(low["resources/1.64.1/prefab_characters/actor_150_infos.pkg.bytes"]))
        ai_root, _ = core_processor._jt_parse(core_processor.pg_decrypt(ai_ents["150_HanXin_actorinfo.bytes"], "150_HanXin_actorinfo"), 0)
        self.assertIn("15010_", core_processor._jt_first_lod_path(ai_root["children"][0]))
        self.assertIn("15016_", core_processor._jt_first_lod_path(ai_root["children"][1]["children"][1]["children"][0]))
        # Actor_150_Actions A1.xml giữ cả 15009 & 15015, mã hóa 0x224A67EF, không trùng GUID
        a1_raw = core_processor.parse_in_memory_zip(low["resources/1.64.1/ages/prefab_characters/prefab_hero/actor_150_actions.pkg.bytes"])[0][3]
        self.assertEqual(a1_raw[:4], b"\x22\x4a\x67\xef")
        a1_out = core_processor.pg_decrypt(a1_raw, "A1").decode("utf-8")
        self.assertIn("/15009/", a1_out)
        self.assertIn("/15015/", a1_out)
        self.assertEqual(len(set(core_processor.re.findall(r'<Track[^>]*guid="([^"]+)"', a1_out))), 3)
        # 150_AssetRef giữ cả 15009 & 15015
        aref_out = core_processor.pg_decrypt(low["resources/1.64.1/assetrefs/hero/150_assetref.bytes"], "150_AssetRef")
        self.assertIn(b"15009", aref_out)
        self.assertIn(b"15015", aref_out)
        # CommonActions HasteE1 hợp nhất #0 CheckSkinIdTick->CheckSkinIdVirtualTick tại chỗ + giữ Totorox_Sprint_15009_0
        h_out = core_processor.parse_in_memory_zip(low["resources/1.64.1/ages/prefab_characters/prefab_hero/commonactions.pkg.bytes"])[0][3].decode("utf-8")
        self.assertIn("Totorox_Sprint_15009_0", h_out)
        self.assertEqual(h_out.count("c415bae9-6ce0-43a7-83c2-132eaa5c98bb"), 1)
        self.assertIn("15002", h_out)
        # ResPersonalButtonCfg giữ cả 15000 & 15002 với 2 rid phân biệt (không ghi đè rid=96)
        pb_out = core_processor.parse_mses(core_processor.pg_decrypt(low["resources/1.64.1/databin/client/huanhua/respersonalbuttoncfg.bytes"], "ResPersonalButtonCfg"))["recs"]
        pb_by_sid = {struct.unpack_from("<I", r, 8)[0]: rid for rid, r in pb_out}
        self.assertIn(15000, pb_by_sid)
        self.assertIn(15002, pb_by_sid)
        self.assertNotEqual(pb_by_sid[15000], pb_by_sid[15002])
        # HeroSound giữ cả 2 dummy suppression (23500, 23502) lẫn cả 2 clone (15000900, 15002900)
        hsnd_out = dict(core_processor.parse_mses(core_processor.pg_decrypt(low["resources/1.64.1/databin/client/sound/herosound.bytes"], "HeroSound"))["recs"])
        self.assertEqual(core_processor._extract_sound_rec_skin_id(hsnd_out[150001]), 23500)
        self.assertEqual(core_processor._extract_sound_rec_skin_id(hsnd_out[150002]), 23502)
        self.assertIn(15000900, hsnd_out)
        self.assertIn(15002900, hsnd_out)

    def test_selfclosing_skinidarray_and_selective_checkskinid_stoptrack_and_assetref_merge(self):
        import xml.etree.ElementTree as ET
        import core_processor

        # 1) Self-closing <Array name="skinIdArray" ... /> (như 131_LiBai/skill/S2E1.xml Track[2]) không làm hỏng XML khi gộp
        s2e1_base = (
            '<Project><Action>'
            '<Track trackName="Check13112" eventType="CheckSkinIdVirtualTick" guid="aaaa0000-0000-0000-0000-000000000001">'
            '<Event eventName="CheckSkinIdVirtualTick"><int name="skinId" value="13112" />'
            '<Array name="skinIdArray" refParamName="" useRefParam="false" type="int" /></Event></Track>'
            '</Action></Project>'
        )
        s2e1_mod = (
            '<Project><Action>'
            '<Track trackName="Check13112" eventType="CheckSkinIdVirtualTick" guid="aaaa0000-0000-0000-0000-000000000001">'
            '<Event eventName="CheckSkinIdVirtualTick"><int name="skinId" value="13112" />'
            '<Array name="skinIdArray" refParamName="" useRefParam="false" type="int">'
            '<int value="13112" /><int value="13100" /></Array></Event></Track>'
            '</Action></Project>'
        )
        merged_s2e1 = core_processor.merge_xml_tracks(s2e1_base, s2e1_mod, {131})
        root_s2 = ET.fromstring(merged_s2e1)
        arr_s2 = root_s2.find(".//Array[@name='skinIdArray']")
        self.assertIsNotNone(arr_s2)
        vals_s2 = [e.attrib.get("value") for e in arr_s2]
        self.assertIn("13112", vals_s2)
        self.assertIn("13100", vals_s2)

        # Kiểm tra trực tiếp replace_skin_id_array trên thẻ self-closing
        replaced_sc = core_processor.replace_skin_id_array(s2e1_base, ["13112", "13100"])
        root_sc = ET.fromstring(replaced_sc)
        self.assertEqual([e.attrib.get("value") for e in root_sc.find(".//Array[@name='skinIdArray']")], ["13112", "13100"])

        # 2) Gộp 2 mod chọn lọc cùng tướng dùng Totorox_SkinCheck_* + Totorox_Stop_* + TriggerParticleTick khóa bởi <Condition>
        xml_m1 = (
            '<Project><Action>'
            '<Track trackName="BlueBuffStop" eventType="StopTrack" guid="00000000-0000-0000-0000-000000000001">'
            '<Event eventName="StopTrack"><TrackObject name="trackId" id="1" guid="00000000-0000-0000-0000-000000000002" /></Event></Track>'
            '<Track trackName="BaseFX" eventType="TriggerParticleTick" guid="00000000-0000-0000-0000-000000000002" SkinAvatarFilterType="11">'
            '<Event eventName="TriggerParticleTick"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_hanxin/hanxin_attack_01" /></Event>'
            '<SkinOrAvatarList id="15003" /></Track>'
            '<Track trackName="Totorox_SkinCheck_15003" eventType="CheckSkinIdVirtualTick" guid="11110000-0000-0000-0000-000000015003">'
            '<Event eventName="CheckSkinIdVirtualTick"><int name="skinId" value="15003" /><Array name="skinIdArray" type="int"><int value="15003" /></Array></Event></Track>'
            '<Track trackName="Totorox_Stop_0_1_15003" eventType="StopTrack" guid="22220000-0000-0000-0000-000000015003">'
            '<Condition id="2" guid="11110000-0000-0000-0000-000000015003" status="true" />'
            '<Event eventName="StopTrack"><TrackObject name="trackId" id="4" guid="33330000-0000-0000-0000-000000015003" /><bool name="alsoStopNotStartedTrack" value="true" /></Event></Track>'
            '<Track trackName="TriggerParticleTick0" eventType="TriggerParticleTick" guid="33330000-0000-0000-0000-000000015003">'
            '<Condition id="2" guid="11110000-0000-0000-0000-000000015003" status="true" />'
            '<Event eventName="TriggerParticleTick"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_hanxin/15013/hanxin_attack_01_HD" /></Event></Track>'
            '</Action></Project>'
        )
        xml_m2 = (
            '<Project><Action>'
            '<Track trackName="BlueBuffStop" eventType="StopTrack" guid="00000000-0000-0000-0000-000000000001">'
            '<Event eventName="StopTrack"><TrackObject name="trackId" id="1" guid="00000000-0000-0000-0000-000000000002" /></Event></Track>'
            '<Track trackName="BaseFX" eventType="TriggerParticleTick" guid="00000000-0000-0000-0000-000000000002" SkinAvatarFilterType="11">'
            '<Event eventName="TriggerParticleTick"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_hanxin/hanxin_attack_01" /></Event>'
            '<SkinOrAvatarList id="15001" /></Track>'
            '<Track trackName="Totorox_SkinCheck_15001" eventType="CheckSkinIdVirtualTick" guid="11110000-0000-0000-0000-000000015001">'
            '<Event eventName="CheckSkinIdVirtualTick"><int name="skinId" value="15001" /><Array name="skinIdArray" type="int"><int value="15001" /></Array></Event></Track>'
            '<Track trackName="TriggerParticleTick0" eventType="TriggerParticleTick" guid="33330000-0000-0000-0000-000000015001">'
            '<Condition id="2" guid="11110000-0000-0000-0000-000000015001" status="true" />'
            '<Event eventName="TriggerParticleTick"><String name="resourceName" value="prefab_skill_effects/hero_skill_effects/150_hanxin/15012/hanxin_attack_01" /></Event></Track>'
            '</Action></Project>'
        )
        merged_xml = core_processor.merge_xml_tracks(xml_m1, xml_m2, {150})
        root_m = ET.fromstring(merged_xml)
        m_tracks = root_m.findall(".//Track")
        self.assertEqual(len(m_tracks), 7)
        self.assertEqual(len({t.attrib["guid"] for t in m_tracks}), 7)
        # Kiểm tra cả hai nhánh 15013 & 15012 đều còn nguyên và Condition/TrackObject khớp chỉ số + GUID
        idx_chk_3 = next(i for i, t in enumerate(m_tracks) if t.attrib.get("trackName") == "Totorox_SkinCheck_15003")
        idx_chk_1 = next(i for i, t in enumerate(m_tracks) if t.attrib.get("trackName") == "Totorox_SkinCheck_15001")
        idx_stop_3 = next(i for i, t in enumerate(m_tracks) if t.attrib.get("trackName") == "Totorox_Stop_0_1_15003")
        idx_fx_3 = next(i for i, t in enumerate(m_tracks) if "15013/hanxin_attack_01_HD" in ET.tostring(t, encoding="unicode"))
        idx_fx_1 = next(i for i, t in enumerate(m_tracks) if "15012/hanxin_attack_01" in ET.tostring(t, encoding="unicode"))
        self.assertEqual(m_tracks[idx_fx_3].find("./Condition").attrib["id"], str(idx_chk_3))
        self.assertEqual(m_tracks[idx_fx_1].find("./Condition").attrib["id"], str(idx_chk_1))
        self.assertEqual(m_tracks[idx_fx_1].find("./Condition").attrib["guid"], m_tracks[idx_chk_1].attrib["guid"])
        self.assertEqual(m_tracks[idx_stop_3].find("./Event/TrackObject").attrib["id"], str(idx_fx_3))
        self.assertEqual(m_tracks[idx_stop_3].find("./Event/TrackObject").attrib["guid"], m_tracks[idx_fx_3].attrib["guid"])

        # 3) merge_assetref_bytes chọn base_root giàu đường dẫn bare base hơn và hợp nhất animations + skinSubset
        def _jt_str(name: str, val: str) -> dict:
            return {"name": name, "attrs": [("Type", b"System.String"), ("V", val.encode("utf-8"))], "content": b"", "children": []}

        def _mk_aref(p1_list: list[str], anim_list: list[str], ss_pairs: list[tuple[str, list[str]]]) -> bytes:
            ss_els = []
            for sid, spaths in ss_pairs:
                ss_els.append({
                    "name": "Element", "attrs": [], "content": b"",
                    "children": [
                        _jt_str("v1", sid),
                        {"name": "v2", "attrs": [], "content": b"", "children": [
                            {"name": "particlesInFirstLayer", "attrs": [], "content": b"", "children": [
                                {"name": "Element", "attrs": [], "content": b"", "children": [_jt_str("v1", p)]} for p in spaths
                            ]}
                        ]},
                    ],
                })
            tree = {
                "name": "AssetRef", "attrs": [], "content": b"",
                "children": [
                    {"name": "baseSubset", "attrs": [], "content": b"", "children": [
                        {"name": "particlesInFirstLayer", "attrs": [], "content": b"", "children": [
                            {"name": "Element", "attrs": [], "content": b"", "children": [_jt_str("v1", p)]} for p in p1_list
                        ]},
                        {"name": "animations", "attrs": [], "content": b"", "children": [
                            {"name": "Element", "attrs": [], "content": b"", "children": [_jt_str("v1", a)]} for a in anim_list
                        ]},
                    ]},
                    {"name": "skinSubset", "attrs": [], "content": b"", "children": ss_els},
                ],
            }
            return core_processor.pg_encrypt(core_processor._jt_serialize(tree), "150_AssetRef", compress_zstd=True)

        vk = ((1, 64, 1, 13), 1802180, "1.64.1.13")
        # Mod A mất bare base (toàn /15009/), dài hơn; Mod B giữ đủ bare base + anim + skinSubset 15003
        aref_a = _mk_aref(
            [f"prefab_skill_effects/hero_skill_effects/150_hanxin/15009/fx_{i}" for i in range(15)],
            ["150_HanXin/Anim_A"],
            [("15000", ["prefab_skill_effects/hero_skill_effects/150_hanxin/15009/fx_0"])],
        )
        aref_b = _mk_aref(
            [
                "prefab_skill_effects/hero_skill_effects/150_hanxin/hanxin_attack_01",
                "prefab_skill_effects/hero_skill_effects/150_hanxin/hanxin_spell_01",
                "prefab_skill_effects/hero_skill_effects/150_hanxin/15013/hanxin_attack_01_HD",
            ],
            ["150_HanXin/Anim_B"],
            [("15003", ["prefab_skill_effects/hero_skill_effects/150_hanxin/15013/hanxin_attack_01_HD"])],
        )
        mod_a = {"bvk": vk}
        mod_b = {"bvk": vk}
        merged_aref = core_processor.merge_assetref_bytes("150_AssetRef", [(mod_a, aref_a), (mod_b, aref_b)])
        dec_aref = core_processor.pg_decrypt(merged_aref, "150_AssetRef")
        self.assertIn(b"150_hanxin/hanxin_attack_01", dec_aref)
        self.assertIn(b"150_hanxin/15009/fx_0", dec_aref)
        self.assertIn(b"150_hanxin/15013/hanxin_attack_01_HD", dec_aref)
        self.assertIn(b"150_HanXin/Anim_A", dec_aref)
        self.assertIn(b"150_HanXin/Anim_B", dec_aref)
        root_a, _ = core_processor._jt_parse(dec_aref, 0)
        ss_node = next(c for c in root_a["children"] if c["name"] == "skinSubset")
        ss_ids = [next(f for f in el["children"] if f["name"] == "v1")["attrs"][1][1].decode() for el in ss_node["children"]]
        self.assertIn("15000", ss_ids)
        self.assertIn("15003", ss_ids)

    def test_network_error_fixes_lua_dirs_no_loopback_junglemark_heroinfo_and_dummy_scene(self):
        import io
        import zipfile
        import core_processor

        def _mk_pkg_with_dirs(dir_names: list[str], file_items: list[tuple[str, bytes]]) -> bytes:
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_STORED) as zf:
                for d in dir_names:
                    zi = zipfile.ZipInfo(d if d.endswith("/") else d + "/", (2026, 11, 19, 12, 0, 0))
                    zi.compress_type = zipfile.ZIP_STORED
                    zi.external_attr = 0x10
                    zf.writestr(zi, b"")
                for fn, payload in file_items:
                    zi = zipfile.ZipInfo(fn, (2026, 11, 19, 12, 0, 0))
                    zi.compress_type = zipfile.ZIP_STORED
                    zf.writestr(zi, payload)
            return buf.getvalue()

        # 1) KernelLua / StableSystems_3: không thay thành http://127.0.0.1/..., bảo toàn dirs>0 & độ dài byte Lua
        dirty_util = (
            b"\x00" * 128
            + b"\x1bLuaS\x00\x19\x93\r\n\x1a\n"
            + b"\x04\x0a_0x242424"
            + b"\x04\x16_0x237912319231723827"
            + b"\x14Shttps://raw.githubusercontent.com/Nedier000/huhuhuhuhuhuhuh/refs/heads/main/la.txt"
        )
        legacy_loopback_util = (
            b"\x00" * 128
            + b"\x1bLuaS\x00\x19\x93\r\n\x1a\n"
            + b"\x04\x0a_0x242424"
            + b"\x14Shttp://127.0.0.1/00000000000000000000000000000000000000000000000000000000000000000"
        )
        kl_pkg_1 = _mk_pkg_with_dirs(
            ["Lua_Signed/", "Lua_Signed/Kernel/", "Lua_Signed/Kernel/Util/xlua/"],
            [("Lua_Signed/Kernel/Util/xlua/util_lua.bytes", dirty_util)],
        )
        kl_pkg_2 = _mk_pkg_with_dirs(
            ["Lua_Signed/", "Lua_Signed/Kernel/"],
            [("Lua_Signed/Kernel/Util/xlua/util_lua.bytes", legacy_loopback_util)],
        )
        ss_pkg_1 = _mk_pkg_with_dirs(
            ["Lua_Signed/", "Lua_Signed/AOV/", "Lua_Signed/AOV/Lobby/"],
            [("Lua_Signed/AOV/Lobby/LobbyView_lua.bytes", b"\x00" * 128 + b"\x1bLuaS_0x432312_0x242424")],
        )
        ss_pkg_2 = _mk_pkg_with_dirs(
            ["Lua_Signed/"],
            [("Lua_Signed/AOV/Lobby/LobbyView_lua.bytes", b"\x00" * 128 + b"\x1bLuaS_0x432312_0x242424_v2")],
        )

        # 2) CommonActions junglemark.xml: loại track InBattleMsgSendTick (KAMODAOV / YTB: BẨN BỰA AOV), giữ Cam Xa & mowen
        dirty_jm = (
            '<?xml version="1.0" encoding="utf-8"?><Project><Action tag="" length="1.000" loop="false">'
            '<Track trackName="HitTriggerTick0" eventType="HitTriggerTick" guid="8e943844-af73-4d04-8860-1f87daa8a258" enabled="false"><Event eventName="HitTriggerTick" time="0.000" /></Track>'
            '<Track trackName="SkillFuncDuration0" eventType="SkillFuncDuration" guid="ba22c237-d2de-469a-bd24-ab9292870bd2" enabled="true"><Event eventName="SkillFuncDuration" time="0.000" length="1.000" /></Track>'
            '<Track trackName="KAMODAOV_JungleMark_EntryMessage" eventType="InBattleMsgSendTick" guid="e5b5f62f-023a-5d68-80a4-20c6a0b30d4f" enabled="true">'
            '<Event eventName="InBattleMsgSendTick" time="0.000"><String name="msgKey" value="YTB: BẨN BỰA AOV" /></Event></Track>'
            '</Action></Project>'
        ).encode("utf-8")
        cam_jm = (
            '<?xml version="1.0" encoding="utf-8"?><Project><Action tag="" length="1.000" loop="false">'
            '<Track trackName="HitTriggerTick0" eventType="HitTriggerTick" guid="8e943844-af73-4d04-8860-1f87daa8a258" enabled="false"><Event eventName="HitTriggerTick" time="0.000" /></Track>'
            '<Track trackName="SkillFuncDuration0" eventType="SkillFuncDuration" guid="ba22c237-d2de-469a-bd24-ab9292870bd2" enabled="true"><Event eventName="SkillFuncDuration" time="0.000" length="1.000" /></Track>'
            '<Track trackName="SetCameraHeightDuration0" eventType="SetCameraHeightDuration" guid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" enabled="true">'
            '<Event eventName="SetCameraHeightDuration" time="0.000" length="1.000"><float name="heightRate" value="1.265" /></Event></Track>'
            '</Action></Project>'
        ).encode("utf-8")
        mowen_xml = (
            '<Project><Action>'
            '<Track trackName="LegitMsg" eventType="InBattleMsgSendTick" guid="11111111-1111-1111-1111-111111111111">'
            '<Event eventName="InBattleMsgSendTick"><String name="msgKey" value="Mowen_10302" /></Event></Track>'
            '</Action></Project>'
        ).encode("utf-8")

        ca_dirty = _mk_pkg_with_dirs(
            ["PassiveResource/", "mowen/"],
            [("PassiveResource/junglemark.xml", dirty_jm), ("mowen/10302.xml", mowen_xml)],
        )
        ca_cam = _mk_pkg_with_dirs(
            ["PassiveResource/"],
            [("PassiveResource/junglemark.xml", cam_jm)],
        )

        # Kiểm tra single-mod sanitize_common_actions_pkg
        ca_single_clean = core_processor.sanitize_common_actions_pkg(ca_dirty)
        with zipfile.ZipFile(io.BytesIO(ca_single_clean), "r") as zca1:
            jm1 = zca1.read("PassiveResource/junglemark.xml").decode("utf-8")
            self.assertNotIn("InBattleMsgSendTick", jm1)
            self.assertNotIn("KAMODAOV", jm1)
            self.assertIn("SkillFuncDuration0", jm1)
            self.assertIn("InBattleMsgSendTick", zca1.read("mowen/10302.xml").decode("utf-8"))
            self.assertGreaterEqual(len([i for i in zca1.infolist() if i.is_dir()]), 2)

        # 3) Full run_merge với 2 mod: Mod 0 (1.64.1.13 mới) + Mod 1 (1.64.1.12 cũ mang HeroInfoLua cũ & file scene 8 byte ZMODSKIN)
        old_heroinfo = _mk_pkg_with_dirs(["Lua_Signed/"], [("Lua_Signed/AOV/HeroInfo/test.bytes", b"OLD")])
        _, out_files, _, _ = core_processor.run_merge([
            {
                "name": "NewMod_150.zip",
                "explicit_ver": "1.64.1",
                "seed_hids": [150],
                "raw_files": {
                    "Resources/1.64.1/version.txt": b"1.64.1.13|1802180",
                    "Resources/1.64.1/KernelLua.pkg.bytes": kl_pkg_1,
                    "Resources/1.64.1/StableSystems_3.pkg.bytes": ss_pkg_1,
                    "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes": ca_cam,
                    "Resources/1.64.1/assetbundle/scene/scene_artist_5v5_v4_lv5.assetbundle": b"UnityFS\x00" + b"X" * 128,
                    "Resources/1.64.1/assetbundle/scene/scene_artist_5v5_v4_lv1.assetbundle": b"ZMODSKIN",
                },
            },
            {
                "name": "OldMod_595.zip",
                "explicit_ver": "1.64.1",
                "seed_hids": [595],
                "raw_files": {
                    "Resources/1.64.1/version.txt": b"1.64.1.12|1793129",
                    "Resources/1.64.1/KernelLua.pkg.bytes": kl_pkg_2,
                    "Resources/1.64.1/StableSystems_3.pkg.bytes": ss_pkg_2,
                    "Resources/1.64.1/HeroInfoLua.pkg.bytes": old_heroinfo,
                    "Resources/1.64.1/Ages/Prefab_Characters/Prefab_Hero/CommonActions.pkg.bytes": ca_dirty,
                    "Resources/1.64.1/assetbundle/scene/scene_artist_5v5_v4_lv3.assetbundle": b"ZMODSKIN",
                },
            },
        ])
        low = {k.lower(): v for k, v in out_files.items()}

        # HeroInfoLua cũ (1.64.1.12) bị lọc bỏ khỏi bản gộp 1.64.1.13
        self.assertNotIn("resources/1.64.1/heroinfolua.pkg.bytes", low)
        # File scene 8 byte giả ZMODSKIN bị bỏ, file UnityFS thật lv5 được giữ
        self.assertNotIn("resources/1.64.1/assetbundle/scene/scene_artist_5v5_v4_lv1.assetbundle", low)
        self.assertNotIn("resources/1.64.1/assetbundle/scene/scene_artist_5v5_v4_lv3.assetbundle", low)
        self.assertIn("resources/1.64.1/assetbundle/scene/scene_artist_5v5_v4_lv5.assetbundle", low)
        # KernelLua không còn raw.githubusercontent.com hay 127.0.0.1, giữ _0x242424 & bảo toàn dirs
        with zipfile.ZipFile(io.BytesIO(low["resources/1.64.1/kernellua.pkg.bytes"]), "r") as zkl:
            u_out = zkl.read("Lua_Signed/Kernel/Util/xlua/util_lua.bytes")
            self.assertEqual(len(u_out), len(dirty_util))
            self.assertIn(b"_0x242424", u_out)
            self.assertNotIn(b"raw.githubusercontent.com", u_out)
            self.assertNotIn(b"127.0.0.1", u_out)
            self.assertIn(b"none://", u_out)
            self.assertGreaterEqual(len([i for i in zkl.infolist() if i.is_dir()]), 3)
        # StableSystems_3 bảo toàn dirs>0
        with zipfile.ZipFile(io.BytesIO(low["resources/1.64.1/stablesystems_3.pkg.bytes"]), "r") as zss:
            self.assertGreaterEqual(len([i for i in zss.infolist() if i.is_dir()]), 3)
        # CommonActions junglemark sạch InBattleMsgSendTick nhưng vẫn giữ Cam Xa 1.265
        with zipfile.ZipFile(io.BytesIO(low["resources/1.64.1/ages/prefab_characters/prefab_hero/commonactions.pkg.bytes"]), "r") as zca:
            jm_out = zca.read("PassiveResource/junglemark.xml").decode("utf-8")
            self.assertNotIn("InBattleMsgSendTick", jm_out)
            self.assertNotIn("KAMODAOV", jm_out)
            self.assertIn('value="1.265"', jm_out)


class TestBootstrapKillSwitch(unittest.TestCase):
    """Test force-update / kill-switch endpoint."""

    @classmethod
    def setUpClass(cls):
        backend_main.app.state.limiter.enabled = False
        cls.client = TestClient(backend_main.app)
        cls._orig_min = backend_main.MIN_REQUIRED_BUILD

    @classmethod
    def tearDownClass(cls):
        backend_main.MIN_REQUIRED_BUILD = cls._orig_min

    def setUp(self):
        backend_main.MIN_REQUIRED_BUILD = self.__class__._orig_min

    def test_bootstrap_no_header_treated_as_build_zero(self):
        """Không có header X-App-Build → build=0 → phụ thuộc MIN_REQUIRED_BUILD."""
        backend_main.MIN_REQUIRED_BUILD = 1
        res = self.client.get("/api/v1/bootstrap")
        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertEqual(data["status"], "outdated")
        self.assertTrue(data["force_update"])

    def test_bootstrap_outdated_build(self):
        """Build nhỏ hơn MIN_REQUIRED_BUILD → force_update=true."""
        backend_main.MIN_REQUIRED_BUILD = 5
        res = self.client.get("/api/v1/bootstrap", headers={"X-App-Build": "3"})
        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertEqual(data["status"], "outdated")
        self.assertTrue(data["force_update"])
        self.assertIn("download_url", data)
        self.assertIn("message", data)
        self.assertEqual(data["min_build"], 5)

    def test_bootstrap_exact_min_build_passes(self):
        """Build đúng bằng MIN_REQUIRED_BUILD → ok."""
        backend_main.MIN_REQUIRED_BUILD = 5
        res = self.client.get("/api/v1/bootstrap", headers={"X-App-Build": "5"})
        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertEqual(data["status"], "ok")
        self.assertFalse(data["force_update"])

    def test_bootstrap_current_build_passes(self):
        """Build lớn hơn MIN_REQUIRED_BUILD → ok, trả về core_config."""
        backend_main.MIN_REQUIRED_BUILD = 1
        res = self.client.get("/api/v1/bootstrap", headers={"X-App-Build": "999"})
        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertEqual(data["status"], "ok")
        self.assertFalse(data["force_update"])
        self.assertIn("core_config", data)

    def test_bootstrap_invalid_build_header(self):
        """Header X-App-Build không phải số → coi là build 0."""
        backend_main.MIN_REQUIRED_BUILD = 1
        res = self.client.get("/api/v1/bootstrap", headers={"X-App-Build": "abc"})
        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertEqual(data["status"], "outdated")
        self.assertTrue(data["force_update"])


if __name__ == "__main__":
    unittest.main()