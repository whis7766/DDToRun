#!/bin/sh
# Boot contract reporter for debug images.
#
# A tenant running this image under PVE has no host shell, no guest agent
# (VM.Config.Options is not granted) and - in the headless profile - no
# password login. The serial line is the only channel left, so the contract
# this image promises is asserted here, once, at boot, and printed as
# "SELFTEST <key>=<value>" lines that the e2e parses. Production images do not
# carry this script (see rootfs/80-selftest.sh).
CONSOLE=/dev/ttyS0
[ -w "$CONSOLE" ] || CONSOLE=/dev/console

# Baked in at build time: the profile name is not in the runtime environment.
PROFILE=$(cat /etc/selftest-profile 2>/dev/null || echo unknown)

say() {
	printf '%s\n' "$*" >>"$CONSOLE" 2>/dev/null || true
}

svc_state() {
	rc-service "$1" status 2>/dev/null | tr -d '\n' || true
}

fail=0
say "SELFTEST-BEGIN"
say "SELFTEST profile=$PROFILE"

if [ "$PROFILE" = "headless" ]; then
	for _svc in sshd app-runner; do
		case "$(svc_state "$_svc")" in
		*started*) say "SELFTEST $_svc=started" ;;
		*)
			say "SELFTEST $_svc=down"
			fail=1
			;;
		esac
	done
	# The supervisor must log its start exactly once; a duplicated line means it
	# was respawned by an openrc restart storm.
	_dups=$(grep -c 'app-runner starting' /var/log/app-runner.log 2>/dev/null || echo 0)
	say "SELFTEST app-runner-starts=$_dups"
	[ "$_dups" = "1" ] || fail=1
else
	# Kiosk: app-runner is exec'd by the tty1 fb environment, not a service.
	if pidof app-runner >/dev/null 2>&1; then
		say "SELFTEST app-runner=running"
	else
		say "SELFTEST app-runner=down"
		fail=1
	fi
fi

# Password state: "set" is correct for both profiles (headless needs a usable
# account for key logins, and an empty or locked hash is a regression).
case "$(awk -F: '$1=="root"{print $2}' /etc/shadow)" in
"" | "!"* | "*"*) say "SELFTEST rootpw=unusable" ; fail=1 ;;
*) say "SELFTEST rootpw=set" ;;
esac

# Root filesystem must have been grown past the packed image size. 1 GiB is the
# floor: a 1G image that never ran grow-root reports ~900 MiB.
_rootmb=$(df -m / 2>/dev/null | awk 'NR==2{print $2}')
say "SELFTEST rootfs-mb=${_rootmb:-0}"
[ "${_rootmb:-0}" -gt 1024 ] || fail=1

# Informational: a bare vmbr0 has no DHCP server, so "none" here is expected
# and must not fail the run.
_ipv4=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}')
say "SELFTEST ipv4=${_ipv4:-none}"

if [ "$fail" = "0" ]; then
	say "SELFTEST-RESULT pass"
else
	say "SELFTEST-RESULT fail"
fi
say "SELFTEST-END"
