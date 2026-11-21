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
	_starts=$(awk '/app-runner starting/{n++} END{print n+0}' /var/log/app-runner.log 2>/dev/null)
	say "SELFTEST app-runner-starts=${_starts:-0}"
	[ "${_starts:-0}" -ge 1 ] || fail=1
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

# Root filesystem must have been grown past the packed image size. A 1 GiB
# disk reports ~990 MiB usable in df (metadata + reserved blocks), so the floor
# is 900: an ungrown packed rootfs is far smaller, a grown 1G image clears it.
_rootmb=$(df -m / 2>/dev/null | awk 'NR==2{print $2}')
say "SELFTEST rootfs-mb=${_rootmb:-0}"
[ "${_rootmb:-0}" -gt 900 ] || fail=1

# Informational: a bare vmbr0 has no DHCP server, so "none" here is expected
# and must not fail the run.
_ipv4=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}')
say "SELFTEST ipv4=${_ipv4:-none}"

# --- phase 2: the business binary ---------------------------------------
# The download starts after networking is up, so phase 1 always runs before
# there is anything to report. Poll for the runner's verdict instead, printing
# a heartbeat so the serial reader never looks idle and hangs up.
_appwait=${SELFTEST_APP_WAIT:-180}
_elapsed=0
_seen_running=0
while [ "$_elapsed" -lt "$_appwait" ]; do
	# "exec failed" is the decisive line; "running" is logged *before* the exec
	# attempt, so on its own it proves nothing. Once "running" shows up, keep
	# polling a few more seconds so a following "exec failed" is not missed.
	if grep -q 'exec failed' /var/log/app-runner.log 2>/dev/null; then
		break
	fi
	if grep -q 'running /opt/business-app' /var/log/app-runner.log 2>/dev/null; then
		_seen_running=$((_seen_running + 5))
		[ "$_seen_running" -ge 10 ] && break
	fi
	sleep 5
	_elapsed=$((_elapsed + 5))
	say "SELFTEST wait=${_elapsed}s"
done
# Let the runner finish writing its verdict before reading it.
sleep 3

_appbytes=$(stat -c %s /opt/business-app 2>/dev/null || echo 0)
say "SELFTEST app-bytes=${_appbytes:-0}"

_execerr=$(grep -m1 'exec failed:' /var/log/app-runner.log 2>/dev/null)
if [ -n "$_execerr" ]; then
	case "$_execerr" in
	*"no such file or directory"*) say "SELFTEST app-exec=no-loader" ;;
	*"exec format error"*) say "SELFTEST app-exec=arch" ;;
	*) say "SELFTEST app-exec=failed" ;;
	esac
	# The exact message is worth keeping: it is what a user would see.
	say "SELFTEST app-error=$(printf '%s' "$_execerr" | tr -d '\r' | cut -c1-120)"
else
	if grep -q 'running /opt/business-app' /var/log/app-runner.log 2>/dev/null; then
		say "SELFTEST app-exec=ok"
		# pidof matches comm, which the gcompat loader can rename; scan argv[0]
		# in /proc instead so a genuinely running business app is not misreported.
		_alive=0
		for _p in /proc/[0-9]*; do
			case "$(tr '\0' ' ' <"$_p/cmdline" 2>/dev/null)" in
			/opt/business-app*) _alive=1; break ;;
			esac
		done
		if [ "$_alive" = 1 ]; then
			say "SELFTEST app=alive"
		else
			say "SELFTEST app=exited"
		fi
	else
		_last=$(grep -m1 'download failed\|no app available' /var/log/app-runner.log 2>/dev/null)
		say "SELFTEST app-exec=timeout"
		say "SELFTEST app-error=$(printf '%s' "$_last" | cut -c1-120)"
	fi
fi
_dl=$(awk '/downloaded new version/{n++} END{print n+0}' /var/log/app-runner.log 2>/dev/null)
say "SELFTEST app-downloads=${_dl:-0}"
say "SELFTEST arch=$(uname -m 2>/dev/null)"

# --- phase 3: network performance --------------------------------------
# The appliance lives or dies by its egress (it downloads the business binary
# and then serves traffic). Measure the three things a user would feel:
# gateway latency, resolver latency, and bulk download throughput. All over
# the guest's own NAT path, using a China mirror so the number reflects real
# VPS usage rather than a cross-ocean link.
_gw=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
if [ -n "$_gw" ]; then
	_rtt=$(ping -c 4 -W 2 "$_gw" 2>/dev/null | awk -F'/' '/round-trip|rtt/{print $5}' | awk '{print $1}')
	say "SELFTEST net-gw-rtt-ms=${_rtt:-fail}"
else
	say "SELFTEST net-gw-rtt-ms=no-route"
fi

_dns0=$(date +%s%N 2>/dev/null)
nslookup mirrors.aliyun.com >/dev/null 2>&1
_dns1=$(date +%s%N 2>/dev/null)
case "$_dns0$_dns1" in
*[!0-9]* | "") say "SELFTEST net-dns-ms=unsupported" ;;
*) say "SELFTEST net-dns-ms=$(( (_dns1 - _dns0) / 1000000 ))" ;;
esac

_url="https://mirrors.aliyun.com/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.8-x86_64.tar.gz"
# busybox date has no reliable sub-second field, so accumulate whole seconds of
# transfer instead of timing one small file: repeat the probe until >=2s have
# passed (capped so a slow link cannot run away), then divide bytes by seconds.
_t0=$(date +%s 2>/dev/null)
_total=0
_n=0
_sz=0
while [ "$_n" -lt 40 ]; do
	wget -q -O /tmp/netprobe.bin "$_url" 2>/dev/null
	_sz=$(stat -c %s /tmp/netprobe.bin 2>/dev/null || echo 0)
	_total=$((_total + _sz))
	_n=$((_n + 1))
	_now=$(date +%s 2>/dev/null)
	[ $((_now - _t0)) -ge 2 ] && break
done
_t1=$(date +%s 2>/dev/null)
rm -f /tmp/netprobe.bin
_dur=$((_t1 - _t0))
[ "$_dur" -lt 1 ] && _dur=1
if [ "$_total" -gt 0 ]; then
	say "SELFTEST net-down-mbps=$(awk -v b="$_total" -v d="$_dur" \
		'BEGIN{printf "%.1f", (b/1048576)/d}')"
else
	say "SELFTEST net-down-mbps=fail"
fi
say "SELFTEST net-probe-bytes=${_total:-0}"

# Ground truth for anything the summary above cannot explain: the runner's own
# last lines, verbatim, on the serial transcript.
tail -n 12 /var/log/app-runner.log 2>/dev/null | while IFS= read -r _line; do
	say "SELFTEST log|$(printf '%s' "$_line" | tr -d '\r' | cut -c1-140)"
done

if [ "$fail" = "0" ]; then
	say "SELFTEST-RESULT pass"
else
	say "SELFTEST-RESULT fail"
fi
say "SELFTEST-END"
