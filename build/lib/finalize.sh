# shellcheck shell=sh
# Boot-sector installation, filesystem tuning and artifact export.
# These run on the finished image, after alpine-make-vm-image has built the
# root filesystem inside PART_DEV.

# install_mbr <loop_dev> <part_dev>
#
# The official tool writes extlinux into the partition boot record; an MBR
# disk additionally needs the 440-byte BIOS bootstrap in sector 0. The large
# build-time syslinux directory is dropped at the same time - extlinux has
# already copied the runtime modules to /boot.
install_mbr() {
	_mbr=$(mktemp /tmp/mbr.XXXXXX.bin)
	_mnt=$(mktemp -d /tmp/mbr-mnt.XXXXXX)
	mount "$2" "$_mnt" || die "cannot mount partition for MBR install"

	# Collect the first problem instead of dying inside the mount: the temporary
	# mount has to be released before the build can report anything useful.
	_err=""
	if ! cp "$_mnt/usr/share/syslinux/mbr.bin" "$_mbr" 2>/dev/null || [ ! -s "$_mbr" ]; then
		_err="syslinux mbr.bin not found in image - boot will fail"
	fi
	if [ -z "$_err" ]; then
		for _module in ldlinux.c32 menu.c32 libcom32.c32 libutil.c32; do
			if [ ! -s "$_mnt/boot/$_module" ]; then
				_err="required runtime syslinux module missing: boot/$_module"
				break
			fi
		done
	fi

	# Only touch the image once it is known to be bootable.
	if [ -z "$_err" ]; then
		rm -f "$_mnt"/boot/System.map-* "$_mnt"/boot/config-*
		rm -rf "$_mnt/usr/share/syslinux"
	fi

	sync
	if ! umount "$_mnt"; then
		rm -f "$_mbr"
		rmdir "$_mnt" 2>/dev/null || true
		die "cannot unmount $2${_err:+ (also: $_err)}"
	fi
	rmdir "$_mnt" 2>/dev/null || true

	if [ -n "$_err" ]; then
		rm -f "$_mbr"
		die "$_err"
	fi

	dd if="$_mbr" of="$1" bs=440 count=1 conv=notrunc status=none ||
		die "failed to write MBR bootstrap"
	rm -f "$_mbr"
}

# tune_ext4 <part_dev>
#
# alpine-make-vm-image already disables the 64bit feature (syslinux needs that)
# and uses nodiscard. This appliance runs on always-on VPS hosts, so keep the
# mature ext4 driver, drop the reserved blocks and the periodic fsck counters,
# compact the directory indexes and zero free blocks so zstd compresses better.
#
# The journal stays in. Dropping it saved 16MiB but made every reset or power
# loss a corruption event: without a journal the runtime writes (app download,
# logs, wtmp) leave half-committed metadata, and the next boot's preen fsck
# cannot decide on it - verified by resetting the VM mid download, which left
# /var/log/wtmp pointing at an invalid inode and stopped the machine before
# networking came up, with the app never starting. A smaller 4MiB journal
# carries this write volume comfortably and compresses away with the free
# blocks, so crash safety costs almost nothing in the artifact.
tune_ext4() {
	tune2fs -m 0 -c 0 -i 0 "$1" >/dev/null 2>&1 || true

	# Compact directory indexes first, then put the journal back if the base
	# image dropped it (alpine-make-vm-image's default rootfs is journal-less).
	_rc=0
	e2fsck -fyD "$1" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -le 1 ] || die "e2fsck failed with code $_rc"

	tune2fs -l "$1" | grep -q 'has_journal' ||
		tune2fs -j -J size=4 "$1" >/dev/null || die "failed to enable ext4 journal"

	_rc=0
	e2fsck -fyD "$1" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -le 1 ] || die "e2fsck failed with code $_rc"

	zerofree "$1" >/dev/null 2>&1 || true

	# zerofree is the last offline step before export. Repair once more so any
	# inode/block bitmap or directory-index inconsistency left by the offline
	# tuning is cleared, then gate on a read-only check: a dirty filesystem
	# must never ship (a stray allocated-but-freed inode is later reused at
	# boot, surfacing as an fsck abort and a read-only root).
	_rc=0
	e2fsck -fyD "$1" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -le 1 ] || die "e2fsck failed with code $_rc"

	_rc=0
	e2fsck -fn "$1" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -eq 0 ] || die "shipped filesystem still inconsistent (e2fsck -fn code $_rc)"
}

# export_image <raw> <dist_dir> - copy the raw image plus its checksum.
#
# The ".img.raw" name is what build.yml compresses and what the release asset
# is cut from, so it is part of the contract rather than a cosmetic choice.
export_image() {
	mkdir -p "$2"
	_out="$2/vps-app-runner.img.raw"
	cp "$1" "$_out" || die "failed to copy image to $_out"
	(cd "$2" && sha256sum vps-app-runner.img.raw) | tee "$_out.sha256"
	chmod 644 "$_out" "$_out.sha256" 2>/dev/null || true
	printf 'RESULT_FILE=%s\n' "$_out"
}
