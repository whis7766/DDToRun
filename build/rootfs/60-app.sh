# shellcheck shell=sh
# Install the static app-runner binary and, in headless mode, its service.
# The kiosk profile starts app-runner from tty1 instead (see app-runner-fb.sh).

[ -f /mnt/vendor/app-runner ] || die "/mnt/vendor/app-runner missing (host build step failed)"
install -m 0755 /mnt/vendor/app-runner /usr/local/sbin/app-runner

# A static build must not depend on any shared library; catch an accidental
# dynamic link here rather than at boot.
_missing=$(ldd /usr/local/sbin/app-runner 2>&1 | grep -iE 'not found|no such|error loading' || true)
if [ -n "$_missing" ]; then
	echo "app-runner has missing libraries:"
	echo "$_missing"
	die "app-runner linkage check failed"
fi
echo "app-runner (static) installed"

[ "$PROFILE" = "headless" ] || return 0

install -m 0755 /mnt/files/app-runner.openrc /etc/init.d/app-runner
install -m 0644 /mnt/files/app-runner.conf /etc/conf.d/app-runner
rc-update add app-runner default
