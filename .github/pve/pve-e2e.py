#!/usr/bin/env python3
"""PVE real-machine boot test for a release image.

Flow: obtain a raw image (download a release asset, or use a local file) ->
upload it through the tenant ``content=import`` channel -> create a VM with
``import-from`` (chosen display adapter and disk bus) -> boot it -> capture the
screen over an SSH VNC tunnel -> tear the VM down.

The tenant API does not expose importdisk / import-volume / screendump, so the
import channel plus a direct-tcpip VNC tunnel are the only paths available.
Credentials come from the environment; nothing is hard-coded.

Typical use on the PVE host itself, with an image already on disk:

    ./pve-e2e.py --raw ~/images/import/vpsvga.raw --vga qxl --disk-bus scsi
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import os
import pathlib
import select
import socket
import ssl
import subprocess
import sys
import threading
import time

import paramiko
import requests
import zstandard

NODE = "pve"
STORAGE = "tenant-private"
POOL = "tenant-pool"
HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"


# --- environment -----------------------------------------------------------
def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"missing required environment variable {name}")
    return value


def normalize_fingerprint(value: str) -> str:
    return value.replace(":", "").replace(" ", "").lower()


def verify_server_fingerprint(host: str, port: int, expected: str) -> None:
    """Compare the API server certificate against PVE_TLS_FP when provided."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, port), timeout=15) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as tls:
            der = tls.getpeercert(binary_form=True)
    digest = hashlib.sha256(der).hexdigest()
    if digest != normalize_fingerprint(expected):
        sys.exit(f"TLS fingerprint mismatch: got {digest}, expected {expected}")


# --- PVE API ---------------------------------------------------------------
class PVE:
    """Minimal PVE API client bound to one tenant session."""

    def __init__(self, base: str, user: str, password: str):
        self.base = base
        self.http = requests.Session()
        self.http.verify = False
        resp = self.http.post(
            f"{base}/access/ticket", data={"username": user, "password": password}
        )
        resp.raise_for_status()
        data = resp.json()["data"]
        self.http.cookies.set("PVEAuthCookie", data["ticket"])
        self.http.headers["CSRFPreventionToken"] = data["CSRFPreventionToken"]

    def call(self, method: str, path: str, **params):
        """One API request: parameters go in the query string on GET, in the
        form body otherwise."""
        kwargs = {"params": params or None} if method == "GET" else {"data": params or None}
        resp = self.http.request(method, f"{self.base}{path}", **kwargs)
        if resp.status_code >= 400:
            raise RuntimeError(f"{method} {path} -> {resp.status_code} {resp.text[:300]}")
        return resp.json()["data"]

    def upload(self, content: str, filepath: pathlib.Path):
        with filepath.open("rb") as handle:
            resp = self.http.post(
                f"{self.base}/nodes/{NODE}/storage/{STORAGE}/upload",
                files={"filename": (filepath.name, handle)},
                data={"content": content},
            )
        if resp.status_code >= 400:
            raise RuntimeError(f"upload -> {resp.status_code} {resp.text[:300]}")
        return resp.json()["data"]

    def wait_task(self, upid, timeout: float = 300.0) -> None:
        if not (isinstance(upid, str) and upid.startswith("UPID")):
            return
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.call("GET", f"/nodes/{NODE}/tasks/{upid}/status")
            if status.get("status") == "stopped":
                exit_status = status.get("exitstatus")
                if exit_status and exit_status != "OK":
                    raise RuntimeError(f"task failed: {exit_status}")
                return
            time.sleep(1.5)
        raise TimeoutError(f"task {upid} did not finish in {timeout}s")


# --- image acquisition -----------------------------------------------------
def download_asset(tag: str, asset: str, dest: pathlib.Path) -> pathlib.Path:
    """Download a release asset and decompress it to dest (raw)."""
    token = env("GITHUB_TOKEN")
    repo = env("GITHUB_REPOSITORY")
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}

    release = requests.get(
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}", headers=headers
    )
    release.raise_for_status()
    obj = next((a for a in release.json()["assets"] if a["name"] == asset), None)
    if obj is None:
        sys.exit(f"asset {asset} not found in release {tag}")

    compressed = dest.with_suffix(".zst")
    with requests.get(
        obj["url"], headers={**headers, "Accept": "application/octet-stream"}, stream=True
    ) as resp:
        resp.raise_for_status()
        with compressed.open("wb") as handle:
            for block in resp.iter_content(chunk_size=1 << 20):
                handle.write(block)

    with compressed.open("rb") as src, dest.open("wb") as dst:
        zstandard.ZstdDecompressor().copy_stream(src, dst)
    compressed.unlink()
    return dest


# --- screen capture --------------------------------------------------------
@contextlib.contextmanager
def ssh_vnc_tunnel(vnc_port: int, local_port: int = 5910):
    """Expose the node-local VNC port through a direct-tcpip SSH channel.

    paramiko's request_port_forward is denied on this host, but the lower-level
    direct-tcpip channel works.
    """
    transport = paramiko.Transport((env("PVE_HOST"), int(env("PVE_SSH_PORT"))))
    transport.connect(username=env("PVE_USER"), password=env("PVE_SSH_PASS"))

    stop = threading.Event()
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", local_port))
    server.listen(5)
    server.settimeout(1)

    def pump(client: socket.socket) -> None:
        channel = transport.open_channel(
            "direct-tcpip", ("127.0.0.1", vnc_port), ("127.0.0.1", local_port)
        )
        try:
            while True:
                readable, _, _ = select.select([client, channel], [], [])
                if client in readable:
                    data = client.recv(4096)
                    if not data:
                        break
                    channel.sendall(data)
                if channel in readable:
                    data = channel.recv(4096)
                    if not data:
                        break
                    client.sendall(data)
        finally:
            channel.close()
            client.close()

    def accept_loop() -> None:
        while not stop.is_set():
            try:
                client, _ = server.accept()
            except socket.timeout:
                continue
            threading.Thread(target=pump, args=(client,), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()
    time.sleep(0.5)
    try:
        yield local_port
    finally:
        stop.set()
        server.close()
        transport.close()


def capture_screen(pve: PVE, vmid: str, out_png: pathlib.Path) -> int:
    proxy = pve.call("POST", f"/nodes/{NODE}/qemu/{vmid}/vncproxy")
    with ssh_vnc_tunnel(int(proxy["port"])) as local_port:
        result = subprocess.run(
            ["vncdo", "-s", f"127.0.0.1::{local_port}", "-p", proxy["ticket"],
             "capture", str(out_png)],
            capture_output=True,
            timeout=90,
        )
    return result.returncode


# --- VM lifecycle ----------------------------------------------------------
def create_vm(pve: PVE, disk_bus: str, vga: str, memory: str, import_source: str) -> str:
    vmid = pve.call("GET", "/cluster/nextid")
    config = dict(
        vmid=vmid,
        pool=POOL,
        name=f"ci-{vga}-{disk_bus}",
        memory=memory,
        cores=1,
        ostype="l26",
        net0="virtio,bridge=vmbr0",
        machine="q35",
        bios="seabios",
        onboot=0,
        agent=0,
        tablet=0,
        vga=vga,
    )
    if disk_bus == "scsi":
        config.update(
            scsihw="virtio-scsi-single",
            scsi0=f"{STORAGE}:0,import-from={import_source}",
            boot="order=scsi0",
        )
    else:
        config.update(
            virtio0=f"{STORAGE}:0,import-from={import_source}",
            boot="order=virtio0",
        )
    pve.wait_task(pve.call("POST", f"/nodes/{NODE}/qemu", **config))
    return str(vmid)


def teardown(pve: PVE, vmid: str) -> None:
    """Stop and destroy the VM. Every step is best-effort: a stuck guest must
    never keep the machine around until the pool runs dry."""
    with contextlib.suppress(Exception):
        pve.wait_task(pve.call("POST", f"/nodes/{NODE}/qemu/{vmid}/status/stop"), timeout=120)
    with contextlib.suppress(Exception):
        pve.wait_task(pve.call("DELETE", f"/nodes/{NODE}/qemu/{vmid}"), timeout=120)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="dd", help="release tag to download from")
    parser.add_argument("--asset", default="vpsvga", help="release asset name")
    parser.add_argument("--raw", type=pathlib.Path, help="use an existing raw image instead of downloading")
    parser.add_argument("--vga", default="qxl",
                        choices=["qxl", "std", "cirrus", "virtio", "vmware", "none"],
                        help="display adapter")
    parser.add_argument("--disk-bus", default="scsi", choices=["scsi", "virtio"])
    parser.add_argument("--memory", default=512, type=int, help="guest memory in MB")
    parser.add_argument("--boot-wait", type=float, default=20.0, help="seconds to wait before capturing")
    parser.add_argument("--keep", action="store_true", help="keep the VM running for manual inspection")
    args = parser.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)

    fingerprint = os.environ.get("PVE_TLS_FP")
    if fingerprint:
        verify_server_fingerprint(env("PVE_HOST"), int(env("PVE_API_PORT")), fingerprint)

    pve = PVE(
        base=f"https://{env('PVE_HOST')}:{env('PVE_API_PORT')}/api2/json",
        user=env("PVE_USER"),
        password=env("PVE_API_PASS"),
    )

    raw = args.raw or download_asset(args.tag, args.asset, OUT / args.asset)
    pve.wait_task(pve.upload("import", raw))
    import_source = f"{STORAGE}:import/{raw.name}"

    vmid = create_vm(pve, args.disk_bus, args.vga, str(args.memory), import_source)
    try:
        pve.wait_task(pve.call("POST", f"/nodes/{NODE}/qemu/{vmid}/status/start"))
        print(f"VM {vmid} booting ({args.vga}/{args.disk_bus}), waiting {args.boot_wait:.0f}s")
        time.sleep(args.boot_wait)

        png = OUT / f"screen-{args.vga}-{args.disk_bus}.png"
        rc = capture_screen(pve, vmid, png)
        print(f"capture rc={rc} png={png} exists={png.exists()}")
        if rc != 0:
            sys.exit(f"screen capture failed (rc={rc})")
    finally:
        if args.keep:
            print(f"keeping VM {vmid}")
        else:
            teardown(pve, vmid)
            print("teardown complete")


if __name__ == "__main__":
    import urllib3

    urllib3.disable_warnings()
    main()
