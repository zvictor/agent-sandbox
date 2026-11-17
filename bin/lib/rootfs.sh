[ -n "${PODMAN_HOST_SH_LOADED:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/podman_host.sh"
ROOTFS_MIRROR_FORMAT=10
ROOTFS_RUNTIME_DIRS=$'etc\nconfig\nconfig/.codex\nconfig/.opencode\nconfig/.claude\ncache\ncache/.omp\nworkspace\nnixcache\nrun\nrun/agent-container-api\nrun/agent-nix-helper\nrun/agent-orca\nrun/agent-path-guard\nrun/agent-runtime-receipts\nrun/host-services\nrun/podman\nrun/secrets\nrun/systemd\nrun/systemd/system\nrun/user\nvar\nvar/run\nvar/tmp\nnix\nnix/store\nnix/var\nnix/var/nix\nnix/var/nix/daemon-socket\ntmp\ntmp/.X11-unix\nproc\nsys\nsys/fs\nsys/fs/cgroup\ndev\ndev/net\ndev/snd'
ROOTFS_RUNTIME_COPY_FILES=$'etc/passwd\netc/group\netc/nsswitch.conf'
ROOTFS_RUNTIME_EMPTY_FILES=$'etc/hosts\netc/hostname\netc/resolv.conf\ncache/.gitconfig\nrun/.containerenv\nvar/run/docker.sock\nrun/podman/podman.sock\nnix/var/nix/daemon-socket/socket'

detect_podman_rootfs_mode() {
  local override="${AGENT_PODMAN_ROOTFS_MODE:-auto}"
  local info
  local profile="${SANDBOX_PROFILE:-${AGENT_SANDBOX_PROFILE:-default}}"

  case "$override" in
    auto|overlay|mirror) ;;
    *)
      echo "[agent] invalid AGENT_PODMAN_ROOTFS_MODE='$override' (expected: auto, overlay, mirror)" >&2
      exit 1
      ;;
  esac

  if [ "$profile" = "firecracker-host" ]; then
    printf 'overlay\n'
    return
  fi

  if [ "$profile" = "rootless-linux" ]; then
    if [ "$override" = "overlay" ]; then
      echo "[agent] AGENT_SANDBOX_PROFILE=rootless-linux requires AGENT_PODMAN_ROOTFS_MODE=mirror; overlay cannot prepare mount targets with container root unmapped" >&2
      exit 1
    fi
    printf 'mirror\n'
    return
  fi

  if [ "$override" != "auto" ]; then
    printf '%s\n' "$override"
    return
  fi

  init_podman_storage_context 2>/dev/null || true
  info="$(podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphDriverName}} {{index .Store.GraphStatus "Native Overlay Diff"}}' 2>/dev/null || true)"
  case "$info" in
    "true overlay true")
      printf 'mirror\n'
      ;;
    *)
      printf 'overlay\n'
      ;;
  esac
}

cleanup_stale_rootfs_mirror_temps() {
  local runs_dir="$1"
  local cache_key="$2"
  local stale_dir=""

  for stale_dir in "$runs_dir/$cache_key".tmp.*; do
    [ -d "$stale_dir" ] || continue
    find "$stale_dir" -type d -exec chmod u+rwx {} + >/dev/null 2>&1 || true
    rm -rf "$stale_dir" >/dev/null 2>&1 || true
  done
}

prepare_runtime_rootfs_state() {
  local source_rootfs="$1"
  local target_rootfs="$2"
  local rel_path=""

  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    if ! mkdir -p "$target_rootfs/$rel_path" \
      || ! chmod u+rwx "$target_rootfs/$rel_path"; then
      echo "[agent] failed to prepare rootfs runtime directory: /$rel_path" >&2
      return 1
    fi
  done < <(printf '%s\n' "$ROOTFS_RUNTIME_DIRS")

  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    if [ ! -e "$target_rootfs/$rel_path" ] && [ -r "$source_rootfs/$rel_path" ]; then
      cp -f "$source_rootfs/$rel_path" "$target_rootfs/$rel_path"
    fi
    chmod u+rw "$target_rootfs/$rel_path" >/dev/null 2>&1 || true
  done < <(printf '%s\n' "$ROOTFS_RUNTIME_COPY_FILES")

  if ! rm -f "$target_rootfs/etc/mtab" \
    || ! ln -s /proc/mounts "$target_rootfs/etc/mtab"; then
    echo "[agent] failed to prepare rootfs /etc/mtab" >&2
    return 1
  fi

  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    if ! : > "$target_rootfs/$rel_path" \
      || ! chmod 0644 "$target_rootfs/$rel_path"; then
      echo "[agent] failed to prepare rootfs runtime file: /$rel_path" >&2
      return 1
    fi
  done < <(printf '%s\n' "$ROOTFS_RUNTIME_EMPTY_FILES")
}

validate_rootfs_executables() {
  local rootfs="$1"
  local executable

  for executable in sh catatonit agent-rootless-linux-entrypoint agent-remote-entrypoint; do
    if [ ! -x "$rootfs/bin/$executable" ]; then
      echo "[agent] ERROR: required rootfs executable is missing or unusable: $rootfs/bin/$executable" >&2
      return 1
    fi
  done
}

prepare_writable_rootfs_mirror() (
  local source_rootfs="$1"
  local key="$2"
  local runs_dir="$CACHE_DIR/rootfs-cache"
  local cache_key="${key}--${source_rootfs##*/}.mirror-v${ROOTFS_MIRROR_FORMAT}"
  local target_dir=""
  local ready_file=""
  local tmp_dir=""
  local mirror_lock_fd

  validate_rootfs_executables "$source_rootfs" || return 1

  if ! mkdir -p "$runs_dir"; then
    echo "[agent] failed to create rootfs mirror cache: $runs_dir" >&2
    return 1
  fi
  # Serialize publication and cleanup for this mirror. A different launcher
  # may still be copying another key into the same cache directory.
  exec {mirror_lock_fd}> "$runs_dir/$cache_key.lock" || return 1
  if ! flock "$mirror_lock_fd"; then
    echo "[agent] failed to lock rootfs mirror: $cache_key" >&2
    return 1
  fi
  cleanup_stale_rootfs_mirror_temps "$runs_dir" "$cache_key"
  target_dir="$runs_dir/$cache_key"
  ready_file="$runs_dir/$cache_key.ready"

  if [ "${AGENT_FORCE_REBUILD:-0}" != 1 ] \
    && [ -d "$target_dir" ] && [ -f "$ready_file" ] \
    && validate_rootfs_executables "$target_dir" 2>/dev/null; then
    perf_log "rootfs local mirror cache hit"
    printf '%s\n' "$target_dir"
    return
  fi

  # Discard incomplete copies, including directories that lack a ready marker.
  # Never discard a fresh copy in favor of an unvalidated existing directory.
  if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
    echo "[agent] replacing incomplete or invalidated rootfs mirror: $target_dir" >&2
    find "$target_dir" -type d -exec chmod u+rwx {} + || return 1
    rm -rf "$target_dir" || return 1
  fi
  rm -f "$ready_file" || return 1

  if ! tmp_dir="$(mktemp -d "$runs_dir/${cache_key}.tmp.XXXXXX")"; then
    echo "[agent] failed to create temporary rootfs mirror under: $runs_dir" >&2
    return 1
  fi

  trap 'cleanup_stale_rootfs_mirror_temps "$runs_dir" "$cache_key"' EXIT

  if ! cp -a --reflink=auto --no-preserve=ownership "$source_rootfs/." "$tmp_dir/"; then
    echo "[agent] failed to copy rootfs mirror from: $source_rootfs" >&2
    return 1
  fi

  if ! chmod u+rwx "$tmp_dir" \
    || ! prepare_runtime_rootfs_state "$source_rootfs" "$tmp_dir" \
    || ! validate_rootfs_executables "$tmp_dir"; then
    echo "[agent] failed to prepare writable rootfs mirror" >&2
    return 1
  fi

  if ! mv -T "$tmp_dir" "$target_dir"; then
    echo "[agent] failed to publish rootfs mirror: $target_dir" >&2
    return 1
  fi

  if ! : > "$ready_file"; then
    echo "[agent] failed to mark rootfs mirror ready: $ready_file" >&2
    return 1
  fi

  printf '%s\n' "$target_dir"
)
