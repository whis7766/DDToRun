#!/bin/sh
# Build a dd-ready Alpine Linux VPS image with the official
# alpine-make-vm-image tool.
#
# Layout: legacy BIOS / MBR (one bootable ext4 partition, extlinux, syslinux
# mbr.bin in sector 0) - the most compatible layout for VPS reinstall scripts.
# On first boot the root filesystem grows to the whole disk, the clock is synced
# and app-runner downloads and runs the business binary.
#
# Two profiles, selected by HEADLESS_SSH:
#   false (default)  VGA kiosk - fbterm + CJK font render the app full-screen on
#                    tty1. There is deliberately no text-console fallback.
#   true             headless  - sshd on port 22 (key-only), app supervised in
#                    the background; accessed over SSH.
#
# Both profiles ship no serial console: the appliance is reached over VGA
# kiosk (vpsvga) or SSH (vpsssh). A ttyS0 getty/console is a debug-only aid
# and is intentionally not baked into production images.
#
# Environment (all optional):
#   APP_URL        business binary URL compiled into app-runner
#   IMAGE_SIZE_GB  image size in GB (default 1)
#   ALPINE_MIRROR  apk mirror (default https://dl-cdn.alpinelinux.org/alpine)
#   ALPINE_BRANCH  Alpine branch (default v3.22)
#   KERNEL_FLAVOR  kernel flavor (default virt)
#   HEADLESS_SSH   true|false (default false)
#   PACKAGES       extra apk packages, appended to the profile set
#   CGO_COMPAT     true installs the glibc compat layer
#   KEEP_WORK      true keeps the temporary build directory
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/disk.sh"
. "$SCRIPT_DIR/lib/finalize.sh"
. "$SCRIPT_DIR/lib/provision.sh"

# --- inputs --------------------------------------------------------------
APP_URL=${APP_URL:-}
IMAGE_SIZE_GB=${IMAGE_SIZE_GB:-1}
ALPINE_MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.22}

# apk repositories are keyed by release branch (v3.22, v3.24), not by point
# release (v3.24.4). Passing a point release used to fail deep inside the build
# with "cannot list apk-tools packages"; normalise it here and fail early with
# a message that says what to use instead.
case "$ALPINE_BRANCH" in
v[0-9]*.[0-9]*.[0-9]*) ALPINE_BRANCH=${ALPINE_BRANCH%.*} ;;
esac
case "$ALPINE_BRANCH" in
v[0-9].*) ;;
*) die "ALPINE_BRANCH must look like v3.22 (got '$ALPINE_BRANCH')" ;;
esac
KERNEL_FLAVOR=${KERNEL_FLAVOR:-virt}
HEADLESS_SSH=${HEADLESS_SSH:-false}
EXTRA_PACKAGES=${PACKAGES:-}

case "$HEADLESS_SSH" in
true | false) ;;
*) die "HEADLESS_SSH must be 'true' or 'false'" ;;
esac

# No dhcpcd: IPv6 is disabled, so its only advantage over busybox udhcpc
# (DHCPv6 in one process) is unused. ifupdown-ng's dhcp executor falls back to
# udhcpc when dhcpcd is absent, and busybox ships the udhcpc helper script.
BASE_PACKAGES="cloud-utils-growpart ca-certificates e2fsprogs-extra ifupdown-ng"
if [ "$HEADLESS_SSH" = "true" ]; then
	BASE_PACKAGES="$BASE_PACKAGES openssh"
else
	BASE_PACKAGES="$BASE_PACKAGES font-wqy-zenhei fontconfig freetype ncurses"
fi
if [ "${CGO_COMPAT:-false}" = "true" ]; then
	BASE_PACKAGES="$BASE_PACKAGES gcompat libc6-compat"
fi
PACKAGES="$BASE_PACKAGES $EXTRA_PACKAGES"

# --- workspace -----------------------------------------------------------
require_cmds losetup rsync sfdisk mkfs.ext4 curl tar zerofree tune2fs

WORK=$(mktemp -d /tmp/alpine-build.XXXXXX)
IMG="$WORK/vps-app-runner.raw"
TOOL="$WORK/alpine-make-vm-image"
LOOP_DEV=""
PART_DEV=""

cleanup() {
	detach_loop
	[ "${KEEP_WORK:-false}" = "true" ] || rm -rf "$WORK"
}
# Signals only raise the exit status; cleanup itself is owned by the EXIT trap so
# a loop device can never be left behind by a double invocation.
trap cleanup EXIT
trap 'exit 130' INT TERM

log "profile: HEADLESS_SSH=$HEADLESS_SSH branch=$ALPINE_BRANCH kernel=$KERNEL_FLAVOR"

# --- 1. external pieces --------------------------------------------------
fetch_build_tool "$TOOL"
log "provision apk.static"
provision_apk "$SCRIPT_DIR/vendor" "$WORK" "$ALPINE_BRANCH" "$ALPINE_MIRROR"
if [ "$HEADLESS_SSH" != "true" ]; then
	provision_fbterm_source "$SCRIPT_DIR/vendor"
fi

# --- 2. disk + partition table -------------------------------------------
log "create $IMG (${IMAGE_SIZE_GB}G)"
create_image "$IMG" "$IMAGE_SIZE_GB"
attach_loop "$IMG"
write_partition_table "$IMG"
log "partition ready on $PART_DEV"

# --- 3. build the image in the partition ---------------------------------
log "build root filesystem on $PART_DEV"
HEADLESS_SSH="$HEADLESS_SSH" APP_URL="$APP_URL" \
	"$TOOL" \
	--branch "$ALPINE_BRANCH" \
	--mirror-uri "$ALPINE_MIRROR" \
	--kernel-flavor "$KERNEL_FLAVOR" \
	--rootfs ext4 \
	--packages "$PACKAGES" \
	--script-chroot \
	"$PART_DEV" \
	"$SCRIPT_DIR/setup.sh"

# --- 4. boot sector + filesystem + artifact ------------------------------
log "install syslinux MBR bootstrap"
install_mbr "$LOOP_DEV" "$PART_DEV"

log "tune ext4"
tune_ext4 "$PART_DEV"

# Drop the journal before exporting; the image must be detached first so the
# final fs state reaches the file.
detach_loop
LOOP_DEV=""
file "$IMG"

log "export artifact"
export_image "$IMG" "$(dirname "$SCRIPT_DIR")/dist"
