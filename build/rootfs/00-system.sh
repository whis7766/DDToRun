# shellcheck shell=sh
# System baseline: hostname, sysctl, unused services, inittab.

setup-hostname vps-app

# Directories every later stage installs into. /usr/local/sbin is not part of
# the base rootfs, and the kiosk stage runs before the app stage.
install -d -m 0755 /opt /usr/local/sbin /var/log

# The VPS has no IPv6 route; disabling IPv6 avoids resolver timeouts.
cat >/etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
# Tolerate keys the running kernel does not expose.
echo 'SYSCTL_OPTS="-e"' >/etc/conf.d/sysctl

# Single-appliance: drop services this image never uses. mdev, devfs/sysfs,
# seedrng, hostname, bootmisc, modules, networking and sysctl stay enabled.
for _service in crond:default syslog:boot swap:boot hwclock:boot cgroups:sysinit \
	hwdrivers:sysinit dmesg:sysinit; do
	_name=${_service%%:*}
	_level=${_service##*:}
	rc-update del "$_name" "$_level" >/dev/null 2>&1 || true
done

# Serial console on ttyS0 (115200 8N1). The platform bridges the VM serial0
# socket to a tenant-owned unix socket, so this is the interactive debug path
# in both profiles and is independent of the VGA/kiosk path.
sed -i '/^#\?ttyS0::respawn:/d' /etc/inittab
printf '%s\n' 'ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100' >>/etc/inittab

# The official tool's --serial-console wrote console=ttyS0; pin the baud rate
# to 115200 and regenerate extlinux from its source of truth.
sed -i 's|console=ttyS0|console=ttyS0,115200|' /etc/update-extlinux.conf
update-extlinux --warn-only >/dev/null 2>&1 || true

if [ "$PROFILE" = "headless" ]; then
	# Headless: no VGA login at all, access is over SSH.
	sed -i 's|^tty[1-6]::respawn:.*|#&|' /etc/inittab
else
	# Kiosk: only tty1 remains, and 50-kiosk.sh repoints it at the app.
	sed -i 's|^tty[2-6]::respawn:.*|#&|' /etc/inittab
fi
