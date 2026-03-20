mount_engine() {
  local engine="$1"
  local config_mode="$2"
  local host_config_dir="$3"
  local container_config_dir="$4"
  local env_pairs="$5"
  local auth_env_name="$6"
  local auth_base_dir="$7"
  local active_credentials_file="$8"
  local mount_source=""
  local resolved_auth_path=""
  local selector_value=""

  append_split_arg_values -e "$env_pairs"

  if [ "${LOGIN_TOOL:-}" = "$engine" ] && [ -n "${LOGIN_CONFIG_HOST_DIR:-}" ]; then
    mount_source="$LOGIN_CONFIG_HOST_DIR"
    mkdir -p "$mount_source"
    ARGS+=( -v "$mount_source:$container_config_dir:rw${Z_SUFFIX}" )
    return 0
  fi

  mount_source="$(ensure_runtime_config_dir "$engine" "$config_mode" "$host_config_dir")"
  if [ -z "$mount_source" ]; then
    mount_source="$CACHE_DIR/empty-config/$engine"
    mkdir -p "$mount_source"
  fi

  ARGS+=( -v "$mount_source:$container_config_dir:rw${Z_SUFFIX}" )

  if [ -n "$auth_env_name" ]; then
    selector_value="${!auth_env_name:-}"
  fi

  resolved_auth_path="$(resolve_auth_file_path "$selector_value" "$auth_base_dir")"
  if [ -n "$resolved_auth_path" ]; then
    if [ ! -f "$resolved_auth_path" ]; then
      echo "[agent] ERROR: auth selector '$selector_value' for $engine did not resolve to a readable file: $resolved_auth_path" >&2
      exit 1
    fi
    ARGS+=( -v "$resolved_auth_path:$container_config_dir/$active_credentials_file:ro${Z_SUFFIX}" )
    ARGS+=( -e "${engine^^}_AUTH=$selector_value" )
  fi
}

expand_host_selector_path() {
  local raw_path="$1"

  case "$raw_path" in
    "~")
      printf '%s\n' "$HOST_HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOST_HOME" "${raw_path#~/}"
      ;;
    /*)
      printf '%s\n' "$raw_path"
      ;;
    ./*|../*)
      printf '%s/%s\n' "$PROJECT_ROOT" "$raw_path"
      ;;
    *)
      printf '%s\n' "$raw_path"
      ;;
  esac
}

expand_host_config_path() {
  local raw_path="$1"

  case "$raw_path" in
    "" )
      printf '%s\n' ""
      ;;
    "~")
      printf '%s\n' "$HOST_HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOST_HOME" "${raw_path#~/}"
      ;;
    /*)
      printf '%s\n' "$raw_path"
      ;;
    ./*|../*)
      printf '%s/%s\n' "$PROJECT_ROOT" "$raw_path"
      ;;
    *)
      printf '%s/%s\n' "$PROJECT_ROOT" "$raw_path"
      ;;
  esac
}

ensure_config_state_dir() {
  if [ -z "${CONFIG_STATE_DIR:-}" ]; then
    CONFIG_STATE_DIR="$(mktemp -d "$HELPER_TMPDIR/config.XXXXXX")"
  fi
}

ensure_runtime_config_dir() {
  local engine="$1"
  local config_mode="$2"
  local resolved_path="$3"
  local runtime_path=""

  case "$config_mode" in
    host|project|path)
      if [ -z "$resolved_path" ]; then
        printf '%s\n' ""
        return 0
      fi
      if [ -e "$resolved_path" ] && [ ! -d "$resolved_path" ]; then
        echo "[agent] ERROR: config path for $engine is not a directory: $resolved_path" >&2
        exit 1
      fi
      mkdir -p "$resolved_path"
      printf '%s\n' "$resolved_path"
      ;;
    fresh)
      ensure_config_state_dir
      runtime_path="$CONFIG_STATE_DIR/$engine"
      mkdir -p "$runtime_path"
      printf '%s\n' "$runtime_path"
      ;;
    none|"")
      printf '%s\n' ""
      ;;
    *)
      echo "[agent] ERROR: unsupported config mode '$config_mode' for $engine" >&2
      exit 1
      ;;
  esac
}

resolve_config_root() {
  local selector_value="$1"
  local default_host_path="$2"
  local project_path="$3"
  local mode=""
  local resolved_path=""
  local effective_selector="$selector_value"

  case "${effective_selector:-host}" in
    host)
      mode="host"
      resolved_path="$default_host_path"
      effective_selector="host"
      ;;
    project)
      mode="project"
      resolved_path="$project_path"
      ;;
    fresh)
      mode="fresh"
      resolved_path=""
      ;;
    *)
      mode="path"
      resolved_path="$(expand_host_config_path "$effective_selector")"
      ;;
  esac

  printf '%s|%s|%s\n' "$mode" "$effective_selector" "$resolved_path"
}

resolve_auth_file_path() {
  local selector_value="$1"
  local auth_base_dir="$2"

  if [ -n "$selector_value" ]; then
    case "$selector_value" in
      /*|./*|../*|~|~/*)
        expand_host_selector_path "$selector_value"
        return 0
        ;;
      *)
        if [ -z "$auth_base_dir" ]; then
          printf '%s\n' ""
        else
          printf '%s/%s.json\n' "$auth_base_dir" "$selector_value"
        fi
        return 0
        ;;
    esac
  fi

  printf '%s\n' ""
}

append_split_arg_values() {
  local flag="$1"
  local specs="$2"

  [ -n "$specs" ] || return 0

  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    ARGS+=( "$flag" "$entry" )
  done < <(split_csv_or_lines "$specs")
}

mount_standard_engine() {
  local engine="$1"

  case "$engine" in
    codex)
      mount_engine "codex" "$CODEX_CONFIG_MODE" "$CODEX_HOST_CONFIG" "/cache/.codex" \
        "CODEX_HOME=/cache/.codex,CODEX_CONFIG_DIR=/cache/.codex" \
        "CODEX_AUTH" "$CODEX_AUTH_BASE" "auth.json"
      ;;
    opencode)
      mount_engine "opencode" "$OPENCODE_CONFIG_MODE" "$OPENCODE_HOST_CONFIG" "/cache/.config/opencode" \
        "OPENCODE_CONFIG_DIR=/cache/.config/opencode" \
        "OPENCODE_AUTH" "$OPENCODE_AUTH_BASE" "opencode.json"
      ;;
    claude)
      mount_engine "claude" "$CLAUDE_CONFIG_MODE" "$CLAUDE_HOST_CONFIG" "/cache/.claude" \
        "CLAUDE_CONFIG_DIR=/cache/.claude" \
        "CLAUDE_AUTH" "$CLAUDE_AUTH_BASE" ".credentials.json"
      ;;
    omp)
      mount_engine "omp" "host" "$OMP_HOST_CONFIG" "/cache/.omp" "" "" "" "" ""
      ;;
    *)
      echo "[agent] ERROR: unsupported engine mount '$engine'" >&2
      exit 1
      ;;
  esac
}

mount_tool_configs() {
  case "$TOOL" in
    codex | opencode | claude | omp)
      mount_standard_engine "$TOOL"
      ;;
    codemachine)
      mount_standard_engine codex
      mount_standard_engine opencode
      mount_standard_engine claude
      ;;
  esac
}

prepare_tool_cache_dirs() {
  TOOL_CACHE_DIR="$CACHE_DIR/tools/$TOOL"
  mkdir -p "$TOOL_CACHE_DIR"
  mkdir -p "$TOOL_CACHE_DIR/nix/profiles" "$TOOL_CACHE_DIR/nix/gcroots"
  mkdir -p "$CACHE_DIR/.config/direnv" "$CACHE_DIR/.config"
  cat > "$CACHE_DIR/.config/direnv/direnvrc" <<'EOF_DIRENV'
source /etc/direnv/direnvrc
EOF_DIRENV
}

build_nix_config() {
  Z_SUFFIX=""
  if [ "$OS_NAME" = "Linux" ]; then
    Z_SUFFIX=",Z"
  fi

  WORKSPACE_PATH="${AGENT_WORKSPACE_PATH:-$PWD}"
  if [ ! -d "$WORKSPACE_PATH" ]; then
    echo "[agent] ERROR: workspace path is not a directory: $WORKSPACE_PATH" >&2
    exit 1
  fi
  WORKSPACE_PATH="$(cd "$WORKSPACE_PATH" && pwd -P)"
  WORKSPACE_RUNTIME_PATH="/cache/need/bin:/bin:/usr/bin:/usr/local/bin:$WORKSPACE_PATH/node_modules/.bin"

  NIX_CONFIG="sandbox = false
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY"
  if [ "${AGENT_USE_LOCAL_BINCACHE:-1}" = "1" ]; then
    NIX_CONFIG="$NIX_CONFIG
extra-substituters = file:///nixcache"
  fi
  if [ "${AGENT_LOCAL_BINCACHE_ALLOW_UNSIGNED:-0}" = "1" ]; then
    NIX_CONFIG="$NIX_CONFIG
require-sigs = false"
  fi
}

build_base_container_args() {
  CONTAINER_NAME="agent-${TOOL}-$(printf '%s%s' "${RANDOM:-0}" "${RANDOM:-0}" | tr -cd 'a-zA-Z0-9' | head -c 12)"
  CONTAINER_NAME="${CONTAINER_NAME:0:63}"

  ARGS=(
    --rm
    --name "$CONTAINER_NAME"
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --tmpfs /tmp:rw,exec,nosuid,nodev,size=512m,mode=1777
    --memory="${AGENT_MEMORY_LIMIT:-4g}"
    --cpus="${AGENT_CPU_LIMIT:-2}"
    --pids-limit="${AGENT_PIDS_LIMIT:-512}"
    -w "$WORKSPACE_PATH"
    -v "$TOOL_CACHE_DIR:/cache:rw${Z_SUFFIX}"
    -v "$WORKSPACE_PATH:$WORKSPACE_PATH:rw${Z_SUFFIX}"
    -e HOME=/cache
    -e XDG_CACHE_HOME=/cache
    -e TOOL_CACHE=/cache
    -e CODEX_CACHE=/cache
    -e PATH="$WORKSPACE_RUNTIME_PATH"
    -e NIX_CONFIG="$NIX_CONFIG"
  )
}

append_nix_mount_args() {
  if [ "$OS_NAME" = "Linux" ] && [ -d "/nix/store" ]; then
    ARGS+=( -v "/nix/store:/nix/store:ro" )
  fi

  if [ -n "${AGENT_NIX_BINCACHE_DIR:-}" ]; then
    ARGS+=( -v "${AGENT_NIX_BINCACHE_DIR}:/nixcache:ro${Z_SUFFIX}" )
  else
    ARGS+=( -v "agent-nix-bincache:/nixcache:rw" )
  fi
}

append_runtime_identity_args() {
  if [ "$RUNTIME" = "podman" ]; then
    if [ "$OS_NAME" = "Darwin" ]; then
      ARGS+=( --network=host )
    else
      ARGS+=( --userns=keep-id )
      if podman info --format '{{.Host.Slirp4NetNS.Executable}}' 2>/dev/null | grep -q slirp4netns; then
        ARGS+=( --network=slirp4netns:allow_host_loopback=true )
      else
        ARGS+=( --network=host )
        echo "[agent] warning: slirp4netns unavailable, falling back to --network=host" >&2
      fi
    fi
  else
    ARGS+=( --user "$(id -u):$(id -g)" )
  fi
}

append_host_socket_args() {
  if [ -f "$HOST_HOME/.gitconfig" ]; then
    ARGS+=( -v "$HOST_HOME/.gitconfig:/cache/.gitconfig:ro${Z_SUFFIX}" )
  fi

  if [ "${NEED_HELPER_MODE:-0}" = "1" ] && [ -n "${NEED_HELPER_DIR:-}" ] && [ -d "$NEED_HELPER_DIR" ]; then
    ARGS+=( -v "$NEED_HELPER_DIR:/run/agent-nix-helper:rw${Z_SUFFIX}" )
    ARGS+=( -e AGENT_NEED_HELPER=1 )
    ARGS+=( -e AGENT_NEED_HELPER_DIR=/run/agent-nix-helper )
  fi

  case "${CONTAINER_API_MODE:-none}" in
    podman-session)
      if [ -n "${CONTAINER_API_RUN_DIR:-}" ] && [ -d "$CONTAINER_API_RUN_DIR" ]; then
        ARGS+=( -v "$CONTAINER_API_RUN_DIR:/run/agent-container-api:ro${Z_SUFFIX}" )
        ARGS+=( -e AGENT_CONTAINER_API=podman-session )
        ARGS+=( -e AGENT_CONTAINER_API_SOCKET=/run/agent-container-api/podman.sock )
        ARGS+=( -e CONTAINER_HOST=unix:///run/agent-container-api/podman.sock )
        ARGS+=( -e DOCKER_HOST=unix:///run/agent-container-api/podman.sock )
        ARGS+=( -e TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/run/agent-container-api/podman.sock )
      fi
      ;;
    podman-host)
      if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/podman/podman.sock" ]; then
        ARGS+=( -v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock:rw${Z_SUFFIX}" )
        ARGS+=( -v "$XDG_RUNTIME_DIR/podman/podman.sock:/run/podman/podman.sock:rw${Z_SUFFIX}" )
        ARGS+=( -e DOCKER_HOST=unix:///var/run/docker.sock )
        ARGS+=( -e CONTAINER_HOST=unix:///run/podman/podman.sock )
      fi
      ;;
    docker-host)
      if [ -S /var/run/docker.sock ]; then
        ARGS+=( -v "/var/run/docker.sock:/var/run/docker.sock:rw${Z_SUFFIX}" )
        ARGS+=( -e DOCKER_HOST=unix:///var/run/docker.sock )
      fi
      ;;
  esac

  if [ "${AGENT_ALLOW_PODMAN_SOCKET:-0}" = "1" ] && [ -z "${AGENT_CONTAINER_API:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/podman/podman.sock" ]; then
    ARGS+=( -v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock:rw${Z_SUFFIX}" )
    ARGS+=( -v "$XDG_RUNTIME_DIR/podman/podman.sock:/run/podman/podman.sock:rw${Z_SUFFIX}" )
    ARGS+=( -e DOCKER_HOST=unix:///var/run/docker.sock )
    ARGS+=( -e CONTAINER_HOST=unix:///run/podman/podman.sock )
  fi

  if [ "${AGENT_ALLOW_DOCKER_SOCKET:-0}" = "1" ] && [ -z "${AGENT_CONTAINER_API:-}" ] && [ -S /var/run/docker.sock ]; then
    ARGS+=( -v "/var/run/docker.sock:/var/run/docker.sock:rw${Z_SUFFIX}" )
    ARGS+=( -e DOCKER_HOST=unix:///var/run/docker.sock )
  fi

  if [ "${AGENT_ALLOW_NIX_DAEMON_SOCKET:-0}" = "1" ] && [ -S /nix/var/nix/daemon-socket/socket ]; then
    ARGS+=( -v /nix/var/nix/daemon-socket/socket:/nix/var/nix/daemon-socket/socket:rw )
  fi
}

append_dev_env_args() {
  local env_spec=""
  local key=""
  local value=""
  local runtime_path="$WORKSPACE_RUNTIME_PATH"

  if [ -n "${DEV_ENV_ENV_FILE:-}" ] && [ -f "$DEV_ENV_ENV_FILE" ]; then
    while IFS= read -r env_spec; do
      [ -n "$env_spec" ] || continue
      key="${env_spec%%=*}"
      value="${env_spec#*=}"

      if [ "$key" = "PATH" ]; then
        ARGS+=( -e "PATH=${runtime_path}:$value" )
        continue
      fi

      ARGS+=( -e "$env_spec" )
    done < "$DEV_ENV_ENV_FILE"
  fi
}

append_workspace_git_args() {
  if [ -f "$WORKSPACE_PATH/.git" ]; then
    GITDIR_REL="$(sed -n 's/^gitdir:[[:space:]]*//p' "$WORKSPACE_PATH/.git" | head -n1 || true)"
    if [ -n "$GITDIR_REL" ]; then
      if [ "${GITDIR_REL#/}" != "$GITDIR_REL" ]; then
        MAIN_GIT_DIR="$GITDIR_REL"
      else
        MAIN_GIT_DIR="$(cd "$WORKSPACE_PATH" && cd "$GITDIR_REL" && pwd -P)"
      fi
      if [ -d "$MAIN_GIT_DIR" ]; then
        ARGS+=( -v "$MAIN_GIT_DIR:$MAIN_GIT_DIR:rw${Z_SUFFIX}" )
      fi
    fi
  fi
}

append_auto_mount_dir_args() {
  [ -n "${AGENT_AUTO_MOUNT_DIRS:-}" ] || return 0

  while IFS= read -r MOUNT_NAME; do
    [ -z "$MOUNT_NAME" ] && continue
    MOUNT_DIR=""
    SEARCH_DIR="$PWD"
    while [ "$SEARCH_DIR" != "/" ]; do
      if [ -d "$SEARCH_DIR/$MOUNT_NAME" ]; then
        MOUNT_DIR="$SEARCH_DIR/$MOUNT_NAME"
        break
      fi
      SEARCH_DIR="$(dirname "$SEARCH_DIR")"
    done
    if [ -n "$MOUNT_DIR" ]; then
      ARGS+=( -v "$MOUNT_DIR:/$MOUNT_NAME:rw${Z_SUFFIX}" )
    fi
  done < <(split_csv_or_lines "$AGENT_AUTO_MOUNT_DIRS")
}

append_passthrough_env_args() {
  local key value prefix

  DEFAULT_PASS_ENV_PREFIXES=$'DEPLOYMENT_STAGE\nDEBUG\nGIT_ALLOW\nTESTCONTAINERS_HOST_OVERRIDE\nTESTCONTAINERS_RYUK_DISABLED\nOPENAI_\nANTHROPIC_\nOPENCODE_\nCLAUDE_\nCODEX_\nOMP_\nPI_\nAGENT_'
  PASS_ENV_PREFIXES="${AGENT_PASS_ENV_PREFIXES:-$DEFAULT_PASS_ENV_PREFIXES}"

  while IFS='=' read -r key value; do
    while IFS= read -r prefix; do
      [ -z "$prefix" ] && continue
      case "$key" in
        "$prefix"*)
          ARGS+=( -e "$key=$value" )
          break
          ;;
      esac
    done < <(split_csv_or_lines "$PASS_ENV_PREFIXES")
  done < <(env)
}

append_extra_device_args() {
  local device_specs="${AGENT_EXTRA_DEVICES:-}"

  if [ "${AGENT_ALLOW_KVM:-0}" = "1" ]; then
    if [ -n "$device_specs" ]; then
      device_specs="/dev/kvm
$device_specs"
    else
      device_specs="/dev/kvm"
    fi
  fi

  append_split_arg_values --device "$device_specs"
}

resolve_tool_config_roots() {
  OMP_AGENT_HOST_DIR="${PI_CODING_AGENT_DIR:-${OMP_CODING_AGENT_DIR:-$HOST_HOME/.omp/agent}}"
  OMP_HOST_CONFIG="$(dirname "$OMP_AGENT_HOST_DIR")"

  CODEX_CONFIG_DEFAULT_HOST="$HOST_HOME/.codex"
  OPENCODE_CONFIG_DEFAULT_HOST="$HOST_HOME/.config/opencode"
  CLAUDE_CONFIG_DEFAULT_HOST="$HOST_HOME/.claude"

  CODEX_CONFIG_PROJECT_PATH="$PROJECT_ROOT/.codex"
  OPENCODE_CONFIG_PROJECT_PATH="$PROJECT_ROOT/.config/opencode"
  CLAUDE_CONFIG_PROJECT_PATH="$PROJECT_ROOT/.claude"

  IFS='|' read -r CODEX_CONFIG_MODE CODEX_CONFIG_SELECTOR CODEX_HOST_CONFIG <<EOF
$(resolve_config_root "${CODEX_CONFIG:-}" "$CODEX_CONFIG_DEFAULT_HOST" "$CODEX_CONFIG_PROJECT_PATH")
EOF
  IFS='|' read -r OPENCODE_CONFIG_MODE OPENCODE_CONFIG_SELECTOR OPENCODE_HOST_CONFIG <<EOF
$(resolve_config_root "${OPENCODE_CONFIG:-}" "$OPENCODE_CONFIG_DEFAULT_HOST" "$OPENCODE_CONFIG_PROJECT_PATH")
EOF
  IFS='|' read -r CLAUDE_CONFIG_MODE CLAUDE_CONFIG_SELECTOR CLAUDE_HOST_CONFIG <<EOF
$(resolve_config_root "${CLAUDE_CONFIG:-}" "$CLAUDE_CONFIG_DEFAULT_HOST" "$CLAUDE_CONFIG_PROJECT_PATH")
EOF

  AGENT_AUTH_HOME="${AGENT_AUTH_HOME:-$HOST_HOME/.local/share/agent-sandbox/auth}"
  CODEX_AUTH_BASE="${CODEX_AUTH_BASE_DIR:-$AGENT_AUTH_HOME/codex}"
  OPENCODE_AUTH_BASE="${OPENCODE_AUTH_BASE_DIR:-$AGENT_AUTH_HOME/opencode}"
  CLAUDE_AUTH_BASE="${CLAUDE_AUTH_BASE_DIR:-$AGENT_AUTH_HOME/claude}"
}

append_stdio_and_target_args() {
  ARGS+=( -i )
  if [ "${AGENT_FORCE_TTY:-0}" = "1" ] || { [ -t 0 ] && [ -t 1 ]; }; then
    ARGS+=( -t )
  fi

  ARGS+=( --entrypoint "/bin/$TOOL" )
  RUN_TARGET="$IMAGE_ID"
  if [ "$MODE" = "podman-rootfs" ]; then
    ARGS+=( --rootfs )
    RUN_TARGET="$ROOTFS_IMAGE_ARG"
  fi
  ARGS+=( "$RUN_TARGET" )
  if [ "${#REMAINING_ARGS[@]}" -gt 0 ]; then
    ARGS+=( "${REMAINING_ARGS[@]}" )
  fi
}

build_container_args() {
  prepare_tool_cache_dirs
  build_nix_config
  build_base_container_args
  append_nix_mount_args
  append_runtime_identity_args
  append_host_socket_args
  append_dev_env_args
  append_workspace_git_args

  append_split_arg_values -e "${AGENT_EXTRA_ENV:-}"
  append_auto_mount_dir_args
  append_split_arg_values -v "${AGENT_EXTRA_MOUNTS:-}"
  append_extra_device_args
  append_passthrough_env_args
  resolve_tool_config_roots
  mount_tool_configs
  append_stdio_and_target_args
}
