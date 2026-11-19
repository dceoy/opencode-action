"""Serve scoped evidence reads and hold one review until OpenCode exits."""

import json
import os
import secrets
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock, Thread


MAX_REQUEST_BYTES = 1024 * 1024
ADAPTER_TIMEOUT = 120


class ReviewHandler(BaseHTTPRequestHandler):
    timeout = 10

    def log_message(self, *_):
        pass

    def do_POST(self):
        if self.path != self.server.route:
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_REQUEST_BYTES:
                raise ValueError("invalid request length")
            raw = self.rfile.read(length)
            request = json.loads(raw)
            method = request.get("method", "GET") if isinstance(request, dict) else None
        except (ValueError, OSError, RecursionError):
            self.send_error(400, "Invalid review request")
            return

        if method == "GET":
            try:
                response = self.server.run_adapter(raw, stderr=subprocess.DEVNULL)
            except (OSError, subprocess.TimeoutExpired):
                self.send_error(502, "Review adapter unavailable")
                return
            if response.returncode:
                self.send_error(422, "Scoped GitHub read failed")
                return
            body = response.stdout
        elif method == "POST":
            # Keep the original bytes so the adapter still rejects duplicate
            # JSON keys and checks the target, commit and payload before writing.
            with self.server.lock:
                if self.server.pending not in (None, raw):
                    self.send_error(409, "A review request is already queued")
                    return
                self.server.pending = raw
            body = b'{"status":"queued"}'
        else:
            self.send_error(400, "Invalid review method")
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ReviewServer(ThreadingHTTPServer):
    def __init__(self, adapter, token):
        super().__init__(("127.0.0.1", 0), ReviewHandler)
        self.route = "/" + secrets.token_urlsafe(32)
        self.pending = None
        self.lock = Lock()
        self.adapter = ["bash", adapter, "--request-stdin"]
        self.adapter_env = {**os.environ, "GH_TOKEN": token, "OPENCODE_REVIEW_PARENT_AUTH": "1"}

    def run_adapter(self, request, **kwargs):
        return subprocess.run(self.adapter, input=request, stdout=subprocess.PIPE,
                              env=self.adapter_env, timeout=ADAPTER_TIMEOUT, **kwargs)


def main(adapter, command):
    token = sys.stdin.read()
    if not token:
        print("::error::No GitHub token available for the OpenCode v2 review.", file=sys.stderr)
        return 1

    with ReviewServer(adapter, token) as server:
        broker = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        broker.start()
        try:
            child_env = {**os.environ, "OPENCODE_REVIEW_BROKER_URL": f"http://127.0.0.1:{server.server_port}{server.route}"}
            run = subprocess.run(command, env=child_env, stdin=subprocess.DEVNULL)
            with server.lock:
                pending = server.pending
        finally:
            server.shutdown()
            broker.join()
        if run.returncode:
            return run.returncode if run.returncode > 0 else 128 - run.returncode
        if pending is None:
            print("::error::OpenCode completed without queuing a review.", file=sys.stderr)
            return 1

        try:
            result = server.run_adapter(pending)
            if result.returncode:
                raise ValueError("adapter rejected the review")
            receipt = json.loads(result.stdout)
            commit = receipt.get("commit_id") if isinstance(receipt, dict) else None
            if not (isinstance(commit, str) and type(receipt.get("review_id")) is int
                    and receipt["review_id"] > 0 and receipt.get("state") == "COMMENTED"
                    and commit.lower() == os.environ["PR_REVIEW_HEAD_SHA"].lower()):
                raise ValueError("unexpected GitHub review receipt")
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            print(f"::error::Review publication could not be confirmed ({error}).", file=sys.stderr)
            return 1
        print(json.dumps(receipt))
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2:]))
