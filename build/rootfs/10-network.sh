# shellcheck shell=sh
# Network: DHCP on eth0 and a fixed IPv4 resolver.
#
# DHCP may hand out IPv6 resolvers this host cannot reach, so the DNS config is
# written twice: once now and once from local.d, which runs after networking
# inside the default runlevel.

cat >/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
rc-update add networking boot

mkdir -p /etc/local.d
cat >/etc/local.d/00-dns.start <<'EOF'
#!/bin/sh
printf 'nameserver 119.29.29.29\nnameserver 223.5.5.5\n' > /etc/resolv.conf
EOF
chmod +x /etc/local.d/00-dns.start
rc-update add local default

printf 'nameserver 119.29.29.29\nnameserver 223.5.5.5\n' > /etc/resolv.conf
