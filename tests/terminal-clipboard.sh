#!/usr/bin/env bash
# Check the remote-viewer contract without accessing either device's clipboard.
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source "$repo_root/bin/lib/container_runtime.sh"
fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }

resolve_wayland_socket() { :; }
resolve_x11_socket() { :; }
resolve_xauthority_file() { :; }
Z_SUFFIX=""
unset ORCA_REMOTE_VIEWER_CLIPBOARD SSH_CONNECTION SSH_TTY
TERM_PROGRAM=xterm

# A remote viewer requires no host display access or Orca control API grant.
for boundary in local no-display remote; do
  (
    export ORCA_REMOTE_VIEWER_CLIPBOARD=1
    AGENT_ORCA=0
    AGENT_DISABLE_CLIPBOARD=0 AGENT_REMOTE_CONTAINER_MODE=0
    case "$boundary" in
      no-display) AGENT_DISABLE_CLIPBOARD=1 ;;
      remote) AGENT_REMOTE_CONTAINER_MODE=1 AGENT_REMOTE_FORWARD_CLIPBOARD=0 ;;
    esac
    ARGS=()
    append_clipboard_args
    [ "${#ARGS[@]}" -eq 2 ] && [ "${ARGS[0]}" = -e ] &&
      [ "${ARGS[1]}" = ORCA_REMOTE_VIEWER_CLIPBOARD=1 ] || fail 'remote-viewer marker lost or display access added'
    # The launcher must leave its own SSH state alone; only Codex gets the hint.
    [ "${SSH_CONNECTION+x}" != x ] || fail 'parent shell became an SSH session'
    set -- resume 'session with spaces'
    source "$repo_root/scripts/image/codex-clipboard-env.sh"
    [ "$SSH_CONNECTION" = '127.0.0.1 0 127.0.0.1 0' ] || fail 'Codex did not receive the terminal clipboard hint'
    bash -c '[ "$SSH_CONNECTION" = "127.0.0.1 0 127.0.0.1 0" ]' || fail 'Codex hint was not exported'
    [ "$#" -eq 4 ] && [ "$1" = -c ] &&
      [ "$2" = "shell_environment_policy.set.SSH_CONNECTION=''" ] &&
      [ "$3" = resume ] && [ "$4" = 'session with spaces' ] || fail 'Codex child policy or original arguments lost'
  )
done

# Desktop sessions preserve native clipboard selection and receive no SSH hint.
for marker in unset 0 invalid; do
  (
    [ "$marker" = unset ] || ORCA_REMOTE_VIEWER_CLIPBOARD="$marker"
    ARGS=()
    append_clipboard_args
    [ "${#ARGS[@]}" -eq 0 ] || fail 'desktop session received a remote-viewer marker'
    source "$repo_root/scripts/image/codex-clipboard-env.sh"
    [ "${SSH_CONNECTION+x}" != x ] || fail 'desktop session became an SSH session'
  )
done

# A desktop-started Orca session must support a phone attaching later, too.
(
  TERM_PROGRAM=Orca
  source "$repo_root/scripts/image/codex-clipboard-env.sh"
  [ "$SSH_CONNECTION" = '127.0.0.1 0 127.0.0.1 0' ] || fail 'desktop-started Orca session cannot copy to later viewers'
)

# Real SSH context, including an explicitly empty marker, must be preserved.
for kind in connection tty empty-connection empty-tty; do
  (
    ORCA_REMOTE_VIEWER_CLIPBOARD=1
    case "$kind" in
      connection) export SSH_CONNECTION='192.0.2.1 1234 192.0.2.2 22' ;;
      tty) export SSH_TTY=/dev/pts/7 ;;
      empty-connection) export SSH_CONNECTION='' ;;
      empty-tty) export SSH_TTY='' ;;
    esac
    before="$(declare -p SSH_CONNECTION SSH_TTY 2>/dev/null || true)"
    source "$repo_root/scripts/image/codex-clipboard-env.sh"
    after="$(declare -p SSH_CONNECTION SSH_TTY 2>/dev/null || true)"
    [ "$before" = "$after" ] || fail 'existing SSH context was overwritten'
  )
done

# Remote/daemon clients reject local config overrides; keep their argv intact.
for mode in --remote=unix:///tmp/test.sock agents queue; do
  (
    ORCA_REMOTE_VIEWER_CLIPBOARD=1
    set -- "$mode" 'original argument'
    source "$repo_root/scripts/image/codex-clipboard-env.sh"
    [ "$#" -eq 2 ] && [ "$1" = "$mode" ] && [ "$2" = 'original argument' ] || fail 'remote client received local config overrides'
  )
done

printf '[pass] remote-viewer clipboard routing and Codex-only SSH hint\n'
