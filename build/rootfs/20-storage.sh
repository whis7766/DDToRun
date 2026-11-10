# shellcheck shell=sh
# Grow the root partition and filesystem to the whole disk on boot.

install -m 0755 /mnt/files/grow-root.openrc /etc/init.d/grow-root
rc-update add grow-root boot
