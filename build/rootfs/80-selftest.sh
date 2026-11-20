# shellcheck shell=sh
# Debug builds: install the boot contract reporter that prints to the serial
# console, so an unprivileged PVE tenant can assert what is happening inside a
# guest it cannot log into.
#
# Production images must never carry this: the serial getty and the known root
# password that make it usable are debug-only knobs (DEBUG_SERIAL).

if [ "$DEBUG_SERIAL" != "true" ]; then
	return 0
fi

install -m 0755 /mnt/files/selftest.sh /usr/local/sbin/boot-selftest
install -m 0755 /mnt/files/selftest.openrc /etc/init.d/selftest
rc-update add selftest default >/dev/null

# PROFILE only exists while the build runs; the reporter needs it at boot to
# know which contract to check, so bake it into the image.
printf '%s\n' "$PROFILE" >/etc/selftest-profile
