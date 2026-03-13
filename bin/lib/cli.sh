print_help_and_exit() {
  local enabled_tools="$KNOWN_TOOLS"
  local enabled_suffix=""

  if declare -F prepare_tool_resolution_context >/dev/null 2>&1; then
    prepare_tool_resolution_context >/dev/null 2>&1 || true
    if [ -n "${EFFECTIVE_TOOLS_LIST:-}" ]; then
      enabled_tools="$EFFECTIVE_TOOLS_LIST"
    fi
    if [ -n "${EFFECTIVE_TOOLS_SOURCE:-}" ] && [ "$EFFECTIVE_TOOLS_SOURCE" != "fallback-all" ]; then
      enabled_suffix=" (${EFFECTIVE_TOOLS_SOURCE})"
    fi
  fi

  cat <<EOF
usage:
  agent <tool> [args...]
  agent run <tool> [args...]
  agent login codex <name> [--use] [-- <codex login args...>]
  agent init [--force] [--stdout]
  agent doctor [--verbose] [--json]
  agent help

supported tools:
  $KNOWN_TOOLS

enabled tools:
  $enabled_tools$enabled_suffix

examples:
  agent init
  agent doctor
  agent login codex work --use
  agent run codex
  agent codex
EOF
  exit 0
}

normalize_flake_ref() {
  local ref="$1"
  local path_ref=""

  case "$ref" in
    path:*)
      path_ref="${ref#path:}"
      if [ -d "$path_ref" ]; then
        printf 'path:%s\n' "$(cd "$path_ref" && pwd -P)"
      else
        printf '%s\n' "$ref"
      fi
      return
      ;;
    /*|./*|../*)
      if [ -d "$ref" ] && [ -f "$ref/flake.nix" ]; then
        printf 'path:%s\n' "$(cd "$ref" && pwd -P)"
      else
        printf '%s\n' "$ref"
      fi
      return
      ;;
    *)
      if [ -d "$ref" ] && [ -f "$ref/flake.nix" ]; then
        printf 'path:%s\n' "$(cd "$ref" && pwd -P)"
      else
        printf '%s\n' "$ref"
      fi
      return
      ;;
  esac
}

resolve_tool() {
  local argv0
  argv0="$(basename "$0")"

  if contains_word "$argv0" $KNOWN_TOOLS; then
    TOOL="$argv0"
    REMAINING_ARGS=("$@")
    return
  fi

  if [ "${1:-}" = "--version" ]; then
    TOOL=""
    return
  fi

  if [ "$#" -lt 1 ]; then
    print_help_and_exit
  fi

  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "help" ]; then
    print_help_and_exit
  fi

  if [ "${1:-}" = "run" ]; then
    shift
  fi

  if [ "$#" -lt 1 ]; then
    echo "usage: agent run <tool> [args...]" >&2
    exit 1
  fi

  TOOL="$1"
  shift
  REMAINING_ARGS=("$@")
}

resolve_sandbox_flake() {
  SANDBOX_FLAKE="${AGENT_SANDBOX_FLAKE_REF:-${AGENT_SANDBOX_FLAKE:-}}"
  if [ -z "$SANDBOX_FLAKE" ]; then
    LOCAL_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
    if [ -f "$LOCAL_ROOT/flake.nix" ]; then
      SANDBOX_FLAKE="path:$LOCAL_ROOT"
    else
      SANDBOX_FLAKE="github:zvictor/agent-sandbox"
    fi
  fi
  SANDBOX_FLAKE="$(normalize_flake_ref "$SANDBOX_FLAKE")"
}

print_version_and_exit() {
  resolve_sandbox_flake
  nix_cmd flake metadata "$SANDBOX_FLAKE" --json | jq -r '.locked.rev // .revision // "unknown"'
  exit 0
}

validate_tool_access() {
  if ! contains_word "$TOOL" $KNOWN_TOOLS; then
    echo "[agent] unsupported tool '$TOOL' (supported: $KNOWN_TOOLS)" >&2
    exit 1
  fi

  prepare_tool_resolution_context
  TOOLS_LIST="${EFFECTIVE_TOOLS_LIST:-$KNOWN_TOOLS}"
  if ! contains_word "$TOOL" $TOOLS_LIST; then
    if [ "${EFFECTIVE_TOOLS_SOURCE:-}" = "configured" ] || [ "${EFFECTIVE_TOOLS_SOURCE:-}" = "configured-all" ]; then
      echo "[agent] tool '$TOOL' is disabled by AGENT_TOOLS='$TOOLS_LIST'" >&2
    else
      echo "[agent] tool '$TOOL' is not enabled for this project (effective tools: $TOOLS_LIST)" >&2
      echo "[agent] set AGENT_TOOLS to override the inferred tool list if needed" >&2
    fi
    exit 1
  fi
}
