#!/bin/sh
set -eu

state_dir="${AGENT_REMOTE_STATE_DIR:-/run/agent-remote}"
login_user="${USER:-codex}"
port="${AGENT_REMOTE_SSH_PORT:-2222}"

mkdir -p "$state_dir" "$state_dir/empty"
chmod 700 "$state_dir" "$state_dir/empty" 2>/dev/null || true

authorized_keys="$state_dir/authorized_keys"
if [ ! -s "$authorized_keys" ]; then
  echo "agent-remote: missing authorized_keys at $authorized_keys" >&2
  exit 1
fi
chmod 600 "$authorized_keys" 2>/dev/null || true

host_key="$state_dir/ssh_host_ed25519_key"
if [ ! -s "$host_key" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$host_key"
fi
chmod 600 "$host_key" 2>/dev/null || true

config="$state_dir/sshd_config"
cat > "$config" <<EOF_CONFIG
Port $port
ListenAddress 127.0.0.1
HostKey $host_key
AuthorizedKeysFile $authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers $login_user
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
PermitTTY yes
StrictModes no
PidFile $state_dir/sshd.pid
ForceCommand /bin/agent-remote-dispatch
Subsystem sftp internal-sftp
EOF_CONFIG

exec sshd -D -e -f "$config"
