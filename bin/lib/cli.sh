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
    echo "usage: agent <tool|doctor|init> [args...]" >&2
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

  TOOLS_LIST="${AGENT_TOOLS:-$KNOWN_TOOLS}"
  if ! contains_word "$TOOL" $TOOLS_LIST; then
    echo "[agent] tool '$TOOL' is disabled by AGENT_TOOLS='$TOOLS_LIST'" >&2
    exit 1
  fi
}
