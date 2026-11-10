# shellcheck shell=sh
# SSH access (headless profile only): key-only root, stable host key, port 22.

[ "$PROFILE" = "headless" ] || return 0

install -d -m 0700 /etc/ssh /root/.ssh

# Bake the fixed host key so the fingerprint stays stable across rebuilds.
if [ -f /mnt/vendor/ssh_host_ed25519_key ]; then
	install -m 0600 /mnt/vendor/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
	install -m 0644 /mnt/vendor/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
fi

if [ -f /mnt/vendor/ssh_user_key.pub ]; then
	install -m 0600 /mnt/vendor/ssh_user_key.pub /root/.ssh/authorized_keys
fi

cat >/etc/ssh/sshd_config <<'EOF'
Port 22
ListenAddress 0.0.0.0
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
ClientAliveInterval 120
ClientAliveCountMax 3
EOF

# Remove any keys openssh generated at install time; ours are the only ones.
rm -f /etc/ssh/ssh_rsa_key* /etc/ssh/ssh_ecdsa_key* /etc/ssh/ssh_dsa_key*

rc-update add sshd default
