#!/usr/bin/env python3
"""Behavioural regression for build/vendor/app-runner.go, run on the dev box.

Each case compiles the runner with a temporary appPath/tmpPath/appURL, serves one
body shape from a local HTTP server and inspects the result:

  success  the file at appPath has exactly the served length, tmpPath is gone
  failure  nothing is installed and tmpPath is gone (a retry never resumes a
           partial file)

The runner retries six times with a 3s delay, so failure cases are timed out
instead of waited out.
"""

from __future__ import annotations

import argparse
import http.server
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
SOURCE = REPO / "build" / "vendor" / "app-runner.go"
LENGTH = 1_234_567


def payload(size: int) -> bytes:
    return bytes((i * 7 + 11) & 0xFF for i in range(size))


PLAIN = payload(LENGTH)
CHUNKED = payload(150_007)
CHUNKED_EXT = payload(100_000)


class Handler(http.server.BaseHTTPRequestHandler):
    """One body shape per path; unknown paths answer 404."""

    def log_message(self, *_args):
        pass  # keep the test output clean

    def _send(self, body: bytes, *, chunked: bool, declared: int | None = None):
        self.send_response(200)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(declared if declared is not None else len(body)))
        self.end_headers()
        if chunked:
            for start in range(0, len(body), 4096):
                block = body[start:start + 4096]
                self.wfile.write(f"{len(block):x};case=1\r\n".encode())
                self.wfile.write(block + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler contract
        path = self.path
        if path == "/plain":
            self._send(PLAIN, chunked=False)
        elif path == "/chunked":
            self._send(CHUNKED, chunked=True)
        elif path == "/chunked-ext":
            self._send(CHUNKED_EXT, chunked=True)
        elif path == "/redir-abs":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/chunked")
            self.end_headers()
        elif path == "/redir-rel":
            self.send_response(302)
            self.send_header("Location", "/plain")
            self.end_headers()
        elif path == "/redir-chain":
            self.send_response(302)
            self.send_header("Location", "/redir-abs")
            self.end_headers()
        elif path == "/short":
            # Promises more bytes than it sends, so the runner must reject it.
            self._send(PLAIN[:1000], chunked=False, declared=len(PLAIN))
        else:
            self.send_response(404)
            self.end_headers()


PLACEHOLDER = b"#!/bin/sh\nexit 0\n"


def build_once(work: pathlib.Path, url: str) -> pathlib.Path:
    binary = work / "runner"
    app_path = work / "app"
    tmp_path = work / "app.tmp"
    cmd = [
        "go", "build", "-trimpath", "-ldflags",
        f"-s -w -X main.appPath={app_path} -X main.tmpPath={tmp_path} -X main.appURL={url}",
        "-o", str(binary), str(SOURCE),
    ]
    subprocess.run(cmd, check=True, cwd=str(REPO))
    return binary


def run_case(name: str, url: str, *, expect_bytes: int | None, timeout: float = 8.0) -> bool:
    with tempfile.TemporaryDirectory() as tmpdir:
        work = pathlib.Path(tmpdir)
        binary = build_once(work, url)
        app_path = work / "app"
        tmp_path = work / "app.tmp"

        # The runner replaces itself with appPath on success, so it must exist
        # and be executable before the first exec. PLACEHOLDER marks "not
        # replaced" for the failure cases.
        app_path.write_bytes(PLACEHOLDER)
        app_path.chmod(0o755)

        proc = subprocess.Popen([str(binary)], cwd=str(work),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

        installed = app_path.read_bytes() if app_path.exists() else b""
        leftover = tmp_path.exists()

        if expect_bytes is None:
            untouched = installed == PLACEHOLDER
            ok = untouched and not leftover
            got = f"untouched={untouched} tmp_clean={not leftover}"
        else:
            ok = len(installed) == expect_bytes and not leftover
            got = f"{len(installed)} / {expect_bytes} tmp_clean={not leftover}"
        print(f"{'PASS' if ok else 'FAIL'} {name:14s} {got}")
        return ok


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="run a single case by name")
    args = parser.parse_args()

    if not SOURCE.exists():
        sys.exit(f"missing {SOURCE}")
    if shutil.which("go") is None:
        sys.exit("go toolchain not found")

    port = free_port()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    base = f"http://127.0.0.1:{port}"
    cases = [
        ("/plain", "plain", len(PLAIN)),
        ("/chunked", "chunked", len(CHUNKED)),
        ("/chunked-ext", "chunked-ext", len(CHUNKED_EXT)),
        ("/redir-abs", "redir-abs", len(CHUNKED)),
        ("/redir-rel", "redir-rel", len(PLAIN)),
        ("/redir-chain", "redir-chain", len(CHUNKED)),
        ("/missing", "http 404", None),
        ("/short", "size mismatch", None),
    ]

    results = []
    try:
        for path, name, expect in cases:
            if args.only and args.only != name:
                continue
            started = time.monotonic()
            ok = run_case(name, base + path, expect_bytes=expect)
            print(f"     ({time.monotonic() - started:.1f}s)")
            results.append(ok)
    finally:
        server.shutdown()

    print("ALL PASS" if all(results) else "FAILURES PRESENT")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
