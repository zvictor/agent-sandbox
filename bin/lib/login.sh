resolve_login_args() {
  LOGIN_USE="0"
  LOGIN_TOOL=""
  LOGIN_SLOT_NAME=""
  LOGIN_TOOL_ARGS=()

  [ "$#" -ge 2 ] || {
    echo "usage: agent login codex <name> [--use] [-- <codex login args...>]" >&2
    exit 1
  }

  LOGIN_TOOL="$1"
  shift
  LOGIN_SLOT_NAME="$1"
  shift

  if ! printf '%s\n' "$LOGIN_SLOT_NAME" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    echo "[agent] invalid login slot name '$LOGIN_SLOT_NAME' (expected letters, numbers, ., _, -)" >&2
    exit 1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --use)
        LOGIN_USE="1"
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          LOGIN_TOOL_ARGS+=( "$1" )
          shift
        done
        break
        ;;
      *)
        LOGIN_TOOL_ARGS+=( "$1" )
        ;;
    esac
    shift
  done

  TOOL="$LOGIN_TOOL"

  if [ "${#LOGIN_TOOL_ARGS[@]}" -eq 0 ]; then
    case "$LOGIN_TOOL" in
      codex)
        LOGIN_TOOL_ARGS=( login --device-auth )
        ;;
      *)
        echo "[agent] login is currently only implemented for codex" >&2
        exit 1
        ;;
    esac
  else
    LOGIN_TOOL_ARGS=( login "${LOGIN_TOOL_ARGS[@]}" )
  fi
}

login_auth_env_name_for_tool() {
  case "$1" in
    codex) printf '%s\n' "CODEX_AUTH" ;;
    claude) printf '%s\n' "CLAUDE_AUTH" ;;
    opencode) printf '%s\n' "OPENCODE_AUTH" ;;
    *)
      return 1
      ;;
  esac
}

login_auth_base_dir_for_tool() {
  case "$1" in
    codex) printf '%s\n' "$CODEX_AUTH_BASE" ;;
    claude) printf '%s\n' "$CLAUDE_AUTH_BASE" ;;
    opencode) printf '%s\n' "$OPENCODE_AUTH_BASE" ;;
    *)
      return 1
      ;;
  esac
}

login_active_credentials_file_for_tool() {
  case "$1" in
    codex) printf '%s\n' "auth.json" ;;
    claude) printf '%s\n' ".credentials.json" ;;
    opencode) printf '%s\n' "opencode.json" ;;
    *)
      return 1
      ;;
  esac
}

login_config_dir_for_tool() {
  case "$1" in
    codex) printf '%s\n' "/cache/.codex" ;;
    claude) printf '%s\n' "/cache/.claude" ;;
    opencode) printf '%s\n' "/cache/.config/opencode" ;;
    *)
      return 1
      ;;
  esac
}

prepare_login_state() {
  LOGIN_TOOL="${TOOL:-$LOGIN_TOOL}"

  if [ "$LOGIN_TOOL" != "codex" ]; then
    echo "[agent] login is currently only implemented for codex" >&2
    exit 1
  fi

  resolve_tool_config_roots

  LOGIN_AUTH_ENV_NAME="$(login_auth_env_name_for_tool "$LOGIN_TOOL")"
  LOGIN_AUTH_BASE_DIR="$(login_auth_base_dir_for_tool "$LOGIN_TOOL")"
  LOGIN_ACTIVE_CREDENTIALS_FILE="$(login_active_credentials_file_for_tool "$LOGIN_TOOL")"
  LOGIN_CONTAINER_CONFIG_DIR="$(login_config_dir_for_tool "$LOGIN_TOOL")"

  LOGIN_STATE_DIR="$(mktemp -d "$HELPER_TMPDIR/login.${LOGIN_TOOL}.XXXXXX")"
  LOGIN_CONFIG_HOST_DIR="$LOGIN_STATE_DIR/config"
  LOGIN_AUTH_FILE="$LOGIN_CONFIG_HOST_DIR/$LOGIN_ACTIVE_CREDENTIALS_FILE"
  LOGIN_SAVED_AUTH_PATH="$LOGIN_AUTH_BASE_DIR/$LOGIN_SLOT_NAME.json"
  LOGIN_TOOL="$TOOL"

  mkdir -p "$LOGIN_CONFIG_HOST_DIR" "$LOGIN_AUTH_BASE_DIR"
  REMAINING_ARGS=( "${LOGIN_TOOL_ARGS[@]}" )
}

upsert_project_config_value() {
  local target_file="$1"
  local key="$2"
  local value="$3"
  local tmp_file=""

  mkdir -p "$(dirname "$target_file")"
  tmp_file="$(mktemp "$HELPER_TMPDIR/project-config.XXXXXX")"

  if [ ! -f "$target_file" ]; then
    render_project_config_template > "$target_file"
  fi

  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^[[:space:]]*" key "=" {
      if (!done) {
        print key "=" value
        done = 1
      }
      next
    }
    { print }
    END {
      if (!done) {
        print ""
        print key "=" value
      }
    }
  ' "$target_file" > "$tmp_file"

  mv "$tmp_file" "$target_file"
}

finalize_login() {
  local status="$1"
  local target_file=""

  if [ "$status" -ne 0 ]; then
    echo "[agent] login did not complete successfully; not saving credentials" >&2
    exit "$status"
  fi

  if [ ! -s "$LOGIN_AUTH_FILE" ]; then
    echo "[agent] login finished but no credentials were written to $LOGIN_AUTH_FILE" >&2
    exit 1
  fi

  install -Dm0600 "$LOGIN_AUTH_FILE" "$LOGIN_SAVED_AUTH_PATH"
  echo "[agent] saved $LOGIN_TOOL credentials to $LOGIN_SAVED_AUTH_PATH" >&2

  if [ "$LOGIN_USE" = "1" ]; then
    resolve_project_paths
    resolve_project_config_file
    target_file="$(resolve_project_config_target_file)"
    upsert_project_config_value "$target_file" "$LOGIN_AUTH_ENV_NAME" "$LOGIN_SLOT_NAME"
    echo "[agent] set $LOGIN_AUTH_ENV_NAME=$LOGIN_SLOT_NAME in $target_file" >&2
  fi
}
