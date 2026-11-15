# Podman host runtime and storage isolation helpers.
[ -z "${PODMAN_HOST_SH_LOADED:-}" ] || return 0
PODMAN_HOST_SH_LOADED=1

podman_in_initial_user_namespace() {
  local uid_map_file="${AGENT_TEST_UID_MAP:-/proc/self/uid_map}"
  [ -r "$uid_map_file" ] || return 1
  awk 'NR == 1 && $1 == 0 && $2 == 0 && $3 == 4294967295 { valid = 1 } END { exit !valid }' "$uid_map_file"
}

# Keep Podman's pause process and storage separate from the host when the
# launcher is already in a user namespace. systemd-run retains the original
# XDG_RUNTIME_DIR; only the Podman executable sees the private directory.
prepare_nested_podman_context() {
  [ "${RUNTIME:-}" = podman ] || return 0
  [ "${OS_NAME:-$(uname -s)}" = Linux ] || return 0
  [ "${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}" = rootless-linux ] || return 0
  podman_in_initial_user_namespace && return 0
  [ -z "${SANDBOX_NESTED_PODMAN_CONTEXT:-}" ] || return 0

  local runtime_dir="${XDG_RUNTIME_DIR:-}" podman_path="" context="" key=""
  for key in AGENT_SANDBOX_PODMAN_DIR AGENT_SANDBOX_PODMAN_GRAPHROOT AGENT_SANDBOX_PODMAN_RUNROOT AGENT_SANDBOX_PODMAN_STORAGE_CONF; do
    if [ -n "${!key:-}" ]; then
      echo "[agent] ERROR: $key cannot be overridden for nested rootless Podman" >&2
      return 1
    fi
  done
  [ -n "$runtime_dir" ] && [ -d "$runtime_dir" ] && [ -w "$runtime_dir" ] || {
    echo '[agent] ERROR: nested rootless Podman requires a writable XDG_RUNTIME_DIR' >&2
    return 1
  }
  podman_path="$(type -P podman)" || return 1
  context="$(mktemp -d "$runtime_dir/agent-sandbox-nested.XXXXXX")" || return 1
  mkdir -m 700 "$context/bin" "$context/runtime" || return 1
  if ! printf '#!/usr/bin/env bash\nexport XDG_RUNTIME_DIR=%q\nexec %q "$@"\n' \
    "$context/runtime" "$podman_path" > "$context/bin/podman" || ! chmod 700 "$context/bin/podman"; then
    echo '[agent] ERROR: could not create isolated Podman launcher' >&2
    return 1
  fi
  SANDBOX_NESTED_PODMAN_CONTEXT="$context"
  AGENT_SANDBOX_PODMAN_DIR="$context/storage"
  AGENT_SANDBOX_PODMAN_GRAPHROOT="$context/storage/graphroot"
  AGENT_SANDBOX_PODMAN_RUNROOT="$context/runroot"
  AGENT_SANDBOX_PODMAN_STORAGE_CONF="$context/storage/storage.conf"
  PATH="$context/bin:$PATH"
  export SANDBOX_NESTED_PODMAN_CONTEXT AGENT_SANDBOX_PODMAN_DIR AGENT_SANDBOX_PODMAN_GRAPHROOT
  export AGENT_SANDBOX_PODMAN_RUNROOT AGENT_SANDBOX_PODMAN_STORAGE_CONF PATH
}

assert_host_podman_namespace() {
  [ "${RUNTIME:-}" = "podman" ] || return 0
  [ "${OS_NAME:-$(uname -s)}" = "Linux" ] || return 0
  [ -z "${SANDBOX_NESTED_PODMAN_CONTEXT:-}" ] || return 0
  [ "${AGENT_ALLOW_NESTED_PODMAN:-0}" = "0" ] || return 0

  local uid_map_file="${AGENT_TEST_UID_MAP:-/proc/self/uid_map}"
  if [ -r "$uid_map_file" ]; then
    if ! awk '
      NR == 1 && $1 == 0 && $2 == 0 && $3 == 4294967295 {
        valid = 1
      }
      END { exit !valid }
    ' "$uid_map_file" 2>/dev/null; then
      echo "[agent] ERROR: Refusing to invoke host Podman from a nested user namespace." >&2
      echo "[agent] Host Podman runtime state cannot be safely shared across user namespaces." >&2
      echo "[agent] Run the sandbox directly on the host or use AGENT_ALLOW_NESTED_PODMAN=1." >&2
      return 1
    fi
  fi
  return 0
}

podman_host_write_storage_conf() {
  local conf_path="$1"
  local graphroot="$2"
  local runroot="$3"
  local host_graphroot="${HOST_PODMAN_DEFAULT_GRAPHROOT:-${HOST_HOME:-$HOME}/.local/share/containers/storage}"
  local fuse_overlayfs_bin=""

  if [ -x "/run/current-system/sw/bin/fuse-overlayfs" ]; then
    fuse_overlayfs_bin="/run/current-system/sw/bin/fuse-overlayfs"
  elif command -v fuse-overlayfs >/dev/null 2>&1; then
    fuse_overlayfs_bin="$(command -v fuse-overlayfs)"
  fi

  local tmp_conf="${conf_path}.$$"
  {
    printf '[storage]\n'
    printf 'driver = "overlay"\n'
    printf 'graphroot = "%s"\n' "$graphroot"
    printf 'runroot = "%s"\n' "$runroot"
    printf '\n[storage.options]\n'
    if [ -z "${SANDBOX_NESTED_PODMAN_CONTEXT:-}" ] && [ -d "$host_graphroot" ]; then
      printf 'additionalimagestores = ["%s"]\n' "$host_graphroot"
    fi
    printf '\n[storage.options.overlay]\n'
    printf 'mountopt = "nodev,metacopy=on"\n'
    if [ -n "$fuse_overlayfs_bin" ]; then
      printf 'mount_program = "%s"\n' "$fuse_overlayfs_bin"
    fi
  } > "$tmp_conf" 2>/dev/null || return 1

  if ! mv -f "$tmp_conf" "$conf_path" 2>/dev/null; then
    rm -f "$tmp_conf" 2>/dev/null || true
    return 1
  fi
}

init_podman_storage_context() {
  [ "${RUNTIME:-}" = "podman" ] || return 0
  if firecracker_host_profile 2>/dev/null; then
    return 0
  fi

  local home_dir="${HOST_HOME:-$HOME}"
  local base_dir="${AGENT_SANDBOX_PODMAN_DIR:-${XDG_CACHE_HOME:-$home_dir/.cache}/agent-sandbox/podman}"
  AGENT_SANDBOX_PODMAN_GRAPHROOT="${AGENT_SANDBOX_PODMAN_GRAPHROOT:-$base_dir/graphroot}"

  local default_runroot=""
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    default_runroot="$XDG_RUNTIME_DIR/agent-sandbox-podman/runroot"
  else
    default_runroot="/run/user/$(id -u)/agent-sandbox-podman/runroot"
  fi
  AGENT_SANDBOX_PODMAN_RUNROOT="${AGENT_SANDBOX_PODMAN_RUNROOT:-$default_runroot}"
  AGENT_SANDBOX_PODMAN_STORAGE_CONF="${AGENT_SANDBOX_PODMAN_STORAGE_CONF:-$base_dir/storage.conf}"

  if ! mkdir -p "$base_dir" "$AGENT_SANDBOX_PODMAN_GRAPHROOT" "$AGENT_SANDBOX_PODMAN_RUNROOT"; then
    echo '[agent] ERROR: could not create isolated Podman storage directories' >&2
    return 1
  fi

  if ! podman_host_write_storage_conf "$AGENT_SANDBOX_PODMAN_STORAGE_CONF" \
    "$AGENT_SANDBOX_PODMAN_GRAPHROOT" \
    "$AGENT_SANDBOX_PODMAN_RUNROOT"; then
    echo '[agent] ERROR: could not write isolated Podman storage configuration' >&2
    return 1
  fi

  export CONTAINERS_STORAGE_CONF="$AGENT_SANDBOX_PODMAN_STORAGE_CONF"
}

podman_runtime_cmd() {
  if firecracker_host_profile 2>/dev/null; then
    sudo -n podman "$@"
    return
  fi

  init_podman_storage_context || return 1
  podman "$@"
}

collect_forbidden_storage_paths() {
  local -a paths=()
  local home_dir="${HOST_HOME:-$HOME}"
  local uid=""
  uid="$(id -u 2>/dev/null || true)"
  local runtime_dir="${XDG_RUNTIME_DIR:-${uid:+/run/user/$uid}}"
  local cache_dir="${XDG_CACHE_HOME:-$home_dir/.cache}"
  local podman_dir="${AGENT_SANDBOX_PODMAN_DIR:-$cache_dir/agent-sandbox/podman}"

  [ -n "$home_dir" ] && paths+=( "$home_dir/.local/share/containers" )
  [ -n "${XDG_DATA_HOME:-}" ] && paths+=( "$XDG_DATA_HOME/containers" )
  [ -n "$runtime_dir" ] && paths+=( "$runtime_dir/containers" )
  paths+=( "/var/lib/containers" "/run/containers" )

  paths+=( "$podman_dir" )
  if [ -n "${AGENT_SANDBOX_PODMAN_GRAPHROOT:-}" ]; then
    paths+=( "$AGENT_SANDBOX_PODMAN_GRAPHROOT" )
  fi

  if [ -n "${AGENT_SANDBOX_PODMAN_RUNROOT:-}" ]; then
    paths+=( "$AGENT_SANDBOX_PODMAN_RUNROOT" )
  elif [ -n "$runtime_dir" ]; then
    paths+=( "$runtime_dir/agent-sandbox-podman" )
  fi

  printf '%s\n' "${paths[@]}"
}

podman_host_canonicalize_path() {
  local p="$1"
  [ -n "$p" ] || return 1
  case "$p" in
    "~") p="${HOST_HOME:-$HOME}" ;;
    "~/"*) p="${HOST_HOME:-$HOME}/${p#~/}" ;;
  esac
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p" 2>/dev/null || printf '%s\n' "$p"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -m "$p" 2>/dev/null || readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
  else
    printf '%s\n' "$p"
  fi
}

is_forbidden_storage_path() {
  local candidate="$1"
  local forbidden=""
  local resolved_candidate=""
  local resolved_forbidden=""

  [ -n "$candidate" ] || return 1

  resolved_candidate="$(podman_host_canonicalize_path "$candidate")"
  [ -n "$resolved_candidate" ] || return 1

  # Mounting filesystem root exposes all host storage paths
  if [ "$resolved_candidate" = "/" ]; then
    return 0
  fi
  resolved_candidate="${resolved_candidate%/}"

  while IFS= read -r forbidden; do
    [ -n "$forbidden" ] || continue

    resolved_forbidden="$(podman_host_canonicalize_path "$forbidden")"
    [ -n "$resolved_forbidden" ] || continue
    [ "$resolved_forbidden" != "/" ] || continue
    resolved_forbidden="${resolved_forbidden%/}"
    [ -n "$resolved_forbidden" ] || continue

    if [ "$resolved_candidate" = "$resolved_forbidden" ]; then
      return 0
    fi
    case "$resolved_candidate" in
      "$resolved_forbidden"/*) return 0 ;;
    esac
    case "$resolved_forbidden" in
      "$resolved_candidate"/*) return 0 ;;
    esac
  done < <(collect_forbidden_storage_paths)

  return 1
}

validate_container_mount_safety() {
  [ "${AGENT_ALLOW_CONTAINER_STORAGE_MOUNTS:-0}" = "0" ] || return 0

  local i=0
  local arg=""
  local mount_spec=""
  local source_path=""

  while [ "$i" -lt "${#ARGS[@]}" ]; do
    arg="${ARGS[$i]}"
    mount_spec=""
    case "$arg" in
      --) break ;;
      -v|--volume)
        i=$((i + 1))
        mount_spec="${ARGS[$i]}"
        ;;
      --volume=*)
        mount_spec="${arg#--volume=}"
        ;;
    esac

    if [ -n "$mount_spec" ]; then
      source_path="${mount_spec%%:*}"
      if is_forbidden_storage_path "$source_path"; then
        echo "[agent] ERROR: Refusing to mount host container storage path into sandbox: $source_path" >&2
        echo "[agent] Exposing host container runtime or graph storage risks corruption (issue #29986)." >&2
        return 1
      fi
    fi
    i=$((i + 1))
  done

  return 0
}
