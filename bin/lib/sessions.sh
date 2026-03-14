SESSIONS_OUTPUT="text"
SESSIONS_ALL="0"
SESSIONS_TOOL=""
SESSIONS_CONFIG_MODE=""

resolve_sessions_args() {
  SESSIONS_OUTPUT="text"
  SESSIONS_ALL="0"
  SESSIONS_TOOL=""

  [ "$#" -ge 1 ] || {
    echo "usage: agent sessions codex [--all] [--json]" >&2
    exit 1
  }

  SESSIONS_TOOL="$1"
  shift

  case "$SESSIONS_TOOL" in
    codex) ;;
    *)
      echo "[agent] sessions is currently only implemented for codex" >&2
      exit 1
      ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all)
        SESSIONS_ALL="1"
        ;;
      --json)
        SESSIONS_OUTPUT="json"
        ;;
      *)
        echo "usage: agent sessions codex [--all] [--json]" >&2
        exit 1
        ;;
    esac
    shift
  done
}

session_matches_scope() {
  local session_cwd="$1"

  if [ "$SESSIONS_CONFIG_MODE" = "project" ]; then
    return 0
  fi

  [ -n "$session_cwd" ] || return 1
  [ -n "${PROJECT_ROOT:-}" ] || return 1

  case "$session_cwd" in
    "$PROJECT_ROOT"|"$PROJECT_ROOT"/*|/workspace|/workspace/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

session_stream() {
  local session_file="$1"

  case "$session_file" in
    *.zst)
      if command -v zstdcat >/dev/null 2>&1; then
        zstdcat -- "$session_file" 2>/dev/null
      elif command -v zstd >/dev/null 2>&1; then
        zstd -dc -- "$session_file" 2>/dev/null
      else
        return 1
      fi
      ;;
    *)
      cat -- "$session_file" 2>/dev/null
      ;;
  esac
}

session_meta_fields() {
  local session_file="$1"

  session_stream "$session_file" | jq -r '
    def meta:
      if .type? == "session_meta" then {
        id: (.payload.id // .id // ""),
        cwd: (.payload.cwd // .cwd // ""),
        created_at: (.payload.timestamp // .timestamp // ""),
        git_branch: (.payload.git.branch // .git.branch // ""),
        cli_version: (.payload.cli_version // .cli_version // "")
      }
      elif .item.type? == "session_meta" then {
        id: (.item.payload.id // .item.id // ""),
        cwd: (.item.payload.cwd // .item.cwd // ""),
        created_at: (.item.payload.timestamp // .item.timestamp // .timestamp // ""),
        git_branch: (.item.payload.git.branch // .item.git.branch // .git.branch // ""),
        cli_version: (.item.payload.cli_version // .item.cli_version // "")
      }
      elif .item.SessionMeta? then {
        id: (.item.SessionMeta.id // ""),
        cwd: (.item.SessionMeta.cwd // ""),
        created_at: (.item.SessionMeta.timestamp // .timestamp // ""),
        git_branch: (.git.branch // .item.git.branch // ""),
        cli_version: (.item.SessionMeta.cli_version // "")
      }
      else empty
      end;

    meta
    | select(.id != "" or .cwd != "")
    | [ .id, .cwd, .created_at, .git_branch, .cli_version ]
    | @tsv
  ' 2>/dev/null | head -n 1
}

collect_codex_sessions() {
  local sessions_dir="$1"
  local session_file=""
  local record=""
  local session_id=""
  local session_cwd=""
  local session_timestamp=""
  local session_branch=""
  local session_cli_version=""

  [ -d "$sessions_dir" ] || return 0

  while IFS= read -r session_file; do
    record="$(session_meta_fields "$session_file" || true)"
    [ -n "$record" ] || continue

    IFS=$'\t' read -r session_id session_cwd session_timestamp session_branch session_cli_version <<EOF
$record
EOF

    if [ "$SESSIONS_ALL" != "1" ] && ! session_matches_scope "$session_cwd"; then
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$session_timestamp" \
      "$session_id" \
      "$session_cwd" \
      "$session_branch" \
      "$session_cli_version" \
      "$session_file"
  done < <(
    find "$sessions_dir" \
      -type f \
      \( -name '*.jsonl' -o -name '*.jsonl.zst' \) \
      ! -path '*/archived/*' \
      -print 2>/dev/null | sort
  )
}

print_sessions_text() {
  local config_summary="$1"
  local scope_summary="$2"
  local session_rows="$3"
  local count="$4"

  printf 'Agent Sessions\n\n'
  doctor_line "tool" "$SESSIONS_TOOL"
  doctor_line "config" "$config_summary"
  doctor_line "project_root" "$PROJECT_ROOT"
  doctor_line "scope" "$scope_summary"
  doctor_line "count" "$count"

  if [ "$count" = "0" ]; then
    printf '\nNo sessions found.\n'
    return 0
  fi

  printf '\nSessions\n'
  printf '%-36s  %-20s  %-12s  %s\n' "id" "timestamp" "branch" "cwd"
  printf '%s\n' "$session_rows" | while IFS=$'\t' read -r session_timestamp session_id session_cwd session_branch session_cli_version session_file; do
    [ -n "$session_id" ] || continue
    printf '%-36s  %-20s  %-12s  %s\n' \
      "$session_id" \
      "${session_timestamp%%.*}" \
      "${session_branch:--}" \
      "$session_cwd"
  done
}

print_sessions_json() {
  local config_mode="$1"
  local config_selector="$2"
  local config_root="$3"
  local session_rows="$4"

  printf '{\n'
  printf '  "tool": "%s",\n' "$SESSIONS_TOOL"
  printf '  "config": {\n'
  printf '    "mode": "%s",\n' "$config_mode"
  printf '    "selector": "%s",\n' "$config_selector"
  printf '    "root": "%s"\n' "$config_root"
  printf '  },\n'
  printf '  "project_root": "%s",\n' "$PROJECT_ROOT"
  printf '  "all": %s,\n' "$( [ "$SESSIONS_ALL" = "1" ] && printf 'true' || printf 'false' )"
  printf '  "sessions": [\n'
  if [ -n "$session_rows" ]; then
    printf '%s\n' "$session_rows" | while IFS=$'\t' read -r session_timestamp session_id session_cwd session_branch session_cli_version session_file; do
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

print_sessions_and_exit() {
  local sessions_dir=""
  local config_summary=""
  local config_mode=""
  local config_selector=""
  local config_root=""
  local scope_summary=""
  local session_rows=""
  local count="0"

  resolve_project_paths
  load_project_config
  resolve_host_home
  resolve_tool_config_roots

  case "$SESSIONS_TOOL" in
    codex)
      config_mode="$CODEX_CONFIG_MODE"
      config_selector="$CODEX_CONFIG_SELECTOR"
      config_root="$CODEX_HOST_CONFIG"
      sessions_dir="$CODEX_HOST_CONFIG/sessions"
      ;;
  esac
  SESSIONS_CONFIG_MODE="$config_mode"

  case "$config_mode" in
    fresh)
      config_summary="fresh (new config dir each run)"
      ;;
    *)
      config_summary="${config_selector:-$config_mode} (${config_root:-unset})"
      ;;
  esac

  if [ "$SESSIONS_ALL" = "1" ]; then
    scope_summary="all sessions in config root"
  elif [ "$config_mode" = "project" ]; then
    scope_summary="all sessions in project config root"
  else
    scope_summary="sessions visible from current cwd"
  fi

  if [ "$config_mode" != "fresh" ] && [ -d "$sessions_dir" ]; then
    session_rows="$(collect_codex_sessions "$sessions_dir")"
    if [ -n "$session_rows" ]; then
      count="$(printf '%s\n' "$session_rows" | sed '/^$/d' | wc -l | tr -d ' ')"
    fi
  fi

  if [ "$SESSIONS_OUTPUT" = "json" ]; then
    print_sessions_json "$config_mode" "$config_selector" "$config_root" "$session_rows"
  else
    print_sessions_text "$config_summary" "$scope_summary" "$session_rows" "$count"
  fi

  exit 0
}
