CONTAINER_API_MODE=""
CONTAINER_API_DIR=""
CONTAINER_API_RUN_DIR=""
CONTAINER_API_SOCKET_PATH=""
CONTAINER_API_PID_FILE=""
CONTAINER_API_LOG_FILE=""
CONTAINER_API_STORAGE_CONF=""
CONTAINER_API_TTL=""

resolve_container_api_mode() {
  CONTAINER_API_MODE="${AGENT_CONTAINER_API:-}"

  if [ -z "$CONTAINER_API_MODE" ]; then
    if [ "${AGENT_ALLOW_PODMAN_SOCKET:-0}" = "1" ]; then
      CONTAINER_API_MODE="podman-host"
    elif [ "${AGENT_ALLOW_DOCKER_SOCKET:-0}" = "1" ]; then
      CONTAINER_API_MODE="docker-host"
    else
      CONTAINER_API_MODE="none"
    fi
  fi

  if [ "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}" = "firecracker-host" ]; then
    case "$CONTAINER_API_MODE" in
      ""|none|auto)
        CONTAINER_API_MODE="none"
        return 0
        ;;
      *)
        echo "[agent] AGENT_SANDBOX_PROFILE=firecracker-host does not support AGENT_CONTAINER_API=$CONTAINER_API_MODE" >&2
        exit 1
        ;;
    esac
  fi

  case "$CONTAINER_API_MODE" in
    none|auto|podman-session|podman-host|docker-host) ;;
    *)
      echo "[agent] invalid AGENT_CONTAINER_API='$CONTAINER_API_MODE' (expected: none, auto, podman-session, podman-host, docker-host)" >&2
      exit 1
      ;;
  esac

  if [ "$CONTAINER_API_MODE" = "auto" ]; then
    if command -v podman >/dev/null 2>&1 \
      && env -u DOCKER_HOST -u CONTAINER_HOST podman info >/dev/null 2>&1; then
      CONTAINER_API_MODE="podman-session"
    else
      CONTAINER_API_MODE="none"
    fi
  fi

  if [ "$CONTAINER_API_MODE" = "podman-session" ] && ! command -v podman >/dev/null 2>&1; then
    echo "[agent] AGENT_CONTAINER_API=podman-session requires podman on the host" >&2
    exit 1
  fi
}

container_api_write_storage_conf() {
  local storage_conf="$1"
  local graphroot="$2"
  local runroot="$3"
  local additional_store="$4"

  mkdir -p "$(dirname "$storage_conf")"

  {
    printf '[storage]\n'
    printf 'graphroot = "%s"\n' "$graphroot"
    printf 'runroot = "%s"\n' "$runroot"
    printf '\n[storage.options]\n'
    if [ -n "$additional_store" ]; then
      printf 'additionalimagestores = ["%s"]\n' "$additional_store"
    fi
  } > "$storage_conf"
}

container_api_get_main_podman_graphroot() {
  env -u DOCKER_HOST -u CONTAINER_HOST podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true
}

container_api_pid_is_expected_service() {
  local pid="$1"
  local cmdline=""

  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1

  cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmdline" in
    *podman*" system service "*"--time "*"unix://$CONTAINER_API_SOCKET_PATH"*) return 0 ;;
    *podman*" system service "*"unix://$CONTAINER_API_SOCKET_PATH"*) return 0 ;;
  esac

  return 1
}

container_api_service_running() {
  [ -n "${CONTAINER_API_PID_FILE:-}" ] || return 1
  [ -f "$CONTAINER_API_PID_FILE" ] || return 1

  local pid
  pid="$(cat "$CONTAINER_API_PID_FILE" 2>/dev/null || true)"
  container_api_pid_is_expected_service "$pid"
}

container_api_discard_cached_service() {
  local service_pid="$1"

  if container_api_pid_is_expected_service "$service_pid"; then
    kill "$service_pid" 2>/dev/null || true
  fi

  rm -f "$CONTAINER_API_PID_FILE" "$CONTAINER_API_SOCKET_PATH"
}

container_api_wait_for_socket() {
  local service_pid="${1:-}"
  local wait_seconds="${AGENT_CONTAINER_API_WAIT_SECONDS:-30}"
  local wait_count=0
  local max_wait_count

  case "$wait_seconds" in
    ''|*[!0-9]*)
      wait_seconds=30
      ;;
  esac

  max_wait_count=$((wait_seconds * 10))
  [ "$max_wait_count" -gt 0 ] || max_wait_count=1

  while [ ! -S "$CONTAINER_API_SOCKET_PATH" ] && [ "$wait_count" -lt "$max_wait_count" ]; do
    if [ -n "$service_pid" ] && ! kill -0 "$service_pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    wait_count=$((wait_count + 1))
  done

  [ -S "$CONTAINER_API_SOCKET_PATH" ]
}

container_api_read_service_pid() {
  [ -f "$CONTAINER_API_PID_FILE" ] || return 0
  cat "$CONTAINER_API_PID_FILE" 2>/dev/null || true
}

container_api_report_socket_failure() {
  echo "[agent] fatal: podman session socket not ready at $CONTAINER_API_SOCKET_PATH" >&2
  if [ -f "$CONTAINER_API_LOG_FILE" ]; then
    echo "[agent] service log:" >&2
    cat "$CONTAINER_API_LOG_FILE" >&2
  fi
}

container_api_start_podman_session() {
  local key
  local lock_dir
  local graphroot
  local runroot
  local tmpdir
  local main_graphroot=""
  local runtime_dir=""
  local service_pid=""

  CONTAINER_API_TTL="${AGENT_CONTAINER_API_TTL:-900}"
  key="$(hash_short "$(id -u)|$PROJECT_ROOT|$HOST_HOME")"
  CONTAINER_API_DIR="$CACHE_DIR/container-api/podman-session/$key"
  # Socket must live under XDG_RUNTIME_DIR to stay within the 108-char Unix socket path limit.
  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  CONTAINER_API_RUN_DIR="$runtime_dir/agent-api-$key"
  CONTAINER_API_SOCKET_PATH="$CONTAINER_API_RUN_DIR/podman.sock"
  CONTAINER_API_PID_FILE="$CONTAINER_API_DIR/service.pid"
  CONTAINER_API_LOG_FILE="$CONTAINER_API_DIR/service.log"
  CONTAINER_API_STORAGE_CONF="$CONTAINER_API_DIR/storage.conf"

  graphroot="$CONTAINER_API_DIR/graphroot"
  runroot="$CONTAINER_API_DIR/runroot"
  tmpdir="$CONTAINER_API_DIR/tmp"
  lock_dir="$CONTAINER_API_DIR/.lock"

  if [ "${AGENT_CONTAINER_API_RESET:-0}" = "1" ]; then
    container_api_discard_cached_service "$(container_api_read_service_pid)"
    rm -rf "$CONTAINER_API_DIR" "$CONTAINER_API_RUN_DIR"
  fi

  mkdir -p "$CONTAINER_API_RUN_DIR" "$graphroot" "$runroot" "$tmpdir"

  main_graphroot="$(container_api_get_main_podman_graphroot)"
  if [ -n "$main_graphroot" ] && [ "$main_graphroot" = "$graphroot" ]; then
    main_graphroot=""
  fi
  if [ -n "$main_graphroot" ] && [ ! -d "$main_graphroot" ]; then
    main_graphroot=""
  fi

  container_api_write_storage_conf "$CONTAINER_API_STORAGE_CONF" "$graphroot" "$runroot" "$main_graphroot"

  if container_api_service_running; then
    service_pid="$(container_api_read_service_pid)"
    if container_api_wait_for_socket "$service_pid"; then
      return 0
    fi
    container_api_discard_cached_service "$service_pid"
  fi

  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [ -d "$lock_dir" ] && ! container_api_service_running; then
      rmdir "$lock_dir" 2>/dev/null || true
      mkdir "$lock_dir" 2>/dev/null || return 0
    elif container_api_wait_for_socket "$(container_api_read_service_pid)"; then
      return 0
    else
      container_api_report_socket_failure
      exit 1
    fi
  fi

  if container_api_service_running; then
    rmdir "$lock_dir" 2>/dev/null || true
    service_pid="$(container_api_read_service_pid)"
    if container_api_wait_for_socket "$service_pid"; then
      return 0
    fi
    container_api_discard_cached_service "$service_pid"
  fi

  rm -f "$CONTAINER_API_SOCKET_PATH"

  (
    umask 077
    env -u DOCKER_HOST -u CONTAINER_HOST \
      TMPDIR="$tmpdir" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      CONTAINERS_STORAGE_CONF="$CONTAINER_API_STORAGE_CONF" \
      podman system service --time "$CONTAINER_API_TTL" "unix://$CONTAINER_API_SOCKET_PATH" \
      >"$CONTAINER_API_LOG_FILE" 2>&1
  ) &
  service_pid="$!"
  printf '%s\n' "$service_pid" > "$CONTAINER_API_PID_FILE"
  perf_log "container api warmup started in background (mode=podman-session ttl=${CONTAINER_API_TTL}s)"

  if ! container_api_wait_for_socket "$service_pid"; then
    if ! kill -0 "$service_pid" 2>/dev/null; then
      echo "[agent] podman session service exited unexpectedly" >&2
      cat "$CONTAINER_API_LOG_FILE" >&2 2>/dev/null || true
    else
      container_api_report_socket_failure
    fi
    rmdir "$lock_dir" 2>/dev/null || true
    exit 1
  fi

  rmdir "$lock_dir" 2>/dev/null || true
}

prepare_container_api() {
  resolve_container_api_mode

  case "$CONTAINER_API_MODE" in
    podman-session)
      container_api_start_podman_session
      ;;
  esac
}
