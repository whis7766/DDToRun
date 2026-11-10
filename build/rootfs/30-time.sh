# shellcheck shell=sh
# Correct the virtual clock once at boot, before the app starts.

install -m 0755 /mnt/files/time-sync.openrc /etc/init.d/time-sync
rc-update add time-sync boot
