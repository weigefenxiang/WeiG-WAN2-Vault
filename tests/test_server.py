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
        cls.proc = subprocess.Popen(["python3", str(APP)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

    def test_bad_host_rejected(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", "/", headers={"Host": "evil.example.com"})
        r = conn.getresponse()
        r.read()
        self.assertEqual(r.status, 421)
        conn.close()

    def test_update_and_browser_read(self):
        payload = json.dumps({"ip": "203.0.113.10"}).encode()
        status, _, _ = self.request("POST", "/api/v1/update", payload, {
            "CF-Connecting-IP": "203.0.113.10",
            "Authorization": "Bearer " + "a" * 64,
            "Content-Type": "application/json",
        })
        self.assertEqual(status, 204)

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
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        status, _, body = self.request("GET", "/api/v1/current", headers={
            "CF-Connecting-IP": "198.51.100.20",
            "Cookie": cookie,
        })
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertEqual(data["ip"], "203.0.113.10")
        self.assertEqual(data["client_ip"], "198.51.100.20")

    def test_update_source_mismatch_rejected(self):
        payload = json.dumps({"ip": "203.0.113.11"}).encode()
        status, _, _ = self.request("POST", "/api/v1/update", payload, {
            "CF-Connecting-IP": "203.0.113.12",
            "Authorization": "Bearer " + "a" * 64,
            "Content-Type": "application/json",
        })
        self.assertEqual(status, 403)

    def test_current_requires_login(self):
        status, _, _ = self.request("GET", "/api/v1/current")
        self.assertEqual(status, 401)


if __name__ == "__main__":
    unittest.main()
