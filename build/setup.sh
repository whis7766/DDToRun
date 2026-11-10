#!/bin/sh
# Chroot entry point, executed by alpine-make-vm-image --script-chroot.
# The whole build/ directory is bind-mounted at /mnt and the working directory
# is /mnt, so stages can be sourced by absolute path.
#
# Stages run in filename order. Each stage is a plain POSIX sh script with no
# shebang; setup.sh owns the shell and the error policy.
set -eu

die() {
	echo "ERROR: $*" >&2
	exit 1
}

HEADLESS_SSH=${HEADLESS_SSH:-false}

if [ "$HEADLESS_SSH" = "true" ]; then
	PROFILE=headless
else
	PROFILE=kiosk
fi
export HEADLESS_SSH PROFILE

for _stage in /mnt/rootfs/*.sh; do
	[ -f "$_stage" ] || die "no rootfs stages found under /mnt/rootfs"
	# shellcheck source=/dev/null
	. "$_stage"
done

echo "==> setup done ($PROFILE)"
