#!/usr/bin/env bash
set -euo pipefail

BRIDGE_DIR="${AGENT_NEED_HELPER_DIR:-/run/agent-nix-helper}"
REQUESTS_DIR="$BRIDGE_DIR/requests"
RESPONSES_DIR="$BRIDGE_DIR/responses"
TIMEOUT="${AGENT_NEED_TIMEOUT:-600}"
HELPER_WAITED=0
CACHE_HOME="${XDG_CACHE_HOME:-/cache}"
NEED_CACHE_DIR="${AGENT_NEED_CACHE_DIR:-$CACHE_HOME/need}"
MATERIALIZE_CACHE_DIR="$NEED_CACHE_DIR/materialized"
TOOLS_DIR="${AGENT_NEED_TOOLS_DIR:-$NEED_CACHE_DIR/bin}"
INDEX_DIR="${AGENT_NEED_INDEX_DIR:-$CACHE_HOME/nix-index}"
INDEX_FILE="$INDEX_DIR/files"
BOOTSTRAP_LOCK_DIR="$INDEX_DIR/.bootstrap.lock"
BOOTSTRAP_PID_FILE="$INDEX_DIR/.bootstrap.pid"
BOOTSTRAP_LOG_FILE="$INDEX_DIR/bootstrap.log"
INDEX_BOOTSTRAP_STATE="unknown"

usage() {
  cat >&2 <<'EOF'
usage:
  need <command>
  need lookup <command>
  need missing <command> [args...]
  need run <command-or-installable> -- command args...
  need inject <command-or-installable>
  need bootstrap-index
  need update-index

notes:
  - bare names like 'pnpm' are resolved through nix-locate when the local command
    index is available
  - explicit installables like 'nixpkgs#pnpm' bypass lookup
EOF
  exit 1
}

tool_notice() {
  echo "[agent] $*" >&2
}

cache_key() {
  local value="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_'
  fi
}

load_response_file() {
  local response_file="$1"
  local remove_after="${2:-0}"
  local key=""
  local value=""

  status=""
  installable=""
  out_path=""
  bin_path=""
  message=""

  while IFS='=' read -r key value; do
    case "$key" in
      status) status="$value" ;;
      installable) installable="$value" ;;
      out_path) out_path="$value" ;;
      bin_path) bin_path="$value" ;;
      message) message="$value" ;;
    esac
  done < "$response_file"

  if [ "$remove_after" = "1" ]; then
    rm -f "$response_file"
  fi
}

response_is_usable() {
  if [ -n "$bin_path" ] && [ -d "$bin_path" ]; then
    return 0
  fi

  if [ -n "$out_path" ] && [ -e "$out_path" ]; then
    return 0
  fi

  return 1
}

materialize_cache_file() {
  local target="$1"
  printf '%s/%s.env\n' "$MATERIALIZE_CACHE_DIR" "$(cache_key "$target")"
}

load_cached_materialization() {
  local target="$1"
  local cache_file

  cache_file="$(materialize_cache_file "$target")"
  [ -f "$cache_file" ] || return 1

  load_response_file "$cache_file" "0"
  [ "$status" = "ok" ] || return 1
  response_is_usable || return 1
}

store_cached_materialization() {
  local target="$1"
  local cache_file
  local tmp_file=""

  cache_file="$(materialize_cache_file "$target")"
  mkdir -p "$MATERIALIZE_CACHE_DIR"
  tmp_file="$(mktemp "${cache_file}.tmp.XXXXXX")"
  {
    printf 'status=ok\n'
    printf 'installable=%s\n' "$installable"
    printf 'out_path=%s\n' "$out_path"
    printf 'bin_path=%s\n' "$bin_path"
  } > "$tmp_file"
  mv -f "$tmp_file" "$cache_file"
}

helper_request() {
  local target_installable="$1"
  local req_id=""
  local waited=0

  req_id="$(date +%s)-$$-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%s' "$$")"
  request_file="$REQUESTS_DIR/$req_id.req"
  response_file="$RESPONSES_DIR/$req_id.resp"
  HELPER_WAITED=0

  mkdir -p "$REQUESTS_DIR" "$RESPONSES_DIR"
  tool_notice "materializing $target_installable via the host Nix helper..."
  {
    printf 'command=materialize\n'
    printf 'installable=%s\n' "$target_installable"
  } > "$request_file"

  while [ "$waited" -lt "$TIMEOUT" ]; do
    if [ -f "$response_file" ]; then
      HELPER_WAITED="$waited"
      return 0
    fi

    sleep 1
    waited=$((waited + 1))
    if [ $((waited % 5)) -eq 0 ]; then
      tool_notice "still materializing $target_installable (${waited}s elapsed)"
    fi
  done

  echo "[agent] nix helper timed out waiting for '$target_installable'" >&2
  exit 1
}

load_helper_response() {
  local target_installable="$1"

  load_response_file "$response_file" "1"
  if [ "$status" != "ok" ]; then
    echo "[agent] nix helper failed for '$target_installable': $message" >&2
    exit 1
  fi

  if [ "$HELPER_WAITED" -gt 0 ]; then
    tool_notice "finished materializing $target_installable in ${HELPER_WAITED}s"
  fi
}

project_nix_file() {
  local first_nix=""

  if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/flake.nix" ]; then
    printf '%s\n' "$PROJECT_ROOT/flake.nix"
    return 0
  fi

  if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/shell.nix" ]; then
    printf '%s\n' "$PROJECT_ROOT/shell.nix"
    return 0
  fi

  if [ -n "${PROJECT_ROOT:-}" ] && [ -f "$PROJECT_ROOT/default.nix" ]; then
    printf '%s\n' "$PROJECT_ROOT/default.nix"
    return 0
  fi

  if [ -n "${PROJECT_ROOT:-}" ] && [ -d "$PROJECT_ROOT/nix" ]; then
    first_nix="$(find "$PROJECT_ROOT/nix" -type f -name '*.nix' | LC_ALL=C sort | head -n 1 || true)"
    if [ -n "$first_nix" ]; then
      printf '%s\n' "$first_nix"
      return 0
    fi
  fi

  return 1
}

display_path() {
  local path="$1"

  if [ -n "${PROJECT_ROOT:-}" ]; then
    case "$path" in
      "$PROJECT_ROOT")
        printf '.\n'
        return 0
        ;;
      "$PROJECT_ROOT"/*)
        printf './%s\n' "${path#"$PROJECT_ROOT/"}"
        return 0
        ;;
    esac
  fi

  printf '%s\n' "$path"
}

guess_installable_for_command() {
  local command_name="$1"

  case "$command_name" in
    python|python3)
      printf 'nixpkgs#python3\n'
      ;;
    pip|pip3)
      printf 'nixpkgs#python3Packages.pip\n'
      ;;
    node|npm)
      printf 'nixpkgs#nodejs\n'
      ;;
    pnpm)
      printf 'nixpkgs#pnpm\n'
      ;;
    go)
      printf 'nixpkgs#go\n'
      ;;
    cargo|rustc)
      printf 'nixpkgs#cargo\n'
      ;;
    docker)
      printf 'nixpkgs#docker-client\n'
      ;;
    docker-compose)
      printf 'nixpkgs#docker-compose\n'
      ;;
    podman)
      printf 'nixpkgs#podman\n'
      ;;
    *)
      if printf '%s\n' "$command_name" | grep -Eq '^[A-Za-z0-9._+-]+$'; then
        printf 'nixpkgs#%s\n' "$command_name"
      else
        return 1
      fi
      ;;
  esac
}

index_available() {
  command -v nix-locate >/dev/null 2>&1 || return 1
  [ -s "$INDEX_FILE" ]
}

index_bootstrap_running() {
  local bootstrap_pid=""

  [ -f "$BOOTSTRAP_PID_FILE" ] || return 1
  bootstrap_pid="$(cat "$BOOTSTRAP_PID_FILE" 2>/dev/null || true)"
  [ -n "$bootstrap_pid" ] || return 1
  kill -0 "$bootstrap_pid" 2>/dev/null
}

ensure_index_bootstrap() {
  local bootstrap_pid=""

  INDEX_BOOTSTRAP_STATE="unknown"

  if index_available; then
    INDEX_BOOTSTRAP_STATE="ready"
    return 0
  fi

  if [ "${AGENT_NEED_BOOTSTRAP_INDEX:-1}" != "1" ]; then
    INDEX_BOOTSTRAP_STATE="disabled"
    return 1
  fi

  mkdir -p "$INDEX_DIR"

  if index_bootstrap_running; then
    INDEX_BOOTSTRAP_STATE="running"
    return 0
  fi

  if ! mkdir "$BOOTSTRAP_LOCK_DIR" 2>/dev/null; then
    bootstrap_pid="$(cat "$BOOTSTRAP_PID_FILE" 2>/dev/null || true)"
    if [ -n "$bootstrap_pid" ] && kill -0 "$bootstrap_pid" 2>/dev/null; then
      INDEX_BOOTSTRAP_STATE="running"
      return 0
    fi
    rm -rf "$BOOTSTRAP_LOCK_DIR" "$BOOTSTRAP_PID_FILE"
    mkdir "$BOOTSTRAP_LOCK_DIR" 2>/dev/null || {
      INDEX_BOOTSTRAP_STATE="running"
      return 0
    }
  fi

  INDEX_BOOTSTRAP_STATE="started"
  if command -v nohup >/dev/null 2>&1; then
    nohup /bin/need update-index >"$BOOTSTRAP_LOG_FILE" 2>&1 &
  else
    /bin/need update-index >"$BOOTSTRAP_LOG_FILE" 2>&1 &
  fi
  printf "%s\n" "$!" > "$BOOTSTRAP_PID_FILE"
}

locate_candidates() {
  local command_name="$1"

  index_available || return 2
  nix-locate --minimal --no-group --type x --type s --whole-name --at-root "/bin/$command_name" 2>/dev/null | awk 'NF && !seen[$0]++'
}

score_candidate() {
  local command_name="$1"
  local attr="$2"
  local leaf="${attr##*.}"
  local score="50"

  if [ "$attr" = "$command_name" ] || [ "$attr" = "$command_name.out" ]; then
    score="00"
  elif [ "$leaf" = "$command_name" ] || [ "$leaf" = "$command_name.out" ] || [ "${leaf%.out}" = "$command_name" ]; then
    score="01"
  elif printf '%s\n' "$attr" | grep -Eq "(^|\\.)${command_name}(\\.out)?$"; then
    score="02"
  fi

  printf '%s\t%05d\t%s\n' "$score" "${#attr}" "$attr"
}

sorted_candidates() {
  local command_name="$1"
  local candidate=""
  local -a candidates=()

  mapfile -t candidates < <(locate_candidates "$command_name" || true)
  [ "${#candidates[@]}" -gt 0 ] || return 1

  for candidate in "${candidates[@]}"; do
    score_candidate "$command_name" "$candidate"
  done | sort -t $'\t' -k1,1 -k2,2n -k3,3 | cut -f3
}

render_pkgs_attr_expr() {
  local attr="$1"
  local part=""
  local rendered="pkgs"
  local stripped="${attr%.out}"
  local -a parts=()

  IFS='.' read -r -a parts <<< "$stripped"
  for part in "${parts[@]}"; do
    if printf '%s\n' "$part" | grep -Eq "^[A-Za-z_][A-Za-z0-9_']*$"; then
      rendered="$rendered.$part"
    else
      rendered="$rendered.\"$part\""
    fi
  done

  printf '%s\n' "$rendered"
}

render_command_example() {
  local command_name="$1"
  shift || true

  if [ "$#" -gt 0 ]; then
    printf '%q' "$command_name"
    while [ "$#" -gt 0 ]; do
      printf ' %q' "$1"
      shift
    done
    printf '\n'
  else
    printf '%s ...\n' "$command_name"
  fi
}

resolve_target() {
  local target="$1"
  local best_attr=""
  local -a candidates=()

  resolved_target="$target"
  resolved_installable=""
  resolved_attr=""
  resolution_mode=""

  if printf '%s\n' "$target" | grep -q '#'; then
    resolved_installable="$target"
    resolved_attr="${target#*#}"
    resolution_mode="explicit"
    return 0
  fi

  if mapfile -t candidates < <(sorted_candidates "$target" || true) && [ "${#candidates[@]}" -gt 0 ]; then
    best_attr="${candidates[0]%.out}"
    resolved_installable="nixpkgs#$best_attr"
    resolved_attr="$best_attr"
    resolution_mode="index"
    return 0
  fi

  resolved_installable="$(guess_installable_for_command "$target" || true)"
  if [ -n "$resolved_installable" ]; then
    resolved_attr="${resolved_installable#nixpkgs#}"
    resolution_mode="guess"
    return 0
  fi

  return 1
}

materialize_installable() {
  local target="$1"

  resolve_target "$target" || return 1

  if ! load_cached_materialization "$resolved_installable"; then
    [ -d "$BRIDGE_DIR" ] || {
      echo "[agent] nix helper bridge is unavailable at $BRIDGE_DIR" >&2
      exit 1
    }
    helper_request "$resolved_installable"
    load_helper_response "$resolved_installable"
    store_cached_materialization "$resolved_installable"
  fi
}

lookup_guidance() {
  local command_name="$1"
  shift || true

  local project_file=""
  local best_attr=""
  local -a candidates=()
  local example=""

  example="$(render_command_example "$command_name" "$@")"

  if mapfile -t candidates < <(sorted_candidates "$command_name" || true) && [ "${#candidates[@]}" -gt 0 ]; then
    best_attr="${candidates[0]%.out}"
    {
      echo "The program '$command_name' is not currently available in this sandbox."
      echo
      echo "Best match in nixpkgs:"
      echo "  $best_attr"

      if [ "${#candidates[@]}" -gt 1 ]; then
        local extra=""
        echo
        echo "Other matches:"
        for extra in "${candidates[@]:1:4}"; do
          echo "  $extra"
        done
      fi

      echo
      echo "Run once in this sandbox:"
      echo "  need run $command_name -- $example"
      echo
      echo "Make it available in this sandbox:"
      echo "  need inject $command_name"

      project_file="$(project_nix_file || true)"
      echo
      echo "Project-level fix:"
      if [ -n "$project_file" ]; then
        echo "  add \`$(render_pkgs_attr_expr "$best_attr")\` to $(display_path "$project_file")"
      else
        echo "  no project nix file detected; consider adding \`$(render_pkgs_attr_expr "$best_attr")\` to ./flake.nix"
      fi
    } >&2
    return 0
  fi

  if resolve_target "$command_name"; then
    ensure_index_bootstrap || true
    {
      case "$INDEX_BOOTSTRAP_STATE" in
        started)
          echo "The nix command index is bootstrapping in the background."
          echo "Try this command again in a few seconds."
          echo "Bootstrap log: $BOOTSTRAP_LOG_FILE"
          ;;
        running)
          echo "The nix command index is still bootstrapping in the background."
          echo "Try this command again in a few seconds."
          echo "Bootstrap log: $BOOTSTRAP_LOG_FILE"
          ;;
        disabled)
          echo "The nix command index is not available in this sandbox."
          echo "Run 'need update-index' for exact package lookup."
          ;;
        *)
          echo "The nix command index is not available in this sandbox."
          echo "Run 'need update-index' for exact package lookup."
          ;;
      esac
      echo
      echo "Best-effort guess:"
      echo "  ${resolved_installable#nixpkgs#}"
      echo
      echo "Run once in this sandbox:"
      echo "  need run $command_name -- $example"
      echo
      echo "Make it available in this sandbox:"
      echo "  need inject $command_name"
    } >&2
    return 0
  fi

  {
    echo "The program '$command_name' was not found in nixpkgs."
    if ! index_available; then
      echo "Run 'need update-index' if you want exact package lookup."
    fi
  } >&2
  return 1
}

inject_materialized_bins() {
  local entry=""
  local target_path=""

  [ -n "$bin_path" ] || {
    echo "[agent] $resolved_installable does not expose a bin directory" >&2
    exit 1
  }

  mkdir -p "$TOOLS_DIR"
  for entry in "$bin_path"/*; do
    [ -e "$entry" ] || continue
    [ -x "$entry" ] || continue
    target_path="$TOOLS_DIR/$(basename "$entry")"
    ln -sfn "$entry" "$target_path"
  done

  tool_notice "injected executables from $resolved_installable into $TOOLS_DIR"
}

update_index() {
  local system=""
  local url=""
  local tmp_file=""

  trap 'rm -rf "$BOOTSTRAP_LOCK_DIR" "$BOOTSTRAP_PID_FILE"' EXIT

  system="$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]')"
  url="${AGENT_NEED_INDEX_URL:-https://github.com/nix-community/nix-index-database/releases/latest/download/index-$system}"

  mkdir -p "$INDEX_DIR"
  tmp_file="$(mktemp "$INDEX_DIR/files.tmp.XXXXXX")"
  tool_notice "downloading nix command index for $system..."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp_file"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_file" "$url"
  else
    rm -f "$tmp_file"
    echo "[agent] neither curl nor wget is available to download the nix command index" >&2
    exit 1
  fi

  mv -f "$tmp_file" "$INDEX_FILE"
  tool_notice "updated nix command index at $INDEX_FILE"
}

command_name="${1:-}"
shift || true

case "$command_name" in
  "")
    usage
    ;;
  bootstrap-index)
    [ "$#" -eq 0 ] || usage
    ensure_index_bootstrap >/dev/null 2>&1 || true
    ;;
  update-index)
    [ "$#" -eq 0 ] || usage
    update_index
    ;;
  materialize)
    [ "$#" -eq 1 ] || usage
    materialize_installable "$1"
    if [ -n "$bin_path" ]; then
      printf '%s\n' "$bin_path"
    else
      printf '%s\n' "$out_path"
    fi
    ;;
  lookup)
    [ "$#" -ge 1 ] || usage
    lookup_guidance "$@"
    ;;
  missing)
    [ "$#" -ge 1 ] || usage
    lookup_guidance "$@" || true
    exit 127
    ;;
  run)
    [ "$#" -ge 2 ] || usage
    target="$1"
    shift
    [ "$1" = "--" ] || usage
    shift
    [ "$#" -ge 1 ] || usage
    materialize_installable "$target"
    if [ -n "$bin_path" ]; then
      PATH="$bin_path:$PATH" exec "$@"
    fi
    exec "$@"
    ;;
  inject)
    [ "$#" -eq 1 ] || usage
    materialize_installable "$1"
    inject_materialized_bins
    ;;
  *)
    lookup_guidance "$command_name" "$@"
    ;;
esac
