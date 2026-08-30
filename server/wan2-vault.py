#!/usr/bin/env python3
"""WeiG-WAN2-Vault: localhost-only WAN IPv4 vault for Cloudflare Tunnel."""

from __future__ import annotations

import base64
import hashlib
import hmac
import html
import ipaddress
import json
import os
import secrets
import tempfile
import threading
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

CONFIG_DIR = Path(os.environ.get("WAN2VAULT_CONFIG_DIR", "/etc/wan2-vault"))
STATE_DIR = Path(os.environ.get("WAN2VAULT_STATE_DIR", "/var/lib/wan2-vault"))
CONFIG_FILE = CONFIG_DIR / "config.json"
AUTH_FILE = CONFIG_DIR / "auth.json"
SECRETS_FILE = CONFIG_DIR / "secrets.json"
CURRENT_FILE = STATE_DIR / "current.json"
SESSIONS_FILE = STATE_DIR / "sessions.json"

COOKIE_NAME = "__Host-wan2vault_session"
REMEMBER_SECONDS = 10 * 365 * 24 * 60 * 60
SESSION_SECONDS = 12 * 60 * 60
SLIDING_RENEW_AFTER = 24 * 60 * 60
LOGIN_WINDOW = 10 * 60
LOGIN_MAX_FAILURES = 5
LOGIN_BLOCK_SECONDS = 10 * 60
MAX_BODY = 4096

STORE_LOCK = threading.RLock()
LOGIN_LOCK = threading.RLock()
LOGIN_FAILURES: dict[str, list[float]] = {}
LOGIN_BLOCKED_UNTIL: dict[str, float] = {}


def _read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        obj = json.load(f)
    if not isinstance(obj, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return obj


CONFIG = _read_json(CONFIG_FILE)
AUTH = _read_json(AUTH_FILE)
SECRETS = _read_json(SECRETS_FILE)

PUBLIC_HOSTNAME = str(CONFIG["public_hostname"]).strip().lower().rstrip(".")
BIND_HOST = str(CONFIG.get("bind_host", "127.0.0.1"))
BIND_PORT = int(CONFIG.get("bind_port", 29444))
WRITE_TOKEN = str(SECRETS["write_token"])
SESSION_SECRET = bytes.fromhex(str(SECRETS["session_secret_hex"]))

if BIND_HOST not in {"127.0.0.1", "::1"}:
    raise RuntimeError("Refusing to bind to a non-loopback address")
if len(WRITE_TOKEN) < 32:
    raise RuntimeError("WRITE_TOKEN is too short")
if len(SESSION_SECRET) < 32:
    raise RuntimeError("SESSION_SECRET is too short")


STYLE_CSS = r"""
:root{color-scheme:light dark;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f5f7;color:#171717}
.card{width:min(92vw,480px);background:#fff;border:1px solid #ddd;border-radius:16px;padding:28px;box-shadow:0 12px 34px rgba(0,0,0,.08)}
h1{font-size:1.45rem;margin:0 0 6px}.sub{margin:0 0 24px;color:#666}.field{margin:14px 0}.field label{display:block;font-size:.9rem;margin-bottom:6px}
input[type=text],input[type=password]{width:100%;padding:12px;border:1px solid #bbb;border-radius:10px;font:inherit}.remember{display:flex;gap:8px;align-items:center;margin:16px 0}
button{border:0;border-radius:10px;padding:11px 16px;font:inherit;cursor:pointer;background:#111;color:#fff}.wide{width:100%}.error{background:#fff1f1;border:1px solid #ffcccc;padding:10px;border-radius:9px;margin:12px 0}
.row{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:14px 0;border-bottom:1px solid #eee}.row:last-child{border-bottom:0}.label{color:#666;font-size:.88rem}.value{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;word-break:break-all}.status{font-weight:700}.actions{display:flex;gap:10px;margin-top:22px}.ghost{background:#eee;color:#111}.small{font-size:.85rem;color:#777}.hidden{display:none}
@media(prefers-color-scheme:dark){body{background:#111318;color:#eee}.card{background:#191c22;border-color:#333;box-shadow:none}.sub,.label,.small{color:#aaa}.row{border-color:#333}input[type=text],input[type=password]{background:#111318;color:#eee;border-color:#555}.ghost{background:#333;color:#eee}.error{background:#3a1717;border-color:#6e2929}}
""".strip()

APP_JS = r"""
(() => {
  const $ = (id) => document.getElementById(id);
  const ip = $('wan2-ip');
  if (!ip) return;
  const updated = $('updated');
  const status = $('status');
  const client = $('client-ip');
  const copy = $('copy-ip');
  async function refresh() {
    try {
      const r = await fetch('/api/v1/current', {cache:'no-store', credentials:'same-origin'});
      if (r.status === 401) { location.reload(); return; }
      if (!r.ok) throw new Error('request failed');
      const d = await r.json();
      ip.textContent = d.ip || 'Not reported';
      updated.textContent = d.updated_human || 'Never';
      status.textContent = d.status || 'Unknown';
      client.textContent = d.client_ip || 'Unknown';
      copy.disabled = !d.ip;
    } catch (_) {
      status.textContent = 'Unavailable';
    }
  }
  copy.addEventListener('click', async () => {
    const v = ip.textContent.trim();
    if (!v || v === 'Not reported') return;
    try { await navigator.clipboard.writeText(v); copy.textContent = 'Copied'; setTimeout(() => copy.textContent='Copy IP', 1200); } catch (_) {}
  });
  refresh();
  setInterval(refresh, 15000);
})();
""".strip()


def _atomic_write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def _load_sessions() -> dict:
    try:
        obj = _read_json(SESSIONS_FILE)
    except FileNotFoundError:
        return {}
    return obj


def _save_sessions(obj: dict) -> None:
    _atomic_write_json(SESSIONS_FILE, obj)


def _session_hash(token: str) -> str:
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def _csrf(token: str) -> str:
    return hmac.new(SESSION_SECRET, b"csrf:" + token.encode("ascii"), hashlib.sha256).hexdigest()


def _new_token() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode("ascii")


def _verify_password(password: str) -> bool:
    salt = bytes.fromhex(str(AUTH["salt_hex"]))
    expected = bytes.fromhex(str(AUTH["password_hash_hex"]))
    params = AUTH.get("scrypt", {})
    actual = hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=int(params.get("n", 16384)),
        r=int(params.get("r", 8)),
        p=int(params.get("p", 1)),
        dklen=len(expected),
    )
    return hmac.compare_digest(actual, expected)


def _safe_client_ip(value: str | None) -> str | None:
    if not value:
        return None
    try:
        return str(ipaddress.ip_address(value.strip()))
    except ValueError:
        return None


def _human_age(seconds: int) -> str:
    if seconds < 0:
        return "just now"
    if seconds < 60:
        return f"{seconds}s ago"
    if seconds < 3600:
        return f"{seconds // 60}m ago"
    if seconds < 86400:
        return f"{seconds // 3600}h ago"
    return f"{seconds // 86400}d ago"


def _status_for_age(age: int | None) -> str:
    if age is None:
        return "Unknown"
    if age <= 45 * 60:
        return "Online"
    if age <= 2 * 60 * 60:
        return "Stale"
    return "Unknown"


def _prune_login_state(now: float) -> None:
    for ip in list(LOGIN_FAILURES):
        kept = [t for t in LOGIN_FAILURES[ip] if now - t <= LOGIN_WINDOW]
        if kept:
            LOGIN_FAILURES[ip] = kept
        else:
            LOGIN_FAILURES.pop(ip, None)
    for ip in list(LOGIN_BLOCKED_UNTIL):
        if LOGIN_BLOCKED_UNTIL[ip] <= now:
            LOGIN_BLOCKED_UNTIL.pop(ip, None)


class Handler(BaseHTTPRequestHandler):
    server_version = ""
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:
        return

    def _security_headers(self, *, html_page: bool = False) -> None:
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Strict-Transport-Security", "max-age=31536000")
        if html_page:
            self.send_header(
                "Content-Security-Policy",
                "default-src 'none'; style-src 'self'; script-src 'self'; "
                "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
            )

    def _reply(self, code: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8", *, html_page: bool = False, extra_headers: list[tuple[str, str]] | None = None) -> None:
        self.send_response(code)
        self._security_headers(html_page=html_page)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        cookie_value = getattr(self, "_pending_cookie", None)
        if cookie_value:
            self.send_header("Set-Cookie", cookie_value)
        if extra_headers:
            for k, v in extra_headers:
                if k.lower() == "set-cookie" and cookie_value:
                    continue
                self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._reply(code, body, "application/json; charset=utf-8")

    def _hostname_ok(self) -> bool:
        raw = (self.headers.get("Host") or "").strip().lower()
        host = raw.split(":", 1)[0].rstrip(".")
        return host == PUBLIC_HOSTNAME

    def _client_ip(self) -> str | None:
        return _safe_client_ip(self.headers.get("CF-Connecting-IP"))

    def _read_body(self) -> bytes | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length < 0 or length > MAX_BODY:
            return None
        return self.rfile.read(length)

    def _parse_form(self) -> dict[str, str] | None:
        raw = self._read_body()
        if raw is None:
            return None
        try:
            parsed = parse_qs(raw.decode("utf-8"), keep_blank_values=True, strict_parsing=False)
        except UnicodeDecodeError:
            return None
        return {k: v[-1] for k, v in parsed.items() if v}

    def _cookie_token(self) -> str | None:
        raw = self.headers.get("Cookie")
        if not raw:
            return None
        try:
            jar = cookies.SimpleCookie()
            jar.load(raw)
            morsel = jar.get(COOKIE_NAME)
            return morsel.value if morsel else None
        except cookies.CookieError:
            return None

    def _authenticate_session(self) -> tuple[str, dict] | None:
        token = self._cookie_token()
        if not token or len(token) > 128:
            return None
        key = _session_hash(token)
        now = int(time.time())
        with STORE_LOCK:
            sessions = _load_sessions()
            record = sessions.get(key)
            if not isinstance(record, dict):
                return None
            if int(record.get("expires", 0)) <= now:
                sessions.pop(key, None)
                _save_sessions(sessions)
                return None
            last_seen = int(record.get("last_seen", 0))
            if now - last_seen >= SLIDING_RENEW_AFTER:
                record["last_seen"] = now
                record["expires"] = now + (REMEMBER_SECONDS if record.get("remember") else SESSION_SECONDS)
                sessions[key] = record
                _save_sessions(sessions)
                self._set_session_cookie(token, bool(record.get("remember")))
        return token, record

    def _set_session_cookie(self, token: str, remember: bool) -> None:
        parts = [
            f"{COOKIE_NAME}={token}",
            "Path=/",
            "Secure",
            "HttpOnly",
            "SameSite=Strict",
        ]
        if remember:
            parts.append(f"Max-Age={REMEMBER_SECONDS}")
        self._pending_cookie = "; ".join(parts)

    def _clear_session_cookie(self) -> None:
        self._pending_cookie = f"{COOKIE_NAME}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"

    def _reply_with_cookie(self, code: int, body: bytes, content_type: str, *, html_page: bool = False, location: str | None = None) -> None:
        headers: list[tuple[str, str]] = []
        if location:
            headers.append(("Location", location))
        self._reply(code, body, content_type, html_page=html_page, extra_headers=headers)

    def _login_page(self, error: str | None = None) -> bytes:
        error_html = f'<div class="error">{html.escape(error)}</div>' if error else ""
        return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Private Vault</title><link rel="stylesheet" href="/assets/style.css"></head>
<body><main class="card"><h1>Private Vault</h1><p class="sub">Sign in to continue</p>{error_html}
<form method="post" action="/login" autocomplete="on">
<div class="field"><label for="username">Username</label><input id="username" name="username" type="text" autocomplete="username" required maxlength="128"></div>
<div class="field"><label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password" required maxlength="512"></div>
<label class="remember"><input type="checkbox" name="remember" value="1" checked> Keep me signed in until I log out</label>
<button class="wide" type="submit">Sign in</button></form></main></body></html>""".encode("utf-8")

    def _dashboard_page(self, csrf: str) -> bytes:
        return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>WAN2 Vault</title><link rel="stylesheet" href="/assets/style.css"></head>
<body><main class="card"><h1>WeiG WAN2 Vault</h1><p class="sub">Current private WAN status</p>
<div class="row"><div><div class="label">WAN2 IPv4</div><div id="wan2-ip" class="value">Loading…</div></div><button id="copy-ip" class="ghost" type="button">Copy IP</button></div>
<div class="row"><div><div class="label">Status</div><div id="status" class="status">Loading…</div></div></div>
<div class="row"><div><div class="label">Last report</div><div id="updated">Loading…</div></div></div>
<div class="row"><div><div class="label">Current client IP</div><div id="client-ip" class="value">Loading…</div></div></div>
<div class="actions"><form method="post" action="/logout"><input type="hidden" name="csrf" value="{html.escape(csrf)}"><button class="ghost" type="submit">Log out</button></form></div>
<p class="small">WAN IP responses are never browser-cached.</p></main><script src="/assets/app.js" defer></script></body></html>""".encode("utf-8")

    def do_GET(self) -> None:
        self._pending_cookie = None
        if not self._hostname_ok():
            return self._reply(421, b"Misdirected Request\n")

        if self.path == "/assets/style.css":
            return self._reply(200, STYLE_CSS.encode("utf-8"), "text/css; charset=utf-8")
        if self.path == "/assets/app.js":
            return self._reply(200, APP_JS.encode("utf-8"), "application/javascript; charset=utf-8")

        if self.path == "/":
            session = self._authenticate_session()
            if not session:
                return self._reply_with_cookie(200, self._login_page(), "text/html; charset=utf-8", html_page=True)
            token, _ = session
            return self._reply_with_cookie(200, self._dashboard_page(_csrf(token)), "text/html; charset=utf-8", html_page=True)

        if self.path == "/api/v1/current":
            session = self._authenticate_session()
            if not session:
                return self._json(401, {"error": "unauthorized"})
            now = int(time.time())
            try:
                current = _read_json(CURRENT_FILE)
                ip = _safe_client_ip(str(current.get("ip", "")))
                updated_at = int(current.get("updated_at", 0))
                age = max(0, now - updated_at) if updated_at else None
            except (FileNotFoundError, ValueError, TypeError):
                ip, updated_at, age = None, 0, None
            return self._json(200, {
                "ip": ip,
                "updated_at": updated_at or None,
                "updated_human": _human_age(age) if age is not None else "Never",
                "age_seconds": age,
                "status": _status_for_age(age),
                "client_ip": self._client_ip(),
            })

        return self._reply(404, b"Not Found\n")

    def do_POST(self) -> None:
        self._pending_cookie = None
        if not self._hostname_ok():
            return self._reply(421, b"Misdirected Request\n")

        if self.path == "/login":
            client_ip = self._client_ip() or "unknown"
            now = time.time()
            with LOGIN_LOCK:
                _prune_login_state(now)
                if LOGIN_BLOCKED_UNTIL.get(client_ip, 0) > now:
                    return self._reply_with_cookie(429, self._login_page("Too many failed attempts. Try again later."), "text/html; charset=utf-8", html_page=True)

            form = self._parse_form()
            if form is None:
                return self._reply(400, b"Bad Request\n")
            username = form.get("username", "")
            password = form.get("password", "")
            remember = form.get("remember") == "1"

            user_ok = hmac.compare_digest(username, str(AUTH["username"]))
            pass_ok = _verify_password(password) if user_ok else _verify_password("not-the-password")

            if not (user_ok and pass_ok):
                with LOGIN_LOCK:
                    failures = LOGIN_FAILURES.setdefault(client_ip, [])
                    failures.append(now)
                    failures[:] = [t for t in failures if now - t <= LOGIN_WINDOW]
                    if len(failures) >= LOGIN_MAX_FAILURES:
                        LOGIN_BLOCKED_UNTIL[client_ip] = now + LOGIN_BLOCK_SECONDS
                        LOGIN_FAILURES.pop(client_ip, None)
                return self._reply_with_cookie(401, self._login_page("Invalid username or password."), "text/html; charset=utf-8", html_page=True)

            with LOGIN_LOCK:
                LOGIN_FAILURES.pop(client_ip, None)
                LOGIN_BLOCKED_UNTIL.pop(client_ip, None)

            token = _new_token()
            ts = int(now)
            record = {
                "created_at": ts,
                "last_seen": ts,
                "expires": ts + (REMEMBER_SECONDS if remember else SESSION_SECONDS),
                "remember": remember,
            }
            with STORE_LOCK:
                sessions = _load_sessions()
                sessions[_session_hash(token)] = record
                _save_sessions(sessions)
            self._set_session_cookie(token, remember)
            return self._reply_with_cookie(303, b"", "text/plain; charset=utf-8", location="/")

        if self.path == "/logout":
            session = self._authenticate_session()
            if not session:
                self._clear_session_cookie()
                return self._reply_with_cookie(303, b"", "text/plain; charset=utf-8", location="/")
            token, _ = session
            form = self._parse_form()
            if form is None or not hmac.compare_digest(form.get("csrf", ""), _csrf(token)):
                return self._reply(403, b"Forbidden\n")
            with STORE_LOCK:
                sessions = _load_sessions()
                sessions.pop(_session_hash(token), None)
                _save_sessions(sessions)
            self._clear_session_cookie()
            return self._reply_with_cookie(303, b"", "text/plain; charset=utf-8", location="/")

        if self.path == "/api/v1/update":
            authz = self.headers.get("Authorization", "")
            if not hmac.compare_digest(authz, f"Bearer {WRITE_TOKEN}"):
                return self._json(401, {"error": "unauthorized"})
            raw = self._read_body()
            if raw is None:
                return self._json(400, {"error": "bad_request"})
            try:
                payload = json.loads(raw.decode("utf-8"))
                posted = str(ipaddress.ip_address(str(payload["ip"])))
                if ipaddress.ip_address(posted).version != 4:
                    raise ValueError
            except (UnicodeDecodeError, json.JSONDecodeError, KeyError, ValueError, TypeError):
                return self._json(400, {"error": "invalid_ipv4"})

            edge_ip = self._client_ip()
            if not edge_ip:
                return self._json(403, {"error": "cloudflare_source_required"})
            try:
                if ipaddress.ip_address(edge_ip).version != 4:
                    return self._json(403, {"error": "ipv4_source_required"})
            except ValueError:
                return self._json(403, {"error": "invalid_source"})
            if not hmac.compare_digest(posted, edge_ip):
                return self._json(403, {"error": "source_mismatch"})

            with STORE_LOCK:
                _atomic_write_json(CURRENT_FILE, {"ip": posted, "updated_at": int(time.time())})
            self.send_response(204)
            self._security_headers()
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        return self._reply(404, b"Not Found\n")


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
