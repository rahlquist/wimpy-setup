#!/usr/bin/env python3
"""Recording stub of the Llama Hugs canonical API for the test harness.

POST /api/hugs/models/{model}         -> 200 {"ok": true}
POST /api/hugs/models/{model}/assets  -> 200 {"ok": true}
POST /api/hugs/models/{model}/smoke   -> 200 {"ok": true}
GET  /health                          -> 200 {"ok": true}

Every POST is appended to the log file as one JSON line:
  {"method": "POST", "path": "...", "body": {...}}

Env:
  HUGS_STUB_LOG   log file path (default /tmp/hugs-stub.log)
  HUGS_STUB_PORT  listen port (default 18099)
  HUGS_STUB_FAIL  "1" -> respond 500 to every POST (persistence-failure tests)
"""
import json
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ.get("HUGS_STUB_LOG", "/tmp/hugs-stub.log")
Path(LOG).parent.mkdir(parents=True, exist_ok=True)
FAIL = os.environ.get("HUGS_STUB_FAIL", "0") == "1"


class Handler(BaseHTTPRequestHandler):
    def _record_and_read(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        body = {}
        if raw:
            try:
                body = json.loads(raw)
            except Exception:
                body = {"_raw": raw.decode("utf-8", "replace")}
        try:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")
        except Exception:
            pass
        return raw

    def _reply(self, code, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self._record_and_read()
        self._reply(500 if FAIL else 200, {"ok": not FAIL})

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"ok": True})
            return
        self._reply(404, {"ok": False, "error": "not found"})

    def log_message(self, format, *args):
        pass


def main():
    port = int(os.environ.get("HUGS_STUB_PORT", "18099"))
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"hugs-api stub on 127.0.0.1:{port} log={LOG} fail={FAIL}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
