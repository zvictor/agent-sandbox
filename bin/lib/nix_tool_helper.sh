NIX_TOOL_HELPER_MODE=""
NIX_TOOL_HELPER_DIR=""
NIX_TOOL_HELPER_PID_FILE=""
NIX_TOOL_HELPER_LOG_FILE=""
NIX_TOOL_HELPER_TTL=""

resolve_nix_tool_helper_mode() {
  NIX_TOOL_HELPER_MODE="${AGENT_NIX_TOOL_HELPER:-1}"

  case "$NIX_TOOL_HELPER_MODE" in
    0|1) ;;
    *)
      echo "[agent] invalid AGENT_NIX_TOOL_HELPER='$NIX_TOOL_HELPER_MODE' (expected: 0 or 1)" >&2
      exit 1
      ;;
  esac
}

nix_tool_helper_service_running() {
  [ -n "${NIX_TOOL_HELPER_PID_FILE:-}" ] || return 1
  [ -f "$NIX_TOOL_HELPER_PID_FILE" ] || return 1

  local pid
  pid="$(cat "$NIX_TOOL_HELPER_PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

prepare_nix_tool_helper() {
  local key
  local lock_dir
  local service_pid=""

  resolve_nix_tool_helper_mode
  [ "$NIX_TOOL_HELPER_MODE" = "1" ] || return 0

  key="$(hash_short "$(id -u)|$HOST_HOME|$PROJECT_ROOT")"
  NIX_TOOL_HELPER_TTL="${AGENT_NIX_TOOL_HELPER_TTL:-900}"
  NIX_TOOL_HELPER_DIR="$CACHE_DIR/nix-tool-helper/$key"
  NIX_TOOL_HELPER_PID_FILE="$NIX_TOOL_HELPER_DIR/service.pid"
  NIX_TOOL_HELPER_LOG_FILE="$NIX_TOOL_HELPER_DIR/service.log"
  lock_dir="$NIX_TOOL_HELPER_DIR/.lock"

  mkdir -p "$NIX_TOOL_HELPER_DIR/requests" "$NIX_TOOL_HELPER_DIR/processing" "$NIX_TOOL_HELPER_DIR/responses"

  if nix_tool_helper_service_running; then
    return 0
  fi

  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [ -d "$lock_dir" ] && ! nix_tool_helper_service_running; then
      rmdir "$lock_dir" 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null || return 0
    else
      return 0
    fi
  fi

  if nix_tool_helper_service_running; then
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
  fi

  (
    umask 077
    "$AGENT_BIN_DIR/agent-nix-helper" serve "$NIX_TOOL_HELPER_DIR" "$NIX_TOOL_HELPER_TTL" \
      >"$NIX_TOOL_HELPER_LOG_FILE" 2>&1
  ) &
  service_pid="$!"
  printf '%s\n' "$service_pid" > "$NIX_TOOL_HELPER_PID_FILE"
  perf_log "nix tool helper started in background (ttl=${NIX_TOOL_HELPER_TTL}s)"

  rmdir "$lock_dir" 2>/dev/null || true
}
