#!/usr/bin/python3
"""magpie-codex-router relay (macOS).

Lets Codex Desktop stay logged in with ChatGPT while model requests go to a
magpie gateway (any OpenAI Responses-compatible gateway with its own key).

Codex sends its ChatGPT token (or a placeholder API key) in Authorization.
This relay drops it and the ChatGPT account header, injects the gateway key
from the macOS Keychain, and forwards the request upstream. The ChatGPT token
never leaves this machine. It also converts the gateway's OpenAI-style
/v1/models list into the catalog format Codex expects.

Listens on 127.0.0.1 only. Python 3 standard library only.
Config: relay.json next to this file (written by install.sh).
"""
import copy
import getpass
import http.client
import http.server
import json
import os
import re
import socketserver
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("MAGPIE_RELAY_CONFIG",
                             os.path.join(HERE, "relay.json"))
TEMPLATES = os.path.join(HERE, "templates.json")


def load_config():
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    up = urlsplit(cfg["upstream"].rstrip("/"))
    if up.scheme not in ("https", "http") or not up.hostname:
        raise ValueError("upstream must be an http(s) URL")
    # Codex sends paths like /v1/responses. Keep any extra path prefix the
    # gateway has before /v1 (e.g. https://host/api/v1 -> /api).
    prefix = up.path[:-3] if up.path.endswith("/v1") else up.path
    return {
        "scheme": up.scheme,
        "host": up.hostname,
        "port": up.port or (443 if up.scheme == "https" else 80),
        "netloc": up.netloc,
        "prefix": prefix.rstrip("/"),
        "listen_port": int(cfg.get("port", 18765)),
        "keychain": ["/usr/bin/security", "find-generic-password",
                     "-a", cfg.get("keychain_account") or getpass.getuser(),
                     "-s", cfg.get("keychain_service", "magpie-api-key"),
                     "-w"],
    }


CFG = load_config()
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

_key = {"value": None, "at": 0.0}
_key_lock = threading.Lock()


def gateway_key(force=False):
    with _key_lock:
        if force or not _key["value"] or time.time() - _key["at"] > KEY_TTL:
            out = subprocess.run(CFG["keychain"], capture_output=True,
                                 text=True, timeout=10,
                                 check=True).stdout.strip()
            if not out:
                raise RuntimeError("empty gateway key from Keychain")
            _key.update(value=out, at=time.time())
        return _key["value"]


def _version(qs):
    v = (parse_qs(qs).get("client_version") or [""])[0]
    nums = [int(x) for x in re.findall(r"\d+", v)[:2]]
    return tuple(nums) if len(nums) == 2 else None


def to_codex_catalog(upstream, client_version):
    """Convert the gateway's OpenAI-style /v1/models list into Codex's catalog."""
    with open(TEMPLATES) as f:
        templates = {m["slug"]: m for m in json.load(f)["models"]}
    generic = next((templates[s] for s in GENERIC_TEMPLATES if s in templates),
                   next(iter(templates.values())))
    legacy = client_version is not None and client_version < LEGACY_BEFORE
    models = []
    for i, src in enumerate(upstream.get("data", [])):
        mid = src.get("id")
        if not mid:
            continue
        base = mid.split("/", 1)[-1]
        tpl = templates.get(base, generic)
        m = copy.deepcopy(tpl)
        descs = {r["effort"]: r.get("description", "")
                 for r in tpl.get("supported_reasoning_levels", [])}
        efforts = [r["effort"] for r in src.get("supported_reasoning_levels")
                   or [] if r.get("effort")]
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
            t.get("id") == "priority" for t in tiers) else []
        name = src.get("magpie_label") or src.get("display_name") or mid
        m.update(slug=mid, display_name=name,
                 description=f"{src.get('display_name') or mid} via gateway",
                 visibility="list", priority=i + 1, upgrade=None,
                 availability_nux=None)
        models.append(m)
    return {"models": models}


def log(msg):
    sys.stderr.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + msg + "\n")
    sys.stderr.flush()


def upstream_connection():
    cls = (http.client.HTTPSConnection if CFG["scheme"] == "https"
           else http.client.HTTPConnection)
    return cls(CFG["host"], CFG["port"], timeout=600)


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

    def _send_json(self, status, payload):
        out = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(out)
        self.close_connection = True

    def _proxy(self):
        if self.headers.get("Upgrade"):
            self.send_error(501, "websocket not supported by relay")
            return
        body = self._read_body()
        url = urlsplit(self.path)
        catalog = (self.command == "GET" and url.path == "/v1/models"
                   and "client_version" in url.query)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in DROP_REQ}
        headers["Host"] = CFG["netloc"]
        if body is not None:
            headers["Content-Length"] = str(len(body))
        target = CFG["prefix"] + self.path
        for attempt in (0, 1):
            try:
                headers["Authorization"] = "Bearer " + gateway_key(
                    force=attempt == 1)
            except Exception as e:
                log(f"keychain error: {e!r}")
                self.send_error(500, "relay could not read gateway key")
                return
            conn = upstream_connection()
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
        log(f"{self.command} {self.path} -> {resp.status}")
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
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _proxy


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    gateway_key()
    listen = ("127.0.0.1", CFG["listen_port"])
    log(f"relay listening on http://{listen[0]}:{listen[1]} -> "
        f"{CFG['scheme']}://{CFG['netloc']}{CFG['prefix']}")
    Server(listen, Handler).serve_forever()
