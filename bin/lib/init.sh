resolve_init_args() {
  INIT_FORCE="0"
  INIT_STDOUT="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        INIT_FORCE="1"
        ;;
      --stdout)
        INIT_STDOUT="1"
        ;;
      *)
        echo "usage: agent init [--force] [--stdout]" >&2
        exit 1
        ;;
    esac
    shift
  done
}

list_named_json_slots() {
  local slot_base="$1"
  local slot_file=""

  [ -d "$slot_base" ] || return 0

  for slot_file in "$slot_base"/*.json; do
    [ -f "$slot_file" ] || continue
    basename "$slot_file" .json
  done
}

render_auth_setting() {
  local env_name="$1"
  local auth_base="$2"
  local count=0
  local first=""
  local slots=""
  local detected=""

  [ -d "$auth_base" ] || return 0

  slots="$(list_named_json_slots "$auth_base")"
  while IFS= read -r detected; do
    [ -n "$detected" ] || continue
    count=$((count + 1))
    if [ -z "$first" ]; then
      first="$detected"
    fi
  done <<EOF
$slots
EOF

  if [ "$count" -eq 1 ]; then
    printf '%s=%s\n' "$env_name" "$first"
    return 0
  fi

  if [ "$count" -gt 1 ]; then
    printf '# %s=<choose one of: %s>\n' "$env_name" "$(printf '%s\n' "$slots" | paste -sd ',' - | sed 's/,/, /g')"
    return 0
  fi

  printf '# %s=work\n' "$env_name"
}

render_tool_allowlist_setting() {
  local detected_tools=""
  local count=0

  if [ -d "$CODEX_HOST_CONFIG" ] || [ -d "$CODEX_AUTH_BASE" ] || [ -d "$CODEX_CONFIG_PROJECT_PATH" ]; then
    detected_tools="${detected_tools:+$detected_tools }codex"
    count=$((count + 1))
  fi

  if [ -d "$CLAUDE_HOST_CONFIG" ] || [ -d "$CLAUDE_AUTH_BASE" ] || [ -d "$CLAUDE_CONFIG_PROJECT_PATH" ]; then
    detected_tools="${detected_tools:+$detected_tools }claude"
    count=$((count + 1))
  fi

  if [ -d "$OPENCODE_HOST_CONFIG" ] || [ -d "$OPENCODE_AUTH_BASE" ] || [ -d "$OPENCODE_CONFIG_PROJECT_PATH" ]; then
    detected_tools="${detected_tools:+$detected_tools }opencode"
    count=$((count + 1))
  fi

  if [ -d "$OMP_HOST_CONFIG" ]; then
    detected_tools="${detected_tools:+$detected_tools }omp"
    count=$((count + 1))
  fi

  if { [ -d "$CODEX_HOST_CONFIG" ] || [ -d "$CODEX_AUTH_BASE" ] || [ -d "$CODEX_CONFIG_PROJECT_PATH" ]; } \
    && { [ -d "$CLAUDE_HOST_CONFIG" ] || [ -d "$CLAUDE_AUTH_BASE" ] || [ -d "$CLAUDE_CONFIG_PROJECT_PATH" ]; } \
    && { [ -d "$OPENCODE_HOST_CONFIG" ] || [ -d "$OPENCODE_AUTH_BASE" ] || [ -d "$OPENCODE_CONFIG_PROJECT_PATH" ]; }
  then
    detected_tools="${detected_tools:+$detected_tools }codemachine"
  fi

  if [ -n "$detected_tools" ]; then
    printf '# AGENT_TOOLS="%s"\n' "$detected_tools"
  else
    printf '# AGENT_TOOLS="codex claude opencode"\n'
  fi
}

render_config_setting() {
  local env_name="$1"
  local project_path="$2"

  if [ -d "$project_path" ]; then
    printf '%s=project\n' "$env_name"
  else
    printf '# %s=host\n' "$env_name"
  fi
}

render_project_config_template() {
  local auth_lines=""
  local config_lines=""

  cat <<'EOF'
# Agent Sandbox project defaults
#
# This file is optional. Values here behave like default environment variables
# for this project only. Real environment variables still win.

# Prefer the safer high-level mode. This becomes podman-session when host
# Podman is usable and otherwise falls back to none.
AGENT_CONTAINER_API=auto

# Keep the narrow host-backed tool materialization path enabled.
AGENT_NIX_TOOL_HELPER=1

# Keep the host direnv snapshot helper enabled when the project uses .envrc.
AGENT_DEV_ENV=host-helper

EOF

  config_lines="$(
    {
      render_config_setting "CODEX_CONFIG" "$CODEX_CONFIG_PROJECT_PATH"
      render_config_setting "CLAUDE_CONFIG" "$CLAUDE_CONFIG_PROJECT_PATH"
      render_config_setting "OPENCODE_CONFIG" "$OPENCODE_CONFIG_PROJECT_PATH"
    } | sed '/^$/d'
  )"

  printf '\n# Optional config scope:\n'
  printf '%s\n' "$config_lines"

  cat <<'EOF'
# Use CODEX_CONFIG=fresh for an isolated one-off config dir.
# Use CODEX_CONFIG=/some/path to point at another host config directory.
EOF

  auth_lines="$(
    {
      render_auth_setting "CODEX_AUTH" "$CODEX_AUTH_BASE"
      render_auth_setting "CLAUDE_AUTH" "$CLAUDE_AUTH_BASE"
      render_auth_setting "OPENCODE_AUTH" "$OPENCODE_AUTH_BASE"
    } | sed '/^$/d'
  )"

  printf '\n# Optional named credential slots or explicit credential file paths:\n'
  if [ -n "$auth_lines" ]; then
    printf '%s\n' "$auth_lines"
  else
    printf '# CODEX_AUTH=work\n'
    printf '# CLAUDE_AUTH=work\n'
    printf '# OPENCODE_AUTH=work\n'
  fi

  cat <<'EOF'
# Create a fresh named Codex login with:
# agent login codex work
# agent login codex work --config project
EOF

  cat <<'EOF'

# Optional tool allowlist:
EOF
  render_tool_allowlist_setting
}

resolve_project_config_target_file() {
  if [ -n "${PROJECT_CONFIG_FILE:-}" ] && [ "$PROJECT_CONFIG_FILE" = "$PROJECT_ROOT/.agent-sandbox.env" ]; then
    printf '%s\n' "$PROJECT_CONFIG_FILE"
  elif [ -n "${PROJECT_CONFIG_FILE:-}" ] && [ -f "$PROJECT_CONFIG_FILE" ]; then
    printf '%s\n' "$PROJECT_CONFIG_FILE"
  else
    printf '%s\n' "$PROJECT_ROOT/.agent-sandbox.env"
  fi
}

print_init_and_exit() {
  local target_file=""

  resolve_project_paths
  resolve_project_config_file
  resolve_host_home
  resolve_tool_config_roots

  target_file="$(resolve_project_config_target_file)"

  if [ "$INIT_STDOUT" = "1" ]; then
    render_project_config_template
    exit 0
  fi

  if [ -e "$target_file" ] && [ "$INIT_FORCE" != "1" ]; then
    echo "[agent] config file already exists: $target_file" >&2
    echo "[agent] use 'agent init --force' to overwrite it or 'agent doctor' to inspect current state" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$target_file")"
  render_project_config_template > "$target_file"
  echo "[agent] wrote project defaults: $target_file" >&2
  exit 0
}
