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

render_project_config_template() {
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

# Optional tool profiles:
# CODEX_PROFILE=work
# CLAUDE_PROFILE=work
# OPENCODE_PROFILE=work

# Optional tool allowlist:
# AGENT_TOOLS="codex claude opencode"
EOF
}

print_init_and_exit() {
  local target_file=""

  resolve_project_paths
  resolve_project_config_file

  if [ -n "${PROJECT_CONFIG_FILE:-}" ] && [ "$PROJECT_CONFIG_FILE" = "$PROJECT_NIX_DIR/agent-sandbox.env" ]; then
    target_file="$PROJECT_CONFIG_FILE"
  elif [ -n "${PROJECT_CONFIG_FILE:-}" ] && [ -f "$PROJECT_CONFIG_FILE" ]; then
    target_file="$PROJECT_CONFIG_FILE"
  else
    target_file="$PROJECT_NIX_DIR/agent-sandbox.env"
  fi

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
