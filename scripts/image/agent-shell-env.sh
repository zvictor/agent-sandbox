if [ -n "${BASH_VERSION:-}" ] && command -v agent-compat >/dev/null 2>&1; then
  command_not_found_handle() {
    /bin/agent-compat command-not-found "$@" 2>/dev/null && return 0
    printf '%s: command not found\n' "$1" >&2
    return 127
  }
fi
