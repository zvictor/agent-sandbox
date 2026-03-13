resolve_runtime() {
  RUNTIME="${AGENT_RUNTIME:-${CODEX_RUNTIME:-}}"
  if [ -z "$RUNTIME" ]; then
    if command -v podman >/dev/null 2>&1; then
      RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
      RUNTIME="docker"
    else
      echo "[agent] neither podman nor docker is available in PATH" >&2
      exit 1
    fi
  fi

  if ! command -v "$RUNTIME" >/dev/null 2>&1; then
    echo "[agent] requested runtime '$RUNTIME' is not available" >&2
    exit 1
  fi
}

resolve_lock_args() {
  LOCK_ARGS=()
  SANDBOX_LOCK_PATH=""
  case "$SANDBOX_FLAKE" in
    path:*)
      SANDBOX_LOCK_PATH="${SANDBOX_FLAKE#path:}"
      ;;
    /*|./*|../*)
      SANDBOX_LOCK_PATH="$SANDBOX_FLAKE"
      ;;
  esac
  if [ -n "$SANDBOX_LOCK_PATH" ] && [ -f "$SANDBOX_LOCK_PATH/flake.lock" ]; then
    LOCK_ARGS+=(--no-update-lock-file)
  fi
}

resolve_project_paths() {
  PROJECT_ROOT="${AGENT_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  PROJECT_NIX_DIR="${AGENT_PROJECT_NIX_DIR:-$PROJECT_ROOT/nix}"
}

resolve_host_home() {
  HOST_HOME="${AGENT_HOST_HOME:-$HOME}"
  if [ "$HOST_HOME" = "/cache" ] || [ ! -d "$HOST_HOME" ]; then
    if command -v getent >/dev/null 2>&1; then
      HOST_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
    fi
  fi
  if [ -z "$HOST_HOME" ] || [ ! -d "$HOST_HOME" ]; then
    HOST_HOME="$PROJECT_ROOT"
  fi
}

prepare_project_contract_input() {
  TMP_DIR=""
  STORE_INPUT_PATH=""
  STORE_INPUT_NAME=""
  PROJECT_OVERRIDE_ARGS=()

  if [ -f "$PROJECT_NIX_DIR/packages.nix" ]; then
    TMP_DIR="$(mktemp -d)"
    stage_project_contract_input "$TMP_DIR"
    STORE_INPUT_PATH="$TMP_DIR"
    STORE_INPUT_NAME="project-nix"
  elif [ -f "$PROJECT_ROOT/shell.nix" ]; then
    TMP_DIR="$(mktemp -d)"
    stage_project_contract_input "$TMP_DIR"
    STORE_INPUT_PATH="$TMP_DIR"
    STORE_INPUT_NAME="project-shell"
  else
    STORE_INPUT_NAME="empty-project"
  fi
}

prepare_cache_dirs() {
  DEFAULT_CACHE_BASE="${XDG_CACHE_HOME:-$HOST_HOME/.cache}"
  if ! mkdir -p "$DEFAULT_CACHE_BASE" >/dev/null 2>&1; then
    DEFAULT_CACHE_BASE="$PROJECT_ROOT/.cache-agent"
  fi
  CACHE_DIR="${AGENT_CACHE_DIR:-$DEFAULT_CACHE_BASE/agent-sandbox}"
  GCROOTS_DIR="$CACHE_DIR/gcroots"
  IMAGES_DIR="$CACHE_DIR/images"
  HELPER_TMPDIR="${AGENT_HELPER_TMPDIR:-$CACHE_DIR/tmp}"
  mkdir -p "$CACHE_DIR" "$GCROOTS_DIR" "$IMAGES_DIR" "$HELPER_TMPDIR"
}

resolve_direnv_nix_path() {
  local expr=""
  local resolved_path=""

  AGENT_DIRENV_NIX_PATH="${AGENT_DIRENV_NIX_PATH:-}"

  if [ -n "$AGENT_DIRENV_NIX_PATH" ] && [ -e "$AGENT_DIRENV_NIX_PATH" ]; then
    export AGENT_DIRENV_NIX_PATH
    return 0
  fi

  AGENT_DIRENV_NIX_PATH=""

  if ! command -v nix >/dev/null 2>&1; then
    return 0
  fi

  expr="let flake = builtins.getFlake \"${SANDBOX_FLAKE}\"; in if flake.inputs ? nixpkgs then flake.inputs.nixpkgs.outPath else \"\""
  resolved_path="$(nix_cmd eval --impure --raw --expr "$expr" 2>/dev/null || true)"

  if [ -n "$resolved_path" ] && [ -e "$resolved_path" ]; then
    AGENT_DIRENV_NIX_PATH="$resolved_path"
    export AGENT_DIRENV_NIX_PATH
  fi
}

log_debug_context() {
  if [ "${AGENT_DEBUG:-0}" = "1" ]; then
    echo "[agent] TOOL=$TOOL" >&2
    echo "[agent] RUNTIME=$RUNTIME" >&2
    echo "[agent] SANDBOX_FLAKE=$SANDBOX_FLAKE" >&2
    echo "[agent] PROJECT_ROOT=$PROJECT_ROOT" >&2
    echo "[agent] STORE_INPUT_PATH=$STORE_INPUT_PATH" >&2
    echo "[agent] DEV_ENV_MODE=${DEV_ENV_MODE:-unset}" >&2
    echo "[agent] DEV_ENV_ENV_FILE=${DEV_ENV_ENV_FILE:-}" >&2
    echo "[agent] DIRENV_NIX_PATH=${AGENT_DIRENV_NIX_PATH:-}" >&2
    echo "[agent] CONTAINER_API_MODE=${CONTAINER_API_MODE:-none}" >&2
  fi
}

prepare_project_store_input() {
  PROJECT_STORE_PATH=""
  STORE_ADD_MS=0

  if [ -n "$STORE_INPUT_PATH" ]; then
    STORE_ADD_START_MS="$(now_ms)"
    if PROJECT_STORE_PATH="$(nix_cmd store add --mode nar --name "$STORE_INPUT_NAME" "$STORE_INPUT_PATH" 2>/dev/null)"; then
      :
    else
      PROJECT_STORE_PATH="$(nix_cmd store add-path "$STORE_INPUT_PATH" --name "$STORE_INPUT_NAME")"
    fi
    STORE_ADD_END_MS="$(now_ms)"
    STORE_ADD_MS="$((STORE_ADD_END_MS - STORE_ADD_START_MS))"
    PROJECT_OVERRIDE_ARGS=( --override-input projectPkgs "path:${PROJECT_STORE_PATH}" )
    perf_log "project store input (${STORE_INPUT_NAME}) resolved in $(format_duration_ms "$STORE_ADD_MS")"
  else
    perf_log "project store input (${STORE_INPUT_NAME}) resolved in 0ms"
  fi

  STORE_KEY="${PROJECT_STORE_PATH##*/}"
  if [ -z "$STORE_KEY" ]; then
    STORE_KEY="$STORE_INPUT_NAME"
  fi
}

bootstrap_environment() {
  OS_NAME="$(uname -s)"

  mkdir -p "${TMPDIR:-/tmp}" >/dev/null 2>&1 || true
  mkdir -p /var/tmp >/dev/null 2>&1 || true

  resolve_runtime
  resolve_sandbox_flake
  resolve_lock_args
  resolve_project_paths
  resolve_host_home
  prepare_project_contract_input
  prepare_cache_dirs
  resolve_direnv_nix_path
  prepare_dev_env_state
  log_debug_context
  prepare_project_store_input
}
