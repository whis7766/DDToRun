#!/bin/sh
# This script is executed CHROOTED inside the freshly installed Alpine image
# (official alpine-make-vm-image runs it via --script-chroot; the script dir is
# bind-mounted at /mnt, the chroot root is the image itself).
set -e
APP_URL="${APP_URL:-}"

echo "==> system config: hostname / network"
setup-hostname vps-app

# DHCP on eth0 (virtio-net names eth0 on Alpine default naming)
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
rc-update add networking boot

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
rc-update del sysctl boot >/dev/null 2>&1 || true
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
    busybox ntpd -q -n -p ntp.aliyun.com -p ntp.tencent.com -p cn.ntp.org.cn >/dev/null 2>&1
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
        tar xzf /mnt/vendor/fbterm-src.tar.gz 2>/dev/null
        if ( cd fbterm-master \
             && ./configure --prefix=/usr >/tmp/fbterm-build.log 2>&1 \
             && make -j"$(nproc)" >>/tmp/fbterm-build.log 2>&1 \
             && make install >>/tmp/fbterm-build.log 2>&1 ); then
            :
        else
            echo "fbterm build FAILED - see /tmp/fbterm-build.log"
            tail -15 /tmp/fbterm-build.log; exit 1
        fi
        cd / && rm -rf /tmp/fbterm-master
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
FBTERM="$(command -v fbterm || true)"
FONT="$(find /usr/share/fonts -type f \( -name '*.ttc' -o -name '*.ttf' -o -name '*.otf' \) 2>/dev/null | head -1)"
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
# No extra kernel modules to autoload (virt kernel drivers are built in);
# keep /etc/modules empty so nothing extra is probed at boot.
: > /etc/modules
rm -rf /var/cache/apk/* /usr/share/doc /usr/share/man /usr/share/info 2>/dev/null || true

echo "==> setup done"
