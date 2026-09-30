#!/bin/sh
# This script is executed CHROOTED inside the freshly installed Alpine image
# (official alpine-make-vm-image runs it via --script-chroot; the script dir is
# bind-mounted at /mnt, the chroot root is the image itself).
set -e
APP_URL="${APP_URL:-}"

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
# virt kernel has all drivers built-in; no hardware probing / cgroup namespaces
# needed for a single-app appliance. sysctl config is empty and dmesg buffer is
# not consumed - skip them to shorten boot.
rc-update del cgroups sysinit >/dev/null 2>&1 || true
rc-update del hwdrivers sysinit >/dev/null 2>&1 || true
# Keep sysctl boot: we need it to apply disable_ipv6.
rc-update del dmesg sysinit >/dev/null 2>&1 || true

# Only tty1 runs the app (kiosk); drop the other gettys.
sed -i 's|^tty[2-6]::respawn:.*|#&|' /etc/inittab

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
    # partition table itself (partx --update). Then grow the filesystem.
    # Stamp only when the whole chain succeeds, so failures retry next boot.
    if growpart "$DISK" "$PART_NUM" >/dev/null 2>&1 \
        && resize2fs "$ROOT_DEV" >/dev/null 2>&1; then
        [ -n "$DISK_SECTORS" ] && echo "$DISK_SECTORS" > "$STAMP"
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

# --- single-app mode: business binary on the VGA console (tty1) ----------
# The image is a single-purpose appliance. On boot the business binary takes
# over the VGA screen (kiosk-style). CJK rendering uses fbterm, compiled here
# from source against Alpine's musl toolchain (the Alpine-native, official
# build flow) + the official font-wqy-zenhei package. If no framebuffer/font
# is present it degrades to the plain VGA tty. No serial console is configured
# (production output is VGA-only); state is mirrored to a log file.
if [ -n "$APP_URL" ]; then
    mkdir -p /opt /usr/local/sbin /var/log
    # --- compile fbterm natively (musl) for Chinese on the VGA console ----
    # Alpine ships no fbterm package; build from upstream source in the chroot
    # with the official toolchain, then drop the dev packages again.
    if [ -f /mnt/vendor/fbterm-src.tar.gz ]; then
        echo "==> compiling fbterm from source (Alpine native, CJK support)"
        apk add --no-cache build-base fontconfig-dev freetype-dev linux-headers ncurses >/dev/null 2>&1 || true
        cd /tmp
        rm -rf /tmp/fbterm-*
        tar xzf /mnt/vendor/fbterm-src.tar.gz 2>/dev/null
        FBTERM_DIR="$(find /tmp -maxdepth 1 -type d -name 'fbterm-*' | head -1)"
        [ -n "$FBTERM_DIR" ] || { echo "fbterm source did not extract to a fbterm-* directory"; exit 1; }
        # musl on Alpine edge doesn't expose WAIT_ANY; provide a fallback.
        sed -i 's|WAIT_ANY|((pid_t)-1)|g' "$FBTERM_DIR/src/fbterm.cpp"
        FB_CXXFLAGS="-D_GNU_SOURCE -include sys/select.h -include sys/time.h -include unistd.h -Wno-error=narrowing -Wno-narrowing"
        if ( cd "$FBTERM_DIR" \
             && CXXFLAGS="$FB_CXXFLAGS" ./configure --prefix=/usr --disable-signalfd >/tmp/fbterm-build.log 2>&1 \
             && make -j"$(nproc)" CXXFLAGS="$FB_CXXFLAGS" >>/tmp/fbterm-build.log 2>&1 \
             && make install >>/tmp/fbterm-build.log 2>&1 ); then
            :
        else
            echo "fbterm build FAILED - see /tmp/fbterm-build.log"
            tail -15 /tmp/fbterm-build.log; exit 1
        fi
        cd / && rm -rf /tmp/fbterm-*
        strip /usr/bin/fbterm 2>/dev/null || true
        # Remove ONLY build-time packages (compiler + headers + -dev). The
        # runtime shared libraries fbterm links against (fontconfig, freetype,
        # libstdc++) are separate packages and must stay. ncurses is kept too:
        # it provides the terminfo database that `tic fbterm` populated and
        # that programs inside fbterm look up via $TERM.
        apk del build-base fontconfig-dev freetype-dev linux-headers >/dev/null 2>&1 || true
        # Hard-verify the installed binary actually has all shared libraries
        # and can launch (file-exists is not enough; a missing lib would make
        # tty1 respawn-loop with only a blank VGA).
        FB_BIN="$(command -v fbterm 2>/dev/null || true)"
        if [ -z "$FB_BIN" ]; then
            echo "fbterm build did not produce a binary"; exit 1
        fi
        missing="$(ldd "$FB_BIN" 2>&1 | grep -iE 'not found|no such|error loading' || true)"
        if [ -n "$missing" ]; then
            echo "fbterm installed but has missing shared libraries:"
            echo "$missing"; exit 1
        fi
        echo "fbterm ready: $(fbterm --version 2>&1 | head -1)"
    else
        echo "WARNING: fbterm source missing - VGA Chinese display degraded"
    fi
    # Bake the download URL into the image so the Go launcher (which has no
    # shell wrapper injecting env) can read it at runtime.
    printf 'APP_URL=%s\n' "$APP_URL" > /etc/app-runner.env
    # Install the Go-built static app-runner binary (compiled on the host
    # runner with CGO_ENABLED=0; no shell interpreter, no aria2c, no glibc).
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
    # CJK-aware launcher: fbterm (framebuffer terminal) + CJK font for Chinese;
    # fall back to the plain VGA tty when no framebuffer / font / fbterm.
    cat > /usr/local/sbin/app-runner-fb.sh <<'EOF'
#!/bin/sh
# Force IPv4 DNS before Go starts (DHCP may have handed out unreachable IPv6).
printf 'nameserver 119.29.29.29\nnameserver 223.5.5.5\n' > /etc/resolv.conf 2>/dev/null
FBTERM="$(command -v fbterm || true)"
# Prefer the CJK font (wqy-zenhei) if present; fall back to any TTF/TTC/OTF.
FONT="$(find /usr/share/fonts -type f -iname 'wqy*' 2>/dev/null | head -1)"
[ -z "$FONT" ] && FONT="$(find /usr/share/fonts -type f \( -name '*.ttc' -o -name '*.ttf' -o -name '*.otf' \) 2>/dev/null | head -1)"
if [ -c /dev/fb0 ] && [ -n "$FONT" ] && [ -n "$FBTERM" ]; then
    exec "$FBTERM" -f "$FONT" -s 22 -- /usr/local/sbin/app-runner
else
    exec /usr/local/sbin/app-runner
fi
EOF
    chmod +x /usr/local/sbin/app-runner-fb.sh
    # take over VGA tty1 (replace getty with the app loop) - standard init
    sed -i 's|^#\?tty1::respawn:.*|tty1::respawn:/usr/local/sbin/app-runner-fb.sh|' /etc/inittab
    grep -q '^tty1::respawn:' /etc/inittab || echo 'tty1::respawn:/usr/local/sbin/app-runner-fb.sh' >> /etc/inittab
fi

# --- image size cleanup --------------------------------------------------
# Load network drivers at boot (virtio_net for VPS, e1000 for compat/QEMU).
cat > /etc/modules <<'EOF'
virtio
virtio_ring
virtio_pci
virtio_net
e1000
EOF
rm -rf /var/cache/apk/* /usr/share/doc /usr/share/man /usr/share/info 2>/dev/null || true

# VPS doesn't need firmware blobs.
rm -rf /lib/firmware 2>/dev/null || true

# Keep network driver modules (virtio_net, e1000) and their deps; delete the rest.
KEEP_MODS="virtio_net virtio_pci virtio virtio_ring net af_packet stp llc e1000 mii net_failover virtio-mmio tcp_bbr tcp_htcp tcp_cubic"
find /lib/modules -name '*.ko*' | while read m; do
  keep=0
  for k in $KEEP_MODS; do
    case "$(basename "$m")" in "$k".ko*) keep=1;; esac
  done
  [ "$keep" = "0" ] && rm -f "$m"
done
# Rebuild module dependency tree.
depmod -a 2>/dev/null || true
echo "==> kept network modules:"
find /lib/modules -name '*.ko*' 2>/dev/null
# Enable BBR for better network performance (write directly to /proc/sys).
cat > /etc/local.d/10-bbr.start <<'EOF'
#!/bin/sh
modprobe tcp_bbr 2>/dev/null
modprobe sch_fq 2>/dev/null
echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null
echo bbr > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
EOF
chmod +x /etc/local.d/10-bbr.start

# Keep only the CJK font; remove other fonts to save space.
find /usr/share/fonts -type f ! -iname 'wqy*' -delete 2>/dev/null || true

# Remove locale/i18n data.
rm -rf /usr/share/locale /usr/share/i18n 2>/dev/null || true

echo "==> setup done"
