#!/usr/bin/env python3
"""PVE real-machine boot test for a release image, over the tenant API only.

Flow: make sure an importable qcow2 sits in the tenant's ``import`` storage
(pulled by a throwaway LXC worker on the node's own network, or already there)
-> create a VM with ``import-from`` -> boot it -> grab a frame through
``vncproxy`` and the API gateway's WebSocket -> tear everything down.

There is no SSH anywhere in this path. The tenant role grants the VM and
datastore permissions but no host shell, so every step goes through the API:

* image transfer uses a fetcher container: the node downloads the release asset
  with its own egress and hands it to the node-local API. Image bytes must never
  travel over the tenant tunnel - it is a metered NAT path.
* the screen comes back over ``vncwebsocket`` (the ticket is the VNC password),
  bridged to a local TCP port for vncdotool.
* ``VM.Config.Options`` is not in the tenant role, so the VM is created without
  ``name`` / ``bios`` / ``onboot`` / ``agent``: those options are refused
  outright. Everything else (cores, memory, cpu, vga, machine, scsi0, net0,
  boot) is allowed and used.

Guest-side assertions (rc-status, log dedupe, root password state) need either
SSH or the guest agent, and setting ``agent=1`` is itself a
``VM.Config.Options`` change, so they are out of reach here. Two channels
remain, and both are used:

* the captured frame: the kiosk profile must show the fbterm UI, the headless
  profile must show boot messages;
* with ``--serial`` (debug images only): ``termproxy`` over ``vncwebsocket``
  gives the guest's ttyS0, where ``boot-selftest`` prints its contract as
  ``SELFTEST key=value`` lines. Production images have no serial console, so
  this mode is only meaningful for the ``vpsssh-dbg`` flavor.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import os
import pathlib
import re
import socket
import ssl
import subprocess
import sys
import tarfile
import threading
import time

import requests
import urllib3

HERE = pathlib.Path(__file__).resolve().parent
REPO_DIR = HERE.parents[1]
OUT = HERE / "out"

NODE = os.environ.get("PVE_NODE", "")
STORAGE = os.environ.get("PVE_STORAGE", "")
POOL = os.environ.get("PVE_POOL", "")

# The fetcher worker takes a static address: DHCP for containers on this bridge
# never produced a lease, while a static address on the same subnet reaches the
# node API. Keep it configurable so two workers never collide.
FETCH_IP = os.environ.get("PVE_FETCH_IP", "10.0.0.250/24")
FETCH_GW = os.environ.get("PVE_FETCH_GW", "10.0.0.101")

API_TICKET = "/access/ticket"


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
    """Minimal PVE API client for one tenant session, with retry on the gateway.

    The tenant API arrives through a tunnel that drops and reconnects; a single
    refused connection must not kill a six-minute boot test.
    """

    def __init__(self, base: str, user: str, password: str):
        self.base = base
        self.user = user
        self.password = password
        # This dev box exports a CA bundle that would override verify=False.
        self.http = requests.Session()
        self.http.trust_env = False
        self.http.verify = False
        self.cookie = ""
        self.csrf = ""
        self.login()

    def login(self) -> None:
        for attempt in range(6):
            try:
                resp = self.http.post(
                    f"{self.base}{API_TICKET}",
                    data={"username": self.user, "password": self.password}, timeout=20)
                resp.raise_for_status()
                data = resp.json()["data"]
                self.cookie = data["ticket"]
                self.csrf = data["CSRFPreventionToken"]
                self.http.cookies.set("PVEAuthCookie", self.cookie)
                self.http.headers["CSRFPreventionToken"] = self.csrf
                return
            except (requests.RequestException, ValueError):
                if attempt == 5:
                    raise
                time.sleep(8)

    def call(self, method: str, path: str, **params):
        """One API request: parameters go in the query string on GET, in the
        form body otherwise. Gateway hiccups are retried."""
        kwargs = {"params": params or None} if method == "GET" else {"data": params or None}
        last = None
        for attempt in range(5):
            try:
                resp = self.http.request(method, f"{self.base}{path}", timeout=60, **kwargs)
            except requests.RequestException as exc:
                last = exc
                time.sleep(5)
                continue
            if resp.status_code == 401:
                self.login()
                continue
            if resp.status_code >= 400:
                raise RuntimeError(f"{method} {path} -> {resp.status_code} {resp.text[:300]}")
            return resp.json()["data"]
        raise RuntimeError(f"{method} {path} -> gateway unreachable: {last}")

    def upload(self, content: str, filepath: pathlib.Path):
        with filepath.open("rb") as handle:
            resp = self.http.post(
                f"{self.base}/nodes/{NODE}/storage/{STORAGE}/upload",
                files={"filename": (filepath.name, handle)},
                data={"content": content}, timeout=3600,
            )
        if resp.status_code >= 400:
            raise RuntimeError(f"upload -> {resp.status_code} {resp.text[:300]}")
        return resp.json()["data"]

    def wait_task(self, upid, timeout: float = 900.0) -> None:
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
            time.sleep(2)
        raise TimeoutError(f"task {upid} did not finish in {timeout}s")


def discover(pve: PVE) -> None:
    """Fill NODE / STORAGE / POOL from the API when the environment is silent."""
    global NODE, STORAGE, POOL
    if not NODE:
        NODE = pve.call("GET", "/nodes")[0]["node"]
    if POOL:
        return
    pools = [p["poolid"] for p in pve.call("GET", "/pools")]
    if len(pools) == 1:
        POOL = pools[0]
    if not STORAGE:
        members = pve.call("GET", f"/pools/{POOL}")["members"]
        stores = [m["storage"] for m in members if m["type"] == "storage"]
        STORAGE = stores[0]
    print(f"tenant: node={NODE} storage={STORAGE} pool={POOL}")


# --- image acquisition -----------------------------------------------------
def import_volume_exists(pve: PVE, name: str) -> bool:
    for entry in pve.call("GET", f"/nodes/{NODE}/storage/{STORAGE}/content"):
        if str(entry.get("volid", "")).endswith(f"import/{name}"):
            return True
    return False


def github_asset(tag: str, name: str) -> dict:
    token = env("GITHUB_TOKEN")
    repo = env("GITHUB_REPOSITORY")
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
    release = requests.get(
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}", headers=headers, timeout=60)
    release.raise_for_status()
    for asset in release.json()["assets"]:
        if asset["name"] == name:
            return asset
    sys.exit(f"asset {name} not found in release {tag}")


FETCH_INITTAB = """::sysinit:/root/fetch.sh
::ctrlaltdel:/sbin/reboot
"""

# The worker reports through staged pads instead of a console: the container
# console has no reader at boot and a blocked write stalls init, so nothing may
# print. Stage N writes 8N MiB (8N+4 on failure); the orchestrator reads the
# volume's used space back from the storage API to know where the run stopped.
FETCH_SCRIPT = r"""#!/bin/sh
exec >/root/fetch.log 2>&1 </dev/null
mkdir -p /root/out
stage() { if [ "$2" = ok ]; then C=$((8*$1)); else C=$((8*$1+4)); fi
	dd if=/dev/urandom of=/root/out/pad-$1 bs=1M count=$C 2>/dev/null; }
ip link set dev eth0 up
ip addr add @IP@ dev eth0 2>/dev/null
ip route add default via @GW@ 2>/dev/null
printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > /etc/resolv.conf
stage 1 ok
udhcpc -i eth0 -n -q -t 4 >/dev/null 2>&1
stage 2 ok
timeout 150 apk add --no-cache curl ca-certificates >/dev/null 2>&1
command -v curl >/dev/null 2>&1 && R=ok || R=fail
stage 3 $R
[ "$R" = ok ] || exit 1
API=https://@GW@:8006/api2/json
T=$(curl -sk --connect-timeout 10 -d 'username=@USER@&password=@PASS@' "$API/access/ticket")
TK=$(printf '%s' "$T" | sed -n 's/.*"ticket":"\([^"]*\)".*/\1/p')
CS=$(printf '%s' "$T" | sed -n 's/.*"CSRFPreventionToken":"\([^"]*\)".*/\1/p')
[ -n "$TK" ] && R=ok || R=fail
stage 4 $R
curl -sL --connect-timeout 15 --max-time 900 -H "Authorization: Bearer @TOKEN@" \
	-H "Accept: application/octet-stream" -o /root/@ASSET@ \
	"https://api.github.com/repos/@REPO@/releases/assets/@ASSET_ID@"
SIZE=$(stat -c %s /root/@ASSET@ 2>/dev/null || echo 0)
[ "$SIZE" = "@ASSET_SIZE@" ] && R=ok || R=fail
stage 5 $R
curl -sk --max-time 1800 -H "Cookie: PVEAuthCookie=$TK" -H "CSRFPreventionToken: $CS" \
	-F content=import -F "filename=@/root/@ASSET@" -o /root/out/up.json \
	"$API/nodes/@NODE@/storage/@STORAGE@/upload"
grep -q UPID /root/out/up.json 2>/dev/null && R=ok || R=fail
stage 6 $R
"""


def build_fetch_template(dest: pathlib.Path, asset: dict) -> None:
    """Patch the Alpine minirootfs into a one-shot fetch worker template."""
    mini_url = "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.8-x86_64.tar.gz"
    mini = OUT / "alpine-minirootfs.tar.gz"
    if not mini.exists():
        with requests.get(mini_url, timeout=120) as resp:
            resp.raise_for_status()
            mini.write_bytes(resp.content)
    script = FETCH_SCRIPT
    for key, value in {
        "@IP@": FETCH_IP, "@GW@": FETCH_GW, "@USER@": env("PVE_USER"),
        "@PASS@": env("PVE_API_PASS"), "@TOKEN@": env("GITHUB_TOKEN"),
        "@ASSET@": asset["name"], "@ASSET_ID@": str(asset["id"]),
        "@ASSET_SIZE@": str(asset["size"]), "@REPO@": env("GITHUB_REPOSITORY"),
        "@NODE@": NODE, "@STORAGE@": STORAGE,
    }.items():
        script = script.replace(key, value)
    with tarfile.open(mini, "r:gz") as tin, tarfile.open(dest, "w:gz") as tout:
        for member in tin.getmembers():
            payload = tin.extractfile(member) if member.isfile() else None
            if member.name.endswith("etc/inittab") and payload:
                body = FETCH_INITTAB.encode()
                member.size = len(body)
                tout.addfile(member, io.BytesIO(body))
            else:
                tout.addfile(member, payload)
        info = tarfile.TarInfo("./root/fetch.sh")
        body = script.encode()
        info.size, info.mode, info.mtime = len(body), 0o755, int(time.time())
        tout.addfile(info, io.BytesIO(body))


def destroy(pve: PVE, kind: str, vmid) -> bool:
    """Stop and destroy a VM or CT, retrying the destroy.

    PVE refuses to destroy a guest that is still shutting down ("container is
    locked" / "unable to destroy"), and the first attempt right after the stop
    call always lands in that window. Swallowing it leaks a running container
    per test run, so retry and stay loud when it really fails.
    """
    with contextlib.suppress(Exception):
        pve.wait_task(pve.call("POST", f"/nodes/{NODE}/{kind}/{vmid}/status/stop"),
                      timeout=120)
    last: Exception | None = None
    for _ in range(6):
        try:
            pve.wait_task(pve.call("DELETE", f"/nodes/{NODE}/{kind}/{vmid}"), timeout=120)
            return True
        except Exception as exc:  # noqa: BLE001 - retried, then reported
            last = exc
            time.sleep(3)
    print(f"WARNING: could not destroy {kind} {vmid}: {last}")
    return False


def fetch_into_storage(pve: PVE, asset: dict) -> None:
    """Run the worker CT until the qcow2 lands in import storage."""
    template = f"fetch-worker-{asset['name']}.tar.gz"
    template_path = OUT / template
    if not import_volume_exists(pve, template):
        build_fetch_template(template_path, asset)
        pve.wait_task(pve.upload("vztmpl", template_path))

    ostemplate = f"{STORAGE}:vztmpl/{template}"
    vmid = pve.call("GET", "/cluster/nextid")
    pve.wait_task(pve.call("POST", f"/nodes/{NODE}/lxc",
                           vmid=vmid, pool=POOL, ostemplate=ostemplate,
                           rootfs=f"{STORAGE}:8", memory=512, cores=2, swap=0,
                           # hostname/password/onboot live under VM.Config.Options
                           # and are refused by the tenant role.
                           net0=f"name=eth0,bridge=vmbr0,ip={FETCH_IP},gw={FETCH_GW}"))
    pve.wait_task(pve.call("POST", f"/nodes/{NODE}/lxc/{vmid}/status/start"))
    print(f"fetch worker CT {vmid} started, waiting for {asset['name']}")

    deadline = time.monotonic() + 1500
    while time.monotonic() < deadline:
        if import_volume_exists(pve, asset["name"]):
            print("image present in import storage")
            destroy(pve, "lxc", vmid)
            with contextlib.suppress(Exception):
                pve.call("DELETE", f"/nodes/{NODE}/storage/{STORAGE}/content/"
                         f"vztmpl/{template}")
            template_path.unlink(missing_ok=True)
            return
        time.sleep(15)
    sys.exit(f"fetch worker {vmid} did not deliver the image in time; inspect its rootfs pads")


# --- VM lifecycle ----------------------------------------------------------
def create_vm(pve: PVE, disk_bus: str, vga: str, memory: str, import_source: str,
              serial: bool = False) -> str:
    vmid = pve.call("GET", "/cluster/nextid")
    config = dict(
        vmid=vmid, pool=POOL, memory=memory, cores=1,
        net0="virtio,bridge=vmbr0", machine="q35", vga=vga,
        # app-runner is built GOAMD64=v3; the kvm64 baseline lacks the v3 set.
        cpu="host",
    )
    if serial:
        # socket, not a TCP port: PVE owns the unix socket and termproxy relays
        # it, which keeps the guest unreachable from the tenant network.
        config.update(serial0="socket")
    if disk_bus == "scsi":
        config.update(scsihw="virtio-scsi-single",
                      scsi0=f"{STORAGE}:0,import-from={import_source}",
                      boot="order=scsi0")
    else:
        config.update(virtio0=f"{STORAGE}:0,import-from={import_source}",
                      boot="order=virtio0")
    pve.wait_task(pve.call("POST", f"/nodes/{NODE}/qemu", **config))
    return str(vmid)


def teardown(pve: PVE, vmid: str) -> None:
    destroy(pve, "qemu", vmid)


# --- screen capture --------------------------------------------------------
@contextlib.contextmanager
def vnc_bridge(pve: PVE, vmid: str, local_port: int = 5910):
    """Expose the node-local VNC port through the gateway's WebSocket.

    The vncticket authenticates the upgrade and doubles as the VNC password;
    after that the tunnel is raw RFB bytes.
    """
    import websocket

    for _var in ("http_proxy", "https_proxy", "all_proxy"):
        os.environ.pop(_var, None)
        os.environ.pop(_var.upper(), None)
    proxy = pve.call("POST", f"/nodes/{NODE}/qemu/{vmid}/vncproxy")
    tunnel = (f"wss://{env('PVE_HOST')}:{env('PVE_API_PORT')}/api2/json/nodes/{NODE}"
              f"/qemu/{vmid}/vncwebsocket?port={proxy['port']}"
              f"&vncticket={requests.utils.quote(proxy['ticket'], safe='')}")
    ws = websocket.create_connection(
        tunnel, header={"Cookie": f"PVEAuthCookie={pve.cookie}"},
        sslopt={"cert_reqs": ssl.CERT_NONE}, timeout=60, suppress_origin=True)

    stop = threading.Event()
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", local_port))
    server.listen(1)
    server.settimeout(1)

    def drain_to_client(client):
        with contextlib.suppress(Exception):
            while not stop.is_set():
                data = ws.recv()
                if isinstance(data, bytes):
                    client.sendall(data)
                else:
                    break
        with contextlib.suppress(Exception):
            client.close()

    def client_to_ws(client):
        with contextlib.suppress(Exception):
            while not stop.is_set():
                data = client.recv(4096)
                if not data:
                    break
                ws.send(data)

    def accept_loop():
        while not stop.is_set():
            try:
                client, _ = server.accept()
            except (socket.timeout, OSError):
                return
            threading.Thread(target=client_to_ws, args=(client,), daemon=True).start()
            threading.Thread(target=drain_to_client, args=(client,), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()
    try:
        yield proxy["ticket"], local_port
    finally:
        stop.set()
        server.close()
        with contextlib.suppress(Exception):
            ws.close()


def capture_screen(pve: PVE, vmid: str, out_png: pathlib.Path, attempts: int = 2,
                   timeout: float = 60.0) -> int:
    """Capture a frame. The proxy ticket can be momentarily not ready right
    after boot, so retry once with a fresh one."""
    last = 1
    for _ in range(attempts):
        with vnc_bridge(pve, vmid) as (ticket, port):
            result = subprocess.run(
                ["vncdo", "-s", f"127.0.0.1::{port}", "-p", ticket, "capture", str(out_png)],
                capture_output=True, timeout=timeout)
        last = result.returncode
        if last == 0:
            return 0
    return last


# --- serial console --------------------------------------------------------
SELFTEST_EXPECT = {
    "sshd": "started",
    "app-runner": "started",
    "rootpw": "set",
}
# Numeric keys are checked as a minimum: a business binary that exits on its
# own makes supervisor restarts legitimate, so the count is "at least one".
SELFTEST_MIN = {"app-runner-starts": 1}
APP_VERDICTS = ("ok", "no-loader", "arch", "failed", "timeout")


def read_serial(pve: PVE, vmid: str, marker: str = "SELFTEST-END",
                timeout: float = 300.0, idle: float = 25.0, reconnects: int = 3) -> str:
    """Collect the guest's ttyS0 output through termproxy.

    termproxy hands out a ticket for the node-local websocket; the upgrade is
    authenticated with a ``user:ticket`` line, after which the stream is raw
    console bytes (kernel messages and the login prompt share it). The guest
    chardev drops output when nobody is attached, so the caller must connect
    right after starting the VM - the boot log and the selftest are then
    buffered here instead of lost.

    The gateway closes these long-lived sockets without warning now and then
    (the frp tunnel drops for a few seconds), so a closed socket is reconnected
    and the transcript continues instead of failing the run.
    """
    import websocket

    for _var in ("http_proxy", "https_proxy", "all_proxy"):
        os.environ.pop(_var, None)
        os.environ.pop(_var.upper(), None)

    buf = ""
    deadline = time.time() + timeout
    for attempt in range(reconnects):
        if marker in buf or time.time() >= deadline:
            break
        term = pve.call("POST", f"/nodes/{NODE}/qemu/{vmid}/termproxy")
        url = (f"wss://{env('PVE_HOST')}:{env('PVE_API_PORT')}/api2/json/nodes/{NODE}"
               f"/qemu/{vmid}/vncwebsocket?port={term['port']}"
               f"&vncticket={requests.utils.quote(term['ticket'], safe='')}")
        ws = websocket.create_connection(
            url, header={"Cookie": f"PVEAuthCookie={pve.cookie}"},
            sslopt={"cert_reqs": ssl.CERT_NONE}, timeout=10, suppress_origin=True)
        try:
            ws.send(f"{term['user']}:{term['ticket']}\n")
            last_data = time.time()
            while time.time() < deadline:
                try:
                    data = ws.recv()
                except websocket.WebSocketTimeoutException:
                    data = ""
                if data:
                    if isinstance(data, bytes):
                        data = data.decode("utf-8", "replace")
                    buf += data
                    last_data = time.time()
                    if marker in buf:
                        break
                elif buf and time.time() - last_data > idle:
                    # Quiet line: either the boot finished without the marker or
                    # the guest is wedged. Stop waiting on this socket.
                    break
                elif marker in buf:
                    break
        except websocket.WebSocketConnectionClosedException:
            # Gateway dropped the socket; a reconnect resumes the transcript.
            pass
        finally:
            with contextlib.suppress(Exception):
                ws.close()
        if marker in buf:
            break
        if buf and time.time() > deadline:
            break
        time.sleep(2)
    return buf


def parse_selftest(text: str) -> tuple[dict, str | None]:
    values: dict = {}
    verdict = None
    for line in text.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line).strip()
        match = re.match(r"SELFTEST-RESULT (pass|fail)", line)
        if match:
            verdict = match.group(1)
            continue
        match = re.match(r"SELFTEST ([a-z0-9-]+)=(.*)", line)
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values, verdict


def assert_serial(text: str, expect_app: str | None = None) -> list[str]:
    values, verdict = parse_selftest(text)
    problems = []
    if not values:
        return ["no SELFTEST output on the serial line"]
    for key, want in SELFTEST_EXPECT.items():
        if key not in values:
            problems.append(f"missing {key}")
        elif values[key] != want:
            problems.append(f"{key}={values[key]} (want {want})")
    for key, minimum in SELFTEST_MIN.items():
        if key not in values:
            problems.append(f"missing {key}")
        else:
            try:
                if int(values[key]) < minimum:
                    problems.append(f"{key}={values[key]} (want >= {minimum})")
            except ValueError:
                problems.append(f"{key}={values[key]} (not a number)")
    if expect_app:
        got = values.get("app-exec")
        if got != expect_app:
            problems.append(
                f"app-exec={got} (want {expect_app}"
                + (f", error: {values.get('app-error')}" if values.get("app-error") else "")
                + ")")
    if verdict != "pass":
        problems.append(f"verdict={verdict}")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="dd", help="release tag holding the assets")
    parser.add_argument("--asset", default="vpsvga", help="release asset base name")
    parser.add_argument("--import-name", help="qcow2 already present in import storage")
    parser.add_argument("--vga", default="qxl",
                        choices=["qxl", "std", "cirrus", "virtio", "vmware", "none"])
    parser.add_argument("--disk-bus", default="scsi", choices=["scsi", "virtio"])
    parser.add_argument("--memory", default=512, type=int)
    parser.add_argument("--boot-wait", type=float, default=30.0)
    parser.add_argument("--keep", action="store_true", help="leave the VM running")
    parser.add_argument("--serial", action="store_true",
                        help="attach serial0 and assert the boot selftest over termproxy")
    parser.add_argument("--serial-timeout", type=float, default=300.0)
    parser.add_argument("--capture-timeout", type=float, default=60.0)
    parser.add_argument("--expect-app", choices=APP_VERDICTS,
                        help="require this verdict for the business binary: "
                             "ok=loaded, no-loader=missing dynamic loader, arch=wrong "
                             "architecture/archive, failed=other exec error, timeout=never ran")
    parser.add_argument("--capture-only", action="store_true",
                        help="reuse an existing VM instead of creating one")
    args = parser.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)

    fingerprint = os.environ.get("PVE_TLS_FP")
    if fingerprint:
        verify_server_fingerprint(env("PVE_HOST"), int(env("PVE_API_PORT")), fingerprint)

    pve = PVE(base=f"https://{env('PVE_HOST')}:{env('PVE_API_PORT')}/api2/json",
              user=env("PVE_USER"), password=env("PVE_API_PASS"))
    discover(pve)

    if args.capture_only:
        vmid = env("PVE_VMID")
        png = OUT / "screen.png"
        if capture_screen(pve, vmid, png) != 0:
            sys.exit("screen capture failed")
        print(f"captured {png}")
        return

    name = args.import_name or f"{args.asset}.qcow2"
    if not import_volume_exists(pve, name):
        asset = github_asset(args.tag, name)
        fetch_into_storage(pve, asset)
    import_source = f"{STORAGE}:import/{name}"

    vmid = create_vm(pve, args.disk_bus, args.vga, str(args.memory), import_source,
                     serial=args.serial)
    try:
        pve.wait_task(pve.call("POST", f"/nodes/{NODE}/qemu/{vmid}/status/start"))
        print(f"VM {vmid} booting ({args.vga}/{args.disk_bus}), waiting {args.boot_wait:.0f}s")
        serial_box: dict = {}
        if args.serial:
            # Attach before the boot finishes: the guest chardev discards output
            # while nobody is connected, and the selftest is a one-shot print.
            def _collect():
                try:
                    serial_box["text"] = read_serial(pve, vmid, timeout=args.serial_timeout)
                except Exception as exc:  # noqa: BLE001 - reported as a failure
                    serial_box["error"] = repr(exc)

            reader = threading.Thread(target=_collect, daemon=True)
            reader.start()
        time.sleep(args.boot_wait)

        # Serial first: a debug image moves the kernel console to ttyS0, so its
        # frame is legitimately black and the ttyS0 transcript is the assertion.
        if args.serial:
            print("reading serial console (termproxy)")
            reader.join(timeout=args.serial_timeout)
            if "text" not in serial_box:
                reader_error = serial_box.get("error", "reader still running")
                sys.exit(f"serial console unavailable: {reader_error}")
            text = serial_box["text"]
            log = OUT / f"serial-{args.asset}.log"
            log.write_text(text)
            for line in text.splitlines():
                clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line).replace("\r", "")
                if "SELFTEST" in clean:
                    print(f"  {clean.strip()}")
            problems = assert_serial(text, args.expect_app)
            print(f"serial log={log} bytes={len(text)}")
            if problems:
                sys.exit("serial assertions failed: " + "; ".join(problems))
            print("serial assertions passed")

        png = OUT / f"screen-{args.asset}-{args.vga}-{args.disk_bus}.png"
        try:
            rc = capture_screen(pve, vmid, png, timeout=args.capture_timeout)
        except subprocess.TimeoutExpired:
            # A debug image keeps its console on ttyS0: the VGA display may never
            # update, and vncdotool then waits for a refresh that never comes.
            print("capture timed out (no display updates)")
            rc = 1
        size = png.stat().st_size if png.exists() else 0
        print(f"capture rc={rc} png={png} bytes={size}")
        if rc != 0 and not args.serial:
            sys.exit("screen capture failed")
        # A uniform frame compresses to almost nothing; anything with content
        # (kiosk UI or boot messages) is far above this floor. Debug images are
        # exempt: their console lives on the serial line.
        if size < 4096 and not args.serial:
            sys.exit(f"frame looks blank ({size} bytes)")
        print(f"PVE_VMID={vmid}")
    finally:
        if args.keep:
            print(f"keeping VM {vmid}")
        else:
            teardown(pve, vmid)
            print("teardown complete")


if __name__ == "__main__":
    urllib3.disable_warnings()
    main()
