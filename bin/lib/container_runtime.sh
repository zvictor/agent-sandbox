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
    if ! mkdir -p "$mount_source"; then
      echo "[agent] ERROR: could not create config directory for $engine: $mount_source" >&2
      exit 1
    fi
    require_runtime_config_dir_access "$engine" "$mount_source"
    ARGS+=( -v "$mount_source:$container_config_dir:rw${Z_SUFFIX}" )
    return 0
  fi

  mount_source="$(ensure_runtime_config_dir "$engine" "$config_mode" "$host_config_dir")"
  if [ -z "$mount_source" ]; then
    mount_source="$CACHE_DIR/empty-config/$engine"
    mkdir -p "$mount_source"
  fi
  mount_source="$(resolve_mount_dir "$mount_source")"

  ARGS+=( -v "$mount_source:$container_config_dir:rw${Z_SUFFIX}" )

  if [ -n "$auth_env_name" ]; then
    selector_value="${!auth_env_name:-}"
  fi

  if [ "$engine" = "codex" ]; then
    initialize_codex_config_file "$mount_source" "$selector_value" "$config_mode"
  fi

  # Synthesize auth.json from OPENAI_API_KEY when no CODEX_AUTH slot is set
  if [ "$engine" = "codex" ] && [ -z "$selector_value" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
    local synth_auth_dir
    synth_auth_dir="$(mktemp -d "$HELPER_TMPDIR/codex-auth.XXXXXX")"
    local synth_json
    synth_json=$(jq -n \
      --arg key "$OPENAI_API_KEY" \
      '{OPENAI_API_KEY: $key, email: "apikey@example.com", planType: "pro"}')
    printf '%s\n' "$synth_json" > "$synth_auth_dir/auth.json"
    chmod 600 "$synth_auth_dir/auth.json"
    prepare_codex_auth_mount_target "$mount_source/$active_credentials_file"
    ARGS+=( -v "$synth_auth_dir/auth.json:$container_config_dir/$active_credentials_file:ro${Z_SUFFIX}" )
    return 0
  fi

  resolved_auth_path="$(resolve_auth_file_path "$selector_value" "$auth_base_dir")"
  if [ -n "$resolved_auth_path" ]; then
    if [ ! -f "$resolved_auth_path" ] || [ ! -r "$resolved_auth_path" ]; then
      echo "[agent] ERROR: auth selector '$selector_value' for $engine did not resolve to a readable file: $resolved_auth_path" >&2
      exit 1
    fi
    if [ "$engine" = "codex" ]; then
      prepare_codex_auth_mount_target "$mount_source/$active_credentials_file"
    fi
    ARGS+=( -v "$resolved_auth_path:$container_config_dir/$active_credentials_file:ro${Z_SUFFIX}" )
    ARGS+=( -e "${engine^^}_AUTH=$selector_value" )
  fi
}

initialize_codex_config_file() {
  local config_dir="$1"
  local auth_selector="$2"
  local config_mode="${3:-host}"
  local config_file="$config_dir/config.toml"
  local host_config_file="$HOST_HOME/.codex/config.toml"
  local pending_config=""

  if [ -e "$config_file" ]; then
    return 0
  fi

  pending_config="$(mktemp "$config_dir/.config.toml.XXXXXX")"
  if ! {
    printf 'mcp_oauth_credentials_store = "file"\n'
    if [ -z "$auth_selector" ] && [ -n "${OPENAI_API_KEY:-}" ] && [ -n "${OPENAI_BASE_URL:-}" ]; then
      printf 'openai_base_url = %s\n' "$(jq -Rn --arg value "$OPENAI_BASE_URL" '$value')"
    fi
    if [ "$config_mode" != "project" ] && [ "$host_config_file" != "$config_file" ] && [ -f "$host_config_file" ]; then
      sed -e '/^mcp_oauth_credentials_store[[:space:]]*=/d' -e '/^openai_base_url[[:space:]]*=/d' "$host_config_file"
    fi
  } > "$pending_config"; then
    rm -f "$pending_config"
    echo "[agent] ERROR: could not initialize Codex config file: $config_file" >&2
    exit 1
  fi

  if ! mv "$pending_config" "$config_file"; then
    rm -f "$pending_config"
    echo "[agent] ERROR: could not install Codex config file: $config_file" >&2
    exit 1
  fi
}

prepare_codex_auth_mount_target() {
  local target_file="$1"

  if [ -L "$target_file" ] || { [ -e "$target_file" ] && [ ! -f "$target_file" ]; }; then
    echo "[agent] ERROR: Codex auth mount target must be a regular file: $target_file" >&2
    exit 1
  fi
  if [ -e "$target_file" ]; then
    return 0
  fi

  if ! : > "$target_file" || ! chmod 600 "$target_file"; then
    echo "[agent] ERROR: could not prepare Codex auth mount target: $target_file" >&2
    exit 1
  fi
  CODEX_AUTH_PLACEHOLDER="$target_file"
}

prepare_codex_project_managed_config() {
  local managed_dir="$CODEX_MANAGED_CONFIG_PROJECT_DIR"
  local managed_file="$managed_dir/managed_config.toml"
  local project_config="$CODEX_HOST_CONFIG/config.toml"
  local host_config="$HOST_HOME/.codex/config.toml"
  local legacy_config="$CODEX_CONFIG_LEGACY_PROJECT_PATH/config.toml"
  local source_config=""
  local pending_config=""

  if [ -L "$managed_dir" ] || { [ -e "$managed_dir" ] && [ ! -d "$managed_dir" ]; }; then
    echo "[agent] ERROR: project Codex config path must be a real directory: $managed_dir" >&2
    exit 1
  fi
  if ! mkdir -p "$managed_dir"; then
    echo "[agent] ERROR: could not create project Codex config directory: $managed_dir" >&2
    exit 1
  fi

  if [ -L "$managed_file" ] || { [ -e "$managed_file" ] && [ ! -f "$managed_file" ]; }; then
    echo "[agent] ERROR: project Codex managed config must be a regular file: $managed_file" >&2
    exit 1
  fi
  if [ -e "$managed_file" ]; then
    if [ ! -r "$managed_file" ]; then
      echo "[agent] ERROR: project Codex managed config is not readable: $managed_file" >&2
      exit 1
    fi
    return 0
  fi

  if [ -f "$legacy_config" ] && [ -r "$legacy_config" ]; then
    source_config="$legacy_config"
  elif [ -f "$project_config" ] && [ -r "$project_config" ]; then
    source_config="$project_config"
  elif [ "$host_config" != "$project_config" ] && [ -f "$host_config" ] && [ -r "$host_config" ]; then
    source_config="$host_config"
  fi

  pending_config="$(mktemp "$managed_dir/.managed_config.toml.XXXXXX")"
  if ! {
    printf 'mcp_oauth_credentials_store = "file"\n'
    if [ -n "${OPENAI_BASE_URL:-}" ]; then
      printf 'openai_base_url = %s\n' "$(jq -Rn --arg value "$OPENAI_BASE_URL" '$value')"
    fi
    if [ -n "$source_config" ]; then
      sed -e '/^mcp_oauth_credentials_store[[:space:]]*=/d' -e '/^openai_base_url[[:space:]]*=/d' "$source_config"
    fi
  } > "$pending_config"; then
    rm -f "$pending_config"
    echo "[agent] ERROR: could not initialize project Codex managed config: $managed_file" >&2
    exit 1
  fi

  if ! chmod u+rw "$pending_config" || ! mv "$pending_config" "$managed_file"; then
    rm -f "$pending_config"
    echo "[agent] ERROR: could not install project Codex managed config: $managed_file" >&2
    exit 1
  fi
}

resolve_mount_dir() {
  local dir_path="$1"

  (
    cd "$dir_path" &&
    pwd -P
  )
}

current_sandbox_profile() {
  printf '%s\n' "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}"
}

remote_container_mode() {
  [ "${AGENT_REMOTE_CONTAINER_MODE:-0}" = "1" ]
}

firecracker_host_profile() {
  [ "$(current_sandbox_profile)" = "firecracker-host" ]
}

rootless_linux_profile() {
  [ "$(current_sandbox_profile)" = "rootless-linux" ]
}

podman_runtime_cmd() {
  if firecracker_host_profile; then
    sudo -n podman "$@"
    return
  fi

  podman "$@"
}

runtime_run_label() {
  if [ "${RUNTIME:-}" = "podman" ] && firecracker_host_profile; then
    printf '%s\n' "sudo -n podman"
    return
  fi

  printf '%s\n' "${RUNTIME:-unknown}"
}

log_container_run_args() {
  local arg=""
  local expect_env_value=0
  local env_spec=""
  local -a rendered_args=()

  for arg in "${ARGS[@]}"; do
    if [ "$expect_env_value" = "1" ]; then
      case "$arg" in
        *=*) rendered_args+=( "${arg%%=*}=REDACTED" ) ;;
        *) rendered_args+=( "REDACTED" ) ;;
      esac
      expect_env_value=0
      continue
    fi

    case "$arg" in
      -e|--env)
        rendered_args+=( "$arg" )
        expect_env_value=1
        ;;
      --env=*)
        env_spec="${arg#--env=}"
        case "$env_spec" in
          *=*) rendered_args+=( "--env=${env_spec%%=*}=REDACTED" ) ;;
          *) rendered_args+=( "--env=REDACTED" ) ;;
        esac
        ;;
      *)
        rendered_args+=( "$arg" )
        ;;
    esac
  done

  printf '[agent] running: %s run' "$(runtime_run_label)" >&2
  for arg in "${rendered_args[@]}"; do
    printf ' %q' "$arg" >&2
  done
  printf '\n' >&2
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

require_runtime_config_dir_access() {
  local engine="$1"
  local resolved_path="$2"
  local config_file=""

  if [ ! -r "$resolved_path" ] || [ ! -w "$resolved_path" ] || [ ! -x "$resolved_path" ]; then
    echo "[agent] ERROR: config directory for $engine must be readable, writable, and searchable: $resolved_path" >&2
    echo "[agent] Hint: fix ownership/permissions on the host path, or select a different config root." >&2
    exit 1
  fi

  case "$engine" in
    codex)
      config_file="$resolved_path/config.toml"
      ;;
  esac

  if [ -n "$config_file" ] && [ -e "$config_file" ] && { [ ! -r "$config_file" ] || [ ! -w "$config_file" ]; }; then
    echo "[agent] ERROR: config file for $engine must be readable and writable: $config_file" >&2
    echo "[agent] Hint: fix ownership/permissions on the host file, or select a different config root." >&2
    exit 1
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
      if ! mkdir -p "$resolved_path"; then
        echo "[agent] ERROR: could not create config directory for $engine: $resolved_path" >&2
        exit 1
      fi
      require_runtime_config_dir_access "$engine" "$resolved_path"
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

runtime_env_key_is_reserved() {
  case "$1" in
    AGENT_NEED_HELPER_DIR|AGENT_RUNTIME_LEASE_ID|AGENT_RUNTIME_RECEIPTS_DIR)
      return 0
      ;;
    AGENT_ROOTLESS_LINUX_TOOL|XDG_RUNTIME_DIR)
      rootless_linux_profile
      return
      ;;
    *)
      return 1
      ;;
  esac
}

append_extra_env_args() {
  local specs="${AGENT_EXTRA_ENV:-}"
  local entry=""
  local key=""

  [ -n "$specs" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    key="${entry%%=*}"
    if runtime_env_key_is_reserved "$key"; then
      echo "[agent] ERROR: AGENT_EXTRA_ENV cannot override runtime-owned variable: $key" >&2
      exit 1
    fi
    ARGS+=( -e "$entry" )
  done < <(split_csv_or_lines "$specs")
}

mount_standard_engine() {
  local engine="$1"

  case "$engine" in
    codex)
      if [ "$CODEX_CONFIG_MODE" = "project" ]; then
        migrate_legacy_codex_project_state
        prepare_codex_project_managed_config
      fi
      mount_engine "codex" "$CODEX_CONFIG_MODE" "$CODEX_HOST_CONFIG" "/cache/.codex" \
        "CODEX_HOME=/cache/.codex,CODEX_CONFIG_DIR=/cache/.codex" \
        "CODEX_AUTH" "$CODEX_AUTH_BASE" "auth.json"
      if [ "$CODEX_CONFIG_MODE" = "project" ]; then
        ARGS+=( -e "AGENT_CODEX_ROLLOUT_SOURCE_HOME=$CODEX_CONFIG_PROJECT_PATH" )
        ARGS+=( -v "$CODEX_MANAGED_CONFIG_PROJECT_DIR:/etc/codex:ro${Z_SUFFIX}" )
      fi
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
      mount_engine "omp" "host" "$OMP_HOST_CONFIG" "/cache/.omp" "" "" "" ""
      ;;
    commandcode)
      mount_engine "commandcode" "$COMMANDCODE_CONFIG_MODE" "$COMMANDCODE_HOST_CONFIG" "/cache/.commandcode" \
        "COMMANDCODE_CONFIG_DIR=/cache/.commandcode" \
        "COMMANDCODE_AUTH" "$COMMANDCODE_AUTH_BASE" "auth.json"
      ;;
    *)
      echo "[agent] ERROR: unsupported engine mount '$engine'" >&2
      exit 1
      ;;
  esac
}

mount_tool_configs() {
  case "$TOOL" in
    codex | opencode | claude | omp | commandcode)
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

prepare_path_guard_dir() {
  local guarded_command=""

  PATH_GUARD_CONTAINER_DIR="/run/agent-path-guard"
  PATH_GUARD_HOST_DIR="$(mktemp -d "$HELPER_TMPDIR/path-guard.XXXXXX")"

  for guarded_command in git sh nix nix-shell need; do
    ln -s "/bin/$guarded_command" "$PATH_GUARD_HOST_DIR/$guarded_command"
  done

  if firecracker_host_profile; then
    ln -s "/bin/agent-firecracker-podman" "$PATH_GUARD_HOST_DIR/podman"
  fi
}

runtime_path_scope_key() {
  local value="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print substr($1,1,16)}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print substr($1,1,16)}'
  else
    printf '%s' "$value" | tr -cd 'a-zA-Z0-9' | head -c 16
  fi
}

copy_codex_state_tree_without_clobber() {
  local source_dir="$1"
  local target_dir="$2"
  local source_path=""
  local relative_path=""
  local target_path=""

  [ -d "$source_dir" ] || return 0
  if ! mkdir -p "$target_dir"; then
    echo "[agent] ERROR: could not prepare Codex session migration target: $target_dir" >&2
    exit 1
  fi

  while IFS= read -r source_path; do
    relative_path="${source_path#$source_dir/}"
    target_path="$target_dir/$relative_path"
    if [ -d "$source_path" ] && [ ! -L "$source_path" ]; then
      mkdir -p "$target_path"
    elif [ ! -e "$target_path" ] && [ ! -L "$target_path" ]; then
      mkdir -p "$(dirname "$target_path")"
      cp -a "$source_path" "$target_path"
      CODEX_MIGRATED_FILE_COUNT=$((CODEX_MIGRATED_FILE_COUNT + 1))
    fi
  done < <(find "$source_dir" -mindepth 1 -print)
}

migrate_legacy_codex_project_state() {
  local legacy_root="$CODEX_CONFIG_LEGACY_PROJECT_PATH"
  local project_root="$CODEX_CONFIG_PROJECT_PATH"
  local marker_dir="$CODEX_MANAGED_CONFIG_PROJECT_DIR"
  local marker_file="$marker_dir/cache-state-migration-v1"
  local source_file=""
  local target_file=""

  [ -d "$legacy_root" ] || return 0
  [ ! -e "$marker_file" ] || return 0

  if ! mkdir -p "$project_root" "$marker_dir"; then
    echo "[agent] ERROR: could not prepare project-local Codex state migration" >&2
    exit 1
  fi

  CODEX_MIGRATED_FILE_COUNT=0
  copy_codex_state_tree_without_clobber "$legacy_root/sessions" "$project_root/sessions"
  copy_codex_state_tree_without_clobber "$legacy_root/archived_sessions" "$project_root/archived_sessions"

  for source_file in "$legacy_root/history.jsonl" "$legacy_root"/state*.sqlite*; do
    [ -f "$source_file" ] || continue
    target_file="$project_root/$(basename "$source_file")"
    if [ ! -e "$target_file" ]; then
      cp -a "$source_file" "$target_file"
      CODEX_MIGRATED_FILE_COUNT=$((CODEX_MIGRATED_FILE_COUNT + 1))
    fi
  done

  if ! printf '%s\n' "$legacy_root" > "$marker_file"; then
    echo "[agent] ERROR: could not record project-local Codex state migration" >&2
    exit 1
  fi
  if [ "$CODEX_MIGRATED_FILE_COUNT" -gt 0 ]; then
    echo "[agent] migrated $CODEX_MIGRATED_FILE_COUNT Codex state files into $project_root" >&2
    echo "[agent] preserved the previous state at $legacy_root" >&2
  fi
}

compose_runtime_path() {
  local dev_env_path="${1:-}"
  local -a path_parts=()

  path_parts+=( "$PATH_GUARD_CONTAINER_DIR" )
  if [ -n "${SUDO_RUNTIME_PATH:-}" ]; then
    path_parts+=( "$SUDO_RUNTIME_PATH" )
  fi
  path_parts+=( "$WORKSPACE_NODE_MODULES_BIN" )
  if [ -n "$dev_env_path" ]; then
    path_parts+=( "$dev_env_path" )
  fi
  path_parts+=( "$NEED_TOOLS_PATH" "$IMAGE_FALLBACK_PATH" )

  local IFS=:
  printf '%s\n' "${path_parts[*]}"
}

ssh_runtime_file_is_sensitive() {
  local source_path="$1"
  local file_name=""

  [ -f "$source_path" ] || return 0

  file_name="$(basename "$source_path")"

  case "$file_name" in
    id_*)
      case "$file_name" in
        *.pub|*-cert.pub) ;;
        *) return 0 ;;
      esac
      ;;
    *.pem|*.key|*.p12|*.pfx|*.pkcs12)
      return 0
      ;;
  esac

  if LC_ALL=C grep -Eiq 'BEGIN [A-Z0-9 ]*PRIVATE KEY' "$source_path" 2>/dev/null; then
    return 0
  fi

  return 1
}

ssh_runtime_path_escape() {
  printf '%s\n' "$1" | sed 's/[\/&|]/\\&/g'
}

rewrite_ssh_runtime_paths() {
  local target_path="$1"
  local escaped_host_ssh_dir=""

  [ -f "$target_path" ] || return 0
  if ! LC_ALL=C grep -Iq . "$target_path" 2>/dev/null; then
    return 0
  fi

  escaped_host_ssh_dir="$(ssh_runtime_path_escape "$HOST_HOME/.ssh")"
  sed -i "s|$escaped_host_ssh_dir|/cache/.ssh|g" "$target_path"
}

copy_host_ssh_runtime_files() {
  local host_ssh_dir="$1"
  local runtime_dir="$2"
  local source_path=""
  local relative_path=""
  local target_path=""

  [ -d "$host_ssh_dir" ] || return 0

  while IFS= read -r source_path; do
    [ -f "$source_path" ] || continue
    if ssh_runtime_file_is_sensitive "$source_path"; then
      continue
    fi

    relative_path="${source_path#$host_ssh_dir/}"
    target_path="$runtime_dir/$relative_path"
    if [ "$relative_path" = "config" ]; then
      target_path="$runtime_dir/config.host"
    fi

    mkdir -p "$(dirname "$target_path")"
    cp -fL "$source_path" "$target_path"
    rewrite_ssh_runtime_paths "$target_path"
  done < <(find -L "$host_ssh_dir" -type f | sort)
}

write_ssh_runtime_wrapper_config() {
  local runtime_dir="$1"
  local config_name="$2"
  local known_hosts_root="$3"
  local stable_sock_path="$4"
  local include_host_config="${5:-0}"
  local config_path="$runtime_dir/$config_name"

  cat > "$config_path" <<EOF_SSH
Host *
EOF_SSH

  if [ -n "$stable_sock_path" ]; then
    cat >> "$config_path" <<EOF_SSH
  IdentityAgent $stable_sock_path
EOF_SSH
  fi

  cat >> "$config_path" <<EOF_SSH
  UserKnownHostsFile $known_hosts_root/known_hosts $known_hosts_root/known_hosts2
EOF_SSH

  if [ "$include_host_config" = "1" ]; then
    cat >> "$config_path" <<EOF_SSH
Include $known_hosts_root/config.host
EOF_SSH
  fi
}

prepare_ssh_runtime_dir() {
  local host_ssh_dir="$HOST_HOME/.ssh"
  local stable_sock_path="/run/host-services/ssh-auth.sock"
  local host_sock=""
  local agent_config_path=""

  SSH_RUNTIME_DIR="$TOOL_CACHE_DIR/ssh-runtime"
  rm -rf "$SSH_RUNTIME_DIR"
  mkdir -p "$SSH_RUNTIME_DIR"

  copy_host_ssh_runtime_files "$host_ssh_dir" "$SSH_RUNTIME_DIR"

  host_sock="$(resolve_ssh_auth_socket)"
  if [ -n "$host_sock" ]; then
    agent_config_path="$stable_sock_path"
  fi
  if [ -n "$host_sock" ] || [ -f "$SSH_RUNTIME_DIR/config.host" ] || [ -f "$SSH_RUNTIME_DIR/known_hosts" ] || [ -f "$SSH_RUNTIME_DIR/known_hosts2" ]; then
    if [ -f "$SSH_RUNTIME_DIR/config.host" ]; then
      write_ssh_runtime_wrapper_config "$SSH_RUNTIME_DIR" "config" "/cache/.ssh" "$agent_config_path" 1
    else
      write_ssh_runtime_wrapper_config "$SSH_RUNTIME_DIR" "config" "/cache/.ssh" "$agent_config_path" 0
    fi
  fi

  if [ ! -f "$SSH_RUNTIME_DIR/config" ]; then
    rm -rf "$SSH_RUNTIME_DIR"
    SSH_RUNTIME_DIR=""
    return 0
  fi

  chmod 600 "$SSH_RUNTIME_DIR/config"
  if [ -f "$SSH_RUNTIME_DIR/config.host" ]; then
    chmod 600 "$SSH_RUNTIME_DIR/config.host"
  fi
}

build_nix_config() {
  Z_SUFFIX=""
  if [ "$OS_NAME" = "Linux" ] && ! firecracker_host_profile; then
    Z_SUFFIX=",Z"
  fi

  WORKSPACE_PATH="${AGENT_WORKSPACE_PATH:-$PWD}"
  if [ ! -d "$WORKSPACE_PATH" ]; then
    echo "[agent] ERROR: workspace path is not a directory: $WORKSPACE_PATH" >&2
    exit 1
  fi
  WORKSPACE_PATH="$(cd "$WORKSPACE_PATH" && pwd -P)"
  WORKSPACE_NODE_MODULES_BIN="$WORKSPACE_PATH/node_modules/.bin"
  NEED_CACHE_PATH="${AGENT_NEED_CACHE_DIR:-/cache/need}"
  NEED_TOOLS_PATH="${AGENT_NEED_TOOLS_DIR:-$NEED_CACHE_PATH/projects/$(runtime_path_scope_key "$PROJECT_ROOT")/bin}"
  SUDO_RUNTIME_PATH=""
  if sudo_enabled; then
    SUDO_RUNTIME_PATH="/agent-sudo/bin"
  fi
  IMAGE_FALLBACK_PATH="/bin:/usr/bin:/usr/local/bin"
  WORKSPACE_RUNTIME_PATH="$(compose_runtime_path "")"

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

sudo_enabled() {
  if firecracker_host_profile; then
    case "${AGENT_ALLOW_SUDO:-1}" in
      ""|1)
        return 0
        ;;
      0)
        echo "[agent] ERROR: AGENT_SANDBOX_PROFILE=firecracker-host requires sudo; unset AGENT_ALLOW_SUDO or set it to 1" >&2
        exit 1
        ;;
      *)
        echo "[agent] ERROR: AGENT_ALLOW_SUDO must be 0 or 1" >&2
        exit 1
        ;;
    esac
  fi

  if rootless_linux_profile; then
    case "${AGENT_ALLOW_SUDO:-0}" in
      ""|0)
        return 1
        ;;
      1)
        echo "[agent] ERROR: AGENT_SANDBOX_PROFILE=rootless-linux does not permit sudo" >&2
        exit 1
        ;;
      *)
        echo "[agent] ERROR: AGENT_ALLOW_SUDO must be 0 or 1" >&2
        exit 1
        ;;
    esac
  fi

  case "${AGENT_ALLOW_SUDO:-0}" in
    ""|0)
      return 1
      ;;
    1)
      return 0
      ;;
    *)
      echo "[agent] ERROR: AGENT_ALLOW_SUDO must be 0 or 1" >&2
      exit 1
      ;;
  esac
}

build_base_container_args() {
  if remote_container_mode && rootless_linux_profile; then
    echo "[agent] ERROR: AGENT_SANDBOX_PROFILE=rootless-linux does not support remote container mode" >&2
    exit 1
  fi

  if remote_container_mode; then
    if [ -z "${AGENT_REMOTE_RUNTIME_CONTAINER:-}" ]; then
      echo "[agent] ERROR: remote container mode requires AGENT_REMOTE_RUNTIME_CONTAINER" >&2
      exit 1
    fi
    if [ "${AGENT_REMOTE_POD_DISABLED:-0}" != "1" ] && [ -z "${AGENT_REMOTE_POD_NAME:-}" ]; then
      echo "[agent] ERROR: remote container mode requires AGENT_REMOTE_POD_NAME" >&2
      exit 1
    fi
    CONTAINER_NAME="$AGENT_REMOTE_RUNTIME_CONTAINER"
  else
    CONTAINER_NAME="agent-${TOOL}-$(printf '%s%s' "${RANDOM:-0}" "${RANDOM:-0}" | tr -cd 'a-zA-Z0-9' | head -c 12)"
    CONTAINER_NAME="${CONTAINER_NAME:0:63}"
  fi

  ARGS=(
    --name "$CONTAINER_NAME"
    --init
  )
  if rootless_linux_profile; then
    ARGS+=(
      --cgroups=split
      --cgroupns=private
      --systemd=false
      --security-opt=unmask=/sys/fs/cgroup
      --stop-signal=SIGTERM
    )
  fi
  if remote_container_mode; then
    ARGS+=( --replace -d )
    if [ "${AGENT_REMOTE_POD_DISABLED:-0}" != "1" ]; then
      ARGS+=( --pod "$AGENT_REMOTE_POD_NAME" )
    fi
  else
    ARGS+=( --rm )
  fi

  if firecracker_host_profile; then
    ARGS+=(
      --privileged
      --cap-add=NET_ADMIN
      --security-opt=label=disable
    )
  else
    ARGS+=( --cap-drop=ALL )
  fi

  if firecracker_host_profile; then
    :
  elif sudo_enabled; then
    ARGS+=(
      --cap-add=SETUID
      --cap-add=SETGID
    )
  else
    ARGS+=( --security-opt=no-new-privileges )
  fi

  ARGS+=(
    --tmpfs /tmp:rw,exec,nosuid,nodev,size=512m,mode=1777
  )

  if rootless_linux_profile; then
    ARGS+=(
      --tmpfs "/run/user/$(id -u):rw,nosuid,nodev,size=16m,mode=0700,uid=$(id -u),gid=$(id -g)"
      --tmpfs "/run/systemd/system:rw,nosuid,nodev,size=1m,mode=0755,uid=$(id -u),gid=$(id -g)"
    )
  fi

  if ! firecracker_host_profile; then
    ARGS+=(
      --memory="${AGENT_MEMORY_LIMIT:-4g}"
      --cpus="${AGENT_CPU_LIMIT:-2}"
      --pids-limit="${AGENT_PIDS_LIMIT:-512}"
    )
  fi

  ARGS+=(
    -w "$WORKSPACE_PATH"
    -v "$TOOL_CACHE_DIR:/cache:rw${Z_SUFFIX}"
    -e HOME=/cache
    -e XDG_CACHE_HOME=/cache
    -e TOOL_CACHE=/cache
    -e CODEX_CACHE=/cache
    -e LD_LIBRARY_PATH=/usr/lib:/lib
    -e PATH="$WORKSPACE_RUNTIME_PATH"
    -e AGENT_NEED_TOOLS_DIR="$NEED_TOOLS_PATH"
    -e NIX_CONFIG="$NIX_CONFIG"
  )

  if rootless_linux_profile; then
    ARGS+=( -e "XDG_RUNTIME_DIR=/run/user/$(id -u)" )
  fi
}

append_path_guard_mount_args() {
  if [ -n "${PATH_GUARD_HOST_DIR:-}" ] && [ -d "$PATH_GUARD_HOST_DIR" ]; then
    ARGS+=( -v "$PATH_GUARD_HOST_DIR:$PATH_GUARD_CONTAINER_DIR:ro${Z_SUFFIX}" )
  fi
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

append_runtime_receipt_mount_args() {
  if [ -z "${RUNTIME_LEASE_RECEIPTS_DIR:-}" ] || [ ! -d "$RUNTIME_LEASE_RECEIPTS_DIR" ]; then
    echo "[agent] ERROR: runtime lease receipt directory is unavailable" >&2
    exit 1
  fi

  ARGS+=( -v "$RUNTIME_LEASE_RECEIPTS_DIR:/run/agent-runtime-receipts:ro${Z_SUFFIX}" )
  ARGS+=( -e "AGENT_RUNTIME_LEASE_ID=$RUNTIME_LEASE_ID" )
  ARGS+=( -e "AGENT_RUNTIME_RECEIPTS_DIR=/run/agent-runtime-receipts" )
}

sanitize_runtime_account_name() {
  local raw_name="$1"

  case "$raw_name" in
    ""|[!A-Za-z_]*|*[!A-Za-z0-9_-]*)
      printf '%s\n' "agent"
      ;;
    *)
      printf '%s\n' "$raw_name"
      ;;
  esac
}

runtime_root_chown() {
  if [ "$RUNTIME" = "podman" ]; then
    if firecracker_host_profile; then
      if ! sudo -n chown 0:0 "$@"; then
        echo "[agent] ERROR: failed to prepare root-owned runtime files for firecracker-host profile" >&2
        exit 1
      fi
      return
    fi

    # With --userns=keep-id, host uid 0 in `podman unshare` maps to the
    # caller's container uid, while uid 1 maps to container root.
    if ! podman_runtime_cmd unshare chown 1:1 "$@"; then
      echo "[agent] ERROR: failed to prepare podman root-owned runtime files" >&2
      exit 1
    fi
    return
  fi

  if [ "$(id -u)" = "0" ]; then
    chown 0:0 "$@"
  fi
}

runtime_root_chmod() {
  local mode="$1"
  shift

  if [ "$RUNTIME" = "podman" ]; then
    if firecracker_host_profile; then
      if ! sudo -n chmod "$mode" "$@"; then
        echo "[agent] ERROR: failed to set runtime file modes for firecracker-host profile" >&2
        exit 1
      fi
      return
    fi

    if ! podman_runtime_cmd unshare chmod "$mode" "$@"; then
      echo "[agent] ERROR: failed to set podman runtime file modes" >&2
      exit 1
    fi
    return
  fi

  chmod "$mode" "$@"
}

prepare_runtime_identity_dir() {
  local uid gid account_name group_name sudo_source

  if [ -n "${RUNTIME_IDENTITY_HOST_DIR:-}" ] && [ -d "$RUNTIME_IDENTITY_HOST_DIR" ]; then
    return
  fi

  uid="$(id -u)"
  gid="$(id -g)"
  if remote_container_mode; then
    account_name="$(sanitize_runtime_account_name "${AGENT_REMOTE_USER:-codex}")"
  else
    account_name="$(sanitize_runtime_account_name "${USER:-${LOGNAME:-agent}}")"
  fi
  group_name="$account_name"
  if [ "$uid" = "0" ]; then
    account_name="root"
  fi
  if [ "$gid" = "0" ]; then
    group_name="root"
  fi

  RUNTIME_USER_NAME="$account_name"
  RUNTIME_IDENTITY_HOST_DIR="$(mktemp -d "$HELPER_TMPDIR/runtime-identity.XXXXXX")"

  {
    printf 'root:x:0:0:root:/root:/bin/sh\n'
    if [ "$uid" != "0" ]; then
      printf '%s:x:%s:%s:Agent Sandbox:/cache:/bin/sh\n' "$account_name" "$uid" "$gid"
    fi
  } > "$RUNTIME_IDENTITY_HOST_DIR/passwd"

  {
    printf 'root:x:0:\n'
    if [ "$gid" != "0" ]; then
      printf '%s:x:%s:%s\n' "$group_name" "$gid" "$account_name"
    fi
  } > "$RUNTIME_IDENTITY_HOST_DIR/group"

  if ! sudo_enabled; then
    mkdir -p "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo-disabled"
    return
  fi

  if [ "$MODE" = "podman-rootfs" ]; then
    sudo_source="$ROOTFS_OUT/agent-sudo/bin/sudo"
    if [ ! -x "$sudo_source" ]; then
      echo "[agent] ERROR: rootfs is missing /agent-sudo/bin/sudo" >&2
      exit 1
    fi

    mkdir -p "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin"
    cp -fL "$sudo_source" "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudo"
    cp -fL "$sudo_source" "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudoedit"

    : > "$RUNTIME_IDENTITY_HOST_DIR/sudo.conf"
    cat > "$RUNTIME_IDENTITY_HOST_DIR/sudoers" <<'EOF_SUDOERS'
Defaults env_keep += "HOME XDG_CACHE_HOME TOOL_CACHE CODEX_CACHE AGENT_* CODEX_* CLAUDE_* OPENCODE_* OMP_* PI_* COMMANDCODE_*"
ALL ALL=(ALL:ALL) NOPASSWD:SETENV: ALL
EOF_SUDOERS

    runtime_root_chown \
      "$RUNTIME_IDENTITY_HOST_DIR/passwd" \
      "$RUNTIME_IDENTITY_HOST_DIR/group" \
      "$RUNTIME_IDENTITY_HOST_DIR/sudo.conf" \
      "$RUNTIME_IDENTITY_HOST_DIR/sudoers" \
      "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudo" \
      "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudoedit"
    runtime_root_chmod 0644 \
      "$RUNTIME_IDENTITY_HOST_DIR/passwd" \
      "$RUNTIME_IDENTITY_HOST_DIR/group" \
      "$RUNTIME_IDENTITY_HOST_DIR/sudo.conf"
    runtime_root_chmod 0440 "$RUNTIME_IDENTITY_HOST_DIR/sudoers"
    runtime_root_chmod 4755 \
      "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudo" \
      "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudoedit"
  fi
}

append_runtime_identity_mount_args() {
  prepare_runtime_identity_dir

  ARGS+=( -v "$RUNTIME_IDENTITY_HOST_DIR/passwd:/etc/passwd:ro${Z_SUFFIX}" )
  ARGS+=( -v "$RUNTIME_IDENTITY_HOST_DIR/group:/etc/group:ro${Z_SUFFIX}" )
  ARGS+=( -e "USER=$RUNTIME_USER_NAME" )
  ARGS+=( -e "LOGNAME=$RUNTIME_USER_NAME" )

  if ! sudo_enabled; then
    ARGS+=( -v "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo-disabled:/agent-sudo:ro${Z_SUFFIX}" )
  elif [ "$MODE" = "podman-rootfs" ]; then
    ARGS+=( -v "$RUNTIME_IDENTITY_HOST_DIR/sudo.conf:/etc/sudo.conf:ro${Z_SUFFIX}" )
    ARGS+=( -v "$RUNTIME_IDENTITY_HOST_DIR/sudoers:/etc/sudoers:ro${Z_SUFFIX}" )
    ARGS+=( -v "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudo:/agent-sudo/bin/sudo:ro${Z_SUFFIX}" )
    ARGS+=( -v "$RUNTIME_IDENTITY_HOST_DIR/agent-sudo/bin/sudoedit:/agent-sudo/bin/sudoedit:ro${Z_SUFFIX}" )
  fi
}

append_runtime_identity_args() {
  if [ "$RUNTIME" = "podman" ]; then
    if firecracker_host_profile; then
      ARGS+=(
        --userns=host
        --cgroupns=host
        --network=host
        --user "$(id -u):$(id -g)"
      )
      return
    fi

    if [ "$OS_NAME" = "Darwin" ]; then
      ARGS+=( --network=host )
    else
      ARGS+=( --userns=keep-id )
      if remote_container_mode; then
        return
      fi
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

append_firecracker_host_args() {
  firecracker_host_profile || return 0

  ARGS+=(
    --device /dev/kvm
    --device /dev/net/tun
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw
  )
}

append_host_socket_args() {
  if [ -f "$HOST_HOME/.gitconfig" ]; then
    ARGS+=( -v "$HOST_HOME/.gitconfig:/cache/.gitconfig:ro${Z_SUFFIX}" )
  fi

  if [ "${NEED_HELPER_MODE:-0}" = "1" ] && [ -n "${NEED_HELPER_BRIDGE_DIR:-}" ] && [ -d "$NEED_HELPER_BRIDGE_DIR" ]; then
    ARGS+=( -v "$NEED_HELPER_BRIDGE_DIR:/run/agent-nix-helper:rw${Z_SUFFIX}" )
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

  append_ssh_agent_args
}

resolve_ssh_auth_socket() {
  local sock_path="${SSH_AUTH_SOCK:-}"
  local sock_dir=""

  [ -n "$sock_path" ] || return 0
  [ -S "$sock_path" ] || return 0

  case "$sock_path" in
    /*)
      printf '%s\n' "$sock_path"
      ;;
    *)
      sock_dir="$(cd "$(dirname "$sock_path")" && pwd -P)"
      printf '%s/%s\n' "$sock_dir" "$(basename "$sock_path")"
      ;;
  esac
}

append_ssh_agent_args() {
  local host_sock=""
  local container_sock="/run/host-services/ssh-auth.sock"

  if remote_container_mode && [ "${AGENT_REMOTE_FORWARD_SSH_AGENT:-0}" != "1" ]; then
    return 0
  fi

  host_sock="$(resolve_ssh_auth_socket)"
  [ -n "$host_sock" ] || return 0

  ARGS+=( -v "$host_sock:$container_sock:rw${Z_SUFFIX}" )
  ARGS+=( -e "SSH_AUTH_SOCK=$container_sock" )
}

append_ssh_runtime_mount_args() {
  prepare_ssh_runtime_dir
  if [ -n "${SSH_RUNTIME_DIR:-}" ] && [ -d "$SSH_RUNTIME_DIR" ]; then
    ARGS+=( -v "$SSH_RUNTIME_DIR:/cache/.ssh:ro${Z_SUFFIX}" )
  fi
}

append_remote_state_mount_args() {
  if ! remote_container_mode; then
    return 0
  fi
  if [ -z "${AGENT_REMOTE_RUNTIME_STATE_DIR:-}" ] || [ ! -d "$AGENT_REMOTE_RUNTIME_STATE_DIR" ]; then
    echo "[agent] ERROR: remote container mode requires AGENT_REMOTE_RUNTIME_STATE_DIR" >&2
    exit 1
  fi
  ARGS+=( -v "$AGENT_REMOTE_RUNTIME_STATE_DIR:/run/agent-remote:rw${Z_SUFFIX}" )
}

append_codex_ssh_sandbox_args() {
  local host_sock=""

  [ "$TOOL" = "codex" ] || return 0
  [ -n "${SSH_RUNTIME_DIR:-}" ] || return 0
  [ -d "$SSH_RUNTIME_DIR" ] || return 0

  ARGS+=( --add-dir /cache/.ssh )

  host_sock="$(resolve_ssh_auth_socket)"
  if [ -n "$host_sock" ]; then
    ARGS+=( --add-dir /run/host-services )
  fi
}

append_dev_env_args() {
  local env_spec=""
  local key=""
  local value=""

  if [ -n "${DEV_ENV_ENV_FILE:-}" ] && [ -f "$DEV_ENV_ENV_FILE" ]; then
    while IFS= read -r env_spec; do
      [ -n "$env_spec" ] || continue
      key="${env_spec%%=*}"
      value="${env_spec#*=}"

      if [ "$key" = "PATH" ]; then
        ARGS+=( -e "PATH=$(compose_runtime_path "$value")" )
        continue
      fi

      ARGS+=( -e "$env_spec" )
    done < "$DEV_ENV_ENV_FILE"
  fi
}

resolve_workspace_git_path() {
  local workspace_path="$1"
  local git_path="$2"

  [ -n "$git_path" ] || return 1
  if [ "${git_path#/}" != "$git_path" ]; then
    printf '%s
' "$git_path"
    return 0
  fi

  (
    cd "$workspace_path" &&
    cd "$git_path" &&
    pwd -P
  )
}

path_is_same_or_child() {
  local path="$1"
  local parent="$2"

  [ "$path" = "$parent" ] && return 0
  case "$path" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

append_same_path_mount_arg() {
  local host_dir="$1"
  local resolved_dir=""
  local mounted_dir=""

  [ -d "$host_dir" ] || return 0
  resolved_dir="$(cd "$host_dir" && pwd -P)"

  for mounted_dir in "${SAME_PATH_MOUNT_DIRS[@]}"; do
    if path_is_same_or_child "$resolved_dir" "$mounted_dir"; then
      return 0
    fi
  done

  SAME_PATH_MOUNT_DIRS+=("$resolved_dir")
  ARGS+=( -v "$resolved_dir:$resolved_dir:rw${Z_SUFFIX}" )
}

append_workspace_mount_args() {
  local workspace_git_top=""
  local workspace_git_dir=""
  local workspace_git_common_dir=""

  SAME_PATH_MOUNT_DIRS=()

  if workspace_git_top="$(git -C "$WORKSPACE_PATH" rev-parse --show-toplevel 2>/dev/null)"; then
    # Git discovery from a subdirectory needs the repo top-level, and linked
    # worktrees also need access to the shared common metadata directory.
    append_same_path_mount_arg "$workspace_git_top"

    workspace_git_common_dir="$(git -C "$WORKSPACE_PATH" rev-parse --git-common-dir 2>/dev/null || true)"
    workspace_git_common_dir="$(resolve_workspace_git_path "$WORKSPACE_PATH" "$workspace_git_common_dir" 2>/dev/null || true)"
    if [ -n "$workspace_git_common_dir" ]; then
      append_same_path_mount_arg "$workspace_git_common_dir"
    fi

    workspace_git_dir="$(git -C "$WORKSPACE_PATH" rev-parse --absolute-git-dir 2>/dev/null || true)"
    if [ -n "$workspace_git_dir" ]; then
      append_same_path_mount_arg "$workspace_git_dir"
    fi
  fi

  append_same_path_mount_arg "$WORKSPACE_PATH"
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

  if remote_container_mode && [ "${AGENT_REMOTE_ALLOW_HOST_ENV:-0}" != "1" ]; then
    DEFAULT_PASS_ENV_PREFIXES=$'DEPLOYMENT_STAGE\nDEBUG\nTESTCONTAINERS_HOST_OVERRIDE\nTESTCONTAINERS_RYUK_DISABLED'
  else
    DEFAULT_PASS_ENV_PREFIXES=$'DEPLOYMENT_STAGE\nDEBUG\nTESTCONTAINERS_HOST_OVERRIDE\nTESTCONTAINERS_RYUK_DISABLED\nOPENAI_\nANTHROPIC_\nOPENCODE_\nCLAUDE_\nCODEX_\nCOMMANDCODE_\nOMP_\nPI_\nAGENT_'
  fi
  PASS_ENV_PREFIXES="${AGENT_PASS_ENV_PREFIXES:-$DEFAULT_PASS_ENV_PREFIXES}"

  while IFS='=' read -r key value; do
    case "$key" in
      CODEX_CONFIG|OPENCODE_CONFIG|CLAUDE_CONFIG|COMMANDCODE_CONFIG|CODEX_AUTH|OPENCODE_AUTH|CLAUDE_AUTH|COMMANDCODE_AUTH|SSH_AUTH_SOCK)
        # These are launcher selectors. Once resolved to mounted config/auth
        # paths, forwarding them into the tool can make the inner CLI
        # reinterpret them against the sandbox filesystem. SSH_AUTH_SOCK is
        # mounted separately so the container sees a valid in-container path.
        continue
        ;;
      AGENT_REMOTE_TS_AUTHKEY|AGENT_REMOTE_TAILSCALE_AUTHKEY|TS_AUTHKEY|TS_AUTH_KEY|AGENT_REMOTE_TS_CLIENT_SECRET|AGENT_REMOTE_TS_CLIENT_SECRET_FILE|TS_CLIENT_SECRET)
        continue
        ;;
    esac
    if runtime_env_key_is_reserved "$key"; then
      continue
    fi

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

  if [ "${AGENT_ALLOW_KVM:-0}" = "1" ] && ! firecracker_host_profile; then
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
  COMMANDCODE_CONFIG_DEFAULT_HOST="$HOST_HOME/.commandcode"

  CODEX_CONFIG_PROJECT_PATH="$PROJECT_ROOT/.codex"
  CODEX_CONFIG_LEGACY_PROJECT_PATH="$CACHE_DIR/project-config/codex/$(runtime_path_scope_key "$PROJECT_ROOT")"
  CODEX_MANAGED_CONFIG_PROJECT_DIR="$PROJECT_ROOT/.agent-sandbox/codex"
  OPENCODE_CONFIG_PROJECT_PATH="$PROJECT_ROOT/.config/opencode"
  CLAUDE_CONFIG_PROJECT_PATH="$PROJECT_ROOT/.claude"
  COMMANDCODE_CONFIG_PROJECT_PATH="$PROJECT_ROOT/.commandcode"

  IFS='|' read -r CODEX_CONFIG_MODE CODEX_CONFIG_SELECTOR CODEX_HOST_CONFIG <<EOF
$(resolve_config_root "${CODEX_CONFIG:-}" "$CODEX_CONFIG_DEFAULT_HOST" "$CODEX_CONFIG_PROJECT_PATH")
EOF
  IFS='|' read -r OPENCODE_CONFIG_MODE OPENCODE_CONFIG_SELECTOR OPENCODE_HOST_CONFIG <<EOF
$(resolve_config_root "${OPENCODE_CONFIG:-}" "$OPENCODE_CONFIG_DEFAULT_HOST" "$OPENCODE_CONFIG_PROJECT_PATH")
EOF
  IFS='|' read -r CLAUDE_CONFIG_MODE CLAUDE_CONFIG_SELECTOR CLAUDE_HOST_CONFIG <<EOF
$(resolve_config_root "${CLAUDE_CONFIG:-}" "$CLAUDE_CONFIG_DEFAULT_HOST" "$CLAUDE_CONFIG_PROJECT_PATH")
EOF
  IFS='|' read -r COMMANDCODE_CONFIG_MODE COMMANDCODE_CONFIG_SELECTOR COMMANDCODE_HOST_CONFIG <<EOF
$(resolve_config_root "${COMMANDCODE_CONFIG:-}" "$COMMANDCODE_CONFIG_DEFAULT_HOST" "$COMMANDCODE_CONFIG_PROJECT_PATH")
EOF

  if [ "$CODEX_CONFIG_MODE" = "project" ]; then
    if [ -L "$CODEX_CONFIG_PROJECT_PATH" ]; then
      echo "[agent] ERROR: project Codex home must be a real directory, not a symlink: $CODEX_CONFIG_PROJECT_PATH" >&2
      exit 1
    fi
  fi

  AGENT_AUTH_HOME="${AGENT_AUTH_HOME:-$HOST_HOME/.local/share/agent-sandbox/auth}"
  CODEX_AUTH_BASE="${CODEX_AUTH_BASE_DIR:-$AGENT_AUTH_HOME/codex}"
  OPENCODE_AUTH_BASE="${OPENCODE_AUTH_BASE_DIR:-$AGENT_AUTH_HOME/opencode}"
  CLAUDE_AUTH_BASE="${CLAUDE_AUTH_BASE_DIR:-$AGENT_AUTH_HOME/claude}"
  COMMANDCODE_AUTH_BASE="${COMMANDCODE_AUTH_BASE_DIR:-$AGENT_AUTH_HOME/commandcode}"
}

append_stdio_and_target_args() {
  if remote_container_mode; then
    ARGS+=(
      -e "AGENT_REMOTE_STATE_DIR=/run/agent-remote"
      -e "AGENT_REMOTE_NAME=${AGENT_REMOTE_NAME:-}"
      -e "AGENT_WORKSPACE_PATH=$WORKSPACE_PATH"
      --entrypoint "/bin/agent-remote-entrypoint"
    )
    if [ "$MODE" = "podman-rootfs" ]; then
      ARGS+=( --rootfs )
      RUN_TARGET="$ROOTFS_IMAGE_ARG"
    else
      RUN_TARGET="$IMAGE_ID"
    fi
    ARGS+=( "$RUN_TARGET" )
    return 0
  fi

  ARGS+=( -i )
  if [ "${AGENT_FORCE_TTY:-0}" = "1" ] || { [ -t 0 ] && [ -t 1 ]; }; then
    ARGS+=( -t )
  fi

  if rootless_linux_profile; then
    ARGS+=(
      -e "AGENT_ROOTLESS_LINUX_TOOL=/bin/$TOOL"
      --entrypoint "/bin/agent-rootless-linux-entrypoint"
    )
  else
    ARGS+=( --entrypoint "/bin/$TOOL" )
  fi
  if [ "$MODE" = "podman-rootfs" ]; then
    ARGS+=( --rootfs )
    RUN_TARGET="$ROOTFS_IMAGE_ARG"
  else
    RUN_TARGET="$IMAGE_ID"
  fi
  ARGS+=( "$RUN_TARGET" )
  append_codex_ssh_sandbox_args
  if [ "${#REMAINING_ARGS[@]}" -gt 0 ]; then
    ARGS+=( "${REMAINING_ARGS[@]}" )
  fi
}

run_with_logical_argv0() {
  local logical_argv0="$1"
  shift

  bash -c 'exec -a "$1" bash -c '"'"'"$@"; status=$?; exit "$status"'"'"' "$1" "${@:2}"' \
    agent-runtime-supervisor "$logical_argv0" "$@"
}

run_container_runtime() {
  if [ "$RUNTIME" = "podman" ] && firecracker_host_profile; then
    run_with_logical_argv0 "$TOOL" sudo -n podman run "${ARGS[@]}"
    return
  fi

  if [ "$RUNTIME" = "podman" ] && rootless_linux_profile; then
    run_with_logical_argv0 "$TOOL" \
      systemd-run --user --scope --quiet --collect \
      --property='Delegate=cpu memory pids' -- \
      podman run "${ARGS[@]}"
    return
  fi

  run_with_logical_argv0 "$TOOL" "$RUNTIME" run "${ARGS[@]}"
}

build_container_args() {
  prepare_tool_cache_dirs
  prepare_path_guard_dir
  build_nix_config
  resolve_tool_config_roots
  build_base_container_args
  append_path_guard_mount_args
  append_nix_mount_args
  append_runtime_receipt_mount_args
  append_runtime_identity_mount_args
  append_runtime_identity_args
  append_firecracker_host_args
  append_host_socket_args
  append_ssh_runtime_mount_args
  append_remote_state_mount_args
  append_dev_env_args
  append_workspace_mount_args

  append_extra_env_args
  append_auto_mount_dir_args
  append_split_arg_values -v "${AGENT_EXTRA_MOUNTS:-}"
  append_extra_device_args
  append_passthrough_env_args
  mount_tool_configs
  append_stdio_and_target_args
}
