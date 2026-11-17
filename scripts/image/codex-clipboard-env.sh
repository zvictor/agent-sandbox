# Orca's remote viewers receive OSC 52 from the terminal stream. Codex detects
# that route through SSH session markers, even when the desktop clipboard works.
# Orca terminals can acquire a mobile viewer after Codex starts. Their existing
# TERM_PROGRAM identity supplies the same route even without the remote marker.
# Match Orca's Codex-only marker without changing the launcher/parent shell.
if { [ "${ORCA_REMOTE_VIEWER_CLIPBOARD:-}" = 1 ] || [ "${TERM_PROGRAM:-}" = Orca ]; } &&
   [ "${SSH_CONNECTION+x}" != x ] && [ "${SSH_TTY+x}" != x ]; then
  export SSH_CONNECTION='127.0.0.1 0 127.0.0.1 0'
fi

# Like Orca's Codex wrapper, keep its synthetic SSH hint out of commands Codex
# runs. Real SSH state and the user's include/exclude lists remain untouched.
if [ "${SSH_CONNECTION:-}" = '127.0.0.1 0 127.0.0.1 0' ]; then
  codex_clipboard_local_config=1
  for codex_clipboard_arg in "$@"; do
    case "$codex_clipboard_arg" in
      --remote|--remote=*|agents|queue) codex_clipboard_local_config=0 ;;
    esac
  done
  if [ "$codex_clipboard_local_config" = 1 ]; then
    set -- -c "shell_environment_policy.set.SSH_CONNECTION=''" "$@"
  fi
  unset codex_clipboard_local_config codex_clipboard_arg
fi
