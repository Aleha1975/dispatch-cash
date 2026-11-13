"""Structured log, pluggable alerts, JSON state file (atomic), localhost /status server."""
from __future__ import annotations

import importlib
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LEVELS = {"info": 0, "warn": 1, "alarm": 2}


class Log:
    """JSON lines to stderr and optionally a file."""

    def __init__(self, path: str = "", name: str = "", echo: bool = True):
        self.path, self.name, self.echo = path, name, echo
        if path and os.path.dirname(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
        self.lock = threading.Lock()

    def __call__(self, event: str, **kw):
        rec = {"ts": round(time.time(), 3), "vault": self.name, "event": event, **kw}
        line = json.dumps(rec, default=str)
        with self.lock:
            if self.echo:
                print(line, file=sys.stderr, flush=True)
            if self.path:
                with open(self.path, "a") as fh:
                    fh.write(line + "\n")


def telegram_sender(token_env: str, chat_env: str):
    """Returns send(level, text) that posts to Telegram with token/chat from env (never from code/config)."""

    def send(level: str, text: str):
        token, chat = os.environ.get(token_env), os.environ.get(chat_env)
        if not token or not chat:
            raise RuntimeError(f"telegram env {token_env}/{chat_env} not set")
        body = urllib.parse.urlencode({"chat_id": chat, "text": text, "disable_web_page_preview": "true"}).encode()
        urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", body, timeout=10).read()

    return send


class Alerts:
    """alert(level, key, text): always logged; forwarded to the sink if level >= min_level and the same key was
    not sent within dedupe_s. Sink failures are logged, never raised."""

    def __init__(self, cfg, log: Log, name: str, sink=None):
        self.cfg, self.log, self.name = cfg, log, name
        self.last: dict[str, float] = {}
        self.recent: list[dict] = []
        if sink is not None:
            self.sink = sink
        elif cfg.sink == "telegram":
            self.sink = telegram_sender(cfg.telegram_token_env, cfg.telegram_chat_env)
        elif cfg.sink == "callable" and cfg.callable:
            mod, fn = cfg.callable.split(":")
            self.sink = getattr(importlib.import_module(mod), fn)
        else:
            self.sink = None

    def __call__(self, level: str, key: str, text: str):
        self.log("alert", level=level, key=key, text=text)
        self.recent = (self.recent + [{"ts": int(time.time()), "level": level, "key": key, "text": text}])[-30:]
        if LEVELS.get(level, 0) < LEVELS.get(self.cfg.min_level, 1) or self.sink is None:
            return
        now = time.time()
        if now - self.last.get(key, 0) < self.cfg.dedupe_s:
            return
        self.last[key] = now
        try:
            self.sink(level, f"[{self.name}] {text}")
        except Exception as e:  # never let alerting kill the keeper
            self.log("alert_sink_failed", error=str(e))


class State:
    def __init__(self, path: str):
        self.path = path
        if os.path.dirname(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
        self.d: dict = {}
        if os.path.exists(path):
            with open(path) as fh:
                self.d = json.load(fh)
        self.d.setdefault("version", 1)

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(self.d, fh, indent=1, sort_keys=True, default=str)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self.path)


class StatusServer:
    def __init__(self, host: str, port: int, get_status):
        get = get_status

        class H(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path.split("?")[0] not in ("/status", "/healthz"):
                    self.send_response(404)
                    self.end_headers()
                    return
                st = get()
                body = json.dumps(st if self.path.startswith("/status") else {"ok": st.get("ok")},
                                  default=str).encode()
                self.send_response(200 if (self.path.startswith("/status") or st.get("ok")) else 503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        if host not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("status server binds to localhost only")
        self.srv = ThreadingHTTPServer((host, port), H)
        self.port = self.srv.server_address[1]
        self.t = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.t.start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()
