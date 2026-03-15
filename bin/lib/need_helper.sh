NEED_HELPER_MODE=""
NEED_HELPER_DIR=""
NEED_HELPER_PID_FILE=""
NEED_HELPER_LOG_FILE=""
NEED_HELPER_TTL=""

resolve_need_helper_mode() {
  NEED_HELPER_MODE="${AGENT_NEED_HELPER:-1}"

  case "$NEED_HELPER_MODE" in
    0|1) ;;
    *)
      echo "[agent] invalid AGENT_NEED_HELPER='$NEED_HELPER_MODE' (expected: 0 or 1)" >&2
      exit 1
      ;;
  esac
}

need_helper_service_running() {
  [ -n "${NEED_HELPER_PID_FILE:-}" ] || return 1
  [ -f "$NEED_HELPER_PID_FILE" ] || return 1

  local pid
  pid="$(cat "$NEED_HELPER_PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

prepare_need_helper() {
  local key
  local lock_dir
  local service_pid=""

  resolve_need_helper_mode
  [ "$NEED_HELPER_MODE" = "1" ] || return 0

  key="$(hash_short "$(id -u)|$HOST_HOME|$PROJECT_ROOT")"
  NEED_HELPER_TTL="${AGENT_NEED_HELPER_TTL:-900}"
  NEED_HELPER_DIR="$CACHE_DIR/nix-tool-helper/$key"
  NEED_HELPER_PID_FILE="$NEED_HELPER_DIR/service.pid"
  NEED_HELPER_LOG_FILE="$NEED_HELPER_DIR/service.log"
  lock_dir="$NEED_HELPER_DIR/.lock"

  mkdir -p "$NEED_HELPER_DIR/requests" "$NEED_HELPER_DIR/processing" "$NEED_HELPER_DIR/responses"

  if need_helper_service_running; then
    return 0
  fi

  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [ -d "$lock_dir" ] && ! need_helper_service_running; then
      rmdir "$lock_dir" 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null || return 0
    else
      return 0
    fi
  fi

  if need_helper_service_running; then
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
  fi

  (
    umask 077
    "$AGENT_BIN_DIR/agent-nix-helper" serve "$NEED_HELPER_DIR" "$NEED_HELPER_TTL" \
      >"$NEED_HELPER_LOG_FILE" 2>&1
  ) &
  service_pid="$!"
  printf '%s\n' "$service_pid" > "$NEED_HELPER_PID_FILE"
  perf_log "need helper started in background (ttl=${NEED_HELPER_TTL}s)"

  rmdir "$lock_dir" 2>/dev/null || true
}
