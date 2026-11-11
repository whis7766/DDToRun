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


def ssh_username() -> str:
    """SSH login name. The API user carries the realm suffix (``ddtester@pve``),
    but the SSH account is the bare name; PVE_SSH_USER overrides if needed."""
    return os.environ.get("PVE_SSH_USER") or env("PVE_USER").split("@")[0]


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
            f"{base}/access/ticket", data={"username": user, "password": password},
            verify=False,
        )
        resp.raise_for_status()
        data = resp.json()["data"]
        self.http.cookies.set("PVEAuthCookie", data["ticket"])
        self.http.headers["CSRFPreventionToken"] = data["CSRFPreventionToken"]

    def call(self, method: str, path: str, **params):
        """One API request: parameters go in the query string on GET, in the
        form body otherwise."""
        kwargs = {"params": params or None} if method == "GET" else {"data": params or None}
        resp = self.http.request(method, f"{self.base}{path}", verify=False, **kwargs)
        if resp.status_code >= 400:
            raise RuntimeError(f"{method} {path} -> {resp.status_code} {resp.text[:300]}")
        return resp.json()["data"]

    def upload(self, content: str, filepath: pathlib.Path):
        with filepath.open("rb") as handle:
            resp = self.http.post(
                f"{self.base}/nodes/{NODE}/storage/{STORAGE}/upload",
                files={"filename": (filepath.name, handle)},
                data={"content": content}, verify=False,
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
    transport.connect(username=ssh_username(), password=env("PVE_SSH_PASS"))

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
            except (socket.timeout, OSError):
                # OSError (EBADF) arrives once the listener is closed in cleanup.
                return
            threading.Thread(target=pump, args=(client,), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()
    time.sleep(0.5)
    try:
        yield local_port
    finally:
        stop.set()
        server.close()
        transport.close()


def headless_check(pve: PVE, vmid: str, timeout: float = 180.0) -> None:
    """Log in with the baked user key and assert the headless boot contract.

    Screen capture alone cannot tell a broken SSH image from a working one, so
    this asserts the three things that actually matter and have regressed
    before:

      * public-key login still works (a locked root shadow field silently
        rejects every key login, and password auth is off, so there is no
        fallback path into the machine);
      * sshd and app-runner reached ``started`` in the default runlevel;
      * app-runner logs each line once (the runner writing its own log file on
        top of the service redirect used to duplicate every line).

    The guest takes a DHCP lease, so the address is resolved from the MAC in
    ``ip neigh`` on the node after a ping sweep; hostnames are not unique.
    """
    mac = pve.call("GET", f"/nodes/{NODE}/qemu/{vmid}/config")["net0"].split("=")[1].split(",")[0]
    ip = guest_ip_by_mac(mac, timeout)
    print(f"headless: guest {mac} -> {ip}")

    key = HERE.parents[1] / "build" / "vendor" / "ssh_user_key"
    if not key.exists():
        sys.exit(f"missing user key {key}")

    transport = paramiko.Transport((env("PVE_HOST"), int(env("PVE_SSH_PORT"))))
    transport.connect(username=ssh_username(), password=env("PVE_SSH_PASS"))
    deadline = time.monotonic() + timeout
    last: Exception | None = None
    client: paramiko.SSHClient | None = None
    while time.monotonic() < deadline:
        try:
            channel = transport.open_channel(
                "direct-tcpip", (ip, 22), ("127.0.0.1", 0), timeout=10
            )
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            client.connect(ip, 22, username="root",
                           pkey=paramiko.Ed25519Key.from_private_key_file(str(key)),
                           sock=channel, timeout=20, allow_agent=False, look_for_keys=False)
            break
        except Exception as exc:  # noqa: BLE001 - the last error is reported
            last = exc
            time.sleep(5)
    if client is None:
        sys.exit(f"headless: key login failed for {ip}: {last}")
    print("headless: public-key login OK")

    def run(cmd: str) -> str:
        _in, out, _err = client.exec_command(cmd)
        return out.read().decode(errors="replace")

    status = run("rc-status default 2>/dev/null")
    for service in ("sshd", "app-runner"):
        if not any(service in line and "started" in line for line in status.splitlines()):
            sys.exit(f"headless: {service} not started:\n{status}")

    count = run("grep -c 'app-runner starting' /var/log/app-runner.log").strip()
    if count != "1":
        sys.exit(f"headless: app-runner logged its start {count} times, expected 1")

    shadow = run("awk -F: '$1==\"root\"{print $2}' /etc/shadow").strip()
    if not shadow or shadow[0] in "!*":
        sys.exit("headless: root has an empty or locked password field")

    print("headless: sshd + app-runner started, single log line, root password set")
    client.close()
    transport.close()


def guest_ip_by_mac(mac: str, timeout: float = 180.0) -> str:
    """Resolve a guest's DHCP address from the node's neighbour table.

    The guest picks up a lease a few seconds into boot and the table only
    learns about it once something talks to the address, so sweep the segment
    between reads instead of assuming a fixed address.
    """
    transport = paramiko.Transport((env("PVE_HOST"), int(env("PVE_SSH_PORT"))))
    transport.connect(username=ssh_username(), password=env("PVE_SSH_PASS"))

    def shell(cmd: str) -> str:
        chan = transport.open_session()
        chan.exec_command(cmd)
        out = chan.makefile("r", 65536).read().decode(errors="replace")
        chan.recv_exit_status()
        chan.close()
        return out

    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            for line in shell("ip neigh show dev vmbr0").splitlines():
                parts = line.split()
                if len(parts) < 3 or parts[0].count(".") != 3:
                    continue
                if parts[2].lower() == mac.lower():
                    return parts[0]
            shell("seq 2 254 | xargs -P 64 -I{} sh -c 'ping -c1 -W1 10.0.0.{} >/dev/null 2>&1'")
            time.sleep(5)
    finally:
        transport.close()
    sys.exit(f"headless: no neighbour entry for {mac}")


def capture_screen(pve: PVE, vmid: str, out_png: pathlib.Path, attempts: int = 2) -> int:
    """Capture a frame. The vncproxy ticket/port can be momentarily not ready
    right after boot, so retry once with a fresh proxy ticket."""
    last: subprocess.CompletedProcess | None = None
    for _ in range(attempts):
        proxy = pve.call("POST", f"/nodes/{NODE}/qemu/{vmid}/vncproxy")
        try:
            with ssh_vnc_tunnel(int(proxy["port"])) as local_port:
                last = subprocess.run(
                    ["vncdo", "-s", f"127.0.0.1::{local_port}", "-p", proxy["ticket"],
                     "capture", str(out_png)],
                    capture_output=True,
                    timeout=90,
                )
            if last.returncode == 0:
                return 0
        except subprocess.TimeoutExpired:
            last = None
    return last.returncode if last is not None else 1


def serial_check(vmid: str, timeout: float = 60.0) -> None:
    """Log in over the platform-bridged serial socket and run a sanity command.

    The platform maps the guest serial0 socket to ``~/serial-<vmid>.sock``
    (mode 666); ``socat`` bridges it to ``/var/run/qemu-server/<vmid>.serial0``.
    This only works on debug builds that still run a getty on ttyS0; production
    images ship no serial surface, so the check is opt-in via ``--serial``.
    """
    transport = paramiko.Transport((env("PVE_HOST"), int(env("PVE_SSH_PORT"))))
    transport.connect(username=ssh_username(), password=env("PVE_SSH_PASS"))
    chan = transport.open_session()
    chan.settimeout(5)
    chan.exec_command(f"socat - UNIX-CONNECT:$HOME/serial-{vmid}.sock 2>&1")

    buf = ""

    def read_until(marker: str, deadline: float, optional: bool = False) -> str:
        nonlocal buf
        while marker not in buf and time.monotonic() < deadline:
            try:
                data = chan.recv(4096).decode(errors="replace")
            except socket.timeout:
                continue
            if not data:
                break
            buf += data
        if marker not in buf:
            if optional:
                return buf
            raise RuntimeError(f"serial: waited for {marker!r}, tail={buf[-200:]!r}")
        idx = buf.index(marker) + len(marker)
        matched, buf = buf[:idx], buf[idx:]
        return matched

    deadline = time.monotonic() + timeout

    # The getty may not print its prompt until it sees an initial line
    # discipline character; send a CR to wake it before waiting for login:.
    chan.sendall("\r")
    read_until("login:", deadline)
    chan.sendall("root\n")
    # Empty-password builds skip the Password: prompt entirely. Give it only a
    # short window; do not consume the main deadline waiting for a prompt that
    # will never arrive, and only send the empty password if it actually shows.
    if "Password:" in read_until("Password:", time.monotonic() + 3.0, optional=True):
        chan.sendall("\n")
    read_until("#", deadline)

    chan.sendall("uname -a\n")
    out = read_until("#", deadline)
    lines = [line.strip() for line in out.splitlines() if "Linux" in line]
    if not lines:
        raise RuntimeError(f"serial: uname output missing Linux: {out[-200:]!r}")
    print(f"serial console: login OK, uname -> {lines[0]}")

    chan.close()
    transport.close()


# --- VM lifecycle ----------------------------------------------------------
def create_vm(pve: PVE, disk_bus: str, vga: str, memory: str, import_source: str,
              serial: bool = False) -> str:
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
        # The app-runner binary is built GOAMD64=v3; the default kvm64 baseline
        # lacks the v3 instruction set and refuses to run ("only be run on
        # AMD64 processors with v3 microarchitecture support"). host passes the
        # actual hypervisor CPU through.
        cpu="host",
    )
    if serial:
        config["serial0"] = "socket"
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
    parser.add_argument("--serial", action="store_true",
                        help="drive the serial console (debug builds only; production images ship no ttyS0 getty)")
    parser.add_argument("--ssh", action="store_true",
                        help="assert the headless contract: key login, sshd + app-runner started, single log line")
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

    raw = args.raw or download_asset(args.tag, args.asset, OUT / f"{args.asset}.raw")
    pve.wait_task(pve.upload("import", raw))
    import_source = f"{STORAGE}:import/{raw.name}"

    vmid = create_vm(pve, args.disk_bus, args.vga, str(args.memory), import_source,
                     serial=args.serial)
    try:
        pve.wait_task(pve.call("POST", f"/nodes/{NODE}/qemu/{vmid}/status/start"))
        print(f"VM {vmid} booting ({args.vga}/{args.disk_bus}), waiting {args.boot_wait:.0f}s")
        time.sleep(args.boot_wait)

        png = OUT / f"screen-{args.vga}-{args.disk_bus}.png"
        rc = capture_screen(pve, vmid, png)
        print(f"capture rc={rc} png={png} exists={png.exists()}")
        if rc != 0:
            sys.exit(f"screen capture failed (rc={rc})")

        if args.serial:
            serial_check(vmid)
        if args.ssh:
            headless_check(pve, vmid)
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
