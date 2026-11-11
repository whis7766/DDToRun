# shellcheck shell=sh
# System baseline: hostname, sysctl, unused services, inittab.

setup-hostname vps-app

# Directories every later stage installs into. /usr/local/sbin is not part of
# the base rootfs, and the kiosk stage runs before the app stage.
install -d -m 0755 /opt /usr/local/sbin /var/log

# Root account password. The base rootfs ships an empty password field, which
# must not reach a production image. A locked field ("!" / "*") is not the fix
# either: sshd refuses public-key logins for a locked account, so the headless
# profile would lose its only entry path. Instead give root an unguessable
# random hash and discard the plaintext - password authentication stays off in
# sshd_config, and key login keeps working.
_pw=$(head -c 24 /dev/urandom | base64 2>/dev/null || echo "$$-$(date +%s%N)")
_hash=$(mkpasswd -m sha512 "$_pw" 2>/dev/null || true)
[ -n "$_hash" ] || die "mkpasswd could not hash the root password"
awk -v h="$_hash" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' /etc/shadow >/etc/shadow.new &&
	mv /etc/shadow.new /etc/shadow && chmod 600 /etc/shadow ||
	die "could not set the root password hash"
unset _pw _hash

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

# Serial console is deliberately absent: production images are reached over
# VGA kiosk or SSH, not ttyS0. No ttyS0 getty is added and the kernel keeps its
# default console (tty0).

if [ "$PROFILE" = "headless" ]; then
	# Headless: no VGA login at all, access is over SSH.
	sed -i 's|^tty[1-6]::respawn:.*|#&|' /etc/inittab
else
	# Kiosk: only tty1 remains, and 50-kiosk.sh repoints it at the app.
	sed -i 's|^tty[2-6]::respawn:.*|#&|' /etc/inittab
fi
