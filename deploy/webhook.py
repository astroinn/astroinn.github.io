"""Receive signed deployment requests from the blog's GitHub Actions job."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


SECRET = (Path(os.environ["CREDENTIALS_DIRECTORY"]) / "webhook-key").read_bytes().strip()
if len(SECRET) < 32:
    raise ValueError("Webhook key must have at least 32 bytes")


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def do_POST(self):
        if self.path != "/_deploy/blog":
            return self.reply(404)
        lengths = self.headers.get_all("Content-Length", [])
        if (len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,4}", lengths[0])
                or self.headers.get("Transfer-Encoding")):
            return self.reply(400)
        size = int(lengths[0])
        if not 0 < size <= 1024:
            return self.reply(413)

        body = self.rfile.read(size)
        expected = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        signature = self.headers.get("X-Hub-Signature-256", "")
        if not re.fullmatch(r"sha256=[a-f0-9]{64}", signature) or not hmac.compare_digest(expected, signature):
            return self.reply(403)

        try:
            payload = json.loads(body)
            timestamp = payload["timestamp"]
            if type(timestamp) is not int or abs(time.time() - timestamp) > 300:
                return self.reply(403)
        except (UnicodeDecodeError, ValueError, KeyError, TypeError):
            return self.reply(400)

        try:
            subprocess.run(
                ["/usr/bin/timeout", "--kill-after=5s", "70s", "/opt/astroinn-blog/pull-site.sh"],
                stdin=subprocess.DEVNULL, timeout=80, check=True,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            print(f"Deployment failed: {exc}", flush=True)
            return self.reply(503)
        return self.reply(204)

    def reply(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()


HTTPServer(("127.0.0.1", 8097), Handler).serve_forever()
