mount_engine() {
  local engine="$1"
  local host_config_dir="$2"
  local container_config_dir="$3"
  local env_pairs="$4"
  local profile_env_name="$5"
  local profile_base_dir="$6"
  local active_credentials_file="$7"

  append_split_arg_values -e "$env_pairs"

  local mount_source="$host_config_dir"
  if [ -z "$mount_source" ] || [ ! -d "$mount_source" ]; then
    mount_source="$CACHE_DIR/empty-config/$engine"
    mkdir -p "$mount_source"
  fi

  ARGS+=( -v "$mount_source:$container_config_dir:rw${Z_SUFFIX}" )

  if [ -n "$profile_env_name" ]; then
    local profile_name="${!profile_env_name:-}"
    if [ -n "$profile_name" ]; then
      if [ -z "$profile_base_dir" ]; then
        echo "[agent] ERROR: profile base dir is empty for $engine" >&2
        exit 1
      fi
      local profile_path="$profile_base_dir/$profile_name.json"
      if [ ! -f "$profile_path" ]; then
        echo "[agent] ERROR: profile '$profile_name' not found at $profile_path" >&2
        exit 1
      fi
      ARGS+=( -v "$profile_path:$container_config_dir/$active_credentials_file:ro${Z_SUFFIX}" )
    fi
  fi
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
      mount_engine "codex" "$CODEX_HOST_CONFIG" "/config/.codex" \
        "CODEX_HOME=/config/.codex,CODEX_CONFIG_DIR=/config/.codex" \
        "CODEX_PROFILE" "$CODEX_PROFILE_BASE" "auth.json"
      ;;
    opencode)
      mount_engine "opencode" "$OPENCODE_HOST_CONFIG" "/config/.opencode" \
        "OPENCODE_CONFIG_DIR=/config/.opencode" \
        "OPENCODE_PROFILE" "$OPENCODE_PROFILE_BASE" "opencode.json"
      ;;
    claude)
      mount_engine "claude" "$CLAUDE_HOST_CONFIG" "/config/.claude" \
        "CLAUDE_CONFIG_DIR=/config/.claude" \
        "CLAUDE_PROFILE" "$CLAUDE_PROFILE_BASE" ".credentials.json"
      ;;
    omp)
      mount_engine "omp" "$OMP_HOST_CONFIG" "/cache/.omp" "" "" "" ""
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
  mkdir -p "$CACHE_DIR/.config/direnv"
  cat > "$CACHE_DIR/.config/direnv/direnvrc" <<'EOF_DIRENV'
source /etc/direnv/direnvrc
EOF_DIRENV
}

build_nix_config() {
  Z_SUFFIX=""
  if [ "$OS_NAME" = "Linux" ]; then
    Z_SUFFIX=",Z"
  fi

  WORKSPACE_HOST_PATH="${AGENT_WORKSPACE_HOST_PATH:-$PWD}"

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
    --tmpfs /tmp:rw,exec,nosuid,nodev,size=512m
    --memory="${AGENT_MEMORY_LIMIT:-4g}"
    --cpus="${AGENT_CPU_LIMIT:-2}"
    --pids-limit="${AGENT_PIDS_LIMIT:-512}"
    -w /workspace
    -v "$TOOL_CACHE_DIR:/cache:rw${Z_SUFFIX}"
    -v "$WORKSPACE_HOST_PATH:/workspace:rw${Z_SUFFIX}"
    -e HOME=/cache
    -e XDG_CACHE_HOME=/cache
    -e TOOL_CACHE=/cache
    -e CODEX_CACHE=/cache
    -e WORKSPACE_HOST_PATH="$WORKSPACE_HOST_PATH"
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
  local runtime_path="/bin:/usr/bin:/usr/local/bin:/workspace/node_modules/.bin"

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
  if [ -f "$WORKSPACE_HOST_PATH/.git" ]; then
    GITDIR_REL="$(sed -n 's/^gitdir:[[:space:]]*//p' "$WORKSPACE_HOST_PATH/.git" | head -n1 || true)"
    if [ -n "$GITDIR_REL" ]; then
      if [ "${GITDIR_REL#/}" != "$GITDIR_REL" ]; then
        MAIN_GIT_DIR="$GITDIR_REL"
      else
        MAIN_GIT_DIR="$(cd "$WORKSPACE_HOST_PATH" && cd "$GITDIR_REL" && pwd -P)"
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

  DEFAULT_PASS_ENV_PREFIXES=$'DEPLOYMENT_STAGE\nDEBUG\nGIT_ALLOW\nTESTCONTAINERS_HOST_OVERRIDE\nTESTCONTAINERS_RYUK_DISABLED\nCODEX_PROFILE\nOPENCODE_PROFILE\nCLAUDE_PROFILE\nCODEX_CONFIG_DIR\nOPENCODE_CONFIG_DIR\nCLAUDE_CONFIG_DIR\nCODEX_PROFILE_BASE_DIR\nOPENCODE_PROFILE_BASE_DIR\nCLAUDE_PROFILE_BASE_DIR\nOPENAI_\nANTHROPIC_\nOPENCODE_\nCLAUDE_\nCODEX_\nOMP_\nPI_\nAGENT_'
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

resolve_tool_config_roots() {
  CODEX_HOST_CONFIG="${CODEX_CONFIG_DIR:-$HOST_HOME/.codex}"
  OPENCODE_HOST_CONFIG="${OPENCODE_CONFIG_DIR:-$HOST_HOME/.config/opencode}"
  CLAUDE_HOST_CONFIG="${CLAUDE_CONFIG_DIR:-$HOST_HOME/.claude}"
  OMP_AGENT_HOST_DIR="${PI_CODING_AGENT_DIR:-${OMP_CODING_AGENT_DIR:-$HOST_HOME/.omp/agent}}"
  OMP_HOST_CONFIG="$(dirname "$OMP_AGENT_HOST_DIR")"

  CODEX_PROFILE_BASE="${CODEX_PROFILE_BASE_DIR:-$HOST_HOME/.codex/profiles}"
  OPENCODE_PROFILE_BASE="${OPENCODE_PROFILE_BASE_DIR:-$OPENCODE_HOST_CONFIG/profiles}"
  CLAUDE_PROFILE_BASE="${CLAUDE_PROFILE_BASE_DIR:-$CLAUDE_HOST_CONFIG/profiles}"
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
  append_passthrough_env_args
  resolve_tool_config_roots
  mount_tool_configs
  append_stdio_and_target_args
}
