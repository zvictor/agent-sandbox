REMOTE_ACTION=""
REMOTE_NAME_ARG=""
REMOTE_CODEX_ARGS=()
REMOTE_SSH_ARGS=()
REMOTE_DELETE_STATE="0"
REMOTE_START_CODEX="0"
REMOTE_RESUME_ARG=""

print_remote_help_and_exit() {
  cat <<'EOF'
usage:
  agent remote up [--name NAME] [--start-codex] [--resume last|SESSION_ID]
  agent remote down [--name NAME] [--delete-state]
  agent remote status [--name NAME]
  agent remote attach [--name NAME]
  agent remote codex [--name NAME] [-- CODEX_ARGS...]
  agent remote ssh [--name NAME] [-- SSH_ARGS...]
  agent remote sessions [--all] [--json]

remote mode creates one durable sandbox endpoint for the current worktree.
EOF
  exit 0
}

resolve_remote_args() {
  REMOTE_ACTION="${1:-}"
  REMOTE_NAME_ARG=""
  REMOTE_CODEX_ARGS=()
  REMOTE_SSH_ARGS=()
  REMOTE_DELETE_STATE="0"
  REMOTE_START_CODEX="0"
  REMOTE_RESUME_ARG=""

  case "$REMOTE_ACTION" in
    up|down|status|attach|codex|ssh|sessions)
      shift
      ;;
    ""|help|--help|-h)
      print_remote_help_and_exit
      ;;
    *)
      echo "[agent] unsupported remote command '$REMOTE_ACTION'" >&2
      print_remote_help_and_exit
      ;;
  esac

  if [ "$REMOTE_ACTION" = "sessions" ]; then
    REMAINING_ARGS=(codex "$@")
    return
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name)
        [ "$#" -ge 2 ] || {
          echo "[agent] remote --name requires a value" >&2
          exit 1
        }
        REMOTE_NAME_ARG="$2"
        shift 2
        ;;
      --delete-state)
        [ "$REMOTE_ACTION" = "down" ] || {
          echo "[agent] --delete-state is only valid with 'agent remote down'" >&2
          exit 1
        }
        REMOTE_DELETE_STATE="1"
        shift
        ;;
      --start-codex)
        [ "$REMOTE_ACTION" = "up" ] || {
          echo "[agent] --start-codex is only valid with 'agent remote up'" >&2
          exit 1
        }
        REMOTE_START_CODEX="1"
        shift
        ;;
      --resume)
        [ "$REMOTE_ACTION" = "up" ] || {
          echo "[agent] --resume is only valid with 'agent remote up'" >&2
          exit 1
        }
        [ "$#" -ge 2 ] || {
          echo "[agent] --resume requires 'last' or a Codex session id" >&2
          exit 1
        }
        REMOTE_START_CODEX="1"
        REMOTE_RESUME_ARG="$2"
        shift 2
        ;;
      --)
        shift
        case "$REMOTE_ACTION" in
          codex)
            REMOTE_CODEX_ARGS=("$@")
            ;;
          ssh)
            REMOTE_SSH_ARGS=("$@")
            ;;
          *)
            if [ "$#" -gt 0 ]; then
              echo "[agent] unexpected arguments after -- for remote $REMOTE_ACTION" >&2
              exit 1
            fi
            ;;
        esac
        break
        ;;
      *)
        case "$REMOTE_ACTION" in
          codex)
            REMOTE_CODEX_ARGS+=("$1")
            shift
            ;;
          ssh)
            REMOTE_SSH_ARGS+=("$1")
            shift
            ;;
          *)
            echo "[agent] unexpected argument for remote $REMOTE_ACTION: $1" >&2
            exit 1
            ;;
        esac
        ;;
    esac
  done
}

remote_sanitize_name() {
  local raw="$1"
  local sanitized

  sanitized="$(printf '%s' "$raw" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' |
    cut -c1-42)"

  if [ -z "$sanitized" ]; then
    sanitized="codex"
  fi

  printf '%s\n' "$sanitized"
}

remote_default_name() {
  local workspace_path="${AGENT_WORKSPACE_PATH:-$PWD}"
  local project_part workspace_part hash_part

  workspace_path="$(cd "$workspace_path" && pwd -P)"
  project_part="$(basename "${PROJECT_ROOT:-$workspace_path}")"
  workspace_part="$(basename "$workspace_path")"
  hash_part="$(hash_short "$workspace_path" | cut -c1-8)"

  if [ "$project_part" = "$workspace_part" ]; then
    remote_sanitize_name "codex-$workspace_part-$hash_part"
  else
    remote_sanitize_name "codex-$project_part-$workspace_part-$hash_part"
  fi
}

remote_init_names() {
  REMOTE_NAME="$(remote_sanitize_name "${REMOTE_NAME_ARG:-${AGENT_REMOTE_NAME:-$(remote_default_name)}}")"
  AGENT_REMOTE_NAME="$REMOTE_NAME"
  AGENT_REMOTE_USER="${AGENT_REMOTE_USER:-codex}"
  REMOTE_POD_NAME="agent-remote-$REMOTE_NAME"
  REMOTE_RUNTIME_CONTAINER="$REMOTE_POD_NAME-runtime"
  REMOTE_TS_CONTAINER="$REMOTE_POD_NAME-ts"
  REMOTE_HOSTNAME="$(remote_sanitize_name "${AGENT_REMOTE_HOSTNAME:-$REMOTE_NAME}")"
  REMOTE_STATE_DIR="$CACHE_DIR/remote/$REMOTE_NAME"
  REMOTE_RUNTIME_STATE_DIR="$REMOTE_STATE_DIR/runtime"
  REMOTE_TS_STATE_DIR="$REMOTE_STATE_DIR/tailscale"

  export AGENT_REMOTE_NAME AGENT_REMOTE_USER
  export AGENT_REMOTE_POD_NAME="$REMOTE_POD_NAME"
  export AGENT_REMOTE_RUNTIME_CONTAINER="$REMOTE_RUNTIME_CONTAINER"
  export AGENT_REMOTE_RUNTIME_STATE_DIR="$REMOTE_RUNTIME_STATE_DIR"
}

remote_firecracker_confirmation() {
  if ! firecracker_host_profile; then
    return 0
  fi

  if [ "${AGENT_REMOTE_ALLOW_PRIVILEGED_HOST_CONTROL:-}" = "I_UNDERSTAND" ]; then
    return 0
  fi

  cat >&2 <<'EOF'
[agent] WARNING: remote firecracker-host mode exposes a privileged host-control sandbox.
[agent] It uses rootful Podman, host network/cgroup/user namespaces, /dev/kvm, /dev/net/tun,
[agent] CAP_NET_ADMIN, and writable cgroup state. This is not the normal remote sandbox boundary.
EOF

  if [ ! -t 0 ]; then
    echo "[agent] ERROR: set AGENT_REMOTE_ALLOW_PRIVILEGED_HOST_CONTROL=I_UNDERSTAND to use this non-interactively" >&2
    exit 1
  fi

  printf '[agent] Type firecracker-host to continue: ' >&2
  IFS= read -r answer
  if [ "$answer" != "firecracker-host" ]; then
    echo "[agent] remote firecracker-host launch cancelled" >&2
    exit 1
  fi
}

remote_apply_defaults() {
  if [ -z "${CODEX_CONFIG:-}" ]; then
    CODEX_CONFIG=project
    export CODEX_CONFIG
  fi
}

remote_resolve_workspace_path() {
  WORKSPACE_PATH="${AGENT_WORKSPACE_PATH:-$PWD}"
  if [ ! -d "$WORKSPACE_PATH" ]; then
    echo "[agent] ERROR: workspace path is not a directory: $WORKSPACE_PATH" >&2
    exit 1
  fi
  WORKSPACE_PATH="$(cd "$WORKSPACE_PATH" && pwd -P)"
}

remote_bootstrap_light() {
  TOOL="codex"
  OS_NAME="$(uname -s)"
  remote_apply_defaults
  prepare_tool_resolution_context
  resolve_sandbox_profile
  resolve_runtime
  prepare_cache_dirs
  remote_resolve_workspace_path
  remote_init_names
}

remote_bootstrap_full() {
  local confirm_firecracker="${1:-}"

  TOOL="codex"
  remote_apply_defaults
  prepare_tool_resolution_context
  resolve_sandbox_profile
  if [ "$confirm_firecracker" = "confirm-firecracker" ]; then
    remote_firecracker_confirmation
  fi
  bootstrap_environment
  remote_resolve_workspace_path
  remote_init_names
}

remote_require_podman_default_profile() {
  if [ "$OS_NAME" != "Linux" ]; then
    echo "[agent] ERROR: remote mode currently supports Linux hosts only" >&2
    exit 1
  fi

  if firecracker_host_profile; then
    return 0
  fi

  if [ "$RUNTIME" != "podman" ]; then
    echo "[agent] ERROR: remote mode requires AGENT_RUNTIME=podman" >&2
    exit 1
  fi

  if [ -n "${CONTAINER_HOST:-}" ]; then
    echo "[agent] ERROR: remote mode requires local Podman; CONTAINER_HOST is set" >&2
    exit 1
  fi

  if ! podman info >/dev/null 2>&1; then
    echo "[agent] ERROR: remote mode requires a usable rootless Podman" >&2
    exit 1
  fi

  if ! podman info --format '{{.Host.Slirp4NetNS.Executable}}' 2>/dev/null | grep -q slirp4netns; then
    echo "[agent] ERROR: remote mode requires slirp4netns; refusing host-network fallback" >&2
    exit 1
  fi
}

remote_uses_pod() {
  ! firecracker_host_profile
}

remote_reject_implicit_host_bridges() {
  if [ "${AGENT_REMOTE_ALLOW_CONTAINER_API:-0}" != "1" ]; then
    case "${AGENT_CONTAINER_API:-none}" in
      ""|none) ;;
      *)
        echo "[agent] remote mode forcing AGENT_CONTAINER_API=none; set AGENT_REMOTE_ALLOW_CONTAINER_API=1 to keep AGENT_CONTAINER_API=${AGENT_CONTAINER_API}" >&2
        AGENT_CONTAINER_API=none
        export AGENT_CONTAINER_API
        ;;
    esac
    if [ "${AGENT_ALLOW_PODMAN_SOCKET:-0}" = "1" ] || [ "${AGENT_ALLOW_DOCKER_SOCKET:-0}" = "1" ]; then
      echo "[agent] ERROR: remote mode does not inherit raw container socket flags" >&2
      exit 1
    fi
  fi

  if [ "${AGENT_REMOTE_ALLOW_NEED_HELPER:-0}" != "1" ]; then
    case "${AGENT_NEED_HELPER:-1}" in
      0) ;;
      *)
        echo "[agent] remote mode forcing AGENT_NEED_HELPER=0; set AGENT_REMOTE_ALLOW_NEED_HELPER=1 to keep AGENT_NEED_HELPER=${AGENT_NEED_HELPER:-1}" >&2
        AGENT_NEED_HELPER=0
        export AGENT_NEED_HELPER
        ;;
    esac
  fi

  if [ "${AGENT_ALLOW_NIX_DAEMON_SOCKET:-0}" = "1" ] && [ "${AGENT_REMOTE_ALLOW_NIX_DAEMON:-0}" != "1" ]; then
    echo "[agent] ERROR: remote mode does not inherit raw Nix daemon access" >&2
    exit 1
  fi

  if [ -n "${AGENT_EXTRA_MOUNTS:-}" ] && [ "${AGENT_REMOTE_ALLOW_EXTRA_MOUNTS:-0}" != "1" ]; then
    echo "[agent] ERROR: remote mode does not inherit AGENT_EXTRA_MOUNTS by default" >&2
    echo "[agent] Set AGENT_REMOTE_ALLOW_EXTRA_MOUNTS=1 when the wider filesystem boundary is intentional." >&2
    exit 1
  fi

  if { [ -n "${AGENT_EXTRA_DEVICES:-}" ] || [ "${AGENT_ALLOW_KVM:-0}" = "1" ]; } && [ "${AGENT_REMOTE_ALLOW_EXTRA_DEVICES:-0}" != "1" ]; then
    echo "[agent] ERROR: remote mode does not inherit extra devices by default" >&2
    echo "[agent] Set AGENT_REMOTE_ALLOW_EXTRA_DEVICES=1 when the wider device boundary is intentional." >&2
    exit 1
  fi

  if [ -n "${AGENT_AUTO_MOUNT_DIRS:-}" ] && [ "${AGENT_REMOTE_ALLOW_AUTO_MOUNTS:-0}" != "1" ]; then
    echo "[agent] ERROR: remote mode does not inherit AGENT_AUTO_MOUNT_DIRS by default" >&2
    echo "[agent] Set AGENT_REMOTE_ALLOW_AUTO_MOUNTS=1 when the wider filesystem boundary is intentional." >&2
    exit 1
  fi

  if [ -n "${AGENT_EXTRA_ENV:-}" ] && [ "${AGENT_REMOTE_ALLOW_EXTRA_ENV:-0}" != "1" ]; then
    echo "[agent] ERROR: remote mode does not inherit AGENT_EXTRA_ENV by default" >&2
    echo "[agent] Set AGENT_REMOTE_ALLOW_EXTRA_ENV=1 when those variables are intentional." >&2
    exit 1
  fi

  if [ -n "${AGENT_PASS_ENV_PREFIXES:-}" ] && [ "${AGENT_REMOTE_ALLOW_HOST_ENV:-0}" != "1" ]; then
    echo "[agent] ERROR: remote mode does not inherit custom AGENT_PASS_ENV_PREFIXES by default" >&2
    echo "[agent] Set AGENT_REMOTE_ALLOW_HOST_ENV=1 when broad host env passthrough is intentional." >&2
    exit 1
  fi
}

remote_container_running() {
  local name="$1"
  [ "$(podman_runtime_cmd inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" = "true" ]
}

remote_pod_exists() {
  podman_runtime_cmd pod inspect "$REMOTE_POD_NAME" >/dev/null 2>&1
}

remote_create_pod() {
  if ! remote_uses_pod; then
    return 0
  fi

  if remote_pod_exists; then
    podman_runtime_cmd pod start "$REMOTE_POD_NAME" >/dev/null 2>&1 || true
    return 0
  fi

  podman_runtime_cmd pod create \
    --name "$REMOTE_POD_NAME" \
    --network=slirp4netns:allow_host_loopback=true \
    >/dev/null
}

remote_prepare_authorized_keys() {
  local source_file="${AGENT_REMOTE_AUTHORIZED_KEYS_FILE:-}"
  local key_value="${AGENT_REMOTE_AUTHORIZED_KEY:-}"
  local target="$REMOTE_RUNTIME_STATE_DIR/authorized_keys"

  mkdir -p "$REMOTE_RUNTIME_STATE_DIR" "$REMOTE_TS_STATE_DIR"

  if [ -n "$source_file" ]; then
    source_file="$(expand_host_selector_path "$source_file")"
    if [ ! -r "$source_file" ]; then
      echo "[agent] ERROR: AGENT_REMOTE_AUTHORIZED_KEYS_FILE is not readable: $source_file" >&2
      exit 1
    fi
    cp "$source_file" "$target"
  elif [ -n "$key_value" ]; then
    printf '%s\n' "$key_value" > "$target"
  elif [ -r "$HOST_HOME/.ssh/authorized_keys" ]; then
    cp "$HOST_HOME/.ssh/authorized_keys" "$target"
  else
    echo "[agent] ERROR: remote mode needs an SSH public key for mobile access." >&2
    echo "[agent] Set AGENT_REMOTE_AUTHORIZED_KEYS_FILE or AGENT_REMOTE_AUTHORIZED_KEY." >&2
    exit 1
  fi

  chmod 600 "$target"
}

remote_tailscale_state_exists() {
  [ -d "$REMOTE_TS_STATE_DIR" ] && find "$REMOTE_TS_STATE_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .
}

remote_read_secret_value() {
  local value_name="$1"
  local file_name="$2"
  local value="${!value_name:-}"
  local file="${!file_name:-}"

  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi

  if [ -n "$file" ]; then
    file="$(expand_host_selector_path "$file")"
    if [ ! -r "$file" ]; then
      echo "[agent] ERROR: $file_name is not readable: $file" >&2
      exit 1
    fi
    sed -n '1p' "$file"
  fi
}

remote_require_tailscale_auth_available() {
  local authkey client_id client_secret

  if remote_container_running "$REMOTE_TS_CONTAINER" || remote_tailscale_state_exists; then
    return 0
  fi

  authkey="$(remote_read_secret_value AGENT_REMOTE_TS_AUTHKEY AGENT_REMOTE_TS_AUTHKEY_FILE)"
  if [ -z "$authkey" ]; then
    authkey="$(remote_read_secret_value AGENT_REMOTE_TAILSCALE_AUTHKEY AGENT_REMOTE_TAILSCALE_AUTHKEY_FILE)"
  fi
  if [ -z "$authkey" ] && [ -n "${TS_AUTHKEY:-}" ]; then
    authkey="$TS_AUTHKEY"
  fi
  if [ -z "$authkey" ] && [ -n "${TS_AUTH_KEY:-}" ]; then
    authkey="$TS_AUTH_KEY"
  fi

  client_id="$(remote_read_secret_value AGENT_REMOTE_TS_CLIENT_ID AGENT_REMOTE_TS_CLIENT_ID_FILE)"
  client_secret="$(remote_read_secret_value AGENT_REMOTE_TS_CLIENT_SECRET AGENT_REMOTE_TS_CLIENT_SECRET_FILE)"
  if [ -z "$client_id" ] && [ -n "${TS_CLIENT_ID:-}" ]; then
    client_id="$TS_CLIENT_ID"
  fi
  if [ -z "$client_secret" ] && [ -n "${TS_CLIENT_SECRET:-}" ]; then
    client_secret="$TS_CLIENT_SECRET"
  fi

  if [ -z "$authkey" ] && { [ -z "$client_id" ] || [ -z "$client_secret" ]; }; then
    echo "[agent] ERROR: first remote start needs Tailscale auth." >&2
    echo "[agent] Set AGENT_REMOTE_TS_AUTHKEY_FILE, AGENT_REMOTE_TS_AUTHKEY, or OAuth client id/secret env vars." >&2
    exit 1
  fi
}

remote_start_runtime_container() {
  if remote_container_running "$REMOTE_RUNTIME_CONTAINER"; then
    return 0
  fi

  AGENT_REMOTE_CONTAINER_MODE=1
  export AGENT_REMOTE_CONTAINER_MODE
  if ! remote_uses_pod; then
    AGENT_REMOTE_POD_DISABLED=1
    export AGENT_REMOTE_POD_DISABLED
  fi

  build_container_args
  run_container_runtime >/dev/null
}

remote_start_tailscale_sidecar() {
  local authkey client_id client_secret extra_args tag
  local -a ts_env

  if remote_container_running "$REMOTE_TS_CONTAINER"; then
    return 0
  fi

  authkey="$(remote_read_secret_value AGENT_REMOTE_TS_AUTHKEY AGENT_REMOTE_TS_AUTHKEY_FILE)"
  if [ -z "$authkey" ]; then
    authkey="$(remote_read_secret_value AGENT_REMOTE_TAILSCALE_AUTHKEY AGENT_REMOTE_TAILSCALE_AUTHKEY_FILE)"
  fi
  if [ -z "$authkey" ] && [ -n "${TS_AUTHKEY:-}" ]; then
    authkey="$TS_AUTHKEY"
  fi
  if [ -z "$authkey" ] && [ -n "${TS_AUTH_KEY:-}" ]; then
    authkey="$TS_AUTH_KEY"
  fi

  client_id="$(remote_read_secret_value AGENT_REMOTE_TS_CLIENT_ID AGENT_REMOTE_TS_CLIENT_ID_FILE)"
  client_secret="$(remote_read_secret_value AGENT_REMOTE_TS_CLIENT_SECRET AGENT_REMOTE_TS_CLIENT_SECRET_FILE)"
  if [ -z "$client_id" ] && [ -n "${TS_CLIENT_ID:-}" ]; then
    client_id="$TS_CLIENT_ID"
  fi
  if [ -z "$client_secret" ] && [ -n "${TS_CLIENT_SECRET:-}" ]; then
    client_secret="$TS_CLIENT_SECRET"
  fi

  if [ -z "$authkey" ] && { [ -z "$client_id" ] || [ -z "$client_secret" ]; } && ! remote_tailscale_state_exists; then
    echo "[agent] ERROR: first remote start needs Tailscale auth." >&2
    echo "[agent] Set AGENT_REMOTE_TS_AUTHKEY_FILE, AGENT_REMOTE_TS_AUTHKEY, or OAuth client id/secret env vars." >&2
    exit 1
  fi

  tag="${AGENT_REMOTE_TAILSCALE_TAG:-tag:codex-agent}"
  extra_args="${AGENT_REMOTE_TS_EXTRA_ARGS:-}"
  if [ -n "$tag" ]; then
    extra_args="${extra_args:+$extra_args }--advertise-tags=$tag"
  fi

  ts_env=(
    -e "TS_HOSTNAME=$REMOTE_HOSTNAME"
    -e "TS_STATE_DIR=/var/lib/tailscale"
    -e "TS_USERSPACE=true"
    -e "TS_AUTH_ONCE=true"
  )
  if [ -n "$extra_args" ]; then
    ts_env+=( -e "TS_EXTRA_ARGS=$extra_args" )
  fi
  if [ -n "$authkey" ]; then
    ts_env+=( -e "TS_AUTHKEY=$authkey" )
  elif [ -n "$client_id" ] && [ -n "$client_secret" ]; then
    ts_env+=( -e "TS_CLIENT_ID=$client_id" -e "TS_CLIENT_SECRET=$client_secret" )
  fi

  if remote_uses_pod; then
    podman_runtime_cmd run -d \
      --init \
      --pod "$REMOTE_POD_NAME" \
      --name "$REMOTE_TS_CONTAINER" \
      --replace \
      --security-opt=no-new-privileges \
      -v "$REMOTE_TS_STATE_DIR:/var/lib/tailscale:Z" \
      "${ts_env[@]}" \
      "${AGENT_REMOTE_TAILSCALE_IMAGE:-docker.io/tailscale/tailscale:latest}" \
      >/dev/null
  else
    podman_runtime_cmd run -d \
      --init \
      --network=host \
      --name "$REMOTE_TS_CONTAINER" \
      --replace \
      --security-opt=no-new-privileges \
      -v "$REMOTE_TS_STATE_DIR:/var/lib/tailscale:Z" \
      "${ts_env[@]}" \
      "${AGENT_REMOTE_TAILSCALE_IMAGE:-docker.io/tailscale/tailscale:latest}" \
      >/dev/null
  fi
}

remote_configure_tailscale_serve() {
  local wait_count=0

  while [ "$wait_count" -lt 60 ]; do
    if podman_runtime_cmd exec "$REMOTE_TS_CONTAINER" tailscale status >/dev/null 2>&1; then
      break
    fi
    sleep 1
    wait_count=$((wait_count + 1))
  done

  if [ "$wait_count" -ge 60 ]; then
    echo "[agent] ERROR: Tailscale sidecar did not become ready" >&2
    podman_runtime_cmd logs "$REMOTE_TS_CONTAINER" >&2 || true
    exit 1
  fi

  podman_runtime_cmd exec "$REMOTE_TS_CONTAINER" \
    tailscale serve --bg --tcp=22 tcp://127.0.0.1:2222 \
    >/dev/null
}

remote_exec_tty_args() {
  if [ -t 0 ] && [ -t 1 ]; then
    printf '%s\n' -it
  else
    printf '%s\n' -i
  fi
}

remote_exec_in_runtime() {
  local -a tty_args
  mapfile -t tty_args < <(remote_exec_tty_args)
  podman_runtime_cmd exec "${tty_args[@]}" --workdir "$WORKSPACE_PATH" "$REMOTE_RUNTIME_CONTAINER" "$@"
}

remote_live_session_rows() {
  if ! remote_container_running "$REMOTE_RUNTIME_CONTAINER"; then
    return 0
  fi

  podman_runtime_cmd exec "$REMOTE_RUNTIME_CONTAINER" \
    tmux list-sessions -F '#S	#{session_attached}	#{session_windows}' \
    2>/dev/null || true
}

remote_transcript_rows() {
  local sessions_dir=""
  local config_mode=""

  case "$SESSIONS_TOOL" in
    codex)
      config_mode="$CODEX_CONFIG_MODE"
      sessions_dir="$CODEX_HOST_CONFIG/sessions"
      ;;
  esac

  SESSIONS_CONFIG_MODE="$config_mode"
  if [ "$config_mode" != "fresh" ] && [ -d "$sessions_dir" ]; then
    collect_codex_sessions "$sessions_dir"
  fi
}

remote_sessions_text() {
  local live_rows="$1"
  local transcript_rows="$2"
  local live_count="0"
  local transcript_count="0"

  if [ -n "$live_rows" ]; then
    live_count="$(printf '%s\n' "$live_rows" | sed '/^$/d' | wc -l | tr -d ' ')"
  fi
  if [ -n "$transcript_rows" ]; then
    transcript_count="$(printf '%s\n' "$transcript_rows" | sed '/^$/d' | wc -l | tr -d ' ')"
  fi

  printf 'Agent Remote Sessions\n\n'
  doctor_line "name" "$REMOTE_NAME"
  doctor_line "workspace" "$WORKSPACE_PATH"
  doctor_line "live_count" "$live_count"
  doctor_line "transcript_count" "$transcript_count"

  printf '\nLive tmux sessions\n'
  if [ "$live_count" = "0" ]; then
    printf 'No live remote tmux sessions found.\n'
  else
    printf '%-24s  %-8s  %s\n' "name" "attached" "windows"
    printf '%s\n' "$live_rows" | while IFS=$'\t' read -r session_name attached windows; do
      [ -n "$session_name" ] || continue
      printf '%-24s  %-8s  %s\n' "$session_name" "$attached" "$windows"
    done
  fi

  printf '\nResumable Codex transcripts\n'
  if [ "$transcript_count" = "0" ]; then
    printf 'No resumable Codex transcripts found for this config scope.\n'
    return 0
  fi

  printf '%-36s  %-20s  %-12s  %s\n' "id" "timestamp" "branch" "cwd"
  printf '%s\n' "$transcript_rows" | while IFS=$'\t' read -r session_timestamp session_id session_cwd session_branch session_cli_version session_file; do
    [ -n "$session_id" ] || continue
    printf '%-36s  %-20s  %-12s  %s\n' \
      "$session_id" \
      "${session_timestamp%%.*}" \
      "${session_branch:--}" \
      "$session_cwd"
  done
}

remote_sessions_json() {
  local live_rows="$1"
  local transcript_rows="$2"

  printf '{\n'
  printf '  "remote": %s,\n' "$(
    jq -cn \
      --arg name "$REMOTE_NAME" \
      --arg workspace "$WORKSPACE_PATH" \
      --arg runtime_container "$REMOTE_RUNTIME_CONTAINER" \
      '{name:$name,workspace:$workspace,runtime_container:$runtime_container}'
  )"
  printf '  "live_sessions": [\n'
  if [ -n "$live_rows" ]; then
    printf '%s\n' "$live_rows" | while IFS=$'\t' read -r session_name attached windows; do
      [ -n "$session_name" ] || continue
      jq -cn \
        --arg name "$session_name" \
        --arg attached "$attached" \
        --arg windows "$windows" \
        '{name:$name,attached:($attached|tonumber),windows:($windows|tonumber)}'
    done | sed '$!s/$/,/'
  fi
  printf '  ],\n'
  printf '  "resumable_transcripts": [\n'
  if [ -n "$transcript_rows" ]; then
    printf '%s\n' "$transcript_rows" | while IFS=$'\t' read -r session_timestamp session_id session_cwd session_branch session_cli_version session_file; do
      [ -n "$session_id" ] || continue
      jq -cn \
        --arg id "$session_id" \
        --arg timestamp "$session_timestamp" \
        --arg cwd "$session_cwd" \
        --arg branch "$session_branch" \
        --arg cli_version "$session_cli_version" \
        --arg file "$session_file" \
        '{id:$id,timestamp:$timestamp,cwd:$cwd,branch:$branch,cli_version:$cli_version,file:$file}'
    done | sed '$!s/$/,/'
  fi
  printf '  ]\n'
  printf '}\n'
}

remote_run_up() {
  remote_bootstrap_full confirm-firecracker
  remote_require_podman_default_profile
  remote_reject_implicit_host_bridges

  remote_require_tailscale_auth_available
  remote_prepare_authorized_keys

  prepare_runtime_lease
  if remote_container_running "$REMOTE_RUNTIME_CONTAINER"; then
    if ! runtime_lease_has_artifact_receipt; then
      echo "[agent] ERROR: running remote sandbox predates runtime leases; run 'agent remote down' and start it again" >&2
      exit 1
    fi
    prepare_need_helper
  else
    prepare_runtime_artifacts
    prepare_container_api
    prepare_need_helper
    log_debug_context
  fi

  remote_create_pod
  remote_start_runtime_container
  remote_start_tailscale_sidecar
  remote_configure_tailscale_serve

  if [ "$REMOTE_START_CODEX" = "1" ]; then
    if [ -n "$REMOTE_RESUME_ARG" ]; then
      if [ "$REMOTE_RESUME_ARG" = "last" ]; then
        remote_exec_in_runtime /bin/agent-remote-codex resume --last
      else
        remote_exec_in_runtime /bin/agent-remote-codex resume "$REMOTE_RESUME_ARG"
      fi
    else
      remote_exec_in_runtime /bin/agent-remote-codex "${REMOTE_CODEX_ARGS[@]}"
    fi
  fi

  remote_print_status
}

remote_print_status() {
  printf 'Agent Remote\n\n'
  doctor_line "name" "$REMOTE_NAME"
  doctor_line "hostname" "$REMOTE_HOSTNAME"
  doctor_line "workspace" "${WORKSPACE_PATH:-${AGENT_WORKSPACE_PATH:-$PWD}}"
  doctor_line "pod" "$REMOTE_POD_NAME"
  doctor_line "runtime_container" "$REMOTE_RUNTIME_CONTAINER ($(remote_container_running "$REMOTE_RUNTIME_CONTAINER" && printf running || printf stopped))"
  doctor_line "tailscale_container" "$REMOTE_TS_CONTAINER ($(remote_container_running "$REMOTE_TS_CONTAINER" && printf running || printf stopped))"
  doctor_line "ssh_user" "${AGENT_REMOTE_USER:-codex}"
  doctor_line "ssh" "ssh ${AGENT_REMOTE_USER:-codex}@$REMOTE_HOSTNAME"
}

remote_run_down() {
  remote_bootstrap_light
  if remote_uses_pod; then
    if remote_pod_exists; then
      podman_runtime_cmd pod rm -f "$REMOTE_POD_NAME" >/dev/null
    fi
  else
    podman_runtime_cmd rm -f "$REMOTE_RUNTIME_CONTAINER" "$REMOTE_TS_CONTAINER" >/dev/null 2>&1 || true
  fi
  remove_runtime_lease "$REMOTE_STATE_DIR/runtime-lease"
  if [ "$REMOTE_DELETE_STATE" = "1" ]; then
    rm -rf "$REMOTE_STATE_DIR"
  fi
  echo "[agent] remote '$REMOTE_NAME' stopped"
}

remote_run_status() {
  remote_bootstrap_light
  WORKSPACE_PATH="${AGENT_WORKSPACE_PATH:-$PWD}"
  WORKSPACE_PATH="$(cd "$WORKSPACE_PATH" && pwd -P)"
  remote_print_status
}

remote_run_attach() {
  remote_bootstrap_light
  remote_require_podman_default_profile
  if ! remote_container_running "$REMOTE_RUNTIME_CONTAINER"; then
    echo "[agent] ERROR: remote '$REMOTE_NAME' is not running; run 'agent remote up' first" >&2
    exit 1
  fi
  remote_exec_in_runtime /bin/agent-remote-shell
}

remote_run_codex() {
  remote_bootstrap_light
  remote_require_podman_default_profile
  if ! remote_container_running "$REMOTE_RUNTIME_CONTAINER"; then
    echo "[agent] remote '$REMOTE_NAME' is not running; starting it first" >&2
    REMOTE_START_CODEX="1"
    remote_run_up
    return
  fi
  remote_exec_in_runtime /bin/agent-remote-codex "${REMOTE_CODEX_ARGS[@]}"
}

remote_run_ssh() {
  remote_bootstrap_light
  exec ssh "${REMOTE_SSH_ARGS[@]}" "${AGENT_REMOTE_USER:-codex}@$REMOTE_HOSTNAME"
}

remote_run_sessions() {
  local live_rows=""
  local transcript_rows=""

  resolve_sessions_args "${REMAINING_ARGS[@]}"
  remote_bootstrap_light
  WORKSPACE_PATH="${AGENT_WORKSPACE_PATH:-$PWD}"
  WORKSPACE_PATH="$(cd "$WORKSPACE_PATH" && pwd -P)"

  live_rows="$(remote_live_session_rows)"
  transcript_rows="$(remote_transcript_rows)"

  if [ "$SESSIONS_OUTPUT" = "json" ]; then
    remote_sessions_json "$live_rows" "$transcript_rows"
  else
    remote_sessions_text "$live_rows" "$transcript_rows"
  fi
}

run_remote_and_exit() {
  case "$REMOTE_ACTION" in
    up)
      remote_run_up
      ;;
    down)
      remote_run_down
      ;;
    status)
      remote_run_status
      ;;
    attach)
      remote_run_attach
      ;;
    codex)
      remote_run_codex
      ;;
    ssh)
      remote_run_ssh
      ;;
    sessions)
      remote_run_sessions
      ;;
  esac
  exit 0
}
