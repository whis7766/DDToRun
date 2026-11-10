# shellcheck shell=sh
# System baseline: hostname, sysctl, unused services, inittab.

setup-hostname vps-app

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

# No serial console on this appliance.
sed -i '/^#\?ttyS0::respawn:/d' /etc/inittab

if [ "$PROFILE" = "headless" ]; then
	# Headless: no VGA login at all, access is over SSH.
	sed -i 's|^tty[1-6]::respawn:.*|#&|' /etc/inittab
else
	# Kiosk: only tty1 remains, and 50-kiosk.sh repoints it at the app.
	sed -i 's|^tty[2-6]::respawn:.*|#&|' /etc/inittab
fi
