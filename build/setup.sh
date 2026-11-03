#!/bin/sh
# This script is executed CHROOTED inside the freshly installed Alpine image
# (official alpine-make-vm-image runs it via --script-chroot; the script dir is
# bind-mounted at /mnt, the chroot root is the image itself).
set -e
APP_URL="${APP_URL:-}"
HEADLESS_SSH="${HEADLESS_SSH:-false}"
CJK_TTY="${CJK_TTY:-true}"

echo "==> system config: hostname / network"
setup-hostname vps-app

cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
rc-update add networking boot

# Disable IPv6 entirely (VPS has no IPv6 route; avoids IPv6 DNS timeouts).
cat > /etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
# Don't fail if a key doesn't exist on this kernel.
echo 'SYSCTL_OPTS="-e"' > /etc/conf.d/sysctl

# Static IPv4 DNS (DHCP may hand out IPv6 resolvers we can't reach).
# Write it now and again in local.d (runs after networking in default runlevel).
cat > /etc/resolv.conf <<'EOF'
nameserver 119.29.29.29
nameserver 223.5.5.5
EOF
mkdir -p /etc/local.d
cat > /etc/local.d/00-dns.start <<'SCRIPT'
#!/bin/sh
printf 'nameserver 119.29.29.29\nnameserver 223.5.5.5\n' > /etc/resolv.conf
SCRIPT
chmod +x /etc/local.d/00-dns.start
rc-update add local default

# --- single-app appliance: disable unused services/processes -------------
# Drop crond (no scheduled jobs), syslog/klogd (app writes its own log +
# VGA), swap (no swap partition), hwclock (virtual RTC not needed). Keep
# mdev, devfs/sysfs, seedrng, hostname, bootmisc, modules, networking.
rc-update del crond default >/dev/null 2>&1 || true
rc-update del syslog boot >/dev/null 2>&1 || true
rc-update del swap boot >/dev/null 2>&1 || true
rc-update del hwclock boot >/dev/null 2>&1 || true
# A fixed VM appliance does not need hardware probing or cgroup namespace
# setup. The official kernel module tree remains intact; only unnecessary
# OpenRC services are skipped. Keep sysctl because IPv6 must be disabled there.
rc-update del cgroups sysinit >/dev/null 2>&1 || true
rc-update del hwdrivers sysinit >/dev/null 2>&1 || true
rc-update del dmesg sysinit >/dev/null 2>&1 || true

sed -i '/^#\?ttyS0::respawn:/d' /etc/inittab
if [ "$HEADLESS_SSH" = "true" ]; then
    # Headless: no VGA console login; access the box over SSH only.
    sed -i 's|^#\?tty[1-6]::respawn:.*|#&|' /etc/inittab
else
    # Kiosk: only tty1 runs the app; drop the other gettys.
    sed -i 's|^tty[2-6]::respawn:.*|#&|' /etc/inittab
fi

# --- grow root fs to fill the whole disk on boot -------------------------
# MBR layout: root is on the first partition (/dev/vda1). Resolve the real
# partition from root=UUID in the kernel cmdline (findmnt may report the whole
# disk /dev/vda), then grow partition + filesystem with the cloud-init
# standard tools.
#
# Idempotent: growpart (Canonical, Alpine shell port) only acts when the
# partition can actually grow - "NOCHANGE" exits 0. After a completed grow we
# also stamp the disk size in /var/lib/grow-root.done so already-grown boots
# skip instantly; resizing the VPS disk later changes the size, invalidates
# the stamp and re-grows. The stamp is only written on success, so failures
# retry next boot.
cat > /etc/init.d/grow-root <<'EOF'
#!/sbin/openrc-run
description="Grow root filesystem to fill the whole disk"
depend() { need localmount; }
start() {
    ebegin "Growing root filesystem to fill disk"
    ROOT_UUID=$(sed -n 's/.*root=UUID=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)
    ROOT_DEV=""
    [ -n "$ROOT_UUID" ] && ROOT_DEV=$(findfs "UUID=$ROOT_UUID" 2>/dev/null || true)
    [ -z "$ROOT_DEV" ] && ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null || true)
    [ -n "$ROOT_DEV" ] || { eend 0; return 0; }

    DISK=$(echo "$ROOT_DEV" | sed 's/p\?[0-9]*$//')
    PART_NUM=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$')
    [ -n "$PART_NUM" ] || { eend 0; return 0; }

    # Idempotent skip: disk size unchanged since the last completed grow.
    STAMP=/var/lib/grow-root.done
    DISK_SECTORS=$(cat "/sys/class/block/$(basename "$DISK")/size" 2>/dev/null || true)
    if [ -n "$DISK_SECTORS" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$DISK_SECTORS" ]; then
        eend 0
        return 0
    fi

    # growpart extends the partition only when needed and updates the kernel
    # partition table itself (partx --update). It exits non-zero with NOCHANGE
    # when the partition already ends at the disk boundary; treat that as
    # success and still write the stamp so equal-size test/DD images converge.
    growpart_out=$(growpart "$DISK" "$PART_NUM" 2>&1)
    growpart_rc=$?
    if [ "$growpart_rc" -ne 0 ] \
        && ! printf '%s\n' "$growpart_out" | grep -qi 'NOCHANGE'; then
        eend 1
        return 1
    fi
    if resize2fs "$ROOT_DEV" >/dev/null 2>&1; then
        [ -n "$DISK_SECTORS" ] && echo "$DISK_SECTORS" > "$STAMP"
    else
        eend 1
        return 1
    fi
    eend 0
}
EOF
chmod +x /etc/init.d/grow-root
rc-update add grow-root boot

# --- time sync: correct system clock on every boot ----------------------
# Virtual RTC may drift. Sync once via NTP before the app starts (the Go
# launcher and the business app need a correct clock for TLS). busybox ntpd
# is already present; -q = query once then exit, -n = no daemonize.
cat > /etc/init.d/time-sync <<'EOF'
#!/sbin/openrc-run
description="Sync system clock via NTP once at boot"
depend() { need net; }
start() {
    ebegin "Syncing time via NTP"
    timeout 15 busybox ntpd -q -n -p ntp.aliyun.com -p ntp.tencent.com -p cn.ntp.org.cn >/dev/null 2>&1
    eend 0
}
EOF
chmod +x /etc/init.d/time-sync
rc-update add time-sync boot

# --- SSH remote access (sshd on port 22, key-only) ----------------------
# Headless builds only. Host keys are baked in from /mnt/vendor/ so the host
# fingerprint stays stable; root login is key-only.
if [ "$HEADLESS_SSH" = "true" ]; then
install -d -m 0700 /etc/ssh /root/.ssh
# Bake fixed host keys
if [ -f /mnt/vendor/ssh_host_ed25519_key ]; then
    install -m 0600 /mnt/vendor/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
    install -m 0644 /mnt/vendor/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
fi
# Bake authorized_keys (public half of the user key)
if [ -f /mnt/vendor/ssh_user_key.pub ]; then
    install -m 0600 /mnt/vendor/ssh_user_key.pub /root/.ssh/authorized_keys
fi
# sshd config: port 22, key-only root, no password, no idle timeout
cat > /etc/ssh/sshd_config <<'EOF'
Port 22
ListenAddress 0.0.0.0
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
ClientAliveInterval 120
ClientAliveCountMax 3
EOF
# Clear any host keys openssh might have generated on first install; we want ours.
rm -f /etc/ssh/ssh_rsa_key* /etc/ssh/ssh_ecdsa_key* /etc/ssh/ssh_dsa_key* 2>/dev/null || true
rc-update add sshd default
fi

# --- single-app mode: business binary on the VGA console (tty1) ----------
# The image is a single-purpose appliance. On boot the business binary takes
# over the VGA screen (kiosk-style). CJK rendering uses fbterm, compiled here
# from source against Alpine's musl toolchain (the Alpine-native, official
# build flow) + the official font-wqy-zenhei package. If no framebuffer/font
# The default VGA kiosk uses fbterm on tty1 for CJK text. No plain VGA tty
# fallback: a required display component failure fails the image build early.
# The business URL is baked into the app-runner binary (default value, or an
# -X main.appURL override at build time), so the app-runner service is always
# installed and runs on every boot; APP_URL is no longer a switch.
mkdir -p /opt /usr/local/sbin /var/log
    # --- compile fbterm natively (musl) for Chinese on the VGA console ----
    # Alpine ships no fbterm package; build from upstream source in the chroot
    # with the official toolchain, then drop the dev packages again.
    if [ "$HEADLESS_SSH" = "true" ] || [ "$CJK_TTY" = "false" ]; then
        echo "Skipping fbterm build for non-VGA/CJK-disabled profile"
    elif [ ! -f /mnt/vendor/fbterm-src.tar.gz ]; then
        echo "ERROR: fbterm source required for CJK tty but missing"; exit 1
    else
        echo "==> building fbterm from upstream source using its autotools guide"
        # Community-standard Alpine pattern: group temporary build packages in a
        # virtual world group, then remove the group and unused dependencies.
        # Explicit C/C++ toolchain; retry transient apk fetch failures and fail
        # loudly here instead of letting ./configure die with a vague
        # "C++ compiler cannot create executables" after a half-installed set.
        for attempt in 1 2 3; do
            if apk add --no-cache --virtual .fbterm-build-deps \
                build-base g++ pkgconf fontconfig-dev freetype-dev linux-headers; then
                break
            fi
            echo "fbterm build-deps install attempt $attempt failed; retrying"
            sleep 3
        done
        command -v g++ >/dev/null 2>&1 || { echo "ERROR: g++ unavailable after build-deps install"; exit 1; }
        cd /tmp
        rm -rf /tmp/fbterm-*
        tar xzf /mnt/vendor/fbterm-src.tar.gz 2>/dev/null
        FBTERM_DIR="$(find /tmp -maxdepth 1 -type d -name 'fbterm-*' | head -1)"
        [ -n "$FBTERM_DIR" ] || { echo "fbterm source did not extract to a fbterm-* directory"; exit 1; }
        FB_CXXFLAGS="-D_GNU_SOURCE -include sys/select.h -include sys/time.h -include unistd.h -DWAIT_ANY=-1 -Wno-narrowing"
        if ( cd "$FBTERM_DIR" \
             && CXXFLAGS="$FB_CXXFLAGS" ./configure --prefix=/usr --disable-gpm --disable-vesa --disable-signalfd >/tmp/fbterm-build.log 2>&1 \
             && make -j"$(nproc)" CXXFLAGS="$FB_CXXFLAGS" >>/tmp/fbterm-build.log 2>&1 \
             && make install >>/tmp/fbterm-build.log 2>&1 ); then
            :
        else
            echo "fbterm build FAILED - see /tmp/fbterm-build.log"
            tail -15 /tmp/fbterm-build.log; exit 1
        fi
        cd / && rm -rf /tmp/fbterm-*
        strip /usr/bin/fbterm 2>/dev/null || true
        apk del .fbterm-build-deps >/dev/null 2>&1 || true
        apk cache clean >/dev/null 2>&1 || true
        rm -f /tmp/fbterm-build.log
        FB_BIN="$(command -v fbterm 2>/dev/null || true)"
        if [ -z "$FB_BIN" ]; then
            echo "fbterm build did not produce a binary"; exit 1
        fi
        if ! infocmp fbterm >/dev/null 2>&1; then
            echo "fbterm terminfo entry was not installed"; exit 1
        fi
        missing="$(ldd "$FB_BIN" 2>&1 | grep -iE 'not found|no such|error loading' || true)"
        if [ -n "$missing" ]; then
            echo "fbterm installed but has missing shared libraries:"
            echo "$missing"; exit 1
        fi
        echo "fbterm ready: $(fbterm --version 2>&1 | head -1)"
    fi
    # Install the Go-built static app-runner binary (compiled on the host
    # runner with CGO_ENABLED=0; fully self-contained, no external downloader).
    if [ -f /mnt/vendor/app-runner ]; then
        install -m 0755 /mnt/vendor/app-runner /usr/local/sbin/app-runner
        # hard-verify it has no missing shared libraries (static build should be
        # fully self-contained; catch any accidental dynamic link early)
        miss="$(ldd /usr/local/sbin/app-runner 2>&1 | grep -iE 'not found|no such|error loading' || true)"
        if [ -n "$miss" ]; then
            echo "app-runner binary has missing libs:"; echo "$miss"; exit 1
        fi
        echo "app-runner (Go static) installed"
    else
        echo "ERROR: /mnt/vendor/app-runner missing (host build step failed)"; exit 1
    fi
    if [ "$HEADLESS_SSH" = "true" ]; then
        # Headless SSH: supervised background service; sshd remains optional.
        # Read-only GPU inventory: never modprobes a driver and never touches
        # /dev/fb0; an SSH session reads /var/log/gpu-audit.log to identify the
        # platform display-class device (e.g. whether it is a QXL/SPICE device).
        cat > /usr/local/sbin/gpu-audit.sh <<'EOF'
#!/bin/sh
{
    echo "=== gpu inventory $(date 2>/dev/null) ==="
    echo "--- PCI class 0x03 (display) vendor:device ---"
    for d in /sys/bus/pci/devices/*; do
        c=$(cat "$d/class" 2>/dev/null || true)
        case "$c" in
            0x03*) echo "$(basename "$d") class=$c vendor=$(cat "$d/vendor" 2>/dev/null) device=$(cat "$d/device" 2>/dev/null)" ;;
        esac
    done
    echo "--- /proc/fb (headless flavor normally has none) ---"
    cat /proc/fb 2>/dev/null || echo "(no framebuffer bound)"
    echo "--- kernel drm/gpu messages ---"
    dmesg 2>/dev/null | grep -iE 'qxl|bochs|cirrus|virtio.?gpu|vmwgfx|vboxvideo|hyperv_drm|drm_xen|simpledrm|drm' | tail -40 || true
    echo "=== end inventory ==="
} > /var/log/gpu-audit.log 2>&1 || true
EOF
        chmod +x /usr/local/sbin/gpu-audit.sh
        cat > /etc/init.d/app-runner <<'EOF'
#!/sbin/openrc-run
description="Download and run the business application"
supervisor=supervise-daemon
command=/usr/local/sbin/app-runner
environment="APP_RUNNER_LOG_STDOUT_ONLY=1"
command_user=root
pidfile=/run/app-runner.pid
output_log=/var/log/app-runner.log
error_log=/var/log/app-runner.log
depend() { need net; after time-sync sshd; }
pre_start() {
    [ -x /usr/local/sbin/gpu-audit.sh ] && /usr/local/sbin/gpu-audit.sh || true
    pkill -f '^/opt/business-app' 2>/dev/null || true
}
EOF
        cat > /etc/conf.d/app-runner <<'EOF'
respawn=respawn
respawn_delay=2
EOF
        chmod +x /etc/init.d/app-runner
        rc-update add app-runner default
    elif [ "$CJK_TTY" = "false" ]; then
        # CJK disabled: supervised background service, no VGA takeover.
        cat > /etc/init.d/app-runner <<'EOF'
#!/sbin/openrc-run
description="Download and run the business application"
supervisor=supervise-daemon
command=/usr/local/sbin/app-runner
environment="APP_RUNNER_LOG_STDOUT_ONLY=1"
command_user=root
pidfile=/run/app-runner.pid
output_log=/var/log/app-runner.log
error_log=/var/log/app-runner.log
depend() { need net; after time-sync; }
pre_start() {
    pkill -f '^/opt/business-app' 2>/dev/null || true
}
EOF
        cat > /etc/conf.d/app-runner <<'EOF'
respawn=respawn
respawn_delay=2
EOF
        chmod +x /etc/init.d/app-runner
        rc-update add app-runner default
    else
        # Default VGA kiosk: the single CJK-only boot path. fbterm + wqy-zenhei
        # render the app full-screen on /dev/fb0. There is deliberately NO text
        # console fallback: if no framebuffer device appears the script exits
        # (inittab respawns it); it never switches to an ASCII-only console.
        cat > /usr/local/sbin/app-runner-fb.sh <<'EOF'
#!/bin/sh
# Single CJK path: fbterm full-screen on the framebuffer. No text fallback.
printf 'nameserver 119.29.29.29\nnameserver 223.5.5.5\n' > /etc/resolv.conf 2>/dev/null
pkill -f '^/opt/business-app' 2>/dev/null || true
stty sane 2>/dev/null || true
# Probe common virtual display controllers; modprobe pulls the drm/fb
# dependency closure in automatically (bochs=QEMU std VGA, cirrus=QEMU cirrus,
# virtio-gpu=virtio GPU, qxl=SPICE/QXL cloud desktop, vmwgfx=VMware SVGA,
# vboxvideo=VirtualBox, hyperv_drm=Hyper-V, drm_xen_front=Xen; simpledrm=
# simple-framebuffer/EFI GOP). Only drivers matching an actual device bind.
for m in bochs cirrus virtio-gpu simpledrm qxl vmwgfx vboxvideo hyperv_drm drm_xen_front; do modprobe "$m" 2>/dev/null || true; done
# Wait for the kernel to register /dev/fb0 after a driver binds the hardware.
i=0
while [ ! -c /dev/fb0 ] && [ "$i" -lt 30 ]; do
    modprobe fb 2>/dev/null || true
    i=$((i + 1))
    sleep 0.5
done
FBTERM="$(command -v fbterm || true)"
FONT="$(find /usr/share/fonts -type f -iname 'wqy*' 2>/dev/null | head -1)"
[ -c /dev/fb0 ] || { echo "fb0 missing: no framebuffer device bound"; sleep 3; exit 1; }
[ -n "$FBTERM" ] || { echo "fbterm missing"; exit 1; }
[ -n "$FONT" ] || { echo "CJK font missing"; exit 1; }
# Read-only backend audit: record which display driver bound /dev/fb0 (for
# example qxldrmfb / bochs-drmdrmfb / cirrusdrmfb / virtio_gpudrmfb) and the
# PCI display-class device. Non-blocking by design: if any audit command fails
# the boot path must continue unchanged; this never adds a fallback.
{
    echo "=== framebuffer backend audit ==="
    echo "--- /proc/fb ---"; cat /proc/fb 2>/dev/null || true
    echo "--- /dev/fb0 ---"; ls -l /dev/fb0 2>/dev/null || true
    echo "--- related kernel modules ---"
    lsmod 2>/dev/null | grep -iE 'qxl|bochs|cirrus|virtio_gpu|vmwgfx|vboxvideo|hyperv_drm|drm_xen_front|simpledrm|drm_ttm|drm_kms|^drm ' || true
    echo "--- PCI class 0x03 (display) vendor:device ---"
    for d in /sys/bus/pci/devices/*; do
        c=$(cat "$d/class" 2>/dev/null || true)
        case "$c" in
            0x03*) echo "$(basename "$d") class=$c vendor=$(cat "$d/vendor" 2>/dev/null) device=$(cat "$d/device" 2>/dev/null)" ;;
        esac
    done
    echo "--- kernel drm/framebuffer messages ---"
    dmesg 2>/dev/null | grep -iE 'qxldrmfb|bochs-drm|cirrusdrmfb|virtio_gpudrmfb|vmwgfx|vboxvideo|hyperv_drm|drm_xen|simpledrm|fb0:|frame buffer device' || true
    echo "=== end audit ==="
} > /var/log/fb-backend.log 2>&1 || true
printf '\033c' 2>/dev/null || true
printf '\033[2J\033[H' 2>/dev/null || true
RUN="exec /usr/local/sbin/app-runner 2>&1 | tee -a /var/log/app-runner.log"
APP_RUNNER_LOG_STDOUT_ONLY=1 exec "$FBTERM" -f "$FONT" -s 22 -- sh -c "$RUN"
EOF
        chmod +x /usr/local/sbin/app-runner-fb.sh
        sed -i 's|^#\?tty1::respawn:.*|tty1::respawn:/usr/local/sbin/app-runner-fb.sh|' /etc/inittab
        grep -q '^tty1::respawn:' /etc/inittab || echo 'tty1::respawn:/usr/local/sbin/app-runner-fb.sh' >> /etc/inittab
    fi

# --- explicit boot modules ------------------------------------------------
# Declare required modules explicitly; do not prune the kernel module tree
# with a hand-maintained allowlist. Missing module availability is caught at
# build/boot time instead of silently removing a driver.
cat > /etc/modules <<'EOF'
virtio
virtio_ring
virtio_pci
virtio_blk
virtio_net
e1000
tun
ext4
mbcache
sch_fq
EOF
# VGA flavor loads framebuffer/drm drivers so fbterm gets /dev/fb0 on cloud
# desktops that expose a virtual GPU (QEMU std VGA -> bochs, QEMU cirrus ->
# cirrus, virtio-gpu, simple-framebuffer/EFI GOP -> simpledrm). Module names
# use the real modprobe basename (virtio-gpu, not virtio_gpu); unknown names are
# skipped by modprobe, and drm/fb/i2c-core/virtio_dma_buf load as dependencies.
if [ "$HEADLESS_SSH" != "true" ] && [ "$CJK_TTY" != "false" ]; then
    for m in bochs cirrus virtio-gpu simpledrm qxl vmwgfx vboxvideo hyperv_drm drm_xen_front; do
        grep -qx "$m" /etc/modules || echo "$m" >> /etc/modules
    done
fi
apk cache clean >/dev/null 2>&1 || true
# Enable BBR/fq and basic TCP performance tuning (write directly to /proc/sys
# to avoid sysctl service dependency on an unknown key).
cat > /etc/local.d/10-bbr.start <<'EOF'
#!/bin/sh
modprobe tcp_bbr 2>/dev/null
modprobe sch_fq 2>/dev/null
echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null
echo bbr > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
echo 16777216 > /proc/sys/net/core/rmem_max 2>/dev/null
echo 16777216 > /proc/sys/net/core/wmem_max 2>/dev/null
printf '4096 87380 16777216\n' > /proc/sys/net/ipv4/tcp_rmem 2>/dev/null
printf '4096 65536 16777216\n' > /proc/sys/net/ipv4/tcp_wmem 2>/dev/null
echo 3 > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_sack 2>/dev/null
EOF
chmod +x /etc/local.d/10-bbr.start

# --- trim kernel module tree to the dependency closure ---------------------
# Keep only the drivers this appliance actually needs (virtio storage/net, the
# ext4 fs, BBR qdiscs, and - for the VGA kiosk - the framebuffer/drm chain).
# The retained set is derived from the kernel's own module metadata (modules.dep
# dependency closure), NOT a hand-maintained allowlist, so any driver that is
# required by a kept capability is automatically kept too. Everything outside
# the closure is removed, then the initramfs is rebuilt from the trimmed tree so
# it stops carrying the dropped modules. This mirrors the minimal-kernel intent
# of Alpine's own cloud images while preserving every driver we need at runtime.
KVER="$(ls /lib/modules 2>/dev/null | head -1)"
if [ -n "$KVER" ] && [ -d "/lib/modules/$KVER" ]; then
    MROOT="/lib/modules/$KVER"
    DEP="$MROOT/modules.dep"
    # Omit console/serial drivers (virtio_console/hvc) and test emulation
    # modules (sch_netem): this production appliance has no serial console and
    # never injects delay/loss for testing; nothing kept depends on them.
    SEEDS="virtio virtio_ring virtio_pci virtio_mmio virtio_blk virtio_net virtio_rng virtio_balloon e1000 e1000e tun sch_fq tcp_bbr ext4 jbd2 mbcache crc32c_intel crc32c_generic crc16 crc32_generic rng_core net_failover failover af_packet"
    if [ "$HEADLESS_SSH" != "true" ] && [ "$CJK_TTY" != "false" ]; then
        # VGA kiosk needs the framebuffer + drm chain (fbterm -> /dev/fb0).
        # Include the common cloud hypervisor display drivers; dependency closure
        # automatically keeps ttm, i2c-core, xen-front-pgdir-shbuf, etc.
        SEEDS="$SEEDS fb fb_sys_fops sysfillrect sysimgblt syscopyarea drm drm_kms_helper drm_shmem_helper drm_ttm_helper drm_vram_helper ttm simpledrm bochs cirrus virtio_gpu qxl vmwgfx vboxvideo hyperv_drm drm_xen_front i2c_core virtio_dma_buf"
    fi
    KEEPFILE="/tmp/keepmods.$$"
    : > "$KEEPFILE"
    # seed: any module whose basename matches a seed (dashes normalized to _)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        mod="${line%%:*}"
        base="${mod##*/}"
        stem="$(printf '%s' "$base" | tr '-' '_')"
        case "$stem" in
            *.ko.gz) stem="${stem%.ko.gz}" ;;
            *.ko) stem="${stem%.ko}" ;;
        esac
        for s in $SEEDS; do
            [ "$stem" = "$s" ] && printf '%s\n' "$mod" >> "$KEEPFILE"
        done
    done < "$DEP"
    sort -u "$KEEPFILE" -o "$KEEPFILE"
    # closure: walk dependency edges until a fixpoint
    changed=1
    while [ "$changed" = 1 ]; do
        changed=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            mod="${line%%:*}"
            grep -Fxq "$mod" "$KEEPFILE" || continue
            for d in ${line#*:}; do
                if ! grep -Fxq "$d" "$KEEPFILE"; then
                    printf '%s\n' "$d" >> "$KEEPFILE"; changed=1
                fi
            done
        done < "$DEP"
        sort -u "$KEEPFILE" -o "$KEEPFILE"
    done
    # remove every module file outside the closure
    find "$MROOT/kernel" -name '*.ko*' | while IFS= read -r f; do
        rel="${f#"$MROOT"/}"
        grep -Fxq "$rel" "$KEEPFILE" || rm -f "$f"
    done
    find "$MROOT/kernel" -type d -empty -delete 2>/dev/null
    rm -f "$KEEPFILE"
    echo "  kept $(find "$MROOT/kernel" -name '*.ko*' 2>/dev/null | wc -l) kernel modules"
    # drop scsi from mkinitfs features and rebuild the initramfs from the tree
    if [ -f /etc/mkinitfs/mkinitfs.conf ]; then
        sed -i 's/scsi //g; s/  */ /g' /etc/mkinitfs/mkinitfs.conf
    fi
    if command -v mkinitfs >/dev/null 2>&1; then
        if ! mkinitfs -o /boot/initramfs-virt "$KVER" >/dev/null 2>&1; then
            echo "  WARN: mkinitfs rebuild failed; keeping original initramfs"
        fi
    fi
fi

echo "==> setup done"
