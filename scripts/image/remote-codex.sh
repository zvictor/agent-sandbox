#!/bin/sh
set -eu

workspace="${AGENT_WORKSPACE_PATH:-/workspace}"
session="${AGENT_REMOTE_CODEX_TMUX_SESSION:-codex}"

cd "$workspace" 2>/dev/null || cd /

quote_arg() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

if tmux has-session -t "$session" 2>/dev/null; then
  if [ "$#" -gt 0 ]; then
    echo "agent-remote: Codex session '$session' is already running; new arguments are ignored" >&2
  fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "agent-remote: Codex session '$session' is running"
    exit 0
  fi
  exec tmux attach-session -t "$session"
fi

cmd="exec codex --sandbox workspace-write --ask-for-approval on-request"

if [ -d /cache/.ssh ]; then
  cmd="$cmd --add-dir /cache/.ssh"
fi
if [ -S /run/host-services/ssh-auth.sock ]; then
  cmd="$cmd --add-dir /run/host-services"
fi

while [ "$#" -gt 0 ]; do
  cmd="$cmd $(quote_arg "$1")"
  shift
done

tmux new-session -d -s "$session" -c "$PWD" "$cmd"
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "agent-remote: started Codex session '$session'"
  exit 0
fi
exec tmux attach-session -t "$session"
