# shellcheck shell=sh
# Raw disk helpers: create the image, attach a loop device and write the
# legacy-BIOS (MBR) partition table used by every image we ship.
#
# Functions communicate through the globals LOOP_DEV and PART_DEV.

# create_image <path> <size_gb>
create_image() {
	truncate -s "$(($2 * 1024))M" "$1"
}

# attach_loop <image> - sets LOOP_DEV.
attach_loop() {
	LOOP_DEV=""
	for _try in 1 2 3; do
		if LOOP_DEV=$(losetup --find --show "$1" 2>/dev/null); then
			return 0
		fi
		sleep 1
	done
	die "losetup failed for $1"
}

# detach_loop - best effort, safe to call twice.
detach_loop() {
	if [ -n "${LOOP_DEV:-}" ]; then
		partx -d "$LOOP_DEV" 2>/dev/null || true
		losetup -d "$LOOP_DEV" 2>/dev/null || true
	fi
}

# write_partition_table - one bootable Linux partition starting at 1MiB.
#
# Loop backends reject the BLKRRPART ioctl with EINVAL ("Re-reading the
# partition table failed"), so --no-reread/--no-tell-kernel skip the in-use
# check; the partition node is created by partx instead. If that does not
# materialise p1, re-attach with --partscan so the kernel scans at bind time.
write_partition_table() {
	sfdisk --no-reread --no-tell-kernel "$LOOP_DEV" >/dev/null <<-'EOF' || die "sfdisk partition table write failed"
		label: dos
		2048,,L,*
	EOF
	partx -a "$LOOP_DEV" 2>/dev/null || true
	PART_DEV="${LOOP_DEV}p1"
	if [ ! -b "$PART_DEV" ]; then
		partx -d "$LOOP_DEV" 2>/dev/null || true
		losetup -d "$LOOP_DEV" 2>/dev/null || true
		sleep 1
		LOOP_DEV=$(losetup --find --show --partscan "$1") || die "partscan re-attach failed"
		PART_DEV="${LOOP_DEV}p1"
	fi
	[ -b "$PART_DEV" ] || die "partition $PART_DEV not found"
}
