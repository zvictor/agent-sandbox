PROJECT_CONTRACT_ALLOWLIST_FILE_NAME=agent-sandbox.paths

copy_if_present() {
  local source_path="$1"
  local target_path="$2"

  if [ -f "$source_path" ]; then
    mkdir -p "$(dirname "$target_path")"
    cp -aL "$source_path" "$target_path"
  fi
}

resolve_existing_path() {
  local path="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$path"
  else
    return 1
  fi
}

resolve_project_contract_nix_dir() {
  local resolved_shell=""
  local shell_dir=""

  if [ -d "$PROJECT_NIX_DIR" ]; then
    printf '%s\n' "$PROJECT_NIX_DIR"
    return 0
  fi

  if [ -n "${AGENT_PROJECT_NIX_DIR:-}" ] || [ ! -e "$PROJECT_ROOT/shell.nix" ]; then
    return 0
  fi

  resolved_shell="$(resolve_existing_path "$PROJECT_ROOT/shell.nix" 2>/dev/null || true)"
  [ -n "$resolved_shell" ] || return 0

  shell_dir="$(dirname "$resolved_shell")"
  if [ -d "$shell_dir/nix" ]; then
    printf '%s\n' "$shell_dir/nix"
  fi
}

is_mutable_fetchtarball_url() {
  case "$1" in
    http://nixos.org/channels/*/nixexprs.tar.xz|https://nixos.org/channels/*/nixexprs.tar.xz)
      return 0
      ;;
    http://channels.nixos.org/*/nixexprs.tar.xz|https://channels.nixos.org/*/nixexprs.tar.xz)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_project_contract_path() {
  local rel_path="$1"

  rel_path="$(printf '%s' "$rel_path" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$rel_path" in
    ./*)
      rel_path="${rel_path#./}"
      ;;
  esac

  case "$rel_path" in
    "")
      printf '\n'
      return
      ;;
    "."|".."|/*|../*|*/../*|*"/.."|*"/../"* )
      echo "[agent] ERROR: invalid project contract path '$1'" >&2
      exit 1
      ;;
  esac

  printf '%s\n' "$rel_path"
}

stage_project_contract_path() {
  local target_dir="$1"
  local rel_path="$2"
  local source_path="$PROJECT_ROOT/$rel_path"
  local target_path="$target_dir/$rel_path"

  if [ ! -e "$source_path" ]; then
    echo "[agent] ERROR: project contract path '$rel_path' not found at $source_path" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$target_path")"
  cp -a "$source_path" "$target_path"
}

stage_project_contract_allowlist() {
  local target_dir="$1"
  local source_nix_dir="${2:-$PROJECT_NIX_DIR}"
  local allowlist_path=""
  local rel_path=""

  if [ -n "$source_nix_dir" ]; then
    allowlist_path="$source_nix_dir/$PROJECT_CONTRACT_ALLOWLIST_FILE_NAME"
    copy_if_present "$allowlist_path" "$target_dir/nix/$PROJECT_CONTRACT_ALLOWLIST_FILE_NAME"
  fi

  if [ -n "$allowlist_path" ] && [ -f "$allowlist_path" ]; then
    while IFS= read -r rel_path; do
      rel_path="$(normalize_project_contract_path "$rel_path")"
      [ -n "$rel_path" ] || continue
      stage_project_contract_path "$target_dir" "$rel_path"
    done < "$allowlist_path"
  fi

  if [ -n "${AGENT_PROJECT_CONTRACT_FILES:-}" ]; then
    while IFS= read -r rel_path; do
      rel_path="$(normalize_project_contract_path "$rel_path")"
      [ -n "$rel_path" ] || continue
      stage_project_contract_path "$target_dir" "$rel_path"
    done < <(split_csv_or_lines "$AGENT_PROJECT_CONTRACT_FILES")
  fi
}

pin_shell_fetchtarball() {
  local target_dir="$1"
  local shell_file="$target_dir/shell.nix"
  local content=""
  local url=""
  local hash=""
  local cache_key=""
  local cache_file=""
  local cacheable="1"
  local pinned_file="$target_dir/.agent-sandbox-pinned-nixpkgs.json"

  content="$(cat "$shell_file")"
  url="$(printf '%s' "$content" | sed -n 's/.*fetchTarball[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

  if [ -z "$url" ]; then
    return 0
  fi

  cache_key="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  cache_file="${HOME}/.cache/agent-sandbox/pinned-nixpkgs-${cache_key}.json"

  if is_mutable_fetchtarball_url "$url"; then
    cacheable="0"
  fi

  if [ "$cacheable" = "1" ] && [ -f "$cache_file" ]; then
    cp "$cache_file" "$pinned_file"
    echo "[agent] pinned fetchTarball for shell.nix (cached): $url" >&2
    return 0
  fi

  hash="$(nix-prefetch-url --unpack "$url" 2>/dev/null)"

  if [ -z "$hash" ]; then
    echo "[agent] warning: could not prefetch $url, shell.nix may need --impure" >&2
    return 0
  fi

  printf '{"url":"%s","sha256":"%s"}\n' "$url" "$hash" > "$pinned_file"
  if [ "$cacheable" = "1" ]; then
    mkdir -p "$(dirname "$cache_file")"
    cp "$pinned_file" "$cache_file"
    echo "[agent] pinned fetchTarball for shell.nix: $url" >&2
  else
    echo "[agent] pinned fetchTarball for shell.nix (refreshed mutable URL): $url" >&2
  fi
}

stage_project_contract_input() {
  local target_dir="$1"
  local source_nix_dir=""
  local file_path=""

  copy_if_present "$PROJECT_ROOT/shell.nix" "$target_dir/shell.nix"
  copy_if_present "$PROJECT_ROOT/default.nix" "$target_dir/default.nix"
  copy_if_present "$PROJECT_ROOT/flake.nix" "$target_dir/flake.nix"
  copy_if_present "$PROJECT_ROOT/flake.lock" "$target_dir/flake.lock"

  if [ ! -f "$target_dir/flake.lock" ] && [ -f "$target_dir/shell.nix" ]; then
    pin_shell_fetchtarball "$target_dir"
  fi

  source_nix_dir="$(resolve_project_contract_nix_dir)"
  if [ -n "$source_nix_dir" ] && [ -d "$source_nix_dir" ]; then
    while IFS= read -r file_path; do
      [ -f "$source_nix_dir/$file_path" ] || continue
      mkdir -p "$target_dir/nix/$(dirname "$file_path")"
      cp -aL "$source_nix_dir/$file_path" "$target_dir/nix/$file_path"
    done < <(
      cd "$source_nix_dir" && find . \( -type f -o -type l \) -print | sed 's#^\./##' | LC_ALL=C sort
    )
  fi

  stage_project_contract_allowlist "$target_dir" "$source_nix_dir"
}
