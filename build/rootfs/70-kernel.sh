# shellcheck shell=sh
# Kernel modules, network tuning, module-tree trimming and initramfs rebuild.

# --- boot modules -----------------------------------------------------
# Declared explicitly instead of relying on a hand-maintained allowlist; a
# missing module shows up at build/boot time rather than silently vanishing.
cat >/etc/modules <<'EOF'
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

if [ "$PROFILE" = "kiosk" ]; then
	# Generic PCI DRM drivers only. Platform-specific ones (hyperv_drm,
	# drm_xen_front, vmwgfx, vboxvideo) are loaded by app-runner-fb after its
	# bus/DMI check, because hyperv_drm without vmbus wedges the driver.
	for _mod in bochs cirrus virtio-gpu simpledrm qxl; do
		grep -qx "$_mod" /etc/modules || echo "$_mod" >>/etc/modules
	done
fi

# --- network tuning ---------------------------------------------------
cat >/etc/local.d/10-bbr.start <<'EOF'
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

# --- module tree trimming ---------------------------------------------
# Keep only the dependency closure of the capabilities this appliance needs,
# derived from the kernel's own modules.dep rather than a hand-maintained file
# list. Everything outside the closure is deleted, then the initramfs is
# rebuilt from the trimmed tree.
KVER=$(ls /lib/modules 2>/dev/null | head -1)

SEEDS="virtio virtio_ring virtio_pci virtio_mmio virtio_blk virtio_scsi sd_mod
virtio_net virtio_rng virtio_balloon e1000 e1000e tun sch_fq tcp_bbr ext4 jbd2
mbcache crc32c_intel crc32c_generic crc16 crc32_generic rng_core net_failover
failover af_packet"

if [ "$PROFILE" = "kiosk" ]; then
	# fbterm needs /dev/fb0, so keep the framebuffer + drm chain and the common
	# hypervisor display drivers; the closure keeps ttm, i2c-core, etc.
	SEEDS="$SEEDS fb fb_sys_fops sysfillrect sysimgblt syscopyarea drm
drm_kms_helper drm_shmem_helper drm_ttm_helper drm_vram_helper ttm simpledrm
bochs cirrus virtio_gpu qxl vmwgfx vboxvideo hyperv_drm drm_xen_front i2c_core
virtio_dma_buf"
fi

# module_stem <modules.dep path> - basename without directory or .ko suffix,
# with dashes normalised to underscores (module names use underscores).
module_stem() {
	_stem=${1##*/}
	_stem=${_stem%.ko.gz}
	_stem=${_stem%.ko}
	printf '%s\n' "$_stem" | tr '-' '_'
}

# prune_modules <module_root> <seeds...>
prune_modules() {
	_root=$1
	shift
	_dep="$_root/modules.dep"
	_keep="$_root/.keep"
	[ -f "$_dep" ] || return 0

	# Seed set: modules matching a requested capability.
	: >"$_keep"
	while IFS=: read -r _mod _deps; do
		[ -n "$_mod" ] || continue
		_stem=$(module_stem "$_mod")
		for _seed in "$@"; do
			if [ "$_stem" = "$_seed" ]; then
				printf '%s\n' "$_mod" >>"$_keep"
				break
			fi
		done
	done <"$_dep"

	# Dependency closure, iterated to a fixpoint.
	_changed=1
	while [ "$_changed" -eq 1 ]; do
		_changed=0
		while IFS=: read -r _mod _deps; do
			[ -n "$_mod" ] || continue
			grep -Fxq "$_mod" "$_keep" || continue
			for _dep_mod in $_deps; do
				if ! grep -Fxq "$_dep_mod" "$_keep"; then
					printf '%s\n' "$_dep_mod" >>"$_keep"
					_changed=1
				fi
			done
		done <"$_dep"
	done

	# Remove every module file outside the closure.
	find "$_root/kernel" -name '*.ko*' | while IFS= read -r _file; do
		grep -Fxq "${_file#"$_root"/}" "$_keep" || rm -f "$_file"
	done
	find "$_root/kernel" -type d -empty -delete 2>/dev/null
	rm -f "$_keep"

	echo "  kept $(find "$_root/kernel" -name '*.ko*' | wc -l) kernel modules"
}

# --- initramfs -----------------------------------------------------
# The stock "base" feature ships /sbin/apk and an init that uses
# nlplug-findfs; both pull the OpenSSL/device-mapper stack (libcrypto alone is
# ~4.9MB) into the initramfs. The custom "tiny" feature plus a busybox-only
# init keeps the same boot contract with none of that closure. kmod is excluded
# on purpose: it NEEDs libcrypto for compressed modules and signatures, while
# busybox modprobe reads modules.dep and handles .ko.gz without it.
build_initramfs() {
	command -v mkinitfs >/dev/null 2>&1 || return 0

	install -m 0755 /mnt/files/initramfs-init /etc/mkinitfs/initramfs-tiny
	cat >/etc/mkinitfs/features.d/tiny.files <<'EOF'
/bin/busybox
/bin/sh
/sbin/mdev
/lib/mdev
/etc/mdev.conf
/etc/modprobe.d/*.conf
EOF
	: >/etc/mkinitfs/features.d/tiny.modules

	_features="tiny ext4 scsi virtio"
	if [ "$PROFILE" = "kiosk" ]; then
		_features="$_features kms"
	fi
	echo "features=\"$_features\"" >/etc/mkinitfs/mkinitfs.conf

	if ! mkinitfs -i /etc/mkinitfs/initramfs-tiny -o /boot/initramfs-virt "$KVER" >/dev/null 2>&1; then
		echo "  WARN: minimal mkinitfs failed; keeping the stock initramfs"
	fi
}

if [ -n "$KVER" ] && [ -d "/lib/modules/$KVER" ]; then
	# shellcheck disable=SC2086
	prune_modules "/lib/modules/$KVER" $SEEDS
	build_initramfs
fi

apk cache clean >/dev/null 2>&1 || true

# The chroot leaves transient files in /tmp: the fbterm build tree and its log
# in the kiosk profile, plus the .ICE-unix / .X11-unix socket directories that
# fontconfig and the X11 libraries create while running here. None of it
# belongs in a shipped image - and a stale entry like /tmp/.ICE-unix is exactly
# what a boot-time fsck trips over after an unclean shutdown.
rm -rf /tmp/* /tmp/.[!.]* /tmp/..?* 2>/dev/null || true

