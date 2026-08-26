#!/bin/sh
set -eu

cmd="${SSH_ORIGINAL_COMMAND:-}"

case "$cmd" in
  ""|attach)
    exec /bin/agent-remote-shell
    ;;
  shell)
    cd "${AGENT_WORKSPACE_PATH:-/workspace}" 2>/dev/null || cd /
    exec tmux new-session -A -s shell
    ;;
  codex)
    exec /bin/agent-remote-codex
    ;;
  status)
    printf 'workspace=%s\n' "${AGENT_WORKSPACE_PATH:-}"
    tmux list-sessions 2>/dev/null || true
    ;;
  *)
    echo "agent-remote: unsupported SSH command: $cmd" >&2
    echo "supported commands: attach, shell, codex, status" >&2
    exit 2
    ;;
esac
