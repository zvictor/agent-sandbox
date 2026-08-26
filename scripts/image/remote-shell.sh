#!/bin/sh
set -eu

workspace="${AGENT_WORKSPACE_PATH:-/workspace}"
cd "$workspace" 2>/dev/null || cd /

if tmux has-session -t codex 2>/dev/null; then
  exec tmux attach-session -t codex
fi

cat <<'EOF'
No live Codex tmux session is running in this remote sandbox.

Run one of:
  codex    start or attach the Codex tmux session
  shell    open a shell tmux session

Opening shell.
EOF

exec tmux new-session -A -s shell
