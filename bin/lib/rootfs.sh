ROOTFS_MIRROR_FORMAT=3
ROOTFS_RUNTIME_DIRS=$'etc\nconfig\nconfig/.codex\nconfig/.opencode\nconfig/.claude\ncache\ncache/.omp\nworkspace\nnixcache\nrun\nrun/agent-container-api\nrun/podman\nrun/secrets\nvar\nvar/run\nnix\nnix/store\nnix/var\nnix/var/nix\nnix/var/nix/daemon-socket\ntmp'
ROOTFS_RUNTIME_COPY_FILES=$'etc/passwd\netc/group\netc/nsswitch.conf'
ROOTFS_RUNTIME_EMPTY_FILES=$'etc/hosts\netc/hostname\netc/resolv.conf\ncache/.gitconfig\nrun/.containerenv\nvar/run/docker.sock\nrun/podman/podman.sock\nnix/var/nix/daemon-socket/socket'

detect_podman_rootfs_mode() {
  local override="${AGENT_PODMAN_ROOTFS_MODE:-auto}"
  local info

  case "$override" in
    auto|overlay|mirror) ;;
    *)
      echo "[agent] invalid AGENT_PODMAN_ROOTFS_MODE='$override' (expected: auto, overlay, mirror)" >&2
      exit 1
      ;;
  esac

  if [ "$override" != "auto" ]; then
    printf '%s\n' "$override"
    return
  fi

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
  local stale_dir=""

  for stale_dir in "$runs_dir"/*.tmp.*; do
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
    mkdir -p "$target_rootfs/$rel_path"
    chmod u+rwx "$target_rootfs/$rel_path" >/dev/null 2>&1 || true
  done < <(printf '%s\n' "$ROOTFS_RUNTIME_DIRS")

  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    if [ ! -e "$target_rootfs/$rel_path" ] && [ -r "$source_rootfs/$rel_path" ]; then
      cp -f "$source_rootfs/$rel_path" "$target_rootfs/$rel_path"
    fi
    chmod u+rw "$target_rootfs/$rel_path" >/dev/null 2>&1 || true
  done < <(printf '%s\n' "$ROOTFS_RUNTIME_COPY_FILES")

  rm -f "$target_rootfs/etc/mtab"
  ln -s /proc/mounts "$target_rootfs/etc/mtab"

  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    : > "$target_rootfs/$rel_path"
    chmod 0644 "$target_rootfs/$rel_path"
  done < <(printf '%s\n' "$ROOTFS_RUNTIME_EMPTY_FILES")
}

prepare_writable_rootfs_mirror() {
  local source_rootfs="$1"
  local key="$2"
  local runs_dir="$CACHE_DIR/rootfs-cache"
  local cache_key="${key}.mirror-v${ROOTFS_MIRROR_FORMAT}"
  local target_dir=""
  local ready_file=""
  local tmp_dir=""

  mkdir -p "$runs_dir"
  cleanup_stale_rootfs_mirror_temps "$runs_dir"
  target_dir="$runs_dir/$cache_key"
  ready_file="$runs_dir/$cache_key.ready"

  if [ -d "$target_dir" ] && [ -f "$ready_file" ]; then
    perf_log "rootfs local mirror cache hit"
    printf '%s\n' "$target_dir"
    return
  fi

  tmp_dir="$(mktemp -d "$runs_dir/${cache_key}.tmp.XXXXXX")"

  if ! cp -a --reflink=auto --no-preserve=ownership "$source_rootfs/." "$tmp_dir/" 2>/dev/null; then
    cp -a --no-preserve=ownership "$source_rootfs/." "$tmp_dir/"
  fi

  prepare_runtime_rootfs_state "$source_rootfs" "$tmp_dir"
  chmod u+rwx "$tmp_dir" >/dev/null 2>&1 || true

  if [ ! -d "$target_dir" ]; then
    mv "$tmp_dir" "$target_dir"
  else
    find "$tmp_dir" -type d -exec chmod u+rwx {} + >/dev/null 2>&1 || true
    rm -rf "$tmp_dir" >/dev/null 2>&1 || true
  fi

  : > "$ready_file"

  printf '%s\n' "$target_dir"
}

run_stream_image_helper() {
  local helper_attr="$1"
  shift 1

  local helper_tmpdir="${AGENT_HELPER_TMPDIR:-${CACHE_DIR:-${TMPDIR:-/tmp}}/tmp}"
  mkdir -p "$helper_tmpdir" >/dev/null 2>&1 || true

  TMPDIR="$helper_tmpdir" nix_cmd run "${SANDBOX_FLAKE}#streamImage.${helper_attr}" \
    "${PROJECT_OVERRIDE_ARGS[@]}" \
    "${LOCK_ARGS[@]}" -- "$@"
}
