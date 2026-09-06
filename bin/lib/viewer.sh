VIEWER_ARGS=()
VIEWER_HOST_SET="0"
VIEWER_PORT_SET="0"
VIEWER_READ_ONLY_SET="0"
VIEWER_READ_ONLY="1"
VIEWER_USE_BWRAP="auto"
VIEWER_OPEN_BROWSER="0"
VIEWER_OPEN_HOST="127.0.0.1"
VIEWER_OPEN_PORT="3727"
VIEWER_AUTH_DISABLED="0"
VIEWER_TOKEN_SET="0"
VIEWER_TOKEN_VALUE=""
VIEWER_ACCOUNT_AUTH_SET="0"
VIEWER_ACCESS_URL=""
VIEWER_MANAGED_TOKEN_FILE=""
VIEWER_BWRAP_CHECKED="0"
VIEWER_BWRAP_OK="0"

resolve_viewer_args() {
  VIEWER_ARGS=()
  VIEWER_HOST_SET="0"
  VIEWER_PORT_SET="0"
  VIEWER_READ_ONLY_SET="0"
  VIEWER_READ_ONLY="${AGENT_VIEWER_READ_ONLY:-1}"
  VIEWER_USE_BWRAP="${AGENT_VIEWER_SANDBOX:-auto}"
  VIEWER_OPEN_BROWSER="${AGENT_VIEWER_OPEN:-0}"
  VIEWER_OPEN_HOST="${AGENT_VIEWER_HOST:-127.0.0.1}"
  VIEWER_OPEN_PORT="${AGENT_VIEWER_PORT:-3727}"
  VIEWER_AUTH_DISABLED="0"
  VIEWER_TOKEN_SET="0"
  VIEWER_TOKEN_VALUE=""
  VIEWER_ACCOUNT_AUTH_SET="0"
  VIEWER_ACCESS_URL=""
  VIEWER_MANAGED_TOKEN_FILE=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help)
        print_viewer_help_and_exit
        ;;
      --read-write)
        VIEWER_READ_ONLY="0"
        ;;
      --sandbox)
        VIEWER_USE_BWRAP="1"
        ;;
      --no-sandbox)
        VIEWER_USE_BWRAP="0"
        ;;
      --open)
        VIEWER_OPEN_BROWSER="1"
        ;;
      --no-auth)
        VIEWER_AUTH_DISABLED="1"
        VIEWER_ARGS+=("$1")
        ;;
      --token)
        VIEWER_TOKEN_SET="1"
        VIEWER_ARGS+=("$1")
        shift
        if [ "$#" -gt 0 ]; then
          VIEWER_TOKEN_VALUE="$1"
          VIEWER_ARGS+=("$1")
        fi
        ;;
      --token=*)
        VIEWER_TOKEN_SET="1"
        VIEWER_TOKEN_VALUE="${1#--token=}"
        VIEWER_ARGS+=("$1")
        ;;
      --auth-user|--auth-password-hash)
        VIEWER_ACCOUNT_AUTH_SET="1"
        VIEWER_ARGS+=("$1")
        shift
        if [ "$#" -gt 0 ]; then
          VIEWER_ARGS+=("$1")
        fi
        ;;
      --auth-user=*|--auth-password-hash=*)
        VIEWER_ACCOUNT_AUTH_SET="1"
        VIEWER_ARGS+=("$1")
        ;;
      --serve)
        ;;
      --host)
        VIEWER_HOST_SET="1"
        VIEWER_ARGS+=("$1")
        shift
        if [ "$#" -gt 0 ]; then
          VIEWER_ARGS+=("$1")
          VIEWER_OPEN_HOST="$1"
        fi
        ;;
      --host=*)
        VIEWER_HOST_SET="1"
        VIEWER_OPEN_HOST="${1#--host=}"
        VIEWER_ARGS+=("$1")
        ;;
      --port)
        VIEWER_PORT_SET="1"
        VIEWER_ARGS+=("$1")
        shift
        if [ "$#" -gt 0 ]; then
          VIEWER_ARGS+=("$1")
          VIEWER_OPEN_PORT="$1"
        fi
        ;;
      --port=*)
        VIEWER_PORT_SET="1"
        VIEWER_OPEN_PORT="${1#--port=}"
        VIEWER_ARGS+=("$1")
        ;;
      --read-only)
        VIEWER_READ_ONLY_SET="1"
        VIEWER_READ_ONLY="1"
        VIEWER_ARGS+=("$1")
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          VIEWER_ARGS+=("$1")
          shift
        done
        break
        ;;
      *)
        VIEWER_ARGS+=("$1")
        ;;
    esac
    shift
  done
}

print_viewer_help_and_exit() {
  cat <<EOF
usage:
  agent viewer [viewer options] [-- cchv-server options]

viewer options:
  --host <addr>       bind address (default: 127.0.0.1)
  --port <port>       port (default: 3727)
  --read-write        allow mutating WebUI API endpoints
  --sandbox           require Bubblewrap filesystem sandboxing
  --no-sandbox        run directly on the host
  --open              open the local URL with xdg-open when available

All other options are passed to cchv-server. Useful upstream options include:
  --token <value>
  --auth-user <name>
  --auth-password-hash <argon2-phc>
  --base-path <path>
  --no-auth
EOF
  exit 0
}

viewer_bootstrap_environment() {
  PROJECT_OVERRIDE_ARGS=()
  STORE_KEY="viewer"

  resolve_project_paths
  load_project_config
  resolve_host_home
  resolve_sandbox_flake
  resolve_lock_args
  prepare_cache_dirs
  resolve_tool_config_roots

  SANDBOX_META_KEY="$(compute_sandbox_meta_key)"
  SANDBOX_KEY="$(hash_short "$SANDBOX_META_KEY")"
}

prepare_viewer_binary() {
  if command -v cchv-server >/dev/null 2>&1; then
    CCHV_SERVER_BIN="$(command -v cchv-server)"
    return 0
  fi

  CCHV_SERVER_GCROOT="$GCROOTS_DIR/${SANDBOX_KEY}--cchv-server"
  CCHV_SERVER_OUT="$(
    build_cached_artifact \
      "cchv-server" \
      "$CCHV_SERVER_GCROOT" \
      "cchv-server" \
      "cchv-server derivation cache hit" \
      "nix build cchv-server" \
      "[agent] cchv-server build failed."
  )"
  CCHV_SERVER_BIN="$CCHV_SERVER_OUT/bin/cchv-server"
}

viewer_source_dir_or_empty() {
  local dir="$1"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    resolve_mount_dir "$dir"
  fi
}

viewer_replace_symlink() {
  local source="$1"
  local target="$2"

  if [ ! -d "$source" ]; then
    if [ -L "$target" ]; then
      rm -f "$target"
    fi
    return 0
  fi

  mkdir -p "$(dirname "$target")"
  if [ -L "$target" ]; then
    rm -f "$target"
  elif [ -d "$target" ] && [ -z "$(find "$target" -mindepth 1 -print -quit)" ]; then
    rmdir "$target"
  elif [ -e "$target" ]; then
    echo "[agent] viewer home path is not a managed symlink: $target" >&2
    echo "[agent] remove it or set AGENT_VIEWER_HOME to another cache directory" >&2
    exit 1
  fi

  ln -s "$source" "$target"
}

prepare_viewer_mountpoint() {
  local target="$1"

  mkdir -p "$(dirname "$target")"
  if [ -L "$target" ]; then
    rm -f "$target"
  fi
  mkdir -p "$target"
}

prepare_viewer_home() {
  VIEWER_HOME="${AGENT_VIEWER_HOME:-$CACHE_DIR/viewer-home}"
  VIEWER_HOME="$(expand_host_config_path "$VIEWER_HOME")"
  mkdir -p "$VIEWER_HOME/.claude-history-viewer" "$VIEWER_HOME/.cache" "$VIEWER_HOME/.local/share"

  VIEWER_CLAUDE_SOURCE="$(viewer_source_dir_or_empty "${AGENT_VIEWER_CLAUDE_HOME:-$CLAUDE_HOST_CONFIG}")"
  VIEWER_CODEX_SOURCE="$(viewer_source_dir_or_empty "${AGENT_VIEWER_CODEX_HOME:-$CODEX_SESSION_ROOT}")"
  VIEWER_OPENCODE_SOURCE="$(viewer_source_dir_or_empty "${AGENT_VIEWER_OPENCODE_HOME:-${OPENCODE_HOME:-$HOST_HOME/.local/share/opencode}}")"

  VIEWER_CLAUDE_TARGET="$VIEWER_HOME/.claude"
  VIEWER_CODEX_TARGET="$VIEWER_HOME/.codex"
  VIEWER_OPENCODE_TARGET="$VIEWER_HOME/.local/share/opencode"

  if viewer_should_use_bwrap; then
    prepare_viewer_mountpoint "$VIEWER_CLAUDE_TARGET"
    prepare_viewer_mountpoint "$VIEWER_CODEX_TARGET"
    prepare_viewer_mountpoint "$VIEWER_OPENCODE_TARGET"
  else
    viewer_replace_symlink "$VIEWER_CLAUDE_SOURCE" "$VIEWER_CLAUDE_TARGET"
    viewer_replace_symlink "$VIEWER_CODEX_SOURCE" "$VIEWER_CODEX_TARGET"
    viewer_replace_symlink "$VIEWER_OPENCODE_SOURCE" "$VIEWER_OPENCODE_TARGET"
  fi
}

viewer_generate_token() {
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

viewer_account_auth_configured() {
  [ "$VIEWER_ACCOUNT_AUTH_SET" = "1" ] ||
    [ -n "${CCHV_AUTH_USER:-}" ] ||
    [ -n "${CCHV_AUTH_PASSWORD_HASH:-}" ]
}

viewer_make_access_url() {
  local url="http://${VIEWER_OPEN_HOST}:${VIEWER_OPEN_PORT}/"

  if [ -n "$VIEWER_TOKEN_VALUE" ]; then
    url="${url}?token=${VIEWER_TOKEN_VALUE}"
  fi

  VIEWER_ACCESS_URL="$url"
}

prepare_viewer_auth() {
  local token=""

  VIEWER_MANAGED_TOKEN_FILE="$VIEWER_HOME/.claude-history-viewer/webui-token.txt"

  if [ "$VIEWER_AUTH_DISABLED" = "1" ]; then
    viewer_make_access_url
    return 0
  fi

  if [ "$VIEWER_TOKEN_SET" = "1" ]; then
    viewer_make_access_url
    return 0
  fi

  if [ -n "${CCHV_TOKEN:-}" ]; then
    VIEWER_TOKEN_VALUE="$CCHV_TOKEN"
    viewer_make_access_url
    return 0
  fi

  if viewer_account_auth_configured; then
    viewer_make_access_url
    return 0
  fi

  if [ -s "$VIEWER_MANAGED_TOKEN_FILE" ]; then
    token="$(sed -n '1p' "$VIEWER_MANAGED_TOKEN_FILE" | tr -d '\r\n')"
  fi

  if [ -z "$token" ]; then
    token="$(viewer_generate_token)"
    if [ -z "$token" ]; then
      echo "[agent] failed to generate viewer auth token" >&2
      exit 1
    fi
    umask 077
    printf '%s\n' "$token" >"$VIEWER_MANAGED_TOKEN_FILE"
  fi

  VIEWER_TOKEN_VALUE="$token"
  VIEWER_ARGS+=( --token "$VIEWER_TOKEN_VALUE" )
  viewer_make_access_url
}

print_viewer_access_hint() {
  if [ "$VIEWER_AUTH_DISABLED" = "1" ]; then
    echo "[agent] viewer URL: $VIEWER_ACCESS_URL"
    return 0
  fi

  if [ -n "$VIEWER_TOKEN_VALUE" ]; then
    echo "[agent] viewer URL: $VIEWER_ACCESS_URL"
    if [ -n "$VIEWER_MANAGED_TOKEN_FILE" ] && [ -f "$VIEWER_MANAGED_TOKEN_FILE" ]; then
      echo "[agent] viewer token file: $VIEWER_MANAGED_TOKEN_FILE"
    fi
    return 0
  fi

  if viewer_account_auth_configured; then
    echo "[agent] viewer URL: $VIEWER_ACCESS_URL"
    echo "[agent] account authentication is configured; use your configured CCHV credentials."
  fi
}

viewer_should_use_bwrap() {
  case "$VIEWER_USE_BWRAP" in
    1|true|yes|on)
      viewer_bwrap_works || {
        echo "[agent] --sandbox requested but bwrap is not available" >&2
        echo "[agent] or cannot start in this environment; retry with --no-sandbox" >&2
        exit 1
      }
      return 0
      ;;
    0|false|no|off)
      return 1
      ;;
    auto|"")
      [ "$(uname -s)" = "Linux" ] && viewer_bwrap_works
      ;;
    *)
      echo "[agent] invalid AGENT_VIEWER_SANDBOX='$VIEWER_USE_BWRAP' (expected auto, 1, or 0)" >&2
      exit 1
      ;;
  esac
}

viewer_bwrap_works() {
  local true_bin=""

  if [ "$VIEWER_BWRAP_CHECKED" = "1" ]; then
    [ "$VIEWER_BWRAP_OK" = "1" ]
    return
  fi

  VIEWER_BWRAP_CHECKED="1"
  VIEWER_BWRAP_OK="0"

  command -v bwrap >/dev/null 2>&1 || return 1
  true_bin="$(command -v true 2>/dev/null || true)"
  [ -n "$true_bin" ] || return 1

  if bwrap --ro-bind / / "$true_bin" >/dev/null 2>&1; then
    VIEWER_BWRAP_OK="1"
    return 0
  fi

  return 1
}

append_viewer_ro_bind() {
  local source="$1"
  local target="$2"

  [ -n "$source" ] || return 0
  [ -d "$source" ] || return 0
  VIEWER_SANDBOX_ARGS+=( --ro-bind "$source" "$target" )
}

viewer_command_args() {
  VIEWER_FINAL_ARGS=( --serve )

  if [ "$VIEWER_HOST_SET" != "1" ]; then
    VIEWER_FINAL_ARGS+=( --host "${AGENT_VIEWER_HOST:-127.0.0.1}" )
  fi
  if [ "$VIEWER_PORT_SET" != "1" ]; then
    VIEWER_FINAL_ARGS+=( --port "${AGENT_VIEWER_PORT:-3727}" )
  fi
  if [ "$VIEWER_READ_ONLY" != "0" ] && [ "$VIEWER_READ_ONLY_SET" != "1" ]; then
    VIEWER_FINAL_ARGS+=( --read-only )
  fi

  VIEWER_FINAL_ARGS+=( "${VIEWER_ARGS[@]}" )
}

run_viewer_direct() {
  HOME="$VIEWER_HOME" \
  XDG_CACHE_HOME="$VIEWER_HOME/.cache" \
  XDG_DATA_HOME="$VIEWER_HOME/.local/share" \
  CODEX_HOME="$VIEWER_CODEX_TARGET" \
  CODEX_CONFIG_DIR="$VIEWER_CODEX_TARGET" \
  CLAUDE_CONFIG_DIR="$VIEWER_CLAUDE_TARGET" \
  OPENCODE_HOME="$VIEWER_OPENCODE_TARGET" \
    exec "$CCHV_SERVER_BIN" "${VIEWER_FINAL_ARGS[@]}"
}

run_viewer_bwrap() {
  VIEWER_SANDBOX_ARGS=(
    --die-with-parent
    --new-session
    --unshare-pid
    --unshare-ipc
    --unshare-uts
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --ro-bind /nix/store /nix/store
    --ro-bind /etc /etc
    --bind "$VIEWER_HOME" "$VIEWER_HOME"
    --setenv HOME "$VIEWER_HOME"
    --setenv XDG_CACHE_HOME "$VIEWER_HOME/.cache"
    --setenv XDG_DATA_HOME "$VIEWER_HOME/.local/share"
    --setenv CODEX_HOME "$VIEWER_CODEX_TARGET"
    --setenv CODEX_CONFIG_DIR "$VIEWER_CODEX_TARGET"
    --setenv CLAUDE_CONFIG_DIR "$VIEWER_CLAUDE_TARGET"
    --setenv OPENCODE_HOME "$VIEWER_OPENCODE_TARGET"
  )

  if [ -d "$PROJECT_ROOT" ]; then
    VIEWER_SANDBOX_ARGS+=( --ro-bind "$PROJECT_ROOT" "$PROJECT_ROOT" --chdir "$PROJECT_ROOT" )
  fi

  append_viewer_ro_bind "$VIEWER_CLAUDE_SOURCE" "$VIEWER_CLAUDE_TARGET"
  append_viewer_ro_bind "$VIEWER_CODEX_SOURCE" "$VIEWER_CODEX_TARGET"
  append_viewer_ro_bind "$VIEWER_OPENCODE_SOURCE" "$VIEWER_OPENCODE_TARGET"

  exec bwrap "${VIEWER_SANDBOX_ARGS[@]}" "$CCHV_SERVER_BIN" "${VIEWER_FINAL_ARGS[@]}"
}

open_viewer_url_if_requested() {
  if [ "$VIEWER_OPEN_BROWSER" != "1" ]; then
    return 0
  fi
  if ! command -v xdg-open >/dev/null 2>&1; then
    echo "[agent] xdg-open is not available; open $VIEWER_ACCESS_URL manually" >&2
    return 0
  fi
  ( xdg-open "$VIEWER_ACCESS_URL" >/dev/null 2>&1 & )
}

run_viewer_and_exit() {
  viewer_bootstrap_environment
  prepare_viewer_binary
  prepare_viewer_home
  prepare_viewer_auth
  viewer_command_args
  print_viewer_access_hint
  open_viewer_url_if_requested

  if viewer_should_use_bwrap; then
    run_viewer_bwrap
  else
    run_viewer_direct
  fi
}
