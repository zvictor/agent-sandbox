require_host_gc_root_tools() {
  if ! command -v nix-store >/dev/null 2>&1; then
    echo "[agent] ERROR: host GC-root registration requires nix-store" >&2
    return 1
  fi
}

validate_host_gc_root_paths() {
  local store_path="$1"
  local gcroot_path="$2"

  case "$store_path" in
    /nix/store/*) ;;
    *)
      echo "[agent] ERROR: refusing to root a non-store path: $store_path" >&2
      return 1
      ;;
  esac

  case "$gcroot_path" in
    /*) ;;
    *)
      echo "[agent] ERROR: GC-root path must be absolute: $gcroot_path" >&2
      return 1
      ;;
  esac

  case "$gcroot_path" in
    /nix/store|/nix/store/*)
      echo "[agent] ERROR: GC-root path must be outside the Nix store: $gcroot_path" >&2
      return 1
      ;;
  esac
}

assert_host_gc_root() {
  local store_path="$1"
  local gcroot_path="$2"
  local rooted_path=""

  validate_host_gc_root_paths "$store_path" "$gcroot_path" || return 1

  if [ ! -L "$gcroot_path" ]; then
    echo "[agent] ERROR: expected host GC root was not created: $gcroot_path" >&2
    return 1
  fi

  rooted_path="$(readlink -f "$gcroot_path" 2>/dev/null || true)"
  if [ "$rooted_path" != "$store_path" ]; then
    echo "[agent] ERROR: host GC root points to '$rooted_path', expected '$store_path': $gcroot_path" >&2
    return 1
  fi
}

register_host_gc_root() {
  local store_path="$1"
  local gcroot_path="$2"

  validate_host_gc_root_paths "$store_path" "$gcroot_path" || return 1
  require_host_gc_root_tools || return 1
  mkdir -p "$(dirname "$gcroot_path")"

  if ! env -u NIX_CONFIG nix-store \
    --add-root "$gcroot_path" --indirect --realise "$store_path" >/dev/null; then
    echo "[agent] ERROR: could not register host GC root: $gcroot_path" >&2
    return 1
  fi

  assert_host_gc_root "$store_path" "$gcroot_path"
}
