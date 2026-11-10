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

	_log=$(mktemp)
	_rc=0
	cp "$_mnt/usr/share/syslinux/mbr.bin" "$_mbr" 2>"$_log" || _rc=1
	if [ "$_rc" -eq 0 ] && [ ! -s "$_mbr" ]; then
		printf 'syslinux mbr.bin not found in image - boot will fail\n' >"$_log"
		_rc=1
	fi
	if [ "$_rc" -eq 0 ]; then
		for _module in ldlinux.c32 menu.c32 libcom32.c32 libutil.c32; do
			if [ ! -s "$_mnt/boot/$_module" ]; then
				printf 'required runtime syslinux module missing: boot/%s\n' "$_module" >"$_log"
				_rc=1
				break
			fi
		done
	fi
	if [ "$_rc" -eq 0 ]; then
		rm -f "$_mnt"/boot/System.map-* "$_mnt"/boot/config-*
		rm -rf "$_mnt/usr/share/syslinux"
	fi
	sync
	umount "$_mnt" || { cat "$_log"; rm -f "$_log"; rmdir "$_mnt" 2>/dev/null; die "umount failed"; }
	rmdir "$_mnt" 2>/dev/null || true
	if [ "$_rc" -ne 0 ]; then
		cat "$_log"
		rm -f "$_log" "$_mbr"
		die "MBR bootstrap install failed"
	fi
	rm -f "$_log"

	dd if="$_mbr" of="$1" bs=440 count=1 conv=notrunc status=none || die "failed to write MBR bootstrap"
	rm -f "$_mbr"
}

# tune_ext4 <part_dev>
#
# alpine-make-vm-image already disables the 64bit feature (syslinux needs that)
# and uses nodiscard. This appliance runs on always-on VPS hosts, so keep the
# mature ext4 driver but drop the journal (16MiB), the reserved blocks and the
# periodic fsck counters, compact the directory indexes and zero free blocks so
# zstd compresses better.
tune_ext4() {
	tune2fs -m 0 -c 0 -i 0 "$1" >/dev/null 2>&1 || true

	# e2fsck exits 1 when it fixed something; that is fine. Anything else is not.
	_rc=0
	e2fsck -fyD "$1" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -le 1 ] || die "e2fsck failed with code $_rc"

	tune2fs -O ^has_journal "$1" >/dev/null || die "failed to disable ext4 journal"

	_rc=0
	e2fsck -fyD "$1" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -le 1 ] || die "e2fsck failed with code $_rc"

	zerofree "$1" >/dev/null 2>&1 || true
}

# export_image <raw> <dist_dir> - copy the raw image plus its checksum.
export_image() {
	mkdir -p "$2"
	_out="$2/vps-app-runner.img.raw"
	cp "$1" "$_out" || die "failed to copy image to $_out"
	(cd "$2" && sha256sum vps-app-runner.img.raw) | tee "$_out.sha256"
	chmod 644 "$_out" "$_out.sha256" 2>/dev/null || true
	printf 'RESULT_FILE=%s\n' "$_out"
}
