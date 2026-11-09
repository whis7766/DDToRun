#!/usr/bin/env bash
# Build a "dd-ready" Alpine Linux VPS image with the OFFICIAL
# alpine-make-vm-image tool (https://github.com/alpinelinux/alpine-make-vm-image).
#
# Layout: legacy BIOS / MBR partition table (one bootable ext4 partition,
# extlinux bootloader, syslinux mbr.bin in sector 0) — the most compatible
# layout for VPS reinstall scripts and legacy-BIOS providers.
#
# On first boot the root fs auto-grows to the whole disk; an app-runner
# service (static Go binary, download URL baked in) always downloads and runs
# the business binary — on the VGA console (tty1) with Chinese (fbterm +
# wqy-zenhei), or as a supervised service in headless SSH mode.
#
# Env (all optional):
#   APP_URL        business binary URL; blank uses the default baked into
#                  app-runner.go, non-blank overrides it via -X at build time
#   IMAGE_SIZE_GB  image size in GB (default 1)
#   ALPINE_MIRROR  apk mirror (default https://dl-cdn.alpinelinux.org/alpine)
#   ALPINE_BRANCH  alpine branch (default v3.22)
#   KERNEL_FLAVOR  kernel flavor (default virt; official lightweight VM kernel)
#   PACKAGES       extra apk packages (space separated)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

APP_URL="${APP_URL:-}"
IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-1}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.22}"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-virt}"
HEADLESS_SSH="${HEADLESS_SSH:-false}"
CJK_TTY="${CJK_TTY:-true}"
# Headless SSH mode drops fbterm, CJK fonts, and the VGA kiosk takeover; the
# app runs as a supervised background service and is accessed over SSH:22.
if [ "$HEADLESS_SSH" = "true" ]; then
  BASE_PACKAGES="cloud-utils-growpart ca-certificates e2fsprogs-extra ifupdown-ng dhcpcd openssh"
elif [ "$CJK_TTY" != "false" ]; then
  BASE_PACKAGES="cloud-utils-growpart ca-certificates e2fsprogs-extra ifupdown-ng dhcpcd font-wqy-zenhei fontconfig freetype ncurses"
else
  BASE_PACKAGES="cloud-utils-growpart ca-certificates e2fsprogs-extra ifupdown-ng dhcpcd"
fi
# Optional glibc compat layer for a dynamic-glibc (CGO) business binary.
# Defaults to off: only installed when CGO_COMPAT is explicitly "true".
if [ "${CGO_COMPAT:-false}" = "true" ]; then
  BASE_PACKAGES="$BASE_PACKAGES gcompat libc6-compat"
fi
PACKAGES="${PACKAGES:-$BASE_PACKAGES}"

WORK="$(mktemp -d /tmp/alpine-build.XXXXXX)"
IMG="$WORK/vps-app-runner.raw"
TOOL="$WORK/alpine-make-vm-image"

# --- 0. host deps --------------------------------------------------------
for c in losetup rsync sfdisk mkfs.ext4 curl tar zerofree; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing host dep: $c"; exit 1; }
done

# --- 1. fetch official tool ----------------------------------------------
echo "==> [1/6] fetch official alpine-make-vm-image"
curl -fSL --retry 5 --retry-all-errors --connect-timeout 30 -o "$TOOL" \
  https://raw.githubusercontent.com/alpinelinux/alpine-make-vm-image/master/alpine-make-vm-image
chmod +x "$TOOL"

# --- 2. provision apk.static ----------------------------------------------
# The official tool downloads apk-tools from gitlab.alpinelinux.org, which is
# flaky/unreachable from GitHub runners (dl-cdn is fine). We vendor a static
# apk-tools in build/vendor/ so the build never depends on that download.
echo "==> [2/6] provision apk.static"
APK_STATIC=""
VENDOR_APK="$SCRIPT_DIR/vendor/apk.static"
if [ -x "$VENDOR_APK" ]; then
  APK_STATIC="$VENDOR_APK"
else
  PKG=$(curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 \
    "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main/x86_64/" \
    | grep -oE 'apk-tools-static-[0-9]+(\.[0-9]+)*(-r[0-9]+)?\.apk' | sort -V | tail -1)
  [ -n "$PKG" ] || { echo "could not resolve apk-tools-static package"; exit 1; }
  curl -fSL --retry 5 --retry-all-errors --connect-timeout 20 \
    -o "$WORK/apk-tools-static.apk" \
    "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main/x86_64/$PKG"
  tar xzf "$WORK/apk-tools-static.apk" -C "$WORK" sbin/apk.static
  APK_STATIC="$WORK/sbin/apk.static"
fi
chmod +x "$APK_STATIC"
export APK="$APK_STATIC"

# --- 3. provision fbterm source (for CJK on the VGA console) -------------
# Alpine ships no fbterm package; setup.sh compiles it natively in the chroot.
# We fetch the upstream 1.7 release tarball here (not committed; gitignored) so
# the chroot step can find it at /mnt/vendor/fbterm-src.tar.gz.
if [ "$HEADLESS_SSH" != "true" ] && [ "$CJK_TTY" != "false" ]; then
  echo "==> [3/6] provision fbterm source"
  VENDOR_FBTERM="$SCRIPT_DIR/vendor/fbterm-src.tar.gz"
  if [ -s "$VENDOR_FBTERM" ]; then
    echo "  using cached $VENDOR_FBTERM"
  else
    curl -fSL --retry 5 --retry-all-errors --connect-timeout 30 \
      -o "$VENDOR_FBTERM" \
      https://deb.debian.org/debian/pool/main/f/fbterm/fbterm_1.7.orig.tar.gz
  fi
else
  echo "==> [3/6] headless SSH mode: skip fbterm source"
fi

# --- 4. create raw image + MBR partition table ----------------------------
echo "==> [4/6] create ${IMG} (${IMAGE_SIZE_GB}G), MBR partition, attach loop"
truncate -s "$(awk "BEGIN{printf \"%dM\", ${IMAGE_SIZE_GB}*1024}")" "$IMG"
LOOP_DEV=""
for try in 1 2 3; do
  LOOP_DEV=$(losetup --find --show "$IMG" 2>/dev/null) && break
  /usr/bin/sleep 1
done
[ -n "$LOOP_DEV" ] || { echo "losetup failed"; exit 1; }
# one bootable Linux partition filling the disk (starts at 1MiB for alignment).
# Loop backends reject the BLKRRPART ioctl with EINVAL, which sfdisk reports as
# "Re-reading the partition table failed". --no-reread skips the in-use check
# ioctl and --no-tell-kernel skips notifying the kernel after the write; the
# partition node is instead created below via partx, with a --partscan
# re-attach as the fallback.
sfdisk --no-reread --no-tell-kernel "$LOOP_DEV" >/dev/null <<EOF || { echo "sfdisk partition table write failed"; exit 1; }
label: dos
2048,,L,*
EOF
partx -a "$LOOP_DEV" 2>/dev/null || true
PART_DEV="${LOOP_DEV}p1"
# Fallback: if the loop backend did not expose p1 after partx, detach and
# re-attach with --partscan so the kernel scans the table at bind time.
if [ ! -b "$PART_DEV" ]; then
  partx -d "$LOOP_DEV" 2>/dev/null || true
  losetup -d "$LOOP_DEV" 2>/dev/null || true
  /usr/bin/sleep 1
  LOOP_DEV=$(losetup --find --show --partscan "$IMG") || { echo "partscan re-attach failed"; exit 1; }
  PART_DEV="${LOOP_DEV}p1"
fi
[ -b "$PART_DEV" ] || { echo "partition $PART_DEV not found"; exit 1; }
cleanup_loop() { partx -d "$LOOP_DEV" 2>/dev/null || true; losetup -d "$LOOP_DEV" 2>/dev/null || true; }
trap cleanup_loop EXIT

# --- 5. build image inside the partition (official tool) ------------------
echo "==> [5/6] build on $PART_DEV (kernel=${KERNEL_FLAVOR}, branch=${ALPINE_BRANCH})"
# NOTE: --script-chroot is a boolean flag; the setup script is a positional
# arg: alpine-make-vm-image [options] <image> [<script>]
APP_URL="$APP_URL" APK="$APK" HEADLESS_SSH="$HEADLESS_SSH" CJK_TTY="$CJK_TTY" \
  "$TOOL" \
  --branch "$ALPINE_BRANCH" \
  --mirror-uri "$ALPINE_MIRROR" \
  --kernel-flavor "$KERNEL_FLAVOR" \
  --rootfs ext4 \
  --packages "$PACKAGES" \
  --script-chroot \
  "$PART_DEV" \
  "$SCRIPT_DIR/setup.sh"

# --- 6. install syslinux MBR boot code ------------------------------------
# The official tool installs extlinux into the partition boot record; for an
# MBR-partitioned disk we also need the standard MBR bootstrap in sector 0.
echo "==> [6/6] install syslinux MBR boot code"
MBR_TMP="$(mktemp /tmp/mbr.XXXXXX.bin)"
MNT_DIR="$(mktemp -d /tmp/mbr-mnt.XXXXXX)"
if ! mount "$PART_DEV" "$MNT_DIR"; then
  echo "failed to mount ext4 partition for final syslinux cleanup"
  exit 1
fi
# Copy the 440-byte BIOS MBR bootstrap first; afterward the large build-time
# syslinux directory (EFI/PXE/DOS/Windows tools and unused c32 modules) is not
# part of runtime boot. extlinux has already copied the runtime modules to /boot.
cp "$MNT_DIR/usr/share/syslinux/mbr.bin" "$MBR_TMP"
[ -s "$MBR_TMP" ] || { echo "syslinux mbr.bin not found in image - boot will fail"; umount "$MNT_DIR"; exit 1; }
for runtime_module in ldlinux.c32 menu.c32 libcom32.c32 libutil.c32; do
  [ -s "$MNT_DIR/boot/$runtime_module" ] \
    || { echo "required runtime syslinux module missing: boot/$runtime_module"; umount "$MNT_DIR"; exit 1; }
done
rm -f "$MNT_DIR"/boot/System.map-* "$MNT_DIR"/boot/config-*
rm -rf "$MNT_DIR/usr/share/syslinux"
sync
umount "$MNT_DIR"
rmdir "$MNT_DIR" 2>/dev/null || true
dd if="$MBR_TMP" of="$LOOP_DEV" bs=440 count=1 conv=notrunc status=none
rm -f "$MBR_TMP"

# Official ext4 layout from alpine-make-vm-image already disables the 64bit
# feature (required by syslinux) and uses nodiscard at mkfs time. This appliance
# runs on always-on VPS hosts, so keep the mature ext4 driver/metadata but remove
# the 16MiB journal with the standard e2fsprogs toggle. Disable reserved blocks
# and periodic fsck counters, compact directory indexes, then zero free blocks
# for maximum zstd compression.
tune2fs -m 0 -c 0 -i 0 "$PART_DEV" >/dev/null 2>&1 || true
e2fsck -fyD "$PART_DEV" >/dev/null 2>&1 || { rc=$?; [ "$rc" -eq 1 ] || { echo "e2fsck failed with code $rc"; exit 1; }; }
tune2fs -O ^has_journal "$PART_DEV" >/dev/null || { echo "failed to disable ext4 journal"; exit 1; }
e2fsck -fyD "$PART_DEV" >/dev/null 2>&1 || { rc=$?; [ "$rc" -eq 1 ] || { echo "e2fsck failed with code $rc"; exit 1; }; }
zerofree "$PART_DEV" >/dev/null 2>&1 || true

file "$IMG"

# copy RAW image + checksum to dist/; the workflow then zstd-compresses and
# publishes it as the release asset.
OUT_DIR="$(dirname "$SCRIPT_DIR")/dist"
mkdir -p "$OUT_DIR"
RAW_OUT="$OUT_DIR/vps-app-runner.img.raw"
cp "$IMG" "$RAW_OUT"
sha256sum "$RAW_OUT" | tee "$RAW_OUT.sha256"
chmod 644 "$RAW_OUT"* 2>/dev/null || true
echo "RESULT_FILE=$RAW_OUT"
