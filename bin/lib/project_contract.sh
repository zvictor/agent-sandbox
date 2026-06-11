PROJECT_CONTRACT_ALLOWLIST_FILE_NAME=agent-sandbox.paths

copy_if_present() {
  local source_path="$1"
  local target_path="$2"

  if [ -f "$source_path" ]; then
    mkdir -p "$(dirname "$target_path")"
    cp -a "$source_path" "$target_path"
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
  local allowlist_path="$PROJECT_NIX_DIR/$PROJECT_CONTRACT_ALLOWLIST_FILE_NAME"
  local rel_path=""

  copy_if_present "$allowlist_path" "$target_dir/nix/$PROJECT_CONTRACT_ALLOWLIST_FILE_NAME"

  if [ -f "$allowlist_path" ]; then
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
  local file_path=""

  copy_if_present "$PROJECT_ROOT/shell.nix" "$target_dir/shell.nix"
  copy_if_present "$PROJECT_ROOT/default.nix" "$target_dir/default.nix"
  copy_if_present "$PROJECT_ROOT/flake.nix" "$target_dir/flake.nix"
  copy_if_present "$PROJECT_ROOT/flake.lock" "$target_dir/flake.lock"

  if [ ! -f "$target_dir/flake.lock" ] && [ -f "$target_dir/shell.nix" ]; then
    pin_shell_fetchtarball "$target_dir"
  fi

  if [ -d "$PROJECT_NIX_DIR" ]; then
    while IFS= read -r file_path; do
      mkdir -p "$target_dir/nix/$(dirname "$file_path")"
      cp -a "$PROJECT_NIX_DIR/$file_path" "$target_dir/nix/$file_path"
    done < <(
      cd "$PROJECT_NIX_DIR" && find . -type f \( -name '*.nix' -o -name '*.lock' \) -print | sed 's#^\./##' | LC_ALL=C sort
    )
  fi

  stage_project_contract_allowlist "$target_dir"
}
