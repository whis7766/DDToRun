#!/bin/sh
# tty1 kiosk launcher: render app-runner full-screen on /dev/fb0 through fbterm
# with a CJK font. This is the only boot path for the VGA profile - there is no
# ASCII/text-console fallback. If no framebuffer binds, the script reports it,
# exits non-zero and inittab respawns it.

printf 'nameserver 119.29.29.29\nnameserver 223.5.5.5\n' >/etc/resolv.conf 2>/dev/null
pkill -f '^/opt/business-app' 2>/dev/null || true
stty sane 2>/dev/null || true

# Generic PCI DRM drivers stay resident harmlessly when no matching device
# exists; modprobe pulls in the drm/fb dependency closure.
for _mod in bochs cirrus virtio-gpu simpledrm qxl; do
	modprobe "$_mod" 2>/dev/null || true
done

# Platform-specific drivers are gated on their bus/DMI. hyperv_drm loaded
# without vmbus leaves a stale registration and floods dmesg with "Driver
# 'hyperv_drm' is already registered" on every later modprobe.
if [ -d /sys/bus/vmbus ]; then
	modprobe hyperv_drm 2>/dev/null || true
fi
if [ "$(cat /sys/hypervisor/type 2>/dev/null)" = "xen" ]; then
	modprobe drm_xen_front 2>/dev/null || true
fi
case "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" in
*VMware*) modprobe vmwgfx 2>/dev/null || true ;;
*innotek* | *VirtualBox* | *Oracle*) modprobe vboxvideo 2>/dev/null || true ;;
esac

# Give the kernel time to register /dev/fb0 after a driver binds.
_i=0
while [ ! -c /dev/fb0 ] && [ "$_i" -lt 30 ]; do
	modprobe fb 2>/dev/null || true
	_i=$((_i + 1))
	sleep 0.5
done

[ -c /dev/fb0 ] || {
	echo "fb0 missing: no framebuffer device bound"
	sleep 3
	exit 1
}

FBTERM=$(command -v fbterm) || {
	echo "fbterm missing"
	exit 1
}
FONT=$(find /usr/share/fonts -type f -iname 'wqy*' 2>/dev/null | head -1)
[ -n "$FONT" ] || {
	echo "CJK font missing"
	exit 1
}

printf '\033c' 2>/dev/null || true
printf '\033[2J\033[H' 2>/dev/null || true

APP_RUNNER_LOG_STDOUT_ONLY=1 exec "$FBTERM" -f "$FONT" -s 22 -- \
	sh -c 'exec /usr/local/sbin/app-runner 2>&1 | tee -a /var/log/app-runner.log'
