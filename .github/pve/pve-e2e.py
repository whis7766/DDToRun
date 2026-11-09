#!/usr/bin/env python3
"""PVE real-machine boot test, self-contained for GitHub Actions.

Flow: download a release asset (private repo, via GITHUB_TOKEN), decompress the
zstd image, upload it through the PVE content=import channel, create a VM with
import-from (chosen display adapter + disk bus), boot it, capture the screen
over an SSH VNC tunnel, then tear the VM down. Credentials come from env vars.
"""
import argparse, io, os, pathlib, select, socket, subprocess, sys, threading, time

import requests
import paramiko
import zstandard as zstd

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"
OUT.mkdir(parents=True, exist_ok=True)


def env(name):
    v = os.environ.get(name)
    if not v:
        sys.exit(f"missing required env {name}")
    return v


class PVE:
    def __init__(self):
        host = env("PVE_HOST"); port = env("PVE_API_PORT"); user = env("PVE_USER")
        self.base = f"https://{host}:{port}/api2/json"
        self.s = requests.Session(); self.s.verify = False
        r = self.s.post(f"{self.base}/access/ticket",
                        data={"username": user, "password": env("PVE_API_PASS")})
        r.raise_for_status()
        d = r.json()["data"]
        self.ticket = d["ticket"]; self.csrf = d["CSRFPreventionToken"]
        self.s.cookies.set("PVEAuthCookie", self.ticket)
        self.s.headers["CSRFPreventionToken"] = self.csrf

    def call(self, method, path, **params):
        r = self.s.request(method, f"{self.base}{path}", data=params or None)
        if r.status_code >= 400:
            raise RuntimeError(f"{method} {path} -> {r.status_code} {r.text[:300]}")
        return r.json()["data"]

    def upload(self, node, storage, content, filepath):
        with open(filepath, "rb") as f:
            r = self.s.post(
                f"{self.base}/nodes/{node}/storage/{storage}/upload",
                files={"filename": (pathlib.Path(filepath).name, f)},
                data={"content": content})
        if r.status_code >= 400:
            raise RuntimeError(f"upload -> {r.status_code} {r.text[:300]}")
        return r.json()["data"]

    def wait_task(self, upid, timeout=300):
        if not (isinstance(upid, str) and upid.startswith("UPID")):
            return
        deadline = time.time() + timeout
        while time.time() < deadline:
            st = self.call("GET", f"/nodes/pve/tasks/{upid}/status")
            if st.get("status") in ("stopped",):
                if st.get("exitstatus") and st["exitstatus"] != "OK":
                    raise RuntimeError(f"task failed: {st['exitstatus']}")
                return
            time.sleep(1.5)
        raise TimeoutError(upid)


def download_asset(tag, asset):
    token = env("GITHUB_TOKEN")
    repo = env("GITHUB_REPOSITORY")
    h = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
    rel = requests.get(
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}", headers=h)
    rel.raise_for_status()
    obj = next((a for a in rel.json()["assets"] if a["name"] == asset), None)
    if not obj:
        sys.exit(f"asset {asset} not found in release {tag}")
    ar = requests.get(obj["url"], headers={**h, "Accept": "application/octet-stream"})
    ar.raise_for_status()
    comp = pathlib.Path(OUT / f"{asset}.zst")
    comp.write_bytes(ar.content)
    raw = pathlib.Path(OUT / f"{asset}.raw")
    with open(comp, "rb") as fi, open(raw, "wb") as fo:
        zstd.ZstdDecompressor().copy_stream(fi, fo)
    return raw


def vnc_capture(pve, vmid, host, ssh_port, user, ssh_pass, out_png):
    vp = pve.call("POST", f"/nodes/pve/qemu/{vmid}/vncproxy")
    port, ticket = int(vp["port"]), vp["ticket"]
    tr = paramiko.Transport((host, ssh_port)); tr.connect(username=user, password=ssh_pass)
    local_port = 5910; stop = threading.Event()

    def bridge(cs):
        ch = tr.open_channel("direct-tcpip", ("127.0.0.1", port),
                             ("127.0.0.1", local_port))
        while True:
            r, _, _ = select.select([cs, ch], [], [])
            if cs in r:
                d = cs.recv(4096)
                if not d: break
                ch.sendall(d)
            if ch in r:
                d = ch.recv(4096)
                if not d: break
                cs.sendall(d)
        ch.close(); cs.close()

    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", local_port)); srv.listen(5); srv.settimeout(1)

    def loop():
        while not stop.is_set():
            try: c, _ = srv.accept()
            except socket.timeout: continue
            threading.Thread(target=bridge, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start(); time.sleep(0.5)
    rc = subprocess.run(["vncdo", "-s", f"127.0.0.1::{local_port}", "-p", ticket,
                         "capture", str(out_png)], capture_output=True, timeout=90).returncode
    stop.set(); srv.close(); tr.close()
    return rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True); ap.add_argument("--asset", required=True)
    ap.add_argument("--vga", default="qxl"); ap.add_argument("--disk-bus", default="scsi")
    ap.add_argument("--memory", default="512")
    a = ap.parse_args()

    node = "pve"; storage = "tenant-private"; pool = "tenant-pool"
    raw = download_asset(a.tag, a.asset)
    pve = PVE()

    # import source through the tenant import channel
    upid = pve.upload(node, storage, "import", raw)
    pve.wait_task(upid)
    src = f"{storage}:import/{raw.name}"
    vmid = pve.call("GET", "/cluster/nextid")

    vm = dict(vmid=vmid, pool=pool, name=f"ci-{a.vga}-{a.disk_bus}",
              memory=a.memory, cores=1, ostype="l26",
              net0="virtio,bridge=vmbr0", machine="q35", bios="seabios",
              onboot=0, agent="0", tablet=0)
    if a.disk_bus == "scsi":
        vm["scsihw"] = "virtio-scsi-single"
        vm["scsi0"] = f"{storage}:0,import-from={src}"
        vm["boot"] = "order=scsi0"
    else:
        vm["virtio0"] = f"{storage}:0,import-from={src}"
        vm["boot"] = "order=virtio0"
    vm["vga"] = a.vga

    pve.wait_task(pve.call("POST", "/nodes/pve/qemu", **vm))
    pve.wait_task(pve.call("POST", f"/nodes/pve/qemu/{vmid}/status/start"))
    print(f"VM {vmid} booting ({a.vga}/{a.disk_bus}); waiting for console...")
    time.sleep(20)
    png = OUT / f"screen-{a.vga}-{a.disk_bus}.png"
    rc = vnc_capture(pve, vmid, env("PVE_HOST"), int(env("PVE_SSH_PORT")),
                     env("PVE_USER"), env("PVE_SSH_PASS"), png)
    print("capture rc:", rc, "png:", png, png.exists())

    # teardown to respect the tenant memory cap
    try: pve.call("POST", f"/nodes/pve/qemu/{vmid}/status/stop")
    except Exception: pass
    time.sleep(3)
    pve.call("DELETE", f"/nodes/pve/qemu/{vmid}")
    print("teardown complete")


if __name__ == "__main__":
    import urllib3
    urllib3.disable_warnings()
    main()
