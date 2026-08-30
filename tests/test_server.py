import hashlib
import http.client
import json
import os
import secrets
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "server" / "wan2-vault.py"


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        base = Path(cls.tmp.name)
        cls.etc = base / "etc"
        cls.state = base / "state"
        cls.etc.mkdir()
        cls.state.mkdir()
        cls.port = 39557
        salt = secrets.token_bytes(16)
        pw = b"correct horse battery staple"
        pw_hash = hashlib.scrypt(pw, salt=salt, n=16384, r=8, p=1, dklen=32)
        (cls.etc / "config.json").write_text(json.dumps({
            "public_hostname": "notify.example.com",
            "bind_host": "127.0.0.1",
            "bind_port": cls.port,
        }), encoding="utf-8")
        (cls.etc / "auth.json").write_text(json.dumps({
            "username": "testuser",
            "salt_hex": salt.hex(),
            "password_hash_hex": pw_hash.hex(),
            "scrypt": {"n": 16384, "r": 8, "p": 1, "dklen": 32},
        }), encoding="utf-8")
        (cls.etc / "secrets.json").write_text(json.dumps({
            "write_token": "a" * 64,
            "session_secret_hex": secrets.token_bytes(32).hex(),
        }), encoding="utf-8")
        env = os.environ.copy()
        env["WAN2VAULT_CONFIG_DIR"] = str(cls.etc)
        env["WAN2VAULT_STATE_DIR"] = str(cls.state)
        cls.proc = subprocess.Popen(
            ["python3", str(APP)], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=1)
                conn.request("GET", "/", headers={"Host": "notify.example.com"})
                r = conn.getresponse()
                r.read()
                conn.close()
                if r.status == 200:
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("test server did not start")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        cls.tmp.cleanup()

    def setUp(self):
        try:
            (self.state / "current.json").unlink()
        except FileNotFoundError:
            pass

    def request(self, method, path, body=None, headers=None):
        h = {"Host": "notify.example.com"}
        if headers:
            h.update(headers)
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body, headers=h)
        r = conn.getresponse()
        data = r.read()
        out_headers = dict(r.getheaders())
        status = r.status
        conn.close()
        return status, out_headers, data

    def login_cookie(self):
        form = urlencode({
            "username": "testuser",
            "password": "correct horse battery staple",
            "remember": "1",
        }).encode()
        status, headers, _ = self.request("POST", "/login", form, {
            "CF-Connecting-IP": "198.51.100.20",
            "Content-Type": "application/x-www-form-urlencoded",
        })
        self.assertEqual(status, 303)
        return headers["Set-Cookie"].split(";", 1)[0]

    def post_update(self, interface, ip, source=None, device=""):
        payload = {"interface": interface, "ip": ip, "device": device}
        return self.request("POST", "/api/v1/update", json.dumps(payload).encode(), {
            "CF-Connecting-IP": source or ip,
            "Authorization": "Bearer " + "a" * 64,
            "Content-Type": "application/json",
        })

    def current(self, cookie):
        status, _, body = self.request("GET", "/api/v1/current", headers={
            "CF-Connecting-IP": "198.51.100.20",
            "Cookie": cookie,
        })
        self.assertEqual(status, 200)
        return json.loads(body)

    def test_bad_host_rejected(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", "/", headers={"Host": "evil.example.com"})
        r = conn.getresponse()
        r.read()
        self.assertEqual(r.status, 421)
        conn.close()

    def test_legacy_update_defaults_to_wan2(self):
        payload = json.dumps({"ip": "203.0.113.10"}).encode()
        status, _, _ = self.request("POST", "/api/v1/update", payload, {
            "CF-Connecting-IP": "203.0.113.10",
            "Authorization": "Bearer " + "a" * 64,
            "Content-Type": "application/json",
        })
        self.assertEqual(status, 204)
        data = self.current(self.login_cookie())
        self.assertEqual(data["ip"], "203.0.113.10")
        self.assertEqual(data["interfaces"][0]["name"], "WAN2")
        self.assertEqual(data["interfaces"][0]["last_report_status"], "success")

    def test_multiple_interfaces_are_kept_separately(self):
        self.assertEqual(self.post_update("WAN", "203.0.113.10", device="pppoe-WAN")[0], 204)
        self.assertEqual(self.post_update("WAN2", "203.0.113.11", device="pppoe-WAN2")[0], 204)
        data = self.current(self.login_cookie())
        by_name = {x["name"]: x for x in data["interfaces"]}
        self.assertEqual(by_name["WAN"]["ip"], "203.0.113.10")
        self.assertEqual(by_name["WAN2"]["ip"], "203.0.113.11")
        self.assertEqual(by_name["WAN2"]["device"], "pppoe-WAN2")

    def test_unchanged_ip_keeps_change_time(self):
        self.assertEqual(self.post_update("WAN2", "203.0.113.11")[0], 204)
        first = self.current(self.login_cookie())
        first_changed = first["interfaces"][0]["changed_at"]
        time.sleep(1.1)
        self.assertEqual(self.post_update("WAN2", "203.0.113.11")[0], 204)
        second = self.current(self.login_cookie())
        item = second["interfaces"][0]
        self.assertEqual(item["changed_at"], first_changed)
        self.assertGreater(item["last_report_at"], first_changed)

    def test_source_mismatch_records_failure_without_replacing_ip(self):
        self.assertEqual(self.post_update("WAN2", "203.0.113.11")[0], 204)
        status, _, _ = self.post_update("WAN2", "203.0.113.12", source="203.0.113.13")
        self.assertEqual(status, 403)
        data = self.current(self.login_cookie())
        item = data["interfaces"][0]
        self.assertEqual(item["ip"], "203.0.113.11")
        self.assertEqual(item["last_report_status"], "failed")
        self.assertEqual(item["last_report_error"], "source_mismatch")

    def test_inventory_marks_missing_interface_inactive(self):
        self.assertEqual(self.post_update("WAN", "203.0.113.10")[0], 204)
        self.assertEqual(self.post_update("WAN2", "203.0.113.11")[0], 204)
        payload = json.dumps({"interfaces": [{"name": "WAN2", "device": "pppoe-WAN2"}]}).encode()
        status, _, _ = self.request("POST", "/api/v1/inventory", payload, {
            "CF-Connecting-IP": "203.0.113.11",
            "Authorization": "Bearer " + "a" * 64,
            "Content-Type": "application/json",
        })
        self.assertEqual(status, 204)
        data = self.current(self.login_cookie())
        by_name = {x["name"]: x for x in data["interfaces"]}
        self.assertFalse(by_name["WAN"]["active"])
        self.assertTrue(by_name["WAN2"]["active"])

    def test_v1_state_migrates_on_read(self):
        ts = int(time.time()) - 10
        (self.state / "current.json").write_text(
            json.dumps({"ip": "203.0.113.40", "updated_at": ts}), encoding="utf-8",
        )
        data = self.current(self.login_cookie())
        self.assertEqual(data["schema"], 2)
        self.assertEqual(data["interfaces"][0]["name"], "WAN2")
        self.assertEqual(data["interfaces"][0]["ip"], "203.0.113.40")
        self.assertEqual(data["interfaces"][0]["changed_at"], ts)

    def test_current_requires_login(self):
        status, _, _ = self.request("GET", "/api/v1/current")
        self.assertEqual(status, 401)


if __name__ == "__main__":
    unittest.main()
