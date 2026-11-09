"""Local relay: Codex (logged in with ChatGPT) -> magpie gateway. Windows port.

Codex sends its ChatGPT token in Authorization. This relay drops it (and the
ChatGPT account header), injects the magpie key from Windows Credential
Manager, and forwards the request to magpie, streaming responses through.
The ChatGPT token never leaves this machine. Listens on loopback only.

GET /v1/models?client_version=X is converted from magpie's OpenAI-style list
into the Codex catalog format using templates.json (next to this file).
GET /__relay/health answers locally without contacting magpie.

Settings come from relay.json next to this file (written by install.ps1;
"upstream" is required):
  {"listen_port": 18765, "upstream": "https://gateway.example.com", "credential_target": "magpie-api-key"}
"""
import copy
import ctypes
import http.client
import http.server
import json
import os
import re
import socket
import socketserver
import sys
import threading
import time
from ctypes import wintypes
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
SETTINGS_PATH = os.path.join(HERE, "relay.json")
TEMPLATES_PATH = os.path.join(HERE, "templates.json")
LOG_PATH = os.path.join(HERE, "relay.log")
LOG_MAX_BYTES = 2 * 1024 * 1024

DEFAULTS = {
    "listen_host": "127.0.0.1",
    "listen_port": 18765,
    "upstream": "",
    "credential_target": "magpie-api-key",
    "env_fallback": "MAGPIE_API_KEY",
}
LOOPBACK = {"127.0.0.1", "::1", "localhost"}
KEY_TTL = 300
# Template used for gateway models that have no matching official Codex model.
GENERIC_TEMPLATES = ("gpt-5.6-sol", "gpt-6.1-sol", "gpt-6-sol")
# Older Codex builds reject reasoning efforts they don't know.
LEGACY_EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh"}
LEGACY_BEFORE = (0, 150)

DROP_REQ = {"host", "authorization", "chatgpt-account-id", "connection",
            "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
            "te", "trailer", "content-length"}
DROP_RESP = {"connection", "keep-alive", "transfer-encoding",
             "content-length", "upgrade", "trailer"}


def load_settings():
    s = dict(DEFAULTS)
    if os.path.exists(SETTINGS_PATH):
        with open(SETTINGS_PATH, encoding="utf-8-sig") as f:
            s.update(json.load(f))
    if s["listen_host"] not in LOOPBACK:
        raise SystemExit("relay refuses to listen on a non-loopback address")
    if not re.match(r"^https?://[^/]+", s.get("upstream") or ""):
        raise SystemExit("relay.json needs an http(s) \"upstream\" gateway URL")
    s["upstream"] = s["upstream"].rstrip("/")
    if s["upstream"].endswith("/v1"):
        # Codex already sends /v1/... paths; keep only what comes before /v1.
        s["upstream"] = s["upstream"][:-3]
    return s


SETTINGS = load_settings()
UPSTREAM = urlsplit(SETTINGS["upstream"])
UPSTREAM_PREFIX = UPSTREAM.path.rstrip("/")

# ---------------------------------------------------------------- logging

_log_lock = threading.Lock()


def log(msg):
    line = time.strftime("%Y-%m-%dT%H:%M:%S ") + msg + "\n"
    with _log_lock:
        try:
            if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
                os.replace(LOG_PATH, LOG_PATH + ".1")
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass
        if sys.stderr is not None:  # None under pythonw.exe
            try:
                sys.stderr.write(line)
                sys.stderr.flush()
            except Exception:
                pass

# ------------------------------------------------- Windows Credential Manager

CRED_TYPE_GENERIC = 1
ERROR_NOT_FOUND = 1168


class FILETIME(ctypes.Structure):
    _fields_ = [("dwLowDateTime", wintypes.DWORD),
                ("dwHighDateTime", wintypes.DWORD)]


class CREDENTIALW(ctypes.Structure):
    _fields_ = [("Flags", wintypes.DWORD),
                ("Type", wintypes.DWORD),
                ("TargetName", wintypes.LPWSTR),
                ("Comment", wintypes.LPWSTR),
                ("LastWritten", FILETIME),
                ("CredentialBlobSize", wintypes.DWORD),
                ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
                ("Persist", wintypes.DWORD),
                ("AttributeCount", wintypes.DWORD),
                ("Attributes", ctypes.c_void_p),
                ("TargetAlias", wintypes.LPWSTR),
                ("UserName", wintypes.LPWSTR)]


_advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
_CredReadW = _advapi32.CredReadW
_CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                       ctypes.POINTER(ctypes.POINTER(CREDENTIALW))]
_CredReadW.restype = wintypes.BOOL
_CredFree = _advapi32.CredFree
_CredFree.argtypes = [ctypes.c_void_p]
_CredFree.restype = None


def read_credential(target):
    """Return the secret of a generic credential, or None if it doesn't exist."""
    ptr = ctypes.POINTER(CREDENTIALW)()
    if not _CredReadW(target, CRED_TYPE_GENERIC, 0, ctypes.byref(ptr)):
        err = ctypes.get_last_error()
        if err == ERROR_NOT_FOUND:
            return None
        raise OSError(err, "CredReadW failed")
    try:
        cred = ptr.contents
        blob = ctypes.string_at(cred.CredentialBlob, cred.CredentialBlobSize)
    finally:
        _CredFree(ptr)
    # cmdkey and install.ps1 store UTF-16LE; tolerate UTF-8 from other tools.
    if len(blob) % 2 == 0 and b"\x00" in blob:
        value = blob.decode("utf-16-le")
    else:
        value = blob.decode("utf-8")
    return value.strip().strip("\x00") or None


_key = {"value": None, "at": 0.0, "source": None}
_key_lock = threading.Lock()


def magpie_key(force=False):
    with _key_lock:
        if force or not _key["value"] or time.time() - _key["at"] > KEY_TTL:
            value = read_credential(SETTINGS["credential_target"])
            source = "credential:" + SETTINGS["credential_target"]
            if not value and SETTINGS.get("env_fallback"):
                value = os.environ.get(SETTINGS["env_fallback"], "").strip() or None
                source = "env:" + SETTINGS["env_fallback"]
            if not value:
                raise RuntimeError("no magpie key in Credential Manager target "
                                   + SETTINGS["credential_target"])
            if source != _key["source"]:
                log("magpie key loaded from " + source)
            _key.update(value=value, at=time.time(), source=source)
        return _key["value"]

# -------------------------------------------------------------- catalog


_templates = {"data": None}


def templates():
    if _templates["data"] is None:
        with open(TEMPLATES_PATH, encoding="utf-8") as f:
            _templates["data"] = {m["slug"]: m for m in json.load(f)["models"]}
    return _templates["data"]


def _version(qs):
    v = (parse_qs(qs).get("client_version") or [""])[0]
    nums = [int(x) for x in re.findall(r"\d+", v)[:2]]
    return tuple(nums) if len(nums) == 2 else None


def _efforts(src):
    out = []
    for r in src.get("supported_reasoning_levels") or []:
        e = r.get("effort") if isinstance(r, dict) else r
        if isinstance(e, str) and e:
            out.append(e)
    return out


def to_codex_catalog(upstream, client_version):
    """Convert magpie's OpenAI-style /v1/models list into Codex's catalog."""
    tpls = templates()
    generic = next((tpls[s] for s in GENERIC_TEMPLATES if s in tpls),
                   next(iter(tpls.values())))
    legacy = client_version is not None and client_version < LEGACY_BEFORE
    models = []
    for i, src in enumerate(upstream.get("data", [])):
        mid = src.get("id")
        if not mid:
            continue
        base = mid.split("/", 1)[-1]
        tpl = tpls.get(base, generic)
        m = copy.deepcopy(tpl)
        descs = {r["effort"]: r.get("description", "")
                 for r in tpl.get("supported_reasoning_levels", [])}
        efforts = _efforts(src)
        if legacy:
            efforts = [e for e in efforts if e in LEGACY_EFFORTS]
        if not efforts:
            efforts = ["medium"]
        m["supported_reasoning_levels"] = [
            {"effort": e, "description": descs.get(e, e)} for e in efforts]
        if m.get("default_reasoning_level") not in efforts:
            m["default_reasoning_level"] = (
                "medium" if "medium" in efforts else efforts[0])
        if m.get("multi_agent_reasoning_effort") not in (None, *efforts):
            m.pop("multi_agent_reasoning_effort", None)
        ctx = src.get("context_window") or src.get("context_length")
        if ctx:
            m["context_window"] = ctx
            m["max_context_window"] = ctx
        mods = [x for x in (src.get("modalities") or {}).get("input", [])
                if x in ("text", "image")]
        if mods:
            m["input_modalities"] = mods
        tiers = src.get("service_tiers") or []
        m["service_tiers"] = tiers
        m["additional_speed_tiers"] = ["fast"] if any(
            isinstance(t, dict) and t.get("id") == "priority" for t in tiers) else []
        m.update(slug=mid,
                 display_name=src.get("magpie_label") or src.get("display_name") or mid,
                 description=f"{src.get('display_name') or mid} via magpie",
                 visibility="list", priority=i + 1, upgrade=None,
                 availability_nux=None)
        models.append(m)
    return {"models": models}

# -------------------------------------------------------------- proxy


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            parts = []
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip(), 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    break
                parts.append(self.rfile.read(size))
                self.rfile.readline()
            return b"".join(parts)
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else None

    def _send_json(self, status, obj):
        out = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(out)
        self.close_connection = True

    def _health(self):
        try:
            magpie_key()
            key_ok = True
        except Exception:
            key_ok = False
        self._send_json(200, {"ok": True, "pid": os.getpid(), "key": key_ok,
                              "key_source": _key["source"],
                              "upstream": UPSTREAM.netloc})

    def _connect(self):
        port = UPSTREAM.port or (443 if UPSTREAM.scheme == "https" else 80)
        cls = (http.client.HTTPSConnection if UPSTREAM.scheme == "https"
               else http.client.HTTPConnection)
        return cls(UPSTREAM.hostname, port, timeout=600)

    def _proxy(self):
        url = urlsplit(self.path)
        if self.command == "GET" and url.path == "/__relay/health":
            self._health()
            return
        if self.headers.get("Upgrade"):
            self.send_error(501, "websocket not supported by relay")
            return
        if not url.path.startswith("/v1/"):
            self.send_error(404, "relay only forwards /v1/*")
            return
        body = self._read_body()
        catalog = (self.command == "GET" and url.path == "/v1/models"
                   and "client_version" in url.query)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in DROP_REQ}
        headers["Host"] = UPSTREAM.netloc
        if catalog:
            headers["Accept-Encoding"] = "identity"
        if body is not None:
            headers["Content-Length"] = str(len(body))
        target = UPSTREAM_PREFIX + self.path
        for attempt in (0, 1):
            try:
                headers["Authorization"] = "Bearer " + magpie_key(force=attempt == 1)
            except Exception as e:
                log(f"key error: {e}")
                self._send_json(503, {"error": {"message": "magpie relay: " + str(e)}})
                return
            conn = self._connect()
            try:
                conn.request(self.command, target, body=body, headers=headers)
                resp = conn.getresponse()
            except Exception as e:
                conn.close()
                log(f"upstream error {self.command} {url.path}: {e!r}")
                self.send_error(502, "relay upstream error")
                return
            if resp.status == 401 and attempt == 0:
                resp.read()
                conn.close()
                continue
            break
        log(f"{self.command} {url.path} -> {resp.status}")
        if catalog and resp.status == 200:
            try:
                data = to_codex_catalog(json.loads(resp.read()),
                                        _version(url.query))
                log(f"  served Codex catalog: {len(data['models'])} models")
            except Exception as e:
                log(f"  catalog conversion failed: {e!r}")
                data = None
            finally:
                conn.close()
            if data is None:
                self.send_error(502, "relay catalog conversion failed")
            else:
                self._send_json(200, data)
            return
        try:
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in DROP_RESP:
                    self.send_header(k, v)
            no_body = self.command == "HEAD" or resp.status in (204, 304)
            if not no_body:
                self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            if not no_body:
                while True:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except OSError:  # client went away (BrokenPipe/ConnectionReset/Aborted)
            pass
        finally:
            conn.close()
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_HEAD = _proxy


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    # On Windows SO_REUSEADDR lets a second process bind the same port.
    allow_reuse_address = False

    def server_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def main():
    host, port = SETTINGS["listen_host"], int(SETTINGS["listen_port"])
    try:
        server = Server((host, port), Handler)
    except OSError as e:
        log(f"cannot listen on {host}:{port} ({e}); is another relay running?")
        return 3
    try:
        templates()
    except Exception as e:
        log(f"cannot load templates.json: {e!r}")
        return 4
    try:
        magpie_key()
    except Exception as e:
        log(f"warning: {e}; requests will fail until the key is stored")
    log(f"magpie relay pid {os.getpid()} listening on http://{host}:{port} -> {UPSTREAM.netloc}")
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
