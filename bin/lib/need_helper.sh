NEED_HELPER_MODE=""
NEED_HELPER_DIR=""
NEED_HELPER_BRIDGE_DIR=""
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
  runtime_lease_helper_process_matches "$pid" "$NEED_HELPER_BRIDGE_DIR"
}

prepare_need_helper() {
  local lock_dir
  local service_pid=""

  resolve_need_helper_mode
  [ "$NEED_HELPER_MODE" = "1" ] || return 0
  if [ -z "${RUNTIME_LEASE_DIR:-}" ] || [ -z "${RUNTIME_LEASE_ID:-}" ]; then
    echo "[agent] ERROR: need helper requires an active runtime lease" >&2
    exit 1
  fi

  NEED_HELPER_TTL="${AGENT_NEED_HELPER_TTL:-900}"
  NEED_HELPER_DIR="$RUNTIME_LEASE_DIR/need-helper"
  NEED_HELPER_BRIDGE_DIR="$NEED_HELPER_DIR/bridge"
  NEED_HELPER_PID_FILE="$NEED_HELPER_DIR/service.pid"
  NEED_HELPER_LOG_FILE="$NEED_HELPER_DIR/service.log"
  lock_dir="$NEED_HELPER_DIR/.lock"

  mkdir -p "$NEED_HELPER_BRIDGE_DIR/requests" "$NEED_HELPER_BRIDGE_DIR/processing" "$NEED_HELPER_BRIDGE_DIR/responses"

  if need_helper_service_running; then
    return 0
  fi

  # Clean up stale PID file from a dead helper
  if [ -f "$NEED_HELPER_PID_FILE" ]; then
    rm -f "$NEED_HELPER_PID_FILE"
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
    exec "$AGENT_BIN_DIR/agent-nix-helper" serve \
      "$NEED_HELPER_BRIDGE_DIR" "$NEED_HELPER_TTL" "$RUNTIME_LEASE_ID" \
      "$RUNTIME_LEASE_ROOTS_DIR" "$RUNTIME_LEASE_RECEIPTS_DIR" \
      </dev/null >"$NEED_HELPER_LOG_FILE" 2>&1
  ) &
  service_pid="$!"
  printf '%s\n' "$service_pid" > "$NEED_HELPER_PID_FILE"
  perf_log "need helper started in background (pid=$service_pid ttl=${NEED_HELPER_TTL}s)"

  rmdir "$lock_dir" 2>/dev/null || true
}
